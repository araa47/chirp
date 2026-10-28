package dev.chirp.android

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.Alignment
import dev.chirp.android.settings.PageScaffold
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import dev.chirp.android.ui.ActionRow
import dev.chirp.android.ui.SettingsGroup
import dev.chirp.android.ui.SettingsItem
import dev.chirp.android.ui.SwitchRow

/** A screen of its own, shared by the settings tree and the note's settings sheet. */
@Composable
internal fun SavedVoicesScreen(model: SavedVoicesModel, dismiss: () -> Unit) {
    Dialog(onDismissRequest = dismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize()) {
            BackHandler(onBack = dismiss)
            PageScaffold(stringResource(R.string.saved_voices_title), back = dismiss, scroll = rememberScrollState(), modifier = Modifier.fillMaxSize().safeDrawingPadding()) {
                SavedVoicesContent(model)
            }
        }
    }
}

@Composable
internal fun SavedVoicesContent(model: SavedVoicesModel) {
    var disable by remember { mutableStateOf(false) }
    var forgetAll by remember { mutableStateOf(false) }
    var forgetting by remember { mutableStateOf<SavedVoice?>(null) }
    var renaming by remember { mutableStateOf<SavedVoice?>(null) }
    var name by remember { mutableStateOf("") }
    val library = model.library
    SettingsGroup {
        SwitchRow(stringResource(R.string.saved_voices_remember), library?.enabled == true, { on ->
            if (on) model.action(VoiceAction.Enable) else disable = true
        }, enabled = library != null && !model.busy, summary = stringResource(R.string.saved_voices_remember_summary))
        SettingsItem {
            Text(stringResource(R.string.saved_voices_about),
                style = MaterialTheme.typography.bodyMedium)
        }
        model.error?.let { message ->
            SettingsItem { Text(message, color = MaterialTheme.colorScheme.error) }
        }
        if (model.busy) SettingsItem { Text(stringResource(R.string.saved_voices_updating)) }
        if (library?.voices?.isEmpty() == true) SettingsItem {
            Text(stringResource(R.string.saved_voices_empty), style = MaterialTheme.typography.bodyMedium)
        }
        library?.voices.orEmpty().forEach { voice ->
            SettingsItem {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f).padding(vertical = 8.dp)) {
                        Text(voice.name, style = MaterialTheme.typography.titleMedium)
                        Text(voiceDetail(voice), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        if (!voice.compatible) Text(stringResource(R.string.saved_voices_incompatible), style = MaterialTheme.typography.bodySmall)
                    }
                    var menu by remember(voice.id) { mutableStateOf(false) }
                    Box {
                        IconButton({ menu = true }, Modifier.size(48.dp), enabled = !model.busy,
                            colors = IconButtonDefaults.iconButtonColors(contentColor = MaterialTheme.colorScheme.onSurfaceVariant)) {
                            Icon(painterResource(R.drawable.ic_more_horiz), stringResource(R.string.saved_voices_options, voice.name))
                        }
                        DropdownMenu(menu, { menu = false }) {
                            DropdownMenuItem({ Text(stringResource(R.string.saved_voices_rename_menu)) }, { menu = false; renaming = voice; name = voice.name })
                            DropdownMenuItem({ Text(stringResource(R.string.saved_voices_forget_menu)) }, { menu = false; forgetting = voice })
                        }
                    }
                }
            }
        }
        ActionRow(stringResource(R.string.saved_voices_refresh), { model.refresh() })
        if (library?.voices?.isNotEmpty() == true) ActionRow(stringResource(R.string.saved_voices_forget_all_menu), { forgetAll = true }, destructive = true)
    }
    if (disable) AlertDialog(onDismissRequest = { disable = false }, title = { Text(stringResource(R.string.saved_voices_stop_title)) },
        text = { val count = library?.voices?.size ?: 0; Text(pluralStringResource(R.plurals.saved_voices_stop_message, count, count)) },
        confirmButton = { TextButton({ disable = false; model.action(VoiceAction.Disable(true)) }) { Text(stringResource(R.string.saved_voices_turn_off_forget)) } },
        dismissButton = { Row {
            TextButton({ disable = false; model.action(VoiceAction.Disable(false)) }) { Text(stringResource(R.string.saved_voices_keep)) }
            TextButton({ disable = false }) { Text(stringResource(R.string.notes_action_cancel)) }
        } })
    if (forgetAll || forgetting != null) AlertDialog(onDismissRequest = { forgetAll = false; forgetting = null },
        title = { Text(if (forgetAll) stringResource(R.string.saved_voices_forget_all_title) else stringResource(R.string.saved_voices_forget_title, forgetting?.name.orEmpty())) },
        text = { Text(if (forgetAll) stringResource(R.string.saved_voices_forget_all_message)
            else stringResource(R.string.saved_voices_forget_message, forgetting?.name.orEmpty())) },
        confirmButton = { TextButton({
            val action = forgetting?.let { VoiceAction.Forget(it.id) } ?: VoiceAction.ForgetAll
            forgetAll = false; forgetting = null; model.action(action)
        }) { Text(stringResource(R.string.saved_voices_forget)) } }, dismissButton = { TextButton({ forgetAll = false; forgetting = null }) { Text(stringResource(R.string.notes_action_cancel)) } })
    renaming?.let { voice ->
        AlertDialog(onDismissRequest = { renaming = null }, title = { Text(stringResource(R.string.saved_voices_rename_title)) },
            text = { Column {
                OutlinedTextField(name, { name = it.take(60) }, label = { Text(stringResource(R.string.saved_voices_name)) }, singleLine = true)
                Text(stringResource(R.string.saved_voices_names_stay), style = MaterialTheme.typography.bodySmall)
            } }, confirmButton = { TextButton({
                renaming = null; model.action(VoiceAction.Rename(voice.id, cleanVoiceName(name)))
            }, enabled = validVoiceName(cleanVoiceName(name))) { Text(stringResource(R.string.saved_voices_rename)) } },
            dismissButton = { TextButton({ renaming = null }) { Text(stringResource(R.string.notes_action_cancel)) } })
    }
}

@Composable
private fun voiceDetail(voice: SavedVoice): String {
    val earlier = stringResource(R.string.saved_voices_date_earlier)
    fun date(value: String): String = try {
        java.time.Instant.parse(value).atZone(java.time.ZoneId.systemDefault()).toLocalDate()
            .format(java.time.format.DateTimeFormatter.ofPattern("d MMM"))
    } catch (_: Exception) { earlier }
    return if (voice.updated != voice.created) stringResource(R.string.saved_voices_detail_updated, date(voice.created), date(voice.updated), voice.seconds.toInt())
    else stringResource(R.string.saved_voices_detail, date(voice.created), voice.seconds.toInt())
}
