package dev.chirp.android

import android.Manifest
import android.app.KeyguardManager
import android.content.*
import android.net.Uri
import android.os.*
import android.provider.Settings
import android.speech.RecognizerIntent
import android.view.MotionEvent
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import dev.chirp.android.ui.LocalChirpRoles
import dev.chirp.android.ui.Ripple

/** Clipboard entry and the external Speak-button contract share one visible microphone owner. */
open class QuickDictateActivity : ComponentActivity() {
    internal open fun createModel() = QuickDictateModel(applicationContext)
    internal open val tailscale: TailscaleControl by lazy { AndroidTailscale(this) }
    internal val model: QuickDictateModel by viewModels { viewModelFactory { initializer { createModel() } } }
    private val handler = Handler(Looper.getMainLooper())
    private val close = Runnable { finish() }
    private var started = false
    private var askedPermission = false
    private var vpnWatch: AutoCloseable? = null
    private val vpnTimeout = Runnable { endVpnWait(); model.status = StatusLine.TAILSCALE_STALLED }
    internal val recognizing get() = intent.action == RecognizerIntent.ACTION_RECOGNIZE_SPEECH
    private val permission = registerForActivityResult(ActivityResultContracts.RequestPermission()) {
        if (it) model.start() else model.status = StatusLine.ALLOW_MICROPHONE
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setResult(RESULT_CANCELED)
        if (Build.VERSION.SDK_INT >= 33) setRecentsScreenshotEnabled(false)
        model.targetPackage = if (recognizing) callingPackage ?: referrer?.takeIf { it.scheme == "android-app" }?.host else null
        model.appLabel = if (recognizing) callerLabel() else "Quick dictate"
        model.completed = ::complete
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() = abandon(cancel = true)
        })
        setContent {
            ChirpTheme {
                QuickDictateScreen(model, if (recognizing) intent.getStringExtra(RecognizerIntent.EXTRA_PROMPT)?.take(300) else null,
                    recognizing, stop = model::stop, cancel = { abandon(cancel = true) }, retry = ::fix,
                    useRaw = { touch(); model.useRaw() }, edit = ::edit, done = { abandon(cancel = false) })
            }
        }
    }
    override fun onResume() {
        super.onResume()
        if (model.copied) { armClose(); return }
        if (started) return
        val lock = getSystemService(KeyguardManager::class.java)
        if (lock.isKeyguardLocked) lock.requestDismissKeyguard(this, object : KeyguardManager.KeyguardDismissCallback() {
            override fun onDismissSucceeded() { if (!isFinishing) begin() }
            override fun onDismissCancelled() = abandon(cancel = true)
            override fun onDismissError() = abandon(cancel = true)
        }) else begin()
    }
    private fun begin() { started = true; model.start() }
    override fun onStop() { handler.removeCallbacks(close); endVpnWait(); model.cancel(); super.onStop() }
    override fun onDestroy() { handler.removeCallbacks(close); model.completed = null; super.onDestroy() }
    override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
        if (ev.actionMasked == MotionEvent.ACTION_DOWN) touch()
        return super.dispatchTouchEvent(ev)
    }
    override fun onUserInteraction() { super.onUserInteraction(); touch() }
    private fun touch() { if (model.copied) model.closeAt = null; handler.removeCallbacks(close) }
    private fun armClose() { model.closeAt?.let { handler.postDelayed(close, (it - SystemClock.elapsedRealtime()).coerceAtLeast(0)) } }
    private fun callerLabel(): String {
        val pkg = callingPackage ?: referrer?.takeIf { it.scheme == "android-app" }?.host
        return try { pkg?.let { packageManager.getApplicationLabel(packageManager.getApplicationInfo(it, 0)).toString() } ?: "Requesting app" }
        catch (_: android.content.pm.PackageManager.NameNotFoundException) { "Requesting app" }
    }
    internal fun complete(text: String) {
        if (recognizing) {
            setResult(RESULT_OK, Intent().putStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS, arrayListOf(text))
                .putExtra(RecognizerIntent.EXTRA_CONFIDENCE_SCORES, floatArrayOf(-1f)))
            finish()
        } else {
            sensitiveCopy(this, text)
            armClose()
        }
    }
    internal fun abandon(cancel: Boolean) {
        setResult(if (cancel) RESULT_CANCELED else model.errorCode ?: RESULT_CANCELED)
        model.cancel(); finish()
    }
    private fun edit() {
        ScratchpadHandoff.put(model.text)
        startActivity(ScratchpadActivity.intent(this)); finish()
    }
    private fun endVpnWait() { handler.removeCallbacks(vpnTimeout); vpnWatch?.close(); vpnWatch = null }
    private fun setup(section: String) = startActivity(Intent(this, SetupActivity::class.java).putExtra("section", section)
        .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP))
    internal fun fix() {
        when (model.status.action) {
            DictationAction.PAIR -> setup("pair")
            DictationAction.MICROPHONE -> {
                if (askedPermission && !shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO))
                    startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null)))
                else { askedPermission = true; permission.launch(Manifest.permission.RECORD_AUDIO) }
            }
            DictationAction.TAILSCALE_ON -> {
                endVpnWait()
                vpnWatch = tailscale.watch { if (tailscale.connected()) { endVpnWait(); model.start() } }
                if (tailscale.connect()) {
                    model.status = StatusLine.TAILSCALE_CONNECTING
                    handler.postDelayed(vpnTimeout, 12_000)
                } else { endVpnWait(); model.status = StatusLine.TAILSCALE_STALLED }
            }
            DictationAction.TAILSCALE_OPEN, DictationAction.TAILSCALE_SETUP -> {
                if (!tailscale.open()) setup("network")
            }
            DictationAction.NETWORK, null -> model.start()
        }
    }
    companion object {
        fun intent(context: Context) = Intent(context, QuickDictateActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS)
    }
}

internal fun sensitiveCopy(context: Context, text: String) {
    val clip = ClipData.newPlainText("Chirp dictation", text)
    clip.description.extras = PersistableBundle().apply { putBoolean("android.content.extra.IS_SENSITIVE", true) }
    context.getSystemService(ClipboardManager::class.java).setPrimaryClip(clip)
}

@Composable
internal fun QuickDictateScreen(model: QuickDictateModel, prompt: String? = null, recognizing: Boolean = false,
                               stop: () -> Unit = {}, cancel: () -> Unit = {}, retry: () -> Unit = {},
                               useRaw: () -> Unit = {}, edit: () -> Unit = {}, done: () -> Unit = {}) {
    val deadline = model.closeAt
    val view = androidx.compose.ui.platform.LocalView.current
    val rawAvailable = stringResource(R.string.quick_dictate_raw_available)
    androidx.compose.runtime.LaunchedEffect(model.raw) {
        if (model.raw != null && deadline != null) view.announceForAccessibility(rawAvailable)
    }
    val seconds by androidx.compose.runtime.produceState(deadline?.let { actionSeconds(it, SystemClock.elapsedRealtime()) }, deadline) {
        value = deadline?.let { actionSeconds(it, SystemClock.elapsedRealtime()) }
        while (deadline != null) {
            value = actionSeconds(deadline, SystemClock.elapsedRealtime())
            if (value == 0) break
            kotlinx.coroutines.delay(200)
        }
    }
    val colors = MaterialTheme.colorScheme
    val record = LocalChirpRoles.current.record
    val onRecord = if (androidx.core.graphics.ColorUtils.calculateContrast(android.graphics.Color.WHITE, record.toArgb()) >= 4.5) Color.White else Color(0xFF0D1526)
    Box(Modifier.fillMaxSize().navigationBarsPadding().statusBarsPadding(), contentAlignment = Alignment.BottomCenter) {
        Surface(Modifier.widthIn(max = 560.dp).fillMaxWidth(), shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp), color = colors.surface) {
            Column(Modifier.verticalScroll(rememberScrollState()).padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(20.dp)) {
                Text(stringResource(R.string.quick_dictate_title), style = MaterialTheme.typography.headlineSmall)
                prompt?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant) }
                Box(Modifier.size(96.dp), contentAlignment = Alignment.Center) {
                    if (model.active && !model.stopping) Ripple(model.level.toFloat(), Modifier.fillMaxSize())
                    else Ripple(model.level.toFloat(), Modifier.fillMaxSize(), animate = false)
                    Icon(painterResource(R.drawable.ic_mic), null, Modifier.size(32.dp), tint = colors.primary)
                }
                Text(if (recognizing && model.copied) stringResource(R.string.quick_dictate_finished) else model.status.text(),
                    Modifier.semantics { liveRegion = LiveRegionMode.Polite }, style = MaterialTheme.typography.titleMedium)
                if (model.retained) Text(stringResource(R.string.debug_retention), style = MaterialTheme.typography.bodySmall)
                val content = if (model.copied) model.text else model.partial
                if (content.isNotEmpty()) Text(buildAnnotatedString {
                    val stable = if (model.copied) content else model.stable.takeIf { content.startsWith(it) }.orEmpty()
                    withStyle(SpanStyle(color = colors.onSurface)) { append(stable) }
                    withStyle(SpanStyle(color = colors.onSurfaceVariant)) { append(content.removePrefix(stable)) }
                }, Modifier.fillMaxWidth().heightIn(min = 72.dp), style = MaterialTheme.typography.bodyLarge)
                if (model.active) Button(stop, enabled = !model.stopping,
                    colors = ButtonDefaults.buttonColors(containerColor = record, contentColor = onRecord)) {
                    Icon(painterResource(R.drawable.ic_stop), null, Modifier.size(18.dp)); Spacer(Modifier.width(8.dp)); Text(stringResource(R.string.quick_dictate_stop))
                } else if (model.copied && !recognizing) {
                    val useRawLabel = stringResource(R.string.quick_dictate_use_raw)
                    if (model.raw != null && seconds != 0) OutlinedButton(useRaw, Modifier.fillMaxWidth().semantics {
                        contentDescription = if (deadline == null) useRawLabel else rawAvailable
                    }) { Text(seconds?.let { stringResource(R.string.quick_dictate_use_raw_seconds, it) } ?: useRawLabel,
                        Modifier.clearAndSetSemantics { }, style = MaterialTheme.typography.labelLarge.copy(fontFeatureSettings = "tnum")) }
                    OutlinedButton(edit, Modifier.fillMaxWidth()) { Text(stringResource(R.string.quick_dictate_edit)) }
                    Button(done, Modifier.fillMaxWidth()) { Text(stringResource(R.string.settings_done)) }
                } else {
                    Button(retry, Modifier.fillMaxWidth()) { Text(stringResource(when (model.status.action) {
                        DictationAction.PAIR -> R.string.settings_pair_computer
                        DictationAction.MICROPHONE -> R.string.quick_dictate_allow
                        DictationAction.TAILSCALE_ON, DictationAction.TAILSCALE_OPEN, DictationAction.TAILSCALE_SETUP -> R.string.quick_dictate_tailscale_on
                        else -> R.string.quick_dictate_check_again
                    })) }
                    TextButton(done) { Text(stringResource(R.string.settings_done)) }
                }
                if (!model.copied) TextButton(cancel) { Text(stringResource(R.string.settings_cancel)) }
            }
        }
    }
}
