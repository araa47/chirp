package dev.chirp.android

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.provider.Settings
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import dev.chirp.android.ui.*

internal fun accessibilitySettingsIntent(context: Context): Intent {
    // AOSP exposes the action as a system constant, so use its stable intent string.
    val details = Intent("android.settings.ACCESSIBILITY_DETAILS_SETTINGS")
        .putExtra(Intent.EXTRA_COMPONENT_NAME, ComponentName(context, ChirpAccessibilityService::class.java))
    return if (details.resolveActivity(context.packageManager) != null) details else Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
}

internal fun openAccessibilitySettings(context: Context) {
    try {
        context.startActivity(accessibilitySettingsIntent(context))
    } catch (_: SecurityException) {
        // Some system images resolve the service-details action but restrict its caller.
        context.startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
    } catch (_: android.content.ActivityNotFoundException) {
        context.startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
    }
}

/** A single selectable radio node per card, including its explanation and selected state. */
@Composable
internal fun InputModeCards(state: SetupState, choose: (InputMode) -> Unit) {
    Column(Modifier.selectableGroup(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        ModeCard(stringResource(R.string.setup_mode_keyboard), stringResource(R.string.setup_mode_keyboard_body),
            stringResource(R.string.setup_mode_keyboard_meta), state.inputMode == InputMode.KEYBOARD) { choose(InputMode.KEYBOARD) }
        ModeCard(state.keyboardLabel?.let { stringResource(R.string.setup_mode_keep_named, it) } ?: stringResource(R.string.setup_mode_keep),
            stringResource(R.string.setup_mode_keep_body),
            stringResource(R.string.setup_mode_keep_meta), state.inputMode == InputMode.OWN_KEYBOARD) { choose(InputMode.OWN_KEYBOARD) }
        Text(stringResource(R.string.setup_mode_either_way),
            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun ModeCard(title: String, body: String, meta: String, selected: Boolean, choose: () -> Unit) {
    Surface(Modifier.fillMaxWidth().selectable(selected, role = Role.RadioButton, onClick = choose).clearAndSetSemantics {
        role = Role.RadioButton
        this.selected = selected
        this[SemanticsProperties.Text] = listOf(AnnotatedString(title), AnnotatedString(body), AnnotatedString(meta))
        onClick { choose(); true }
    },
        shape = MaterialTheme.shapes.large,
        color = if (selected) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceContainer) {
        Row(Modifier.padding(16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            RadioButton(selected, onClick = null)
            Column(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.titleMedium)
                Text(body, style = MaterialTheme.typography.bodyMedium)
                Text(meta, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
internal fun FloatingMicGuide(state: SetupState, accessibility: () -> Unit, appInfo: () -> Unit, useKeyboard: () -> Unit) {
    if (state.advancedProtection) {
        StatusBanner(StatusKind.Warning, stringResource(R.string.setup_advanced_protection),
            body = stringResource(R.string.setup_advanced_protection_body))
        OutlinedButton(useKeyboard, Modifier.fillMaxWidth().heightIn(min = 56.dp)) { Text(stringResource(R.string.setup_use_keyboard_instead)) }
        return
    }
    Text(stringResource(R.string.setup_bubble_permission),
        style = MaterialTheme.typography.bodyLarge)
    SettingsGroup(stringResource(R.string.setup_bubble_sees)) {
        SettingsItem { Text(stringResource(R.string.setup_bubble_sees_field)) }
        SettingsItem { Text(stringResource(R.string.setup_bubble_sees_never)) }
        SettingsItem { Text(stringResource(R.string.setup_bubble_sees_voice)) }
    }
    Text(stringResource(R.string.setup_bubble_battery),
        style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    SettingsGroup { CheckRow(stringResource(R.string.setup_bubble_on), state.bubbleEnabled) }
    if (!state.bubbleEnabled) {
        Text(stringResource(R.string.setup_bubble_turn_on), style = MaterialTheme.typography.bodyMedium)
        if (state.accessibilityReturns > 0) RestrictedSettingsHelp(state.accessibilityReturns, appInfo, accessibility)
    }
}

@Composable
private fun RestrictedSettingsHelp(returns: Int, appInfo: () -> Unit, accessibility: () -> Unit) {
    var expanded by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(returns) { if (returns >= 2) expanded = true }
    SettingsGroup {
        ActionRow(stringResource(R.string.setup_restricted_question), { expanded = !expanded },
            summary = stringResource(if (expanded) R.string.setup_restricted_hide else R.string.setup_restricted_show))
        if (expanded) {
            SettingsItem { Text(stringResource(R.string.setup_restricted_steps)) }
            ActionRow(stringResource(R.string.setup_open_app_info), appInfo)
            ActionRow(stringResource(R.string.setup_open_accessibility_again), accessibility)
            SettingsItem {
                Text(stringResource(R.string.setup_restricted_menu_note), style = MaterialTheme.typography.bodySmall)
                Text(stringResource(R.string.setup_restricted_managed), style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

@Composable
internal fun HowYouDictate(state: SetupState, choose: (InputMode) -> Unit, accessibility: () -> Unit, appInfo: () -> Unit,
                           picker: () -> Unit, keyboardSettings: () -> Unit) {
    InputModeCards(state, choose)
    when (state.inputMode) {
        InputMode.KEYBOARD -> SettingsGroup(stringResource(R.string.ime_name)) {
            CheckRow(stringResource(R.string.setup_keyboard_enabled), state.inputEnabled)
            CheckRow(stringResource(R.string.setup_keyboard_selected), state.inputSelected)
            if (!state.inputEnabled) ActionRow(stringResource(R.string.setup_enable_keyboard), keyboardSettings)
            ActionRow(stringResource(R.string.setup_choose_keyboard), picker)
        }
        InputMode.OWN_KEYBOARD -> {
            if (state.inputSelected) SettingsGroup { ActionRow(stringResource(R.string.setup_switch_back), picker) }
            FloatingMicGuide(state, accessibility, appInfo, useKeyboard = { choose(InputMode.KEYBOARD) })
            if (state.advancedProtection && !state.bubbleEnabled) Text(stringResource(R.string.setup_bubble_blocked), style = MaterialTheme.typography.bodyMedium)
            if (!state.advancedProtection && !state.bubbleEnabled) Button(accessibility, Modifier.fillMaxWidth().heightIn(min = 56.dp)) { Text(stringResource(R.string.setup_open_accessibility)) }
            // #167: the clipboard is the floating mic's fallback, never automatic.
            if (state.bubbleEnabled) Text(stringResource(R.string.setup_bubble_clipboard),
                Modifier.padding(horizontal = 16.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        null -> Unit
    }
    SettingsGroup(stringResource(R.string.setup_other_ways)) {
        Text(stringResource(R.string.setup_other_ways_body), Modifier.padding(16.dp), style = MaterialTheme.typography.bodyMedium)
        OtherDictationEntries()
    }
}
