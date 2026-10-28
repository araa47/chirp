package dev.chirp.android

import androidx.compose.ui.platform.LocalResources
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import dev.chirp.android.ui.ActionRow
import dev.chirp.android.ui.ChoiceChips
import dev.chirp.android.ui.NavRow
import dev.chirp.android.ui.SettingsGroup
import dev.chirp.android.ui.SettingsItem
import dev.chirp.android.ui.SwitchRow

/** History switch, retention and clear. Turning history off offers to keep or delete existing dictations. */
@Composable
internal fun HistorySettings(showOpen: Boolean = true, store: DictationHistory? = null, title: String? = stringResource(R.string.history_title), changed: () -> Unit = {}) {
    val context = LocalContext.current
    val history = store ?: remember { DictationHistory(context) }
    val scope = rememberCoroutineScope()
    var enabled by remember { mutableStateOf(history.enabled) }
    var retention by remember { mutableStateOf(history.retention) }
    val resources = LocalResources.current
    var confirmOff by remember { mutableStateOf(false) }
    var confirmClear by remember { mutableStateOf(false) }
    SettingsGroup(title = title) {
        SwitchRow(stringResource(R.string.history_keep), enabled, { on ->
            if (on) { history.enable(); enabled = true; changed() } else confirmOff = true
        }, summary = stringResource(if (enabled) R.string.history_keep_on else R.string.history_keep_off),
            infoTitle = stringResource(R.string.history_keep),
            infoBody = stringResource(R.string.history_keep_info))
        SettingsItem {
            Text(stringResource(R.string.history_keep_for), style = MaterialTheme.typography.bodyMedium)
            ChoiceChips(HistoryRetention.entries, retention, { it.label(resources) }) { option ->
                retention = option
                scope.launch { withContext(Dispatchers.IO) { history.retention = option }; changed() }
            }
        }
        if (showOpen) NavRow(stringResource(R.string.history_open_history), { context.startActivity(Intent(context, HistoryActivity::class.java)) })
        ActionRow(stringResource(R.string.history_delete_history), { confirmClear = true }, destructive = true)
    }
    if (confirmOff) AlertDialog(onDismissRequest = { confirmOff = false },
        title = { Text(stringResource(R.string.history_off_confirm)) },
        text = { Text(stringResource(R.string.history_off_confirm_body)) },
        confirmButton = { TextButton({
            confirmOff = false
            scope.launch { withContext(Dispatchers.IO) { history.disable(deleteHistory = true) }; enabled = false; changed() }
        }) { Text(stringResource(R.string.history_off_delete)) } },
        dismissButton = { androidx.compose.foundation.layout.Column {
            TextButton({
                confirmOff = false
                scope.launch { withContext(Dispatchers.IO) { history.disable() }; enabled = false; changed() }
            }) { Text(stringResource(R.string.history_off_keep)) }
            TextButton({ confirmOff = false }) { Text(stringResource(R.string.settings_cancel)) }
        } })
    if (confirmClear) AlertDialog(onDismissRequest = { confirmClear = false },
        title = { Text(stringResource(R.string.history_delete_confirm)) },
        text = { Text(stringResource(R.string.history_delete_confirm_body)) },
        confirmButton = { TextButton({
            confirmClear = false
            scope.launch { withContext(Dispatchers.IO) { history.clear() }; changed() }
        }) { Text(stringResource(R.string.history_delete_history)) } },
        dismissButton = { TextButton({ confirmClear = false }) { Text(stringResource(R.string.settings_cancel)) } })
}

/** The keyboard's "open history" link and older shortcuts: a thin deep link into the app shell's History tab. */
class HistoryActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        startActivity(Intent(this, SetupActivity::class.java).putExtra("section", "history")
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP))
        finish()
    }
}
