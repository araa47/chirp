package dev.chirp.android

import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import dev.chirp.android.ui.ActionRow
import dev.chirp.android.ui.ChoiceChips
import dev.chirp.android.ui.SettingsGroup
import dev.chirp.android.ui.SettingsItem
import dev.chirp.android.ui.SwitchRow

/** Notes settings (library on by default, retention, kept audio, speaker labels), self-contained for the settings tree's Notes page and the Notes screen's own sheet ([title] there). */
@Composable
internal fun NotesSettings(sessions: NotesSessions? = null, title: String? = null, speakerState: NotesSpeakerModel? = null) {
    val context = LocalContext.current
    val store = remember { SettingsStore(context) }
    val kept = sessions ?: remember { NotesSessions(context) }
    val scope = rememberCoroutineScope()
    var recovery by remember { mutableStateOf(store.notesRecovery) }
    var saver by remember { mutableStateOf(store.notesBatterySaver) }
    var keep by remember { mutableStateOf(kept.enabled) }
    var retention by remember { mutableStateOf(kept.retention) }
    var allowRetranscribe by remember { mutableStateOf(store.notesAllowRetranscribe) }
    var keepAudio by remember { mutableStateOf(kept.keepAudio) }
    var audioBytes by remember { mutableStateOf(0L) }
    var confirmDeleteAudio by remember { mutableStateOf(false) }
    var confirmDeleteAll by remember { mutableStateOf(false) }
    val speakerClient = remember { ChirpNetwork.client(context) }
    DisposableEffect(speakerClient) { onDispose { ChirpNetwork.dispose(speakerClient) } }
    val speakers = speakerState ?: remember {
        NotesSpeakerModel(store, scope, io = { withContext(Dispatchers.IO) { it() } },
            fetch = { store.pairing()?.let { try { ChirpNetwork.health(speakerClient, it) } catch (_: Exception) { null } } },
            request = { action -> store.pairing()?.let { try { ChirpNetwork.speakerModel(speakerClient, it, action) } catch (_: Exception) { null } } })
    }
    var savedVoicesOpen by remember { mutableStateOf(false) }
    val voices = remember { SavedVoicesModel(scope, { withContext(Dispatchers.IO) { it() } }) { action ->
        ChirpNetwork.savedVoices(speakerClient, store.pairing() ?: throw VoiceLibraryError("auth"), action)
    } }
    LaunchedEffect(Unit) { speakers.refresh() }
    if (savedVoicesOpen) {
        LaunchedEffect(Unit) { voices.refresh() }
        SavedVoicesScreen(voices) { savedVoicesOpen = false }
    }
    LaunchedEffect(keepAudio, keep) {
        // A size that cannot be read is shown as none, never as a crash of the settings page.
        audioBytes = try { withContext(Dispatchers.IO) { kept.totalAudioBytes() } } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (_: Exception) { 0L }
    }
    val rows: @Composable ColumnScope.() -> Unit = {
        val onLabel = stringResource(R.string.notes_settings_on); val offLabel = stringResource(R.string.notes_settings_off)
        SwitchRow(stringResource(R.string.notes_settings_saver), saver, { saver = it; store.notesBatterySaver = it },
            summary = if (saver) onLabel else offLabel,
            infoTitle = stringResource(R.string.notes_settings_saver), infoBody = stringResource(R.string.notes_settings_saver_info))
        SwitchRow(stringResource(R.string.notes_settings_recovery), recovery, { on ->
            recovery = on; store.notesRecovery = on
            // Off is also a delete: the copy and its key go.
            if (!on) NotesJournal(context, store = store).delete()
        }, summary = if (recovery) onLabel else offLabel, infoTitle = stringResource(R.string.notes_settings_recovery),
            infoBody = stringResource(R.string.notes_settings_recovery_info))
        if (kept.optedOut && !keep) ActionRow(stringResource(R.string.notes_settings_enable_library), { kept.enable(); keep = true })
        else SwitchRow(stringResource(R.string.notes_settings_keep), keep, { on ->
            // Off stops keeping new notes; it never deletes the ones already kept.
            if (on) kept.enable() else kept.disable()
            keep = on
        }, summary = if (keep) stringResource(R.string.notes_settings_keep_on) else offLabel, infoTitle = stringResource(R.string.notes_settings_keep),
            infoBody = stringResource(R.string.notes_settings_keep_info))
        SettingsItem {
            Text(stringResource(R.string.notes_settings_retention), style = MaterialTheme.typography.bodyMedium)
            ChoiceChips(NotesRetention.entries, retention, { it.label }) { option ->
                retention = option
                scope.launch { withContext(Dispatchers.IO) { kept.retention = option } }
            }
            Text(pluralStringResource(R.plurals.notes_settings_retention_detail, NotesSessions.TRASH_DAYS, NotesSessions.TRASH_DAYS), style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        SwitchRow(stringResource(R.string.notes_settings_keep_audio), keepAudio, { on -> keepAudio = on; kept.keepAudio = on },
            summary = stringResource(R.string.notes_settings_off_by_default), infoTitle = stringResource(R.string.notes_settings_keep_audio),
            infoBody = stringResource(R.string.notes_settings_keep_audio_info))
        SwitchRow(stringResource(R.string.notes_settings_retranscribe), allowRetranscribe, { allowRetranscribe = it; store.notesAllowRetranscribe = it },
            enabled = keepAudio || audioBytes > 0, summary = if (allowRetranscribe) stringResource(R.string.notes_settings_retranscribe_on) else offLabel,
            infoTitle = stringResource(R.string.notes_settings_retranscribe), infoBody = stringResource(R.string.notes_settings_retranscribe_info))
        SwitchRow(stringResource(R.string.notes_settings_speakers), speakers.enabled, speakers::setLabels,
            summary = if (speakers.health != null && !speakers.available) stringResource(R.string.notes_settings_speakers_update)
                else stringResource(if (speakers.enabled) R.string.notes_settings_speakers_on else R.string.notes_settings_speakers_off),
            enabled = speakers.available, infoTitle = stringResource(R.string.notes_settings_speakers),
            infoBody = stringResource(R.string.notes_settings_speakers_info))
        if (speakers.available) {
            SettingsItem {
                Text(stringResource(when (speakers.state) {
                    "ready" -> R.string.notes_settings_speaker_model_ready
                    "downloading" -> R.string.notes_settings_speaker_model_downloading
                    "failed" -> R.string.notes_settings_speaker_model_failed
                    else -> R.string.notes_settings_speaker_model_missing
                }), style = MaterialTheme.typography.bodySmall)
                SpeakerModelStatus(speakers)
            }
            if (speakers.state == "ready") ActionRow(stringResource(R.string.notes_settings_remove_speaker_model), speakers::remove, destructive = true)
        }
        if (speakers.health?.speakerVoices == true) ActionRow(stringResource(R.string.saved_voices_title), { savedVoicesOpen = true })
        else SettingsItem { Text(stringResource(R.string.notes_settings_voices_update), style = MaterialTheme.typography.bodySmall) }
        if (audioBytes > 0) ActionRow(stringResource(R.string.notes_settings_delete_audio, megabytes(audioBytes)), { confirmDeleteAudio = true }, destructive = true, enabled = RetranscribeGate.owner == null)
        ActionRow(stringResource(R.string.notes_settings_delete_all), { confirmDeleteAll = true }, destructive = true)
    }
    if (title != null) SettingsGroup(title, content = rows) else SettingsGroup(content = rows)
    if (confirmDeleteAudio) AlertDialog(onDismissRequest = { confirmDeleteAudio = false },
        title = { Text(stringResource(R.string.notes_settings_delete_audio_title)) },
        text = { Text(stringResource(R.string.notes_settings_delete_audio_message)) },
        confirmButton = { TextButton({
            confirmDeleteAudio = false; audioBytes = 0
            scope.launch { withContext(Dispatchers.IO) { kept.deleteAllAudio() } }
        }) { Text(stringResource(R.string.notes_settings_delete_audio_confirm)) } },
        dismissButton = { TextButton({ confirmDeleteAudio = false }) { Text(stringResource(R.string.notes_action_cancel)) } })
    if (confirmDeleteAll) AlertDialog(onDismissRequest = { confirmDeleteAll = false },
        title = { Text(stringResource(R.string.notes_settings_delete_all_title)) },
        text = { Text(stringResource(R.string.notes_settings_delete_all_message)) },
        confirmButton = { TextButton({
            confirmDeleteAll = false; audioBytes = 0
            RetranscribeGate.owner?.cancelRetranscribe(); RetranscribeGate.rebuilds.clear()
            scope.launch { withContext(Dispatchers.IO) { kept.deleteAll() } }
        }) { Text(stringResource(R.string.notes_settings_delete_all_confirm)) } },
        dismissButton = { TextButton({ confirmDeleteAll = false }) { Text(stringResource(R.string.notes_action_cancel)) } })
}

/** Sealed audio size for settings and the note menu. Under 0.1 MB stays a threshold; larger sizes use the phone's locale. */
internal fun megabytes(bytes: Long) = if (bytes < 100_000) "<0.1 MB" else "%.1f MB".format(java.util.Locale.getDefault(), bytes / 1_000_000.0)

/** The settings list's one line for Notes, e.g. "Battery saver · recovery copy · keeps 7 days". */
internal fun notesSummary(context: android.content.Context): String {
    val store = SettingsStore(context); val kept = NotesSessions(context)
    return listOfNotNull(context.getString(R.string.notes_summary_saver).takeIf { store.notesBatterySaver }, context.getString(R.string.notes_summary_recovery).takeIf { store.notesRecovery },
        kept.takeIf { it.enabled }?.let { if (it.retention == NotesRetention.NEVER) context.getString(R.string.notes_summary_keeps) else context.getString(R.string.notes_summary_deletes_after, it.retention.label) })
        .joinToString(" · ").replaceFirstChar { it.uppercase() }.ifEmpty { context.getString(R.string.notes_settings_off) }
}
