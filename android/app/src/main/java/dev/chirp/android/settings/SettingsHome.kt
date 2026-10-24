package dev.chirp.android.settings

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import dev.chirp.android.*
import dev.chirp.android.ui.*

/** The top level: every setting is either a switch here or a row that opens one detail page. */
@Composable
internal fun SettingsHome(state: SetupState, actions: SettingsActions, history: DictationHistory?, open: (SettingsPage) -> Unit) {
    val context = LocalContext.current
    val store = remember { SettingsStore(context) }
    val prefs = remember { keyboardPrefs(context) }
    val dictationHistory = history ?: remember { DictationHistory(context) }
    var cleanup by remember { mutableStateOf(store.correction) }
    var commands by remember { mutableStateOf(store.spokenCommands) }
    var shortcut by remember { mutableStateOf(store.hardwareShortcut) }
    var largerMic by remember { mutableStateOf(store.largerMic) }
    var haptics by remember { mutableStateOf(store.haptics) }
    var soundCues by remember { mutableStateOf(store.soundCues) }
    val connection = connectionSummary(state.paired, state.host, state.reachable, state.checking, state.health)
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text("Settings", Modifier.semantics { heading() }, style = MaterialTheme.typography.headlineMedium)
        if (state.health?.debugRetention == true) StatusBanner(StatusKind.Error, "DEBUG RETENTION IS ON — the Mac may retain audio and text")
        SettingsGroup { NavRow(connection.title, { open(SettingsPage.Connection) }, summary = connection.summary, icon = connection.kind.icon) }
        SettingsGroup("Dictation") {
            if (state.health.cleanupAvailable()) {
                SwitchRow("Clean-up · ${correctionLabel(state.health)}", cleanup, { cleanup = it; store.correction = it }, summary = cleanupDescription(state.health))
                CleanupStyleSettings(state.health)
            } else if (state.paired) SettingsItem { Text("Mac has clean-up off", style = MaterialTheme.typography.bodyMedium) }
            StopDictationSettings()
            SwitchRow("Spoken commands", commands, { commands = it; store.spokenCommands = it },
                summary = "Off by default. Ending a dictation with \"new line\" or \"new paragraph\" types a line break instead of the words.")
            SettingsItem { AutoEnterSettings() }
        }
        SettingsGroup("Keyboard") {
            NavRow("Look", { open(SettingsPage.Look) }, summary = currentKeyboardLook(prefs)?.label ?: "Custom")
            NavRow("Swipe typing", { open(SettingsPage.SwipeTyping) }, summary = when (GestureLibrary.status(context)) {
                GestureLibrary.Status.ACTIVE -> "On"
                GestureLibrary.Status.BUILT_IN -> "On · built in"
                GestureLibrary.Status.NOT_LOADED -> "Library didn't load"
                GestureLibrary.Status.NONE -> "Not added"
            })
            SwitchRow("Hardware keyboard shortcut", shortcut, { shortcut = it; store.hardwareShortcut = it },
                summary = "Ctrl+Alt+Space starts and stops dictation; Esc cancels while listening.")
            SwitchRow("Larger mic on the inner screen", largerMic, { largerMic = it; store.largerMic = it })
            NavRow("Layouts, languages & typing", actions.keyboardPreferences, summary = "Opens the keyboard's own settings")
        }
        SettingsGroup("Feedback") {
            SwitchRow("Haptic cues", haptics, { haptics = it; store.haptics = it })
            SwitchRow("Sound cues", soundCues, { soundCues = it; store.soundCues = it },
                summary = "Short tones for start, stop, inserted and error. Silent when the phone is on vibrate or mute.")
        }
        SettingsGroup("Privacy & history") {
            NavRow("Dictation history", { open(SettingsPage.History) },
                summary = if (dictationHistory.enabled) "On · keeps ${dictationHistory.retention.label}" else "Off")
            NavRow("Notes", { open(SettingsPage.Notes) }, summary = notesSummary(context))
        }
        SettingsGroup("Other ways to dictate") {
            NavRow("Floating mic (Accessibility)", { open(SettingsPage.FloatingMic) }, summary = if (state.bubbleEnabled) "On" else "Off")
        }
        SettingsGroup("About") {
            NavRow("Updates", { open(SettingsPage.Updates) }, summary = "Version ${BuildConfig.VERSION_NAME}")
            NavRow("Diagnostics", { open(SettingsPage.Diagnostics) })
        }
    }
}
