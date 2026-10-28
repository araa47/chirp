package dev.chirp.android.settings

import androidx.compose.ui.platform.LocalResources
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import dev.chirp.android.*
import dev.chirp.android.R
import dev.chirp.android.ui.*

/**
 * The top level (spec §D): about seven category rows, each with an icon and a live one-line summary of what sits
 * behind it. The details live in the category's page; paragraph help is behind the ⓘ on the rows there.
 */
@Composable
internal fun SettingsList(state: SetupState, actions: SettingsActions, history: DictationHistory?, open: (SettingsPage) -> Unit) {
    val context = LocalContext.current
    val prefs = remember { keyboardPrefs(context) }
    var revision by remember { mutableIntStateOf(0) }
    DisposableEffect(context, prefs) {
        val sources = listOf(prefs, context.getSharedPreferences(SettingsStore.FILE, 0),
            context.getSharedPreferences("chirp_notes_sessions", 0), context.getSharedPreferences("chirp_history", 0))
        val listener = android.content.SharedPreferences.OnSharedPreferenceChangeListener { _, _ -> revision++ }
        sources.forEach { it.registerOnSharedPreferenceChangeListener(listener) }
        onDispose { sources.forEach { it.unregisterOnSharedPreferenceChangeListener(listener) } }
    }
    val dictationHistory = history ?: remember { DictationHistory(context) }
    val connection = connectionSummary(state.paired, state.host, state.reachable, state.checking, state.health)
    Column(verticalArrangement = Arrangement.spacedBy(24.dp)) {
        if (state.health?.debugRetention == true) StatusBanner(StatusKind.Error, stringResource(R.string.settings_debug_retention_on))
        // One grouped card, System-Settings style: seven rows with an icon and a live one-line summary each.
        // The list stays composed beside its detail page on a Fold: preference changes must refresh its summaries.
        key(revision) { SettingsGroup {
            NavRow(stringResource(SettingsPage.Connection.title), { open(SettingsPage.Connection) },
                summary = if (state.paired) connection.title else stringResource(R.string.settings_summary_pair), icon = R.drawable.ic_devices)
            NavRow(stringResource(SettingsPage.HowYouDictate.title), { open(SettingsPage.HowYouDictate) }, summary = inputModeSummary(state), icon = R.drawable.ic_mic)
            NavRow(stringResource(SettingsPage.Dictation.title), { open(SettingsPage.Dictation) }, summary = dictationSummary(context, state), icon = R.drawable.ic_tune)
            NavRow(stringResource(SettingsPage.Keyboard.title), { open(SettingsPage.Keyboard) }, summary = if (state.inputMode == InputMode.OWN_KEYBOARD)
                stringResource(R.string.settings_summary_keyboard_unused, state.keyboardLabel ?: stringResource(R.string.settings_your_keyboard_lower))
                else keyboardSummary(context, prefs), icon = R.drawable.ic_keyboard)
            NavRow(stringResource(SettingsPage.Feedback.title), { open(SettingsPage.Feedback) }, summary = feedbackSummary(context), icon = R.drawable.ic_palette)
            NavRow(stringResource(SettingsPage.Notes.title), { open(SettingsPage.Notes) }, summary = notesSummary(context), icon = R.drawable.ic_note)
            NavRow(stringResource(SettingsPage.History.title), { open(SettingsPage.History) },
                summary = if (dictationHistory.enabled) stringResource(R.string.settings_summary_history_on, dictationHistory.retention.label(LocalResources.current))
                    else stringResource(R.string.settings_summary_history_off), icon = R.drawable.ic_shield)
            NavRow(stringResource(SettingsPage.About.title), { open(SettingsPage.About) }, summary = stringResource(R.string.settings_summary_version, BuildConfig.VERSION_NAME), icon = R.drawable.ic_info)
        } }
    }
}

/** "Clean-up on · stops on pause": the two things the Dictation page decides, on one line. */
@Composable
internal fun dictationSummary(context: android.content.Context, state: SetupState): String {
    val store = remember(context) { SettingsStore(context) }
    val cleanup = state.health.cleanupAvailable()
    val stop = stringResource(if (store.stopOnPause) R.string.settings_summary_stops_on_pause else R.string.settings_summary_stops_on_tap)
    return when {
        !state.paired -> stop
        cleanup && store.correction -> stringResource(R.string.settings_summary_cleanup_on, stop)
        cleanup -> stringResource(R.string.settings_summary_cleanup_off, stop)
        else -> stringResource(R.string.settings_summary_cleanup_none, stop)
    }
}

/** "Gboard look · swipe on": the keyboard's look and gesture library, on one line. */
@Composable
internal fun keyboardSummary(context: android.content.Context, prefs: android.content.SharedPreferences): String {
    val swipe = remember(context) { GestureLibrary.status(context).let { it == GestureLibrary.Status.ACTIVE || it == GestureLibrary.Status.BUILT_IN } }
    val look = currentKeyboardLook(prefs)?.label ?: stringResource(R.string.settings_summary_look_custom)
    return stringResource(if (swipe) R.string.settings_summary_swipe_on else R.string.settings_summary_swipe_off, look)
}

/** "Pond · haptic cues on": the app's colours and its feedback cues. */
@Composable
internal fun feedbackSummary(context: android.content.Context): String {
    val store = remember(context) { SettingsStore(context) }
    val colour = stringResource(if (store.appColour == AppColour.DYNAMIC) R.string.settings_colour_dynamic else R.string.settings_colour_pond)
    return stringResource(if (store.haptics) R.string.settings_summary_haptics_on else R.string.settings_summary_haptics_off, colour)
}

@Composable
internal fun inputModeSummary(state: SetupState): String = when (state.inputMode) {
    InputMode.KEYBOARD -> stringResource(R.string.ime_name)
    InputMode.OWN_KEYBOARD -> stringResource(if (state.bubbleEnabled) R.string.settings_summary_own_bubble_on else R.string.settings_summary_own_bubble_off,
        state.keyboardLabel ?: stringResource(R.string.settings_your_keyboard))
    null -> stringResource(R.string.settings_summary_choose_mode)
}
