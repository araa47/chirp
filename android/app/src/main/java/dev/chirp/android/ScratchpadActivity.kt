package dev.chirp.android

import android.Manifest
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PersistableBundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import dev.chirp.android.ui.LocalChirpRoles
import dev.chirp.android.ui.Ripple
import dev.chirp.android.ui.StatusBanner
import dev.chirp.android.ui.StatusKind
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory

/** Dictate long-form text on the phone, edit it, copy or share it. Memory only: the text leaves with the screen. */
open class ScratchpadActivity : ComponentActivity(), AppShortcutHost {
    override val appShortcuts = AppShortcuts()
    @android.annotation.SuppressLint("RestrictedApi") // Override of the public Activity callback, forwarded by AndroidX.
    override fun dispatchKeyEvent(event: android.view.KeyEvent): Boolean = appShortcuts.dispatch(event) || super.dispatchKeyEvent(event)
    override fun onKeyShortcut(keyCode: Int, event: android.view.KeyEvent): Boolean = appShortcuts.dispatch(event) || super.onKeyShortcut(keyCode, event)
    override fun onProvideKeyboardShortcuts(groups: MutableList<android.view.KeyboardShortcutGroup>, menu: android.view.Menu?, deviceId: Int) {
        super.onProvideKeyboardShortcuts(groups, menu, deviceId)
        appShortcuts.provide(groups)
    }
    internal open fun createModel(): ScratchpadModel = ScratchpadModel(applicationContext)
    internal open val tailscale: TailscaleControl by lazy { AndroidTailscale(this) }
    internal val model: ScratchpadModel by viewModels { viewModelFactory { initializer { createModel() } } }
    private val micPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) model.start() else model.status = StatusLine.MICROPHONE_NEEDED
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Keep dictated text out of the Recents thumbnail.
        if (Build.VERSION.SDK_INT >= 33) setRecentsScreenshotEnabled(false)
        setContent {
            ChirpTheme { ScratchpadScreen(model, mic = ::mic, copy = ::copy, share = ::share, act = ::act) }
        }
        ScratchpadHandoff.take()?.let(model::receive)
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        ScratchpadHandoff.take()?.let(model::receive)
    }
    override fun onStart() { super.onStart(); model.refresh() }
    override fun onStop() { model.pause(); super.onStop() }

    internal fun mic() {
        if (model.active || checkSelfPermission(Manifest.permission.RECORD_AUDIO) == android.content.pm.PackageManager.PERMISSION_GRANTED) model.toggle()
        else micPermission.launch(Manifest.permission.RECORD_AUDIO)
    }
    internal fun copy() {
        val text = model.field.text.takeIf { it.isNotBlank() } ?: return
        val clip = ClipData.newPlainText(getString(R.string.bubble_clip_label), text)
        // Keeps the text out of clipboard previews and overlays where the system supports it.
        clip.description.extras = PersistableBundle().apply {
            putBoolean(if (Build.VERSION.SDK_INT >= 33) ClipDescription.EXTRA_IS_SENSITIVE else "android.content.extra.IS_SENSITIVE", true)
        }
        getSystemService(ClipboardManager::class.java)?.setPrimaryClip(clip)
        model.status = StatusLine.COPIED
    }
    internal fun share() {
        val text = model.field.text.takeIf { it.isNotBlank() } ?: return
        startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text), null))
    }
    internal fun act(action: DictationAction) {
        fun setup(section: String) = startActivity(Intent(this, SetupActivity::class.java).putExtra("section", section)
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP))
        when (action) {
            DictationAction.PAIR -> setup("pair")
            DictationAction.MICROPHONE -> startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null)))
            DictationAction.NETWORK, DictationAction.TAILSCALE_OPEN -> if (!tailscale.open()) setup("network")
            DictationAction.TAILSCALE_SETUP -> setup("network")
            DictationAction.TAILSCALE_ON -> if (tailscale.connect()) model.status = StatusLine.TAILSCALE_CONNECTING else if (!tailscale.open()) setup("network")
        }
    }

    companion object {
        /** Opens the Scratchpad from outside the app (Quick Settings tile). */
        fun intent(context: Context) = Intent(context, ScratchpadActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        /** Opens the Scratchpad with the floating mic's words; the text travels in memory, never in the Intent. */
        fun open(context: Context, text: String) {
            ScratchpadHandoff.put(text)
            context.startActivity(intent(context).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP))
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ScratchpadScreen(model: ScratchpadModel, mic: () -> Unit, copy: () -> Unit, share: () -> Unit, act: (DictationAction) -> Unit) {
    AppShortcutActions(
        AppCommand.Dictate to { if (!model.stopping) mic(); true },
        AppCommand.Raw to { if (model.rawAvailable) { model.useRaw(); true } else false },
        AppCommand.Copy to { if (model.hasText) copy(); true },
        AppCommand.Escape to { if (model.active) { model.cancel(); true } else false },
    )
    val view = androidx.compose.ui.platform.LocalView.current
    val rawAvailable = stringResource(R.string.scratchpad_raw_available)
    LaunchedEffect(model.rawUntil) {
        if (model.rawAvailable) view.announceForAccessibility(rawAvailable)
    }
    val rawSeconds by androidx.compose.runtime.produceState(5, model.rawUntil) {
        val deadline = model.rawUntil
        while (deadline != null) {
            value = actionSeconds(deadline, android.os.SystemClock.elapsedRealtime())
            if (value == 0) break
            kotlinx.coroutines.delay(200)
        }
    }
    val action = model.status.action
    Surface(Modifier.fillMaxSize()) {
        Box(Modifier.fillMaxSize().safeDrawingPadding(), contentAlignment = Alignment.TopCenter) {
                Column(Modifier.widthIn(max = 600.dp).fillMaxSize().padding(horizontal = 16.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    // Copy/Share in the top bar (spec §D); Save as note and Clear sit in the overflow.
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Spacer(Modifier.weight(1f))
                        IconButton(copy, enabled = model.hasText) { Icon(painterResource(R.drawable.ic_copy), stringResource(R.string.scratchpad_copy)) }
                        IconButton(share, enabled = model.hasText) { Icon(painterResource(R.drawable.ic_share), stringResource(R.string.scratchpad_share)) }
                        OverflowMenu(model)
                    }
                    if (model.retained) StatusBanner(StatusKind.Error, stringResource(R.string.debug_retention))
                    // The borderless blank page: no label, no outline, just text.
                    TextField(model.field, { if (!model.active) model.field = it }, Modifier.fillMaxWidth().weight(1f).heightIn(min = 120.dp),
                        placeholder = { Text(stringResource(R.string.scratchpad_placeholder)) }, readOnly = model.active,
                        textStyle = MaterialTheme.typography.bodyLarge,
                        colors = TextFieldDefaults.colors(
                            focusedContainerColor = Color.Transparent, unfocusedContainerColor = Color.Transparent, disabledContainerColor = Color.Transparent,
                            focusedIndicatorColor = Color.Transparent, unfocusedIndicatorColor = Color.Transparent, disabledIndicatorColor = Color.Transparent),
                        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences))
                    if (model.active && model.partial.isNotEmpty()) Text(model.partial, Modifier.fillMaxWidth(), color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodyMedium, maxLines = 3)
                    Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(model.status.shown(LocalContext.current.resources), Modifier.weight(1f).semantics { liveRegion = LiveRegionMode.Polite }, style = MaterialTheme.typography.bodyMedium)
                        if (model.rawAvailable && rawSeconds > 0) TextButton(model::useRaw, Modifier.semantics {
                            contentDescription = rawAvailable
                        }) { Text(stringResource(R.string.quick_dictate_use_raw_seconds, rawSeconds), Modifier.clearAndSetSemantics { },
                            style = MaterialTheme.typography.labelLarge.copy(fontFeatureSettings = "tnum")) }
                        if (action != null) TextButton({ act(action) }) { Text(stringResource(action.label)) }
                    }
                    if (model.cleanupAvailable) StyleGroup(model)
                    MicButton(model, mic)
                    // The one privacy line (spec §D: a blank page): said while the page is blank, gone once there is text.
                    if (!model.hasText && !model.active) Text(
                        stringResource(if (model.historyOn) R.string.scratchpad_privacy_history else R.string.scratchpad_privacy_none),
                        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp), style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
                }
        }
    }
}

@Composable
private fun OverflowMenu(model: ScratchpadModel) {
    var menu by remember { mutableStateOf(false) }
    AppShortcutActions(AppCommand.Escape to { if (menu && !model.active) { menu = false; true } else false })
    Box {
        IconButton({ menu = true }) { Icon(painterResource(R.drawable.ic_more_vert), stringResource(R.string.history_more_options)) }
        DropdownMenu(menu, { menu = false }) {
            DropdownMenuItem(leadingIcon = { Icon(painterResource(R.drawable.ic_notes), null) }, text = { Text(stringResource(R.string.scratchpad_save_as_note)) },
                onClick = { menu = false; model.saveAsNote() }, enabled = model.hasText && !model.active)
            DropdownMenuItem(leadingIcon = { Icon(painterResource(R.drawable.ic_delete), null) }, text = { Text(stringResource(R.string.scratchpad_clear)) },
                onClick = { menu = false; model.clear() }, enabled = model.hasText && !model.active)
        }
    }
}

/**
 * The style choice as a single-select chip row above the mic: Raw and the Mac's clean-up styles. Chips keep their label on
 * one line and the row scrolls sideways, so two to eight styles read at any width and at 200% font; the chosen one is
 * scrolled into view.
 */
@Composable
internal fun StyleGroup(model: ScratchpadModel) {
    val raw = stringResource(R.string.scratchpad_style_raw)
    val options = buildList {
        add(Triple(raw, null as CorrectionProfile?, !model.cleanup))
        model.profiles.forEach { add(Triple(it.name, it, model.cleanup && model.style.id == it.id)) }
    }
    val state = rememberLazyListState()
    val selected = options.indexOfFirst { it.third }.coerceAtLeast(0)
    LaunchedEffect(selected, options.size) { state.animateScrollToItem(selected) }
    LazyRow(Modifier.fillMaxWidth().testTag("style-chips"), state = state,
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        itemsIndexed(options, key = { _, option -> option.second?.id ?: "raw" }) { _, (label, profile, isSelected) ->
            FilterChip(isSelected, { model.choose(profile) }, label = { Text(label, maxLines = 1, softWrap = false) }, enabled = !model.active,
                modifier = Modifier.semantics { role = Role.RadioButton },
                // A small selected state may keep the koi container; unselected chips stay outlined.
                colors = FilterChipDefaults.filterChipColors(selectedContainerColor = MaterialTheme.colorScheme.primaryContainer,
                    selectedLabelColor = MaterialTheme.colorScheme.onPrimaryContainer))
        }
    }
}

/** A large mic with the Pond Ripple while listening; Stop in the fixed `record` colour. */
@Composable
private fun MicButton(model: ScratchpadModel, onClick: () -> Unit) {
    val roles = LocalChirpRoles.current
    val listening = model.active && !model.stopping
    // The record red stays fixed under dynamic colour; its content flips to pond ink when the red runs light.
    val onRecord = if (androidx.core.graphics.ColorUtils.calculateLuminance(roles.record.toArgb()) > 0.35f) Color(0xFF0D1526) else Color.White
    val micLabel = stringResource(if (model.active) R.string.scratchpad_mic_stop else R.string.scratchpad_mic_start)
    Box(Modifier.fillMaxWidth().height(168.dp), contentAlignment = Alignment.Center) {
        if (listening) Ripple(model.level.coerceIn(0.0, 1.0).toFloat(), Modifier.size(160.dp), color = roles.koiDecor)
        Surface(onClick, Modifier.size(96.dp).semantics {
            role = Role.Button
            contentDescription = micLabel
        }, enabled = !model.stopping, shape = CircleShape,
            color = if (model.active) roles.record else MaterialTheme.colorScheme.primary,
            contentColor = if (model.active) onRecord else MaterialTheme.colorScheme.onPrimary) {
            Box(contentAlignment = Alignment.Center) {
                androidx.compose.material3.Icon(painterResource(if (model.active) R.drawable.ic_stop else R.drawable.ic_mic), null,
                    Modifier.size(40.dp))
            }
        }
    }
}
