package dev.chirp.android

import android.os.SystemClock
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.ui.text.input.ImeAction
import androidx.lifecycle.compose.LifecycleStartEffect
import dev.chirp.android.ui.Ripple
import dev.chirp.android.ui.ChirpTokens
import dev.chirp.android.ui.LocalChirpRoles
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.chirp.android.ui.StatusBanner
import dev.chirp.android.ui.StatusKind
import kotlinx.coroutines.delay

/** The transcript beside the notes from this width (an unfolded Fold, a tablet); a Notes · Transcript switch below it (the cover screen). */
private val SIDE_BY_SIDE = 1000.dp

/** Where to put the page when switching between reading and editing: a source offset and its distance from the top, px. */
private data class Anchor(val offset: Int, val y: Int)

/**
 * Live Notes as a notes app: the rendered page is the screen. A compact top bar (title, status, Organize, Edit, ⋮), one record
 * control at the bottom, and supporting actions in the overflow menu. Tap the words (or Edit) to edit the Markdown in
 * place, with a small formatting bar above the keyboard; Done or Back returns to the page at the same place.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalComposeUiApi::class)
@Composable
internal fun NotesScreen(model: NotesModel, record: () -> Unit, copy: () -> Unit, share: () -> Unit, act: (DictationAction) -> Unit,
                         leave: (Boolean) -> Unit, save: () -> Unit = {}, handleBack: Boolean = true, back: (() -> Unit)? = null, externalTranscript: Boolean = false, recordingElsewhere: NotesModel? = null, jumpToRecording: () -> Unit = {}, deleteNote: () -> Unit = {}, initiallyEditing: Boolean = false) {
    var renaming by remember { mutableStateOf(false) }
    var settings by remember { mutableStateOf(false) }
    var transcript by rememberSaveable { mutableStateOf(false) }
    var editing by rememberSaveable { mutableStateOf(initiallyEditing) }
    var anchor by remember { mutableStateOf<Anchor?>(null) }
    val focus = LocalFocusManager.current
    val list = rememberLazyListState()
    val scroll = rememberScrollState()
    var layout by remember { mutableStateOf<TextLayoutResult?>(null) }
    val blocks = remember(model.field.text) { NotesBlocks.parse(model.field.text) }
    /** Back on the page where the editor was: the block at the top of the editor, at the same height. */
    fun read() {
        layout?.let { l ->
            val offset = l.getOffsetForPosition(Offset(0f, scroll.value.toFloat()))
            blocks.getOrNull(NotesBlocks.at(blocks, offset))?.let { b -> anchor = Anchor(b.start, l.getLineTop(l.getLineForOffset(b.start)).toInt() - scroll.value) }
        }
        focus.clearFocus(); editing = false
    }
    AppShortcutActions(
        AppCommand.Record to { record(); true },
        AppCommand.Pause to { if (model.state.live) { model.togglePause(); true } else false },
        AppCommand.Edit to { if (editing) read() else editing = true; true },
        AppCommand.Escape to {
            when { settings -> { settings = false; true }; transcript -> { transcript = false; true }
                renaming -> { renaming = false; true }; editing -> { read(); true }; else -> false }
        },
    )
    BackHandler(enabled = handleBack) { model.keepSession(); leave(false) }
    BackHandler(enabled = editing) { read() }
    if (settings) ModalBottomSheet({ settings = false }) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(start = 16.dp, end = 16.dp, bottom = 24.dp)) { NotesSettings(title = stringResource(R.string.notes_editor_settings)) }
    }
    if (transcript && !externalTranscript) ModalBottomSheet({ transcript = false }, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        TranscriptPane(model, Modifier.fillMaxWidth().fillMaxHeight(.85f).padding(horizontal = 24.dp), close = { transcript = false })
    }
    RetranscribeSheet(model)
    if (model.nameSpeakersOpen) NameSpeakersSheet(model) { model.nameSpeakersOpen = false }
    model.voiceNotice?.let { name ->
        AlertDialog(onDismissRequest = model::acknowledgeVoiceNotice, title = { Text(stringResource(R.string.notes_editor_voice_notice_title)) },
            text = { Text(stringResource(R.string.notes_editor_voice_notice_message, name)) },
            confirmButton = { TextButton(model::acknowledgeVoiceNotice) { Text(stringResource(R.string.notes_editor_ok)) } },
            dismissButton = { TextButton(model::disableRememberVoices) { Text(stringResource(R.string.notes_editor_voice_notice_off)) } })
    }
    val menu = NotesMenuActions(copy = copy, share = share, save = save, rename = { renaming = true }, settings = { settings = true }, delete = deleteNote)
    /** Into the editor at the block tapped (or the first one on screen), at the height it had on the page. */
    fun startEditing(block: NotesBlock?) {
        val keys = NotesBlocks.keys(model.field.text, blocks)
        anchor = list.layoutInfo.visibleItemsInfo.firstNotNullOfOrNull { item ->
            val index = keys.indexOf(item.key).takeIf { it >= 0 && (block == null || blocks[it] == block) } ?: return@firstNotNullOfOrNull null
            Anchor(blocks[index].start, item.offset)
        }
        // A tap puts the caret at the end of the words tapped; Edit keeps the caret where it was.
        if (block != null) model.edit(model.field.copy(selection = TextRange(block.end.coerceAtMost(model.field.text.length))))
        editing = true
    }
    // Test tags as resource ids: the emulator harness reads the rendered page by its blocks' tags, never by their words.
    Surface(Modifier.fillMaxSize().semantics { testTagsAsResourceId = true }) {
        BoxWithConstraints(Modifier.fillMaxSize().safeDrawingPadding()) {
            val wide = !externalTranscript && maxWidth >= SIDE_BY_SIDE && maxWidth > maxHeight
            val density = LocalDensity.current
            // Hold to edit beside the recording pill needs roughly 380dp at normal text size; below that they stack, decided by
            // the window and font size rather than the labels so the button never jumps lines while held.
            val stackedDock = maxWidth / density.fontScale < 400.dp
            var dockHeight by remember { mutableIntStateOf(0) }
            val gutter = if (wide) 28.dp else 20.dp
            val statusMaxHeight = maxHeight * .35f

            Column(Modifier.fillMaxSize()) {
                NotesTopBar(model, editing, gutter, edit = { if (editing) read() else startEditing(null) }, menu,
                    renaming = renaming, rename = { renaming = it }, back = back)
                RetranscribeBanner(model)
                if (recordingElsewhere != null) AssistChip(jumpToRecording, modifier = Modifier.padding(horizontal = gutter),
                    label = { Text(stringResource(R.string.notes_editor_recording_elsewhere, recordingElsewhere.displayTitle, recordingElsewhere.elapsedText.text()), maxLines = 1, overflow = TextOverflow.Ellipsis) },
                    leadingIcon = { Ripple(recordingElsewhere.level.toFloat(), Modifier.size(20.dp)) })
                // Independent recovery, connection and speaker notices coexist; cap the stack so notes stay usable.
                NotesStatusStack(model, act, Modifier.padding(horizontal = gutter).heightIn(max = statusMaxHeight))
                if (!editing && !wide && !externalTranscript) Row(Modifier.padding(horizontal = gutter)) {
                    AssistChip({ transcript = true }, label = { Text(stringResource(R.string.notes_editor_transcript)) }, leadingIcon = { Icon(painterResource(R.drawable.ic_transcript), null, Modifier.size(18.dp)) })
                }
                Row(Modifier.fillMaxWidth().weight(1f)) {
                    Box(Modifier.weight(1.5f).fillMaxHeight()) {
                        when {
                            editing -> NotesEditor(model, scroll, anchor, { layout = it }, { anchor = null }, gutter, done = ::read)
                            else -> NotesPage(model, blocks, list, anchor, { anchor = null }, gutter,
                                with(density) { dockHeight.toDp() } + 32.dp, edit = ::startEditing)
                        }
                        if (!editing) NotesDock(model, record, Modifier.align(Alignment.BottomCenter).padding(horizontal = 16.dp, vertical = 16.dp)
                            .onSizeChanged { dockHeight = it.height }, allowCommand = recordingElsewhere == null, stacked = stackedDock)
                    }
                    if (wide) Surface(Modifier.weight(1f).fillMaxHeight().padding(end = 16.dp, bottom = 16.dp), shape = MaterialTheme.shapes.extraLarge,
                        color = MaterialTheme.colorScheme.surfaceContainerLow) {
                        TranscriptPane(model, Modifier.fillMaxSize().padding(horizontal = 20.dp, vertical = 12.dp))
                    }
                }
            }
        }
    }
}

private class NotesMenuActions(val copy: () -> Unit, val share: () -> Unit, val save: () -> Unit, val rename: () -> Unit, val settings: () -> Unit, val delete: () -> Unit)

/** Capture state is independent of structuring, connection and action feedback. */
@Composable
internal fun captureState(model: NotesModel): String = stringResource(when (model.state) {
    NotesRecorder.State.STARTING -> R.string.notes_capture_connecting
    NotesRecorder.State.PAUSED -> R.string.notes_capture_paused
    NotesRecorder.State.STOPPING -> R.string.notes_capture_finishing
    NotesRecorder.State.RECORDING -> R.string.notes_capture_recording
    else -> R.string.notes_capture_stopped
})

@Composable
internal fun NotesStatusStack(model: NotesModel, act: (DictationAction) -> Unit, modifier: Modifier = Modifier) {
    val status = model.status
    val action = status.action
    Column(modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (model.retained) StatusBanner(StatusKind.Error, stringResource(R.string.debug_retention))
        if (action != null) StatusBanner(StatusKind.Warning, status.text.text(), action = stringResource(action.label), onAction = { act(action) })
        if (model.recovered != null) StatusBanner(StatusKind.Info, stringResource(R.string.notes_editor_recovered_title), body = stringResource(R.string.notes_editor_recovered_body))
        if (model.speakerModelControl.status != null) SpeakerModelStatus(model.speakerModelControl)
        // Naming is premature while the model is still preparing. Keep the actionable model status instead.
        else if (model.askToNameSpeakers) StatusBanner(StatusKind.Info, stringResource(R.string.notes_editor_who_spoke), action = stringResource(R.string.notes_speakers_name_all_title),
            onAction = { model.nameSpeakersOpen = true })
        if (!model.retained && action == null) model.explanation?.let {
            Text(it.text(), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** Title (tap to rename) over a one-line status, then Edit and the overflow menu. */
@Composable
private fun NotesTopBar(model: NotesModel, editing: Boolean, gutter: androidx.compose.ui.unit.Dp, edit: () -> Unit, menu: NotesMenuActions, renaming: Boolean, rename: (Boolean) -> Unit, back: (() -> Unit)?) {
    val scheme = MaterialTheme.colorScheme
    Row(Modifier.fillMaxWidth().padding(start = gutter - 4.dp, end = 4.dp, top = 8.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        if (back != null) IconButton(back) { Icon(painterResource(R.drawable.ic_arrow_back), stringResource(R.string.notes_library_back)) }
        Column(Modifier.weight(1f)) {
            val title = model.displayTitle
            val titleDescription = stringResource(R.string.notes_editor_title_field)
            val renameDescription = stringResource(R.string.notes_editor_rename_title, title)
            if (renaming) {
                var name by remember { mutableStateOf(title) }
                val titleFocus = remember { FocusRequester() }
                LaunchedEffect(Unit) { titleFocus.requestFocus() }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    BasicTextField(name, { name = it.take(NotesModel.MAX_NAME) }, Modifier.weight(1f).focusRequester(titleFocus).semantics { contentDescription = titleDescription },
                        singleLine = true, textStyle = ChirpTokens.noteTitle.copy(color = scheme.onSurface), cursorBrush = SolidColor(scheme.primary),
                        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences, imeAction = ImeAction.Done),
                        keyboardActions = KeyboardActions(onDone = { model.rename(name); rename(false) }))
                    IconButton({ model.rename(name); rename(false) }) { Icon(painterResource(R.drawable.ic_check), stringResource(R.string.notes_editor_save_title)) }
                }
            } else {
                Text(title, Modifier.clip(MaterialTheme.shapes.small).clickable(onClickLabel = stringResource(R.string.notes_menu_rename), onClick = { rename(true) }).padding(horizontal = 4.dp)
                .semantics { contentDescription = renameDescription; heading() },
                style = ChirpTokens.noteTitle, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Row(Modifier.padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                if (model.state.active) LiveDot(model.recording)
                Text(model.status.text.text(), Modifier.weight(1f, fill = false).semantics { liveRegion = LiveRegionMode.Polite }, style = MaterialTheme.typography.labelLarge,
                    color = scheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (editing && (model.state.active || model.elapsed > 0)) Text(stringResource(R.string.notes_editor_elapsed, model.elapsedText.text()), style = dev.chirp.android.ui.ChirpTokens.timerSmall,
                    color = scheme.onSurfaceVariant)
            }
        }
        if (model.reorganizing !is Reorganizing.Unavailable) IconButton(model::organize, enabled = model.canOrganize,
            modifier = Modifier.size(48.dp), colors = IconButtonDefaults.iconButtonColors(contentColor = LocalChirpRoles.current.moon)) {
            Icon(painterResource(R.drawable.ic_sparkle), stringResource(R.string.notes_menu_organize))
        }
        IconButton(edit) { Icon(painterResource(if (editing) R.drawable.ic_check else R.drawable.ic_edit), stringResource(if (editing) R.string.notes_editor_done_editing else R.string.notes_editor_edit)) }
        NotesMenu(model, menu)
    }
}

@Composable
private fun LiveDot(on: Boolean) {
    val color = if (on) dev.chirp.android.ui.LocalChirpRoles.current.record else MaterialTheme.colorScheme.outline
    val alpha = if (on) rememberInfiniteTransition(label = "live").animateFloat(1f, .3f, infiniteRepeatable(tween(1000), RepeatMode.Reverse), label = "dot").value else 1f
    Box(Modifier.size(8.dp).alpha(alpha).clip(CircleShape).background(color).clearAndSetSemantics { })
}

@Composable
private fun NotesMenu(model: NotesModel, actions: NotesMenuActions) {
    var open by remember { mutableStateOf(false) }
    var confirmAudio by remember { mutableStateOf(false) }
    val bytes = model.document.audio.sumOf { it.bytes }
    Box {
        IconButton({ open = true }) { Icon(painterResource(R.drawable.ic_more_vert), stringResource(R.string.notes_menu_more)) }
        DropdownMenu(open, { open = false }) {
            @Composable fun item(label: String, icon: Int, enabled: Boolean = true, summary: String? = null, destructive: Boolean = false, run: () -> Unit) =
                DropdownMenuItem({ Column { Text(label); summary?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = if (destructive) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant) } } },
                    { open = false; run() }, leadingIcon = { Icon(painterResource(icon), null) }, enabled = enabled,
                    colors = if (destructive) MenuDefaults.itemColors(textColor = MaterialTheme.colorScheme.error, leadingIconColor = MaterialTheme.colorScheme.error) else MenuDefaults.itemColors())
            @Composable fun toggle(label: String, on: Boolean, summary: String? = null, set: (Boolean) -> Unit) {
                val state = stringResource(if (on) R.string.notes_settings_on else R.string.notes_settings_off)
                DropdownMenuItem({ Column { Text(label); summary?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) } } },
                    { set(!on) }, Modifier.semantics { role = Role.Switch; stateDescription = state },
                    trailingIcon = { Switch(on, null, Modifier.clearAndSetSemantics { }) })
            }
            if (model.reorganizing !is Reorganizing.Unavailable) {
                item(stringResource(R.string.notes_menu_organize), R.drawable.ic_sparkle, model.canOrganize) { model.organize() }
                if (model.canUndo && !model.canUndoRebuild) item(stringResource(R.string.notes_menu_undo_organize), R.drawable.ic_undo) { model.undo() }
            }
            if (model.structureAvailable) toggle(stringResource(R.string.notes_menu_structure), model.structureEnabled, model.structureHost?.let { stringResource(R.string.notes_menu_structure_host, it) }) { model.setStructure(it) }
            if (model.reorganizing !is Reorganizing.Unavailable) toggle(stringResource(R.string.notes_menu_organize_auto), model.auto) { model.setAuto(it) }
            if (model.speakersAvailable) toggle(stringResource(R.string.notes_settings_speakers), model.labelSpeakers, stringResource(R.string.notes_menu_speakers_summary)) { model.setSpeakerLabels(it) }
            if (model.reorganizing !is Reorganizing.Unavailable || model.structureAvailable || model.speakersAvailable) HorizontalDivider()
            item(stringResource(R.string.notes_menu_copy), R.drawable.ic_copy, model.hasContent, run = actions.copy)
            item(stringResource(R.string.notes_menu_share), R.drawable.ic_share, model.hasContent, run = actions.share)
            item(stringResource(R.string.notes_menu_export), R.drawable.ic_download, model.hasContent, run = actions.save)
            HorizontalDivider()
            item(stringResource(R.string.notes_menu_rename), R.drawable.ic_edit, run = actions.rename)
            if (model.canRetranscribe) item(stringResource(R.string.notes_menu_retranscribe), R.drawable.ic_mic) { model.askRetranscribe() }
            if (model.document.previousTranscript != null && !model.retranscribing && !model.state.active) item(stringResource(R.string.notes_menu_restore_transcript), R.drawable.ic_undo) { model.restoreTranscript() }
            if (model.canUndoRebuild) item(stringResource(R.string.notes_menu_undo_rebuild), R.drawable.ic_undo) { model.undo() }
            if (bytes > 0) {
                item(stringResource(R.string.notes_settings_delete_audio_confirm), R.drawable.ic_delete, enabled = !model.retranscribing, summary = stringResource(R.string.notes_menu_audio_size, megabytes(bytes)), destructive = true) { confirmAudio = true }
            }
            item(stringResource(R.string.notes_editor_settings), R.drawable.ic_settings, run = actions.settings)
            // Into Recently Deleted. The library shows Undo. A recording stays until it is stopped.
            item(stringResource(R.string.notes_library_row_delete), R.drawable.ic_delete, enabled = !model.state.active, destructive = true, run = actions.delete)
        }
    }
    if (confirmAudio) AlertDialog(onDismissRequest = { confirmAudio = false },
        title = { Text(stringResource(R.string.notes_menu_delete_audio_title)) },
        text = { Text(stringResource(R.string.notes_menu_delete_audio_message, megabytes(bytes))) },
        confirmButton = { TextButton({ confirmAudio = false; model.deleteAudio() },
            colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)) { Text(stringResource(R.string.notes_settings_delete_audio_confirm)) } },
        dismissButton = { TextButton({ confirmAudio = false }) { Text(stringResource(R.string.notes_action_cancel)) } })
}

/**
 * The rendered notes. New blocks fade in at the end; the list keys blocks by content, so text arriving below never moves
 * what is being read, and it follows the end only while the reader is already there.
 */
@Composable
private fun NotesPage(model: NotesModel, blocks: List<NotesBlock>, list: LazyListState, anchor: Anchor?, settled: () -> Unit,
                      gutter: androidx.compose.ui.unit.Dp, bottomInset: androidx.compose.ui.unit.Dp, edit: (NotesBlock?) -> Unit) {
    val text = model.field.text
    val keys = remember(text, blocks) { NotesBlocks.keys(text, blocks) }
    val hearing = model.hearing
    val lead = 0
    var follow by remember { mutableStateOf(true) }
    LaunchedEffect(list) {
        snapshotFlow { list.isScrollInProgress }.collect { scrolling -> if (!scrolling) follow = !list.canScrollForward }
    }
    LaunchedEffect(keys.lastOrNull(), hearing.length / 40) {
        if (follow && model.state.active && list.layoutInfo.totalItemsCount > 0) list.scrollToItem(list.layoutInfo.totalItemsCount - 1, 100_000)
    }
    LaunchedEffect(anchor) {
        val at = anchor ?: return@LaunchedEffect
        val index = NotesBlocks.at(blocks, at.offset).takeIf { blocks.isNotEmpty() } ?: return@LaunchedEffect settled()
        list.scrollToItem(index + lead); list.scrollBy(-at.y.toFloat()); settled()
    }
    val readable = Modifier.widthIn(max = NOTES_READING_WIDTH).fillMaxWidth().padding(horizontal = gutter)
    LazyColumn(Modifier.fillMaxSize().testTag("notes-page"), list, contentPadding = PaddingValues(top = 4.dp, bottom = bottomInset),
        horizontalAlignment = Alignment.CenterHorizontally) {
        itemsIndexed(blocks, key = { i, _ -> keys[i] }) { _, block ->
            NotesBlockView(block, edit, toggle = { task ->
                model.edit(model.field.copy(text = NotesBlocks.toggle(model.field.text, task)))
            }, readable.animateItem(fadeInSpec = tween(450), placementSpec = null, fadeOutSpec = null))
        }
        if (blocks.isEmpty() && hearing.isBlank()) item(key = "empty") { NotesEmpty(model.state.active, { edit(null) }, readable) }
        if (hearing.isNotBlank()) item(key = "hearing") { HearingLine(hearing, model.recording, readable.animateItem(fadeInSpec = tween(300), placementSpec = null)) }
    }
}

/**
 * The Markdown itself, borderless on the page, with the syntax lightly styled. The formatting bar (heading, bullet,
 * checklist, undo, Done) sits above the keyboard only while editing.
 */
@Composable
private fun NotesEditor(model: NotesModel, scroll: androidx.compose.foundation.ScrollState, anchor: Anchor?, laidOut: (TextLayoutResult) -> Unit,
                        settled: () -> Unit, gutter: androidx.compose.ui.unit.Dp, done: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    val undo = remember { NotesTextUndo() }
    val focus = remember { FocusRequester() }
    var layout by remember { mutableStateOf<TextLayoutResult?>(null) }
    val syntax = remember(scheme) { NotesSyntax(scheme.outline, scheme.primary) }
    val fieldDescription = stringResource(R.string.notes_editor_field)
    fun change(value: TextFieldValue) { undo.record(model.field, value.text); model.edit(value) }
    LaunchedEffect(Unit) { focus.requestFocus() }
    LaunchedEffect(layout != null, anchor) {
        val l = layout ?: return@LaunchedEffect; val at = anchor ?: return@LaunchedEffect
        scroll.scrollTo((l.getLineTop(l.getLineForOffset(at.offset.coerceIn(0, l.layoutInput.text.length))) - at.y).toInt().coerceAtLeast(0)); settled()
    }
    Column(Modifier.fillMaxSize()) {
        Box(Modifier.weight(1f).fillMaxWidth().verticalScroll(scroll), contentAlignment = Alignment.TopCenter) {
            BasicTextField(model.field, ::change, Modifier.widthIn(max = NOTES_READING_WIDTH).fillMaxWidth().padding(horizontal = gutter, vertical = 8.dp)
                .focusRequester(focus).onFocusChanged { model.focused = it.isFocused }.semantics { contentDescription = fieldDescription },
                textStyle = NotesType.body.copy(color = scheme.onSurface), cursorBrush = SolidColor(scheme.primary), visualTransformation = syntax,
                // No autocorrect or suggestions rewriting what was said.
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences, autoCorrectEnabled = false),
                onTextLayout = { layout = it; laidOut(it) },
                decorationBox = { inner ->
                    Box {
                        if (model.field.text.isEmpty()) Text(stringResource(R.string.notes_editor_placeholder),
                            style = NotesType.body, color = scheme.onSurfaceVariant)
                        inner()
                    }
                })
        }
        Surface(color = scheme.surfaceContainer) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                listOf(Triple(NotesLineKind.HEADING, R.drawable.ic_format_heading, R.string.notes_editor_heading), Triple(NotesLineKind.BULLET, R.drawable.ic_format_bullets, R.string.notes_editor_bullets),
                    Triple(NotesLineKind.TASK, R.drawable.ic_checklist, R.string.notes_editor_checklist)).forEach { (kind, icon, label) ->
                    IconButton({ change(NotesFormat.toggle(model.field, kind)) }) { Icon(painterResource(icon), stringResource(label)) }
                }
                VerticalDivider(Modifier.height(24.dp).padding(horizontal = 4.dp))
                IconButton({ undo.undo(model.field.text)?.let(model::edit) }, enabled = undo.canUndo(model.field.text)) { Icon(painterResource(R.drawable.ic_undo), stringResource(R.string.notes_action_undo)) }
                Spacer(Modifier.weight(1f))
                TextButton(done) { Text(stringResource(R.string.notes_speakers_done)) }
            }
        }
    }
}

/**
 * The one prominent control: Record when stopped; while recording a floating pill with Pause, the level meter and the
 * running time, and Stop. Edit by voice sits beside it when the Mac offers it. Notes about the last action float above.
 */
@Composable
private fun NotesDock(model: NotesModel, record: () -> Unit, modifier: Modifier, allowCommand: Boolean = true, stacked: Boolean = false) {
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Notices(model)
        val command = allowCommand && model.voiceEditAvailable && (model.state.active || model.hasContent)
        if (stacked) {
            if (command) CommandButton(model, Modifier)
            if (model.state.active) RecordingPill(model, record) else RecordButton(model, record)
        } else Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
            if (command) CommandButton(model, Modifier.weight(1f, fill = false))
            if (model.state.active) RecordingPill(model, record) else RecordButton(model, record)
        }
    }
}

@Composable
private fun Notices(model: NotesModel) {
    val organized = model.organizeNote
    var shown by remember { mutableStateOf<UiText?>(null) }
    LaunchedEffect(organized) { shown = organized; if (organized != null) { delay(NOTICE_MS); shown = null } }
    LaunchedEffect(model.voiceEditDone) { if (model.voiceEditNote != null) { delay(NotesVoiceEdit.NOTE_MS); model.dismissVoiceEdit() } }
    when {
        model.listeningForCommand -> TextButton(model::cancelCommand) { Text(stringResource(R.string.notes_action_cancel)) }
        model.showEditedChip -> EditedChip(model)
        model.voiceEditNote != null -> Notice(model.voiceEditNote!!.text())
        shown != null -> Notice(shown!!.text())
    }
}

private const val NOTICE_MS = 6000L

@Composable
private fun Notice(text: String) {
    Surface(shape = MaterialTheme.shapes.medium, color = MaterialTheme.colorScheme.inverseSurface, contentColor = MaterialTheme.colorScheme.inverseOnSurface,
        shadowElevation = 2.dp) {
        Text(text, Modifier.padding(horizontal = 16.dp, vertical = 10.dp).semantics { liveRegion = LiveRegionMode.Polite }, style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
private fun RecordButton(model: NotesModel, onClick: () -> Unit) {
    val scheme = MaterialTheme.colorScheme
    val resume = model.hasContent || model.elapsed > 0
    val description = stringResource(if (resume) R.string.notes_dock_continue else R.string.notes_dock_record_notes)
    Surface(onClick, Modifier.heightIn(min = 64.dp).semantics { contentDescription = description }, enabled = !model.busy && !model.retranscribing, shape = CircleShape,
        color = scheme.primary, contentColor = scheme.onPrimary, shadowElevation = 6.dp) {
        Row(Modifier.padding(start = 22.dp, end = 26.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Icon(painterResource(R.drawable.ic_record), null, Modifier.size(22.dp), tint = scheme.onPrimary)
            Text(stringResource(if (resume) R.string.notes_dock_continue else R.string.notes_library_record), style = MaterialTheme.typography.titleMedium)
        }
    }
}

@Composable
private fun RecordingPill(model: NotesModel, stop: () -> Unit, modifier: Modifier = Modifier) {
    val scheme = MaterialTheme.colorScheme
    val state = captureState(model)
    val pauseDescription = stringResource(if (model.paused) R.string.notes_dock_resume else R.string.notes_dock_pause)
    val pillDescription = stringResource(R.string.notes_dock_description, model.displayTitle, model.elapsedText.text())
    val stopDescription = stringResource(R.string.notes_dock_stop)
    Surface(modifier.testTag("notes-recording-dock"), shape = CircleShape, color = scheme.surfaceContainerHighest, shadowElevation = 6.dp) {
        Row(Modifier.heightIn(min = 64.dp).padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            val canPause = model.state == NotesRecorder.State.RECORDING || model.paused
            FilledTonalIconButton(model::togglePause, Modifier.size(48.dp).semantics { contentDescription = pauseDescription },
                enabled = canPause) {
                Icon(painterResource(if (model.paused) R.drawable.ic_play else R.drawable.ic_pause), null)
            }
            // One quiet node: the note, its truthful state and the running time are read on focus, never announced as the clock ticks.
            Row(Modifier.padding(horizontal = 12.dp).clearAndSetSemantics { contentDescription = pillDescription; stateDescription = state },
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                // The ripple is the listening sign; paused shows no ripple, only its word.
                if (model.busy) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                else if (model.recording) Ripple(model.level.toFloat(), Modifier.size(24.dp))
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(state, style = MaterialTheme.typography.labelSmall, color = scheme.onSurfaceVariant)
                    Text(model.elapsedText.text(), style = dev.chirp.android.ui.ChirpTokens.timer)
                }
            }
            FilledIconButton(stop, Modifier.size(48.dp).semantics { contentDescription = stopDescription }, enabled = !model.busy,
                colors = IconButtonDefaults.filledIconButtonColors(containerColor = dev.chirp.android.ui.LocalChirpRoles.current.record, contentColor = scheme.onError)) {
                Icon(painterResource(R.drawable.ic_stop), null)
            }
        }
    }
}

/**
 * Edit by voice: hold it and say what to change, let go to send. A quick tap latches it and the next tap sends, which is
 * also what TalkBack's double tap does. What is said goes to the edit and never into the transcript.
 */
@Composable
private fun CommandButton(model: NotesModel, modifier: Modifier) {
    val listening = model.listeningForCommand
    val enabled = model.canCommand
    var pressed by remember { mutableStateOf(false) }
    val colors = MaterialTheme.colorScheme
    val (container, content) = if (listening) colors.errorContainer to colors.onErrorContainer else colors.tertiaryContainer to colors.onTertiaryContainer
    val description = stringResource(if (listening) R.string.notes_command_send_description else R.string.notes_command_description)
    val clickLabel = stringResource(if (listening) R.string.notes_command_send else R.string.notes_command_start)
    Surface(modifier.heightIn(min = 56.dp).alpha(if (enabled) 1f else 0.38f)
        .pointerInput(enabled) {
            if (enabled) awaitEachGesture {
                val down = awaitFirstDown()
                pressed = true; model.commandPress()
                val up = waitForUpOrCancellation()
                pressed = false
                model.commandRelease((up?.uptimeMillis ?: SystemClock.uptimeMillis()) - down.uptimeMillis)
            }
        }
        .semantics(mergeDescendants = true) {
            role = Role.Button
            contentDescription = description
            onClick(clickLabel) { model.command(); true }
            if (!enabled) disabled()
        }, shape = CircleShape, color = container, contentColor = content, shadowElevation = 3.dp) {
        Row(Modifier.padding(horizontal = 18.dp), Arrangement.Center, Alignment.CenterVertically) {
            Icon(painterResource(if (listening) R.drawable.ic_mic else R.drawable.ic_sparkle), null, Modifier.size(20.dp))
            Spacer(Modifier.width(8.dp))
            Text(stringResource(when { !listening -> R.string.notes_command_hold; pressed -> R.string.notes_command_release; else -> R.string.notes_command_tap }), style = MaterialTheme.typography.labelLarge,
                maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** "Edited · Undo", for 20 s after a voice edit (or until the next edit or a click). */
@Composable
private fun EditedChip(model: NotesModel) {
    Surface(shape = CircleShape, color = MaterialTheme.colorScheme.tertiaryContainer, contentColor = MaterialTheme.colorScheme.onTertiaryContainer, shadowElevation = 2.dp) {
        Row(Modifier.padding(start = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            val undoDescription = stringResource(R.string.notes_command_undo_description)
            Text(stringResource(R.string.notes_status_edited), style = MaterialTheme.typography.labelLarge)
            TextButton(model::undoVoiceEdit, Modifier.semantics { contentDescription = undoDescription }) { Text(stringResource(R.string.notes_action_undo)) }
        }
    }
    LaunchedEffect(model.voiceEditDone) { delay(NotesVoiceEdit.CHIP_MS); model.dismissVoiceEdit() }
}

/** One quiet line per segment: the time as metadata, then what was said. */
@Composable
internal fun TranscriptPane(model: NotesModel, modifier: Modifier, titled: Boolean = true, close: (() -> Unit)? = null) {
    val scheme = MaterialTheme.colorScheme
    val locale = androidx.compose.ui.platform.LocalConfiguration.current.locales[0]
    val player = remember(model.library) { model.library?.let(::NotesAudioPlayer) }
    val playing by (player?.playing ?: remember { kotlinx.coroutines.flow.MutableStateFlow<NotesClipRef?>(null) }).collectAsState()
    val playbackFailed by (player?.failed ?: remember { kotlinx.coroutines.flow.MutableStateFlow(false) }).collectAsState()
    LifecycleStartEffect(player) { onStopOrDispose { player?.stop() } }
    Column(modifier) {
        androidx.compose.foundation.layout.FlowRow(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
            if (titled) Text(stringResource(R.string.notes_editor_transcript), Modifier.semantics { heading() }, style = MaterialTheme.typography.titleSmall, color = scheme.onSurfaceVariant)
            Spacer(Modifier.weight(1f))
            if (model.canRetranscribe) TextButton({ model.askRetranscribe() }) { Text(stringResource(R.string.notes_menu_retranscribe)) }
            if (model.document.previousTranscript != null && !model.retranscribing && !model.state.active) TextButton(model::restoreTranscript) { Text(stringResource(R.string.notes_menu_restore_transcript)) }
            if (model.document.labelled && !model.retranscribing) TextButton({ model.nameSpeakersOpen = true }) { Text(stringResource(R.string.notes_speakers_name_all_title)) }
            FilterChip(model.raw, { model.raw = !model.raw }, label = { Text(stringResource(R.string.notes_transcript_show_raw)) })
            if (close != null) IconButton(close) { Icon(painterResource(R.drawable.ic_close), stringResource(R.string.notes_transcript_close)) }
        }
        Text(stringResource(R.string.notes_transcript_engine, model.document.transcriptEngine.ui.text()), style = MaterialTheme.typography.bodySmall, color = scheme.onSurfaceVariant)
        if (playbackFailed) Text(stringResource(R.string.notes_transcript_playback_failed), Modifier.padding(vertical = 8.dp), color = scheme.error, style = MaterialTheme.typography.bodyMedium)
        val document = model.document
        val roster = document.roster
        var renaming by remember { mutableStateOf<Int?>(null) }
        renaming?.let { person ->
            RenameSpeakerDialog(model, person, { renaming = null }) { name, replace, remember ->
                renaming = null; model.renameSpeaker(person, name, replace, remember)
            }
        }
        // A copy: the document's list is the same object as it grows, which the lazy list would not see change.
        val rows = document.segments.toList()
        model.speakerNote?.let { Text(it.text(), Modifier.padding(vertical = 4.dp), color = scheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall) }
        val list = rememberLazyListState()
        LaunchedEffect(rows.size) { if (rows.isNotEmpty() && !list.canScrollForward) list.animateScrollToItem(rows.size) }
        LazyColumn(Modifier.fillMaxWidth().weight(1f), list, contentPadding = PaddingValues(top = 4.dp, bottom = 128.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            items(rows, key = { it.id }) { segment ->
                val active = playing == NotesClipRef(document.uid, segment.id)
                val playingState = stringResource(R.string.notes_transcript_playing)
                val clip = document.audio.firstOrNull { it.segment == segment.id }
                val boundary = document.boundaries.firstOrNull { it.offset == segment.offset }
                if (boundary != null) Text(stringResource(R.string.notes_transcript_continued, java.text.SimpleDateFormat("MMM d, h:mm a", locale).format(java.util.Date(boundary.time))),
                    Modifier.padding(vertical = 8.dp), style = MaterialTheme.typography.labelMedium, color = scheme.onSurfaceVariant)
                Column {
                if (clip != null && model.canRetranscribe && segment.isGap) TextButton({ model.askRetranscribe(segment.id) }) { Text(stringResource(R.string.notes_library_try_again)) }
                var segmentMenu by remember { mutableStateOf(false) }
                Box {
                DropdownMenu(segmentMenu && model.canRetranscribe, { segmentMenu = false }) { DropdownMenuItem({ Text(stringResource(R.string.notes_menu_retranscribe)) }, { segmentMenu = false; model.askRetranscribe(segment.id) }) }
                Row(Modifier.combinedClickable(onClick = {}, onLongClick = { if (clip != null && model.canRetranscribe) segmentMenu = true }).animateItem(fadeInSpec = tween(300), placementSpec = null).clip(MaterialTheme.shapes.medium)
                    .background(if (active) scheme.secondaryContainer else androidx.compose.ui.graphics.Color.Transparent).padding(8.dp)
                    .semantics { if (active) stateDescription = playingState }, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    if (clip != null) IconButton({ if (active) player?.stop() else player?.play(document.uid, segment.id) }, Modifier.size(48.dp)) {
                        Icon(painterResource(if (active) R.drawable.ic_stop else R.drawable.ic_play), if (active) stringResource(R.string.notes_transcript_stop_playback) else stringResource(R.string.notes_transcript_play_segment, segment.id + 1), tint = scheme.primary)
                    }
                    Text(NotesDocument.timestamp(segment.offset), Modifier.padding(top = 2.dp), style = MaterialTheme.typography.labelSmall, fontFamily = FontFamily.Monospace,
                        color = scheme.outline)
                    val failure = segment.failure
                    val turns = segment.turns
                    if (failure != null) Text(stringResource(R.string.notes_transcript_failed, failure), color = scheme.error, style = MaterialTheme.typography.bodyMedium)
                    else if (!turns.isNullOrEmpty()) Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        turns.forEachIndexed { i, turn ->
                            if ((if (model.raw) turn.raw else turn.text).isBlank()) return@forEachIndexed
                            var menu by remember { mutableStateOf(false) }
                            Box {
                                SpeakerChip(roster.displayName(turn.effectivePerson), roster.colorIndex(turn.effectivePerson), { if (!model.retranscribing) menu = true },
                                    recognized = roster.person(roster.resolve(turn.effectivePerson))?.recognized != null)
                                SpeakerMenu(menu, { menu = false }, roster, turn.effectivePerson, rename = { renaming = roster.resolve(turn.effectivePerson) },
                                    merge = { into -> model.mergeSpeaker(turn.effectivePerson, into) }, separate = model::separateSpeaker,
                                    nameAll = { model.nameSpeakersOpen = true }, reject = { model.rejectVoice(turn.effectivePerson) },
                                    update = if (model.rememberVoices) ({ model.updateVoice(turn.effectivePerson) }) else null,
                                    reassign = { person -> model.reassignTurn(segment.id, i, person) })
                            }
                            val words = if (model.raw) turn.raw else turn.text
                            Text(if ((turn.keptOriginal || segment.keptOriginal) && !model.raw) stringResource(R.string.notes_transcript_kept_original, words) else words,
                                style = MaterialTheme.typography.bodyMedium)
                        }
                    }
                    else Text(if (segment.keptOriginal && !model.raw) stringResource(R.string.notes_transcript_kept_original, segment.text) else if (model.raw) segment.raw else segment.text,
                        modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                }
                }
                }
            }
            if (document.livePartial.isNotBlank()) item(key = "partial") {
                Text(document.livePartial, Modifier.padding(start = 76.dp), color = scheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium, fontStyle = FontStyle.Italic)
            }
            if (rows.isEmpty() && document.livePartial.isBlank()) item(key = "empty") {
                Text(stringResource(R.string.notes_transcript_empty), color = scheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
            }
        }
    }
}
