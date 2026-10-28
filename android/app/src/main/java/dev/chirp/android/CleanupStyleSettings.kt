package dev.chirp.android

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import dev.chirp.android.ui.NavRow

@Composable
internal fun CleanupStyleSettings(health: Health?, appsOnly: Boolean = false) {
    if (!health.cleanupAvailable()) return
    val context = LocalContext.current
    val store = remember { SettingsStore(context) }
    var loaded by remember { mutableStateOf<List<CorrectionProfile>>(emptyList()) }
    val profiles = if (loaded.isEmpty()) CleanupStyles.profiles(health) else loaded
    var edits by remember { mutableStateOf(store.promptEdits) }
    var editingPrompt by remember { mutableStateOf<CorrectionProfile?>(null) }
    val loadingPrompts = stringResource(R.string.cleanup_prompts_loading)
    val pairToLoad = stringResource(R.string.cleanup_prompts_pair)
    val promptsUnavailable = stringResource(R.string.cleanup_prompts_unavailable)
    var promptStatus by remember { mutableStateOf(loadingPrompts) }
    var reload by remember { mutableIntStateOf(0) }
    var open by remember { mutableStateOf(false) }
    LaunchedEffect(open, health, reload) {
        if (!open || appsOnly) return@LaunchedEffect
        val paired = store.pairing()
        if (paired == null) { promptStatus = pairToLoad; return@LaunchedEffect }
        val client = ChirpNetwork.client(context)
        try {
            loaded = withContext(Dispatchers.IO) { ChirpNetwork.profiles(client, paired) }
            promptStatus = ""
        } catch (_: Exception) { promptStatus = promptsUnavailable }
        finally { ChirpNetwork.dispose(client) }
    }
    var default by remember { mutableStateOf(store.defaultStyle) }
    var apps by remember { mutableStateOf(store.appStyles) }
    var selecting by remember { mutableStateOf(false) }
    var editingApp by remember { mutableStateOf<String?>(null) }
    var packageName by remember { mutableStateOf("") }
    val defaultName = stringResource(R.string.cleanup_default)
    val defaultStyleName = profiles.firstOrNull { it.id == default }?.name ?: defaultName
    NavRow(stringResource(if (appsOnly) R.string.cleanup_per_app_styles else R.string.cleanup_styles), { open = true },
        summary = if (apps.isEmpty()) defaultStyleName else pluralStringResource(R.plurals.cleanup_styles_summary_apps, apps.size, defaultStyleName, apps.size))
    if (open) AlertDialog(onDismissRequest = { open = false }, title = { Text(stringResource(if (appsOnly) R.string.cleanup_per_app_styles else R.string.cleanup_styles_title)) },
        text = {
            Column(Modifier.fillMaxWidth().heightIn(max = 480.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (!appsOnly) {
                Text(stringResource(R.string.cleanup_default_style))
                OutlinedButton({ editingApp = null; selecting = true }) {
                    Text(defaultStyleName)
                }
                Text(stringResource(R.string.cleanup_safety_restructure), style = MaterialTheme.typography.bodySmall)
                if (promptStatus.isNotEmpty()) {
                    Text(promptStatus, style = MaterialTheme.typography.bodySmall)
                    TextButton({ reload++ }) { Text(stringResource(R.string.cleanup_prompts_retry)) }
                }
                profiles.forEach { profile ->
                    Text(if (edits.containsKey(profile.id)) stringResource(R.string.cleanup_profile_edited, profile.name) else profile.name, style = MaterialTheme.typography.titleSmall)
                    Text(profile.description, style = MaterialTheme.typography.bodySmall)
                    TextButton({ editingPrompt = profile }, enabled = profile.prompt != null) { Text(stringResource(R.string.cleanup_edit_prompt, profile.name)) }
                }
                HorizontalDivider()
                }
                Text(stringResource(R.string.cleanup_per_app_styles), style = MaterialTheme.typography.titleSmall)
                Text(stringResource(R.string.cleanup_per_app_hint), style = MaterialTheme.typography.bodySmall)
                apps.toSortedMap().forEach { (app, style) ->
                    Column {
                        Text(app, style = MaterialTheme.typography.bodySmall)
                        Row {
                            TextButton({ editingApp = app; selecting = true }) {
                                Text(profiles.firstOrNull { it.id == style }?.name ?: defaultName)
                            }
                            TextButton({ apps = apps - app; store.appStyles = apps }) { Text(stringResource(R.string.cleanup_remove)) }
                        }
                    }
                }
                OutlinedTextField(packageName, { packageName = it.trim() }, label = { Text(stringResource(R.string.cleanup_app_package)) },
                    placeholder = { Text("com.example.app") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                TextButton({ editingApp = packageName; selecting = true },
                    enabled = packageName.matches(Regex("[a-zA-Z0-9_]+(\\.[a-zA-Z0-9_]+)+"))) { Text(stringResource(R.string.cleanup_add_app)) }
            }
        }, confirmButton = { TextButton({ open = false }) { Text(stringResource(R.string.settings_done)) } })
    if (selecting) AlertDialog(onDismissRequest = { selecting = false }, title = { Text(stringResource(R.string.cleanup_choose_style)) },
        text = {
            Column(Modifier.heightIn(max = 400.dp).verticalScroll(rememberScrollState())) {
                profiles.forEach { profile ->
                    TextButton({
                        val app = editingApp
                        if (app == null) { default = profile.id; store.defaultStyle = default }
                        else { apps = apps + (app to profile.id); store.appStyles = apps; packageName = "" }
                        selecting = false
                    }) {
                        Column {
                            Text(if (profile.rewrites) stringResource(R.string.cleanup_profile_rewrites, profile.name) else profile.name)
                            if (profile.description.isNotBlank()) Text(profile.description, style = MaterialTheme.typography.bodySmall)
                        }
                    }
                }
            }
        }, confirmButton = { TextButton({ selecting = false }) { Text(stringResource(R.string.settings_cancel)) } })
    editingPrompt?.let { profile ->
        var draft by remember(profile.id) { mutableStateOf(edits[profile.id] ?: profile.prompt.orEmpty()) }
        AlertDialog(onDismissRequest = { editingPrompt = null }, title = { Text(stringResource(R.string.cleanup_prompt_title, profile.name)) },
            text = { Column {
                Text(profile.description)
                OutlinedTextField(draft, { value ->
                    draft = CleanupStyles.limit(value, profile.maxPromptChars)
                    edits = if (draft == profile.prompt) edits - profile.id else edits + (profile.id to draft)
                    store.promptEdits = edits
                }, modifier = Modifier.fillMaxWidth().heightIn(max = 300.dp), minLines = 4,
                    label = { Text(stringResource(if (edits.containsKey(profile.id)) R.string.cleanup_prompt_edited else R.string.cleanup_prompt_default)) },
                    supportingText = { Text("${CleanupStyles.characterCount(draft)} / ${profile.maxPromptChars}") })
                Text(stringResource(R.string.cleanup_safety_clean_only), style = MaterialTheme.typography.bodySmall)
                TextButton({ edits = edits - profile.id; store.promptEdits = edits; draft = profile.prompt.orEmpty() }) { Text(stringResource(R.string.cleanup_reset_prompt)) }
            } }, confirmButton = { TextButton({ editingPrompt = null }) { Text(stringResource(R.string.settings_done)) } })
    }

}
