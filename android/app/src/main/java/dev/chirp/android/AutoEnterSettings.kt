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
    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        AutoEnterMode.entries.forEach { choice ->
            FilterChip(mode == choice, { mode = choice; store.autoEnter = choice }, label = { Text(choice.label) })
        }
    }
    Text(stringResource(R.string.auto_enter_body),
        style = MaterialTheme.typography.bodySmall)
}
