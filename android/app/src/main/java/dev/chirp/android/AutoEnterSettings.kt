package dev.chirp.android

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.unit.dp
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource

/** "Press Send after dictating": Off, Always, or in chat apps only (the apps set to the Chat style). Read at each dictation. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun AutoEnterSettings() {
    val store = SettingsStore(LocalContext.current)
    var mode by remember { mutableStateOf(store.autoEnter) }
    Text(stringResource(R.string.auto_enter_title), style = MaterialTheme.typography.titleSmall)
    // The shared chip row, so the chosen mode is koi-filled like every other single choice.
    val labels = AutoEnterMode.entries.associateWith { stringResource(it.label) }
    dev.chirp.android.ui.ChoiceChips(AutoEnterMode.entries, mode, { labels.getValue(it) }) { mode = it; store.autoEnter = it }
    Text(stringResource(R.string.auto_enter_body),
        style = MaterialTheme.typography.bodySmall)
}
