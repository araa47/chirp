package dev.chirp.android

import android.Manifest
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import androidx.core.net.toUri
import android.os.Bundle
import android.provider.Settings
import android.view.inputmethod.InputMethodManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LifecycleStartEffect
import androidx.lifecycle.lifecycleScope
import dev.chirp.android.shell.AppShell
import dev.chirp.android.shell.HistoryScreen
import dev.chirp.android.shell.HomeFix
import dev.chirp.android.shell.ShellTab
import dev.chirp.android.settings.SettingsActions
import dev.chirp.android.settings.SettingsPage
import dev.chirp.android.settings.SettingsScreen
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal class SetupState {
    /** The onboarding page (`PAGE_*`). */
    var step by mutableIntStateOf(PAGE_WELCOME)
    /** The page onboarding opened on: back stops here instead of walking through pages the entry skipped. */
    var entryStep by mutableIntStateOf(PAGE_WELCOME)
    var micDenied by mutableStateOf(false)
    /** A pairing was tested and saved in this onboarding run; the pair page shows it instead of the scanner. */
    var connected by mutableStateOf(false)
    var pairIssue by mutableStateOf<PairIssue?>(null)
    /** Home opens with the first-run "Try it" card on top. */
    var tryIt by mutableStateOf(false)
    var wifiPermissionNeeded by mutableStateOf(false)
    var localNetwork by mutableStateOf(android.os.Build.VERSION.SDK_INT < 37)
    var mic by mutableStateOf(false)
    var inputEnabled by mutableStateOf(false)
    var bubbleEnabled by mutableStateOf(false)
    var inputMode by mutableStateOf<InputMode?>(null)
    var keyboardLabel by mutableStateOf<String?>(null)
    var floatingMicSkipped by mutableStateOf(false)
    var advancedProtection by mutableStateOf(false)
    var accessibilityReturns by mutableIntStateOf(0)
    var inputSelected by mutableStateOf(false)
    var diagnostics by mutableStateOf("No crashes recorded")
    var paired by mutableStateOf(false)
    var status by mutableStateOf<UiText>(UiText.Res(R.string.setup_status_initial))
    var checking by mutableStateOf(false)
    var scanning by mutableStateOf(false)
    var link by mutableStateOf("")
    var host by mutableStateOf("")
    var health by mutableStateOf<Health?>(null)
    /** Result of the last Mac check: null until one finishes. */
    var reachable by mutableStateOf<Boolean?>(null)
    /** Classification of the last failed Mac check, as the keyboard words it. */
    var failure by mutableStateOf<ConnectionFailure.Kind?>(null)
    /** Paired over the tailnet while no VPN is up: the Mac can't be reached until Tailscale is on. */
    var tailscaleOff by mutableStateOf(false)
    /** The app shell (Notes · History · Settings) is showing; otherwise onboarding. */
    var shellOpen by mutableStateOf(false)
    var tab by mutableStateOf(ShellTab.Notes)
    /** The shell was opened from outside (the keyboard, a recovery link): Back returns there rather than to Notes. */
    var exitOnBack by mutableStateOf(false)
    /** The pair page was opened from the shell: Back returns to it. */
    var pairFromShell by mutableStateOf(false)
    var settingsPage by mutableStateOf<SettingsPage?>(null)
    /** Bumped to make the Settings tab open [settingsPage] even if it was showing another page. */
    var settingsRequest by mutableIntStateOf(0)
    /** The History entry open in its detail sheet or pane. */
    var historyEntry by mutableStateOf<String?>(null)
}

open class SetupActivity : ComponentActivity(), AppShortcutHost {
    override val appShortcuts = AppShortcuts()
    @android.annotation.SuppressLint("RestrictedApi") // Override of the public Activity callback, forwarded by AndroidX.
    override fun dispatchKeyEvent(event: android.view.KeyEvent): Boolean = appShortcuts.dispatch(event) || super.dispatchKeyEvent(event)
    override fun onKeyShortcut(keyCode: Int, event: android.view.KeyEvent): Boolean = appShortcuts.dispatch(event) || super.onKeyShortcut(keyCode, event)
    override fun onProvideKeyboardShortcuts(groups: MutableList<android.view.KeyboardShortcutGroup>, menu: android.view.Menu?, deviceId: Int) {
        super.onProvideKeyboardShortcuts(groups, menu, deviceId)
        appShortcuts.provide(groups)
    }
    private lateinit var store: SettingsStore
    internal val state = SetupState()
    private var awaitingPrerequisite = false
    private var awaitingAccessibility = false
    internal open val advancedProtection: AdvancedProtection by lazy { AndroidAdvancedProtection(this) }
    private var pairingGeneration = 0
    private var pendingHealth: okhttp3.Call? = null
    private val client by lazy { ChirpNetwork.client(this) }
    private var pendingNetworkTest: Boolean? = null
    internal open val tailscale: TailscaleControl by lazy { AndroidTailscale(this) }
    private var vpnWatch: AutoCloseable? = null
    /** The Notes tab's session, shared with [NotesActivity]; created the first time the tab shows. */
    private val notes by lazy { NotesSessionHolder.model(this) { NotesModel(applicationContext) } }
    private val notesHost = NotesHost(this, { tailscale }, { notes })
    private val networkPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        state.localNetwork = granted
        val pending = pendingNetworkTest; pendingNetworkTest = null
        if (granted && pending != null) testPairing(pending)
        else state.status = UiText.Res(if (granted) R.string.setup_status_wifi_allowed else R.string.setup_status_wifi_denied)
    }
    private val micPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) {
        state.mic = it; state.micDenied = !it
        if (it && !state.shellOpen) advance()
        state.status = UiText.Res(if (it) R.string.setup_status_mic_granted else R.string.setup_status_mic_needed)
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        store = SettingsStore(this)
        // Keep dictated text, history and notes out of the Recents thumbnail.
        if (android.os.Build.VERSION.SDK_INT >= 33) setRecentsScreenshotEnabled(false)
        state.step = savedInstanceState?.getInt("step", 0)?.coerceIn(PAGE_WELCOME, PAGE_PAIR) ?: PAGE_WELCOME
        savedInstanceState?.let {
            state.entryStep = it.getInt("entry", 0).coerceIn(PAGE_WELCOME, PAGE_PAIR); state.connected = it.getBoolean("connected"); state.tryIt = it.getBoolean("try_it")
            state.shellOpen = it.getBoolean("shell"); state.exitOnBack = it.getBoolean("exit_on_back"); state.pairFromShell = it.getBoolean("pair_from_shell")
            state.tab = ShellTab.entries.firstOrNull { tab -> tab.name == it.getString("tab") } ?: ShellTab.Notes
            state.settingsPage = it.getString("settings_page")?.let { name -> SettingsPage.entries.firstOrNull { page -> page.name == name } }
        }
        state.accessibilityReturns = savedInstanceState?.getInt("accessibility_returns") ?: 0
        awaitingAccessibility = savedInstanceState?.getBoolean("awaiting_accessibility") ?: false
        awaitingPrerequisite = savedInstanceState?.getBoolean("awaiting_prerequisite") ?: false
        refresh()
        if (savedInstanceState == null) {
            val first = setupStep(state.inputEnabled, state.inputSelected, state.mic, state.paired, welcomed = false, mode = state.inputMode, bubbleEnabled = state.bubbleEnabled, floatingMicSkipped = state.floatingMicSkipped)
            if (store.onboarded || first == ONBOARDING_DONE) finishOnboarding() else { state.step = first; state.entryStep = first }
        }
        consumeSection(intent)
        setContent {
            ChirpTheme {
                if (state.shellOpen) Shell()
                else {
                    BackHandler(enabled = state.pairFromShell) { state.pairFromShell = false; state.shellOpen = true }
                    Onboarding(state, OnboardingActions(
                        grantMic = {
                            if (state.mic) state.status = UiText.Res(R.string.setup_status_mic_already)
                            else micPermission.launch(Manifest.permission.RECORD_AUDIO)
                        },
                        keyboardSettings = { awaitingPrerequisite = true; startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS)) },
                        appSettings = ::openAppSettings,
                        picker = { awaitingPrerequisite = true; getSystemService(InputMethodManager::class.java).showInputMethodPicker() },
                        grantNetwork = { networkPermission.launch(LOCAL_NETWORK_PERMISSION) },
                        scan = ::scan, pasteLink = ::editLink, retry = { if (state.link.isBlank()) scan() else testPairing(save = true) },
                        openTailscale = { tailscale.open() }, finish = ::advance,
                        chooseMode = ::chooseMode, accessibility = ::openAccessibility, skipFloatingMic = {
                            store.floatingMicSkipped = true; state.floatingMicSkipped = true; advance()
                        },
                        skipPairing = ::finishOnboarding,
                    ))
                }
            }
        }
        consumePairingIntent(intent)
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        consumeSection(intent); consumePairingIntent(intent)
    }

    @Composable
    private fun Shell() {
        AppShortcutActions(
            AppCommand.Notes to { selectTab(ShellTab.Notes); true },
            AppCommand.History to { selectTab(ShellTab.History); true },
            AppCommand.Settings to { selectTab(ShellTab.Settings); true },
        )
        AppShell(state.tab, ::selectTab, state.exitOnBack) { tab ->
            when (tab) {
                ShellTab.Notes -> {
                    LifecycleStartEffect(notes) { NotesSessionHolder.visible(notes, this@SetupActivity, true); notes.refresh()
                        onStopOrDispose { NotesSessionHolder.visible(notes, this@SetupActivity, false) } }
                    NotesLibraryScreen(notes, NotesSessionHolder.reader(this@SetupActivity),
                        record = { id -> if (id == null) notesHost.recordNew() else notesHost.continueNote(id) },
                        copy = { notesHost.copy(it) }, share = { notesHost.share(it) }, save = { notesHost.save(it) }, act = notesHost::act,
                        state = state, connection = { openSettings(SettingsPage.Connection, outside = false) },
                        dictate = { startActivity(Intent(this, ScratchpadActivity::class.java)) })
                }
                ShellTab.History -> HistoryScreen(selected = state.historyEntry, select = { state.historyEntry = it })
                ShellTab.Settings -> key(state.settingsRequest) {
                    SettingsScreen(state, SettingsActions(
                        checkConnection = { testPairing(save = false) },
                        changePairing = ::openPairing,
                        forgetPairing = ::forgetPairing,
                        allowWifi = { networkPermission.launch(LOCAL_NETWORK_PERMISSION) },
                        floatingMicSettings = ::openAccessibility,
                        chooseMode = ::chooseMode, picker = ::chooseKeyboard, appSettings = ::openAppSettings,
                        keyboardSettings = { awaitingPrerequisite = true; startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS)) },
                        keyboardPreferences = ::openKeyboardPreferences,
                        openTailscale = if (tailscale.installed()) ({ tailscale.open() }) else null,
                    ), initialPage = state.settingsPage)
                }
            }
        }
    }
    /** A tab picked in the bar or rail, or from Notes: from here Back goes to Notes as usual. */
    private fun selectTab(tab: ShellTab) { state.exitOnBack = false; state.tab = tab }
    /** Home's connection card: the one fix for what it shows. */
    internal fun fix(fix: HomeFix) {
        when (fix) {
            HomeFix.Pair -> openPairing()
            HomeFix.Microphone -> if (state.micDenied) openAppSettings() else micPermission.launch(Manifest.permission.RECORD_AUDIO)
            HomeFix.TailscaleOn -> if (tailscale.connect()) state.status = UiText.Res(R.string.setup_status_connecting_tailscale) else if (!tailscale.open()) openSettings(SettingsPage.Connection, outside = false)
            HomeFix.Retry -> testPairing(save = false)
        }
    }
    internal fun chooseMode(mode: InputMode) {
        store.inputMode = mode; state.inputMode = mode
        if (mode == InputMode.OWN_KEYBOARD) { store.floatingMicSkipped = false; state.floatingMicSkipped = false }
    }
    private fun chooseKeyboard() { awaitingPrerequisite = true; getSystemService(InputMethodManager::class.java).showInputMethodPicker() }
    internal fun openAccessibility() {
        if (advancedProtection.enabled()) { state.advancedProtection = true; return }
        awaitingAccessibility = true; awaitingPrerequisite = true
        openAccessibilitySettings(this)
    }
    private fun openAppSettings() { awaitingPrerequisite = true; startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, "package:$packageName".toUri())) }
    private fun openKeyboardPreferences() = startActivity(Intent(this, helium314.keyboard.settings.SettingsActivity::class.java))
    private fun forgetPairing() {
        ++pairingGeneration; ChirpNetwork.cancel(pendingHealth); pendingHealth = null
        store.forget(); state.link = ""; state.status = UiText.Res(R.string.setup_status_pairing_removed); state.checking = false; state.reachable = null; state.failure = null; state.connected = false; refresh()
    }
    /** Onboarding is complete (now or on an earlier run): open Notes, with the first-run "Try it" card until it's dismissed. */
    private fun finishOnboarding() {
        store.onboarded = true; state.tryIt = !store.tryItDismissed; state.settingsPage = null; open(ShellTab.Notes, outside = false)
    }
    /** Moves to the first page whose requirement isn't met, or finishes. Never back to the welcome page once past it. */
    internal fun advance() {
        val next = setupStep(state.inputEnabled, state.inputSelected, state.mic, state.paired, welcomed = state.step > PAGE_WELCOME, mode = state.inputMode, bubbleEnabled = state.bubbleEnabled, floatingMicSkipped = state.floatingMicSkipped)
        if (next == ONBOARDING_DONE) finishOnboarding() else state.step = next
    }
    /** Opens the pair page on its own: from the shell (Pair Mac, Change pairing), a pairing link or a recovery action. Back leaves it. */
    private fun openPairing() {
        if (state.shellOpen) { state.entryStep = PAGE_PAIR; state.pairFromShell = true }
        state.shellOpen = false; state.step = PAGE_PAIR; state.connected = false; state.pairIssue = null
    }
    private fun open(tab: ShellTab, outside: Boolean) { state.tab = tab; state.exitOnBack = outside; state.pairFromShell = false; state.shellOpen = true }
    private fun openSettings(page: SettingsPage?, outside: Boolean = true) { state.settingsPage = page; state.settingsRequest++; open(ShellTab.Settings, outside) }
    private fun consumeSection(source: Intent) {
        val section = source.getStringExtra("section")
        source.removeExtra("section")
        when (section) {
            "pair" -> openPairing()
            "microphone" -> fix(HomeFix.Microphone)
            "settings" -> openSettings(null)
            "input" -> openSettings(SettingsPage.HowYouDictate, outside = false)
            "try" -> { state.tryIt = true; open(ShellTab.Notes, outside = false) }
            "connection" -> openSettings(SettingsPage.Connection)
            "network" -> { state.reachable = false; openSettings(SettingsPage.Connection) }
            "history" -> { state.historyEntry = null; open(ShellTab.History, outside = true) }
        }
    }
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && awaitingPrerequisite && ::store.isInitialized) {
            refresh()
            if (awaitingAccessibility) {
                awaitingAccessibility = false
                if (!state.bubbleEnabled) state.accessibilityReturns++
            }
            if (!state.shellOpen && (state.step != PAGE_KEYBOARD || state.inputMode != InputMode.OWN_KEYBOARD || state.bubbleEnabled)) advance()
            awaitingPrerequisite = false
        }
    }
    private fun consumePairingIntent(source: Intent) {
        val value = source.dataString
        source.data = null
        if (value != null) receivePairingLink(value)
    }
    /** A scanned code or opened link: test it and save it, with no further tap. The token reaches prefs only after the Mac answers. */
    private fun receivePairingLink(value: String?) {
        try {
            Pairing.parse(value ?: error("Missing pairing link"))
            ++pairingGeneration; ChirpNetwork.cancel(pendingHealth); pendingHealth = null; state.checking = false
            state.link = value.orEmpty(); openPairing()
            testPairing(save = true)
        } catch (_: Exception) { state.status = UiText.Res(R.string.setup_status_invalid_link); state.pairIssue = PairIssue.InvalidLink }
    }
    /** The paste field: a pasted link that parses is tested and saved straight away. */
    internal fun editLink(value: String) {
        state.link = value; state.pairIssue = null
        if (runCatching { Pairing.parse(value) }.isSuccess) testPairing(save = true)
    }
    internal fun scan() {
        state.scanning = true; state.pairIssue = null
        scanPairingQr(
            received = { if (!isDestroyed) { state.scanning = false; receivePairingLink(it) } },
            cancelled = { if (!isDestroyed) { state.scanning = false; state.status = UiText.Res(R.string.setup_status_scan_cancelled) } },
            failed = { if (!isDestroyed) { state.scanning = false; state.pairIssue = PairIssue.ScannerUnavailable
                state.status = UiText.Res(R.string.setup_status_scanner_unavailable) } },
        )
    }
    protected open fun scanPairingQr(received: (String?) -> Unit, cancelled: () -> Unit, failed: () -> Unit) {
        val options = GmsBarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()
        GmsBarcodeScanning.getClient(this, options).startScan()
            .addOnSuccessListener { received(it.rawValue) }
            .addOnCanceledListener { cancelled() }
            .addOnFailureListener { failed() }
    }
    override fun onResume() {
        super.onResume()
        if (::store.isInitialized) { refresh();
            if (!state.shellOpen && state.step == PAGE_KEYBOARD && state.inputMode == InputMode.OWN_KEYBOARD && state.bubbleEnabled) advance()
            if (state.paired && state.link.isBlank()) testPairing(save = false, requestPermission = false) }
    }
    override fun onSaveInstanceState(outState: Bundle) {
        outState.putInt("step", state.step); outState.putInt("entry", state.entryStep); outState.putBoolean("connected", state.connected)
        outState.putBoolean("try_it", state.tryIt); outState.putBoolean("shell", state.shellOpen); outState.putBoolean("exit_on_back", state.exitOnBack)
        outState.putBoolean("pair_from_shell", state.pairFromShell); outState.putString("tab", state.tab.name)
        outState.putString("settings_page", state.settingsPage?.name)
        outState.putInt("accessibility_returns", state.accessibilityReturns)
        outState.putBoolean("awaiting_accessibility", awaitingAccessibility)
        outState.putBoolean("awaiting_prerequisite", awaitingPrerequisite)
        super.onSaveInstanceState(outState)
    }
    private fun refresh() {
        state.localNetwork = hasLocalNetworkAccess()
        state.mic = ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        state.inputEnabled = getSystemService(InputMethodManager::class.java).enabledInputMethodList.any { it.packageName == packageName }
        state.inputSelected = ComponentName.unflattenFromString(Settings.Secure.getString(contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD).orEmpty()) ==
            ComponentName(this, ChirpImeService::class.java)
        state.diagnostics = DiagnosticsReport.text(this)
        val enabled = Settings.Secure.getString(contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES).orEmpty()
        state.bubbleEnabled = enabled.split(':').any {
            ComponentName.unflattenFromString(it) == ComponentName(this, ChirpAccessibilityService::class.java)
        }
        state.inputMode = store.migrateInputMode(state.inputEnabled, state.inputSelected, state.bubbleEnabled)
        state.keyboardLabel = currentKeyboardLabel(this)
        state.floatingMicSkipped = store.floatingMicSkipped
        state.advancedProtection = advancedProtection.enabled()
        val pairing = store.pairing()
        state.paired = pairing != null
        state.host = pairing?.base?.host.orEmpty()
        state.tailscaleOff = pairing != null && TailscaleControl.routes(pairing.base) && !tailscale.connected()
        state.health = store.health
    }
    internal fun testPairing(save: Boolean, requestPermission: Boolean = true) {
        val pairing = try {
            if (save) Pairing.parse(state.link) else store.pairing() ?: error("Missing pairing")
        } catch (_: Exception) { state.status = UiText.Res(R.string.setup_status_paste_valid); return }
        state.wifiPermissionNeeded = false
        val id = ++pairingGeneration
        ChirpNetwork.cancel(pendingHealth)
        val call = ChirpNetwork.healthCall(client, pairing); pendingHealth = call
        state.checking = true; state.pairIssue = null; state.status = UiText.Res(R.string.setup_status_checking)
        lifecycleScope.launch {
            try {
                val health = checkMac(call)
                if (pairingGeneration != id) return@launch
                pendingHealth = null; state.checking = false
                if (save) { savePairing(pairing, health); state.link = "" }
                else {
                    store.health = health
                }
                state.reachable = true; state.failure = null
                state.status = UiText.Res(if (health.ready) R.string.setup_status_ready else R.string.setup_status_loading_model)
                refresh()
                if (save) state.connected = true
            } catch (error: Exception) {
                recordDebugNetworkFailure(this@SetupActivity, error)
                if (pairingGeneration == id && generateSequence<Throwable>(error) { it.cause }.take(5).any { it is WifiServerPermissionRequired }) {
                    pendingHealth = null; state.checking = false; state.wifiPermissionNeeded = true
                    state.status = UiText.Res(R.string.setup_status_local_network)
                    if (requestPermission) { pendingNetworkTest = save; networkPermission.launch(LOCAL_NETWORK_PERMISSION) }
                    return@launch
                }
                if (pairingGeneration == id) {
                    pendingHealth = null; state.checking = false; state.reachable = false; state.failure = ConnectionFailure.classify(error)
                    if (save) state.pairIssue = PairIssue.Unreachable
                    state.status = UiText.Res(R.string.setup_status_unreachable)
                }
            }
        }
    }
    protected open suspend fun checkMac(call: okhttp3.Call): Health = withContext(Dispatchers.IO) { ChirpNetwork.health(call) }
    protected open fun savePairing(pairing: Pairing, health: Health) = store.save(pairing, health)
    override fun onStart() {
        super.onStart()
        // Tailscale switched on or off while Chirp is open: the card follows, and a Mac that was out of reach is checked again.
        vpnWatch = tailscale.watch {
            val wasOff = state.tailscaleOff; refresh()
            if (wasOff && !state.tailscaleOff && state.paired) testPairing(save = false, requestPermission = false)
        }
    }
    override fun onStop() {
        vpnWatch?.close(); vpnWatch = null
        ++pairingGeneration; ChirpNetwork.cancel(pendingHealth); pendingHealth = null; state.checking = false
        super.onStop()
    }
    override fun onDestroy() {
        state.link = ""; ++pairingGeneration; ChirpNetwork.cancel(pendingHealth); ChirpNetwork.dispose(client); super.onDestroy()
    }
}
