package dev.chirp.android.settings

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import dev.chirp.android.*
import dev.chirp.android.R
import dev.chirp.android.ui.*

@Composable
internal fun SettingsDetail(page: SettingsPage, state: SetupState, actions: SettingsActions, history: DictationHistory?, updates: UpdateController?) {
    when (page) {
        SettingsPage.Connection -> ConnectionPage(state, actions)
        SettingsPage.HowYouDictate -> HowYouDictate(state, actions.chooseMode, actions.floatingMicSettings, actions.appSettings, actions.picker, actions.keyboardSettings)
        SettingsPage.Dictation -> DictationPage(state, actions)
        SettingsPage.Keyboard -> KeyboardPage(actions)
        SettingsPage.Feedback -> FeedbackPage()
        SettingsPage.Notes -> NotesSettings()
        SettingsPage.History -> HistoryPage(history)
        SettingsPage.About -> AboutPage(updates)
    }
}

@Composable
private fun ConnectionPage(state: SetupState, actions: SettingsActions) {
    var confirmForget by remember { mutableStateOf(false) }
    val connection = connectionSummary(state.paired, state.host, state.reachable, state.checking, state.health)
    // Unreachable: the hint says to check Tailscale, so the banner opens it when it is installed.
    val tailscale = actions.openTailscale.takeIf { state.paired && state.reachable == false && !state.checking }
    StatusBanner(connection.kind, connection.title, body = connection.hint ?: connection.summary, live = true,
        action = tailscale?.let { stringResource(R.string.settings_open_tailscale) }, onAction = { tailscale?.invoke() })
    Text(pairingStepsAnnotated(), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    SettingsGroup {
        if (state.paired) ActionRow(stringResource(R.string.settings_check_connection), actions.checkConnection, enabled = !state.checking)
        if (state.wifiPermissionNeeded && !state.localNetwork) ActionRow(stringResource(R.string.settings_allow_wifi), actions.allowWifi,
            summary = stringResource(R.string.settings_allow_wifi_summary))
        NavRow(stringResource(if (state.paired) R.string.settings_change_pairing else R.string.settings_pair_computer), actions.changePairing)
    }
    if (state.paired) SettingsGroup { ActionRow(stringResource(R.string.settings_forget_pairing), { confirmForget = true }, destructive = true) }
    PhoneFallbackSettings()
    if (confirmForget) AlertDialog(onDismissRequest = { confirmForget = false },
        title = { Text(stringResource(R.string.settings_forget_confirm)) },
        text = { Text(stringResource(R.string.settings_forget_confirm_body)) },
        confirmButton = { TextButton({ confirmForget = false; actions.forgetPairing() },
            colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)) { Text(stringResource(R.string.settings_forget)) } },
        dismissButton = { TextButton({ confirmForget = false }) { Text(stringResource(R.string.settings_cancel)) } })
}

/** Clean-up and styles, stop behaviour, spoken commands, auto-enter, and the other ways to dictate. */
@Composable
private fun DictationPage(state: SetupState, actions: SettingsActions) {
    val context = LocalContext.current
    val store = remember { SettingsStore(context) }
    var cleanup by remember { mutableStateOf(store.correction) }
    var commands by remember { mutableStateOf(store.spokenCommands) }
    if (state.health.cleanupAvailable()) {
        SettingsGroup(stringResource(R.string.settings_cleanup)) {
            SwitchRow(stringResource(R.string.settings_cleanup), cleanup, { cleanup = it; store.correction = it },
                summary = if (state.health?.correctionLeavesMachine == true) stringResource(R.string.settings_cleanup_summary_host, state.health?.correctionHost.toString())
                    else stringResource(R.string.settings_cleanup_summary_computer),
                infoTitle = stringResource(R.string.settings_cleanup), infoBody = cleanupDescription(state.health))
            CleanupStyleSettings(state.health)
        }
    } else if (state.paired) SettingsGroup(stringResource(R.string.settings_cleanup)) { SettingsItem { Text(stringResource(R.string.settings_cleanup_off_computer), style = MaterialTheme.typography.bodyMedium) } }
    SettingsGroup(stringResource(R.string.settings_stopping)) { StopDictationSettings() }
    SettingsGroup(stringResource(R.string.settings_spoken_commands)) {
        SwitchRow(stringResource(R.string.settings_spoken_commands), commands, { commands = it; store.spokenCommands = it }, summary = stringResource(R.string.settings_off_by_default),
            infoTitle = stringResource(R.string.settings_spoken_commands), infoBody = stringResource(R.string.settings_spoken_commands_info))
    }
    SettingsGroup(stringResource(R.string.settings_press_send)) { SettingsItem { AutoEnterSettings() } }
    LearningSettings()
}

@Composable
private fun KeyboardPage(actions: SettingsActions) {
    val context = LocalContext.current
    val store = remember { SettingsStore(context) }
    val prefs = remember { keyboardPrefs(context) }
    var shortcut by remember { mutableStateOf(store.hardwareShortcut) }
    var largerMic by remember { mutableStateOf(store.largerMic) }
    KeyboardLookChooser()
    SwipeTypingSettings()
    SettingsGroup(stringResource(R.string.settings_keys)) {
        SwitchRow(stringResource(R.string.settings_hardware_shortcut), shortcut, { shortcut = it; store.hardwareShortcut = it }, summary = stringResource(R.string.settings_hardware_shortcut_summary),
            infoTitle = stringResource(R.string.settings_hardware_shortcut), infoBody = stringResource(R.string.settings_hardware_shortcut_info))
        SwitchRow(stringResource(R.string.settings_larger_mic), largerMic, { largerMic = it; store.largerMic = it })
        NavRow(stringResource(R.string.settings_keyboard_preferences), actions.keyboardPreferences, summary = stringResource(R.string.settings_keyboard_preferences_summary))
    }
}

@Composable
private fun FeedbackPage() {
    val context = LocalContext.current
    val store = remember { SettingsStore(context) }
    var haptics by remember { mutableStateOf(store.haptics) }
    var soundCues by remember { mutableStateOf(store.soundCues) }
    AppColoursSettings()
    SettingsGroup(stringResource(R.string.settings_cues)) {
        SwitchRow(stringResource(R.string.settings_haptic_cues), haptics, { haptics = it; store.haptics = it })
        SwitchRow(stringResource(R.string.settings_sound_cues), soundCues, { soundCues = it; store.soundCues = it }, summary = stringResource(R.string.settings_sound_cues_summary),
            infoTitle = stringResource(R.string.settings_sound_cues), infoBody = stringResource(R.string.settings_sound_cues_info))
    }
}

/** History retention and clear, separate from Notes retention (spec §D). */
@Composable
private fun HistoryPage(history: DictationHistory?) {
    val context = LocalContext.current
    val store = remember { SettingsStore(context) }
    val privateSession by PrivateSession.state.collectAsState()
    SettingsGroup {
        SwitchRow(stringResource(R.string.settings_private_session), privateSession, { store.privateSession = it }, summary = stringResource(R.string.settings_private_session_summary),
            infoTitle = stringResource(R.string.settings_private_session), infoBody = PrivateSession.HELP)
    }
    HistorySettings(showOpen = true, store = history, title = null)   // the page already says "Privacy & history"
    SettingsGroup(stringResource(R.string.settings_what_chirp_keeps)) {
        SettingsItem {
            Text(stringResource(R.string.settings_what_chirp_keeps_body), style = MaterialTheme.typography.bodyMedium)
            LearnMore(stringResource(R.string.settings_local_only), stringResource(R.string.settings_local_only_body))
        }
    }
}

@Composable
private fun AboutPage(updates: UpdateController?) {
    val context = LocalContext.current
    val store = remember { SettingsStore(context) }
    var report by remember { mutableStateOf(DiagnosticsReport.text(context)) }
    var debug by remember { mutableStateOf(store.debugOverlay) }
    UpdateSettings(updates)
    SettingsGroup(stringResource(R.string.settings_diagnostics)) {
        SettingsItem { DiagnosticsBody(report) }
        SwitchRow(stringResource(R.string.settings_debug_overlay), debug, { debug = it; store.debugOverlay = it })
        BuildSetupOptions()
        ActionRow(stringResource(R.string.settings_copy_diagnostics), { copyDiagnostics(context, report) })
        ActionRow(stringResource(R.string.settings_clear_timings), { DiagnosticsReport.clearTimings(context); report = DiagnosticsReport.text(context) })
    }
}

/** Shared by this page and setup's Diagnostics dialog. */
@Composable
internal fun DiagnosticsBody(report: String) {
    Text(stringResource(R.string.settings_diagnostics_body))
    SelectionContainer { Text(report, style = MaterialTheme.typography.bodySmall) }
}

internal fun copyDiagnostics(context: Context, report: String) {
    context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("Chirp diagnostics", report))
}
