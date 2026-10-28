package dev.chirp.android

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun RetranscribeSheet(model: NotesModel) {
    if (model.retranscribeSheet) ModalBottomSheet(onDismissRequest = { model.retranscribeSheet = false },
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        val clips = model.retranscribeClips
        val health = model.retranscribeHealth
        val seconds = clips.sumOf { it.duration }.toInt()
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text(stringResource(R.string.notes_retranscribe_title, model.displayTitle), Modifier.semantics { heading() }, style = MaterialTheme.typography.titleLarge)
            Text(if (model.retranscribeSegment != null)
                stringResource(R.string.notes_retranscribe_send_clip, seconds / 60, (seconds % 60).toString().padStart(2, '0'), model.retranscribeDestination.text())
                else pluralStringResource(R.plurals.notes_retranscribe_send_note, clips.size, seconds / 60, seconds % 60, clips.size, model.retranscribeDestination.text()))
            Text(stringResource(R.string.notes_retranscribe_not_kept))
            Text(stringResource(R.string.notes_retranscribe_models, health?.speechModel ?: health?.engine ?: stringResource(R.string.notes_retranscribe_model_unknown), model.document.transcriptEngine.ui.text()))
            if (model.document.segments.isNotEmpty() && model.document.segments.all { it.engine != null && it.engine == health?.engine })
                Text(stringResource(R.string.notes_retranscribe_same_model))
            Text(stringResource(if (model.retranscribeCleanup) R.string.notes_retranscribe_cleanup_on else R.string.notes_retranscribe_cleanup_off))
            if (model.retranscribeCleanup && health?.correctionLeavesMachine == true && health.correctionHost != null)
                Text(stringResource(R.string.notes_retranscribe_cleanup_host, health.correctionHost))
            if (health?.debugRetention == true)
                Text(stringResource(R.string.notes_retranscribe_debug_retention), color = MaterialTheme.colorScheme.error)
            val missing = model.document.segments.count { segment -> model.document.audio.none { it.segment == segment.id } }
            if (missing > 0 && model.retranscribeSegment == null) Text(pluralStringResource(R.plurals.notes_retranscribe_missing_audio, missing, missing, model.document.segments.size))
            val rebuild = health?.correctionAvailable == true && health.notesStructure
            Row {
                Checkbox(model.rebuildChoice, { model.rebuildChoice = it }, enabled = rebuild)
                Column(Modifier.weight(1f)) {
                    Text(stringResource(R.string.notes_retranscribe_rebuild))
                    Text(stringResource(R.string.notes_retranscribe_rebuild_detail), style = MaterialTheme.typography.bodySmall)
                    if (!rebuild) Text(stringResource(R.string.notes_retranscribe_rebuild_needs_cleanup), style = MaterialTheme.typography.bodySmall)
                }
            }
            if (health?.notesRetranscribe != true) Text(stringResource(R.string.notes_retranscribe_update_chirp))
            else Button(model::startRetranscribe, Modifier.fillMaxWidth()) { Text(stringResource(if (health.debugRetention) R.string.notes_retranscribe_action_anyway else R.string.notes_retranscribe_action)) }
            TextButton({ model.retranscribeSheet = false }, Modifier.fillMaxWidth()) { Text(stringResource(R.string.notes_action_cancel)) }
        }
    }
    if (model.rebuildReview != null) AlertDialog(onDismissRequest = { model.rebuildReview = null },
        title = { Text(stringResource(R.string.notes_retranscribe_replace_title)) }, text = { Column(Modifier.verticalScroll(rememberScrollState())) {
            Text(stringResource(R.string.notes_retranscribe_replace_message))
            Text(requireNotNull(model.rebuildReview))
        } }, confirmButton = { TextButton(model::acceptRebuild) { Text(stringResource(R.string.notes_retranscribe_replace)) } },
        dismissButton = { TextButton({ model.rebuildReview = null }) { Text(stringResource(R.string.notes_retranscribe_keep_edits)) } })
}

@Composable
internal fun RetranscribeBanner(model: NotesModel) {
    model.retranscribeProgress?.let { progress ->
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp).semantics { liveRegion = LiveRegionMode.Polite }) {
            Text(progress.label.text())
            LinearProgressIndicator(progress = { if (progress.total == 0) 0f else progress.done.toFloat() / progress.total }, modifier = Modifier.fillMaxWidth())
            TextButton({ RetranscribeGate.owner?.cancelRetranscribe() }) { Text(stringResource(R.string.notes_action_cancel)) }
        }
    }
    model.retranscribeFailure?.let { failure ->
        Column(Modifier.padding(horizontal = 20.dp)) {
            Text(failure.ui.text(), color = MaterialTheme.colorScheme.error)
            if (model.canApplyRetranscribed) TextButton({ model.applyRetranscribed() }) { Text(stringResource(R.string.notes_retranscribe_apply_done)) }
            TextButton(model::cancelRetranscribe) { Text(stringResource(R.string.notes_action_cancel)) }
        }
    }
    model.retranscribeNotice?.let { notice ->
        Column(Modifier.padding(horizontal = 20.dp)) {
            Text(notice.ui.text(), Modifier.semantics { liveRegion = LiveRegionMode.Polite })
            if (notice == RetranscribeNotice.Rebuilt && model.canUndo) TextButton(model::undo) { Text(stringResource(R.string.notes_action_undo)) }
            else if (notice.restorable && model.document.previousTranscript != null) TextButton(model::restoreTranscript) { Text(stringResource(R.string.notes_action_undo)) }
            TextButton({ model.retranscribeNotice = null }) { Text(stringResource(R.string.notes_action_dismiss)) }
        }
    }
}
