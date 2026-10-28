package dev.chirp.android

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import dev.chirp.android.ui.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun LearningSettings() {
    val context = LocalContext.current
    val store = remember { LearnedStore(context) }
    var enabled by remember { mutableStateOf(store.enabled) }
    var show by remember { mutableStateOf(false) }
    SettingsGroup(stringResource(R.string.learning_title)) {
        SwitchRow(stringResource(R.string.learning_from_edits), enabled, { enabled = it; store.enabled = it }, summary = stringResource(R.string.learning_from_edits_summary),
            infoTitle = stringResource(R.string.learning_from_edits), infoBody = stringResource(R.string.learning_from_edits_info))
        NavRow(stringResource(R.string.learning_learned), { show = true }, summary = stringResource(R.string.learning_learned_summary))
    }
    if (show) ModalBottomSheet({ show = false }) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(24.dp)) { LearnedList(store) }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun LearnedList(store: LearnedStore) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var items by remember { mutableStateOf<List<LearnedItem>>(emptyList()) }
    var revision by remember { mutableIntStateOf(0) }
    var failed by remember { mutableStateOf(false) }
    LaunchedEffect(revision) {
        runCatching { withContext(Dispatchers.IO) { store.all() } }.onSuccess { items = it; failed = false }.onFailure { failed = true }
    }
    fun change(work: () -> Unit) { scope.launch {
        failed = runCatching { withContext(Dispatchers.IO) { work() } }.isFailure
        revision++
    } }
    Text(stringResource(R.string.learning_learned), Modifier.semantics { heading() }, style = MaterialTheme.typography.headlineMedium)
    Text(stringResource(R.string.learning_learned_body), style = MaterialTheme.typography.bodyMedium)
    Spacer(Modifier.height(16.dp))
    if (failed) Text(stringResource(R.string.learning_open_failed))
    else if (items.isEmpty()) Text(stringResource(R.string.learning_empty))
    val allApps = stringResource(R.string.learning_all_apps)
    items.groupBy { it.app }.forEach { (app, group) ->
        val appTitle = remember(app) { app?.let { pkg -> runCatching {
            context.packageManager.getApplicationLabel(context.packageManager.getApplicationInfo(pkg, 0)).toString()
        }.getOrDefault(pkg) } ?: allApps }
        SettingsGroup(appTitle) {
            ActionRow(stringResource(R.string.learning_reset_app), { change { store.reset(app) } }, destructive = true)
            group.sortedByDescending { it.time }.forEach { item -> SettingsItem {
                Text(item.correction.title, style = MaterialTheme.typography.titleMedium)
                Text(if (item.state == LearnedState.LEARNING) stringResource(R.string.learning_progress, item.count, 2) else stringResource(item.state.title),
                    style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary)
                Text("${item.inserted} → ${item.edited}", style = MaterialTheme.typography.bodyMedium)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (item.state != LearnedState.ACTIVE) TextButton({ change { store.set(item.id, LearnedState.ACTIVE) } }) { Text(stringResource(R.string.learning_approve)) }
                    if (item.state != LearnedState.OFF) TextButton({ change { store.set(item.id, LearnedState.OFF) } }) { Text(stringResource(R.string.learning_undo)) }
                    TextButton({ change { store.delete(item.id) } }) { Text(stringResource(R.string.learning_delete)) }
                }
            } }
        }
    }
}

/** Teach a corrected dictation explicitly; a single approved edit activates it. */
@Composable
internal fun TeachChirp(entry: HistoryEntry, close: () -> Unit) {
    val context = LocalContext.current
    val store = remember { LearnedStore(context) }
    val scope = rememberCoroutineScope()
    var wanted by remember(entry.id) { mutableStateOf(entry.text) }
    var message by remember { mutableStateOf<String?>(null) }
    var saving by remember { mutableStateOf(false) }
    val notAllowed = stringResource(R.string.learning_teach_not_allowed)
    val saveFailed = stringResource(R.string.learning_teach_failed)
    val nothingNew = stringResource(R.string.learning_teach_nothing_new)
    AlertDialog(onDismissRequest = close, title = { Text(stringResource(R.string.learning_teach)) }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(stringResource(R.string.learning_teach_body))
            OutlinedTextField(wanted, { if (it.length <= 20000) wanted = it }, label = { Text(stringResource(R.string.learning_teach_wanted)) }, modifier = Modifier.fillMaxWidth())
            message?.let { Text(it) }
        }
    }, confirmButton = { TextButton({
        saving = true
        scope.launch {
            val result = runCatching { withContext(Dispatchers.IO) { store.observe(entry.text, wanted, entry.raw ?: entry.text, entry.packageName, explicit = true) } }
            saving = false
            if (result.getOrNull()?.isNotEmpty() == true) close()
            else message = if (!store.allowed) notAllowed else if (result.isFailure) saveFailed else nothingNew
        }
    }, enabled = !saving && wanted != entry.text) { Text(stringResource(R.string.learning_teach)) } },
        dismissButton = { TextButton(close) { Text(stringResource(R.string.settings_cancel)) } })
}
