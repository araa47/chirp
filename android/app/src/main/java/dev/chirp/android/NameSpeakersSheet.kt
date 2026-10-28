package dev.chirp.android

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.heightIn
import androidx.compose.material3.Surface
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.window.Dialog
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SuggestionChip
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

/**
 * "Name speakers": everyone in the note in one place, instead of a menu per chip. A row per person has their colour, a name
 * field that suggests names from recent notes, a line of what they said first (with ▶ when audio was kept) and "Same as"
 * to merge. Done names them all at once; one toggle replaces the old names in the notes too. Remember voice uses the server library.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun NameSpeakersSheet(model: NotesModel, dismiss: () -> Unit) {
    val document = model.document
    val roster = remember(document) { SpeakerRoster.fromJson(document.roster.toJson()) }
    val merges = remember(document) { mutableStateMapOf<Int, Int>() }
    LaunchedEffect(Unit) { model.loadRecentNames() }
    val player = remember(model.library) { model.library?.let(::NotesAudioPlayer) }
    val playing by (player?.playing ?: remember { kotlinx.coroutines.flow.MutableStateFlow<NotesClipRef?>(null) }).collectAsState()
    androidx.compose.runtime.DisposableEffect(player) { onDispose { player?.stop() } }
    // What is typed, by person; a person with no entry shows the name they have now.
    val rememberVoice = remember { mutableStateMapOf<Int, Boolean>() }
    val drafts = remember { mutableStateMapOf<Int, String>() }
    var samplePerson by remember { mutableStateOf<Int?>(null) }
    val people = merges.size.let { roster.active }
    fun draft(id: Int) = drafts[id] ?: roster.person(id)?.name.orEmpty()
    // Old display name → new one, for the people whose name would change.
    val renames = document.roster.active.mapNotNull { id ->
        val target = roster.resolve(id)
        val new = draft(target).trim().ifEmpty { "Person $target" }
        document.roster.displayName(id).let { old -> if (old != new) old to new else null }
    }.toMap()
    val count = remember(document.version, document.speakerVersion, renames) { document.nameCount(renames.keys) }
    var replace by remember { mutableStateOf(true) }
    var focused by remember { mutableStateOf<Int?>(null) }
    val used = people.map { draft(it).trim().lowercase() }.toSet()
    fun finish() { model.renameSpeakers(people.associateWith { draft(it) }, replace && count > 0, merges.toMap(), people.filter { rememberVoice[it] != false }.toSet()); dismiss() }

    val content: @Composable () -> Unit = {
        Column(Modifier.imePadding().navigationBarsPadding().padding(horizontal = 24.dp).padding(bottom = 16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.notes_speakers_name_all_title), Modifier.weight(1f).semantics { heading() }, style = MaterialTheme.typography.titleLarge)
                TextButton(dismiss) { Text(stringResource(R.string.notes_action_cancel)) }
                TextButton(::finish, Modifier.testTag("name_speakers_done")) { Text(stringResource(R.string.notes_speakers_done)) }
            }
            Text(stringResource(R.string.notes_speakers_name_all_detail),
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Column(Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState()).padding(top = 8.dp)) {
                people.forEachIndexed { index, id ->
                    if (index > 0) HorizontalDivider(Modifier.padding(vertical = 8.dp))
                    val first = document.firstTurn(id)
                    val clip = first?.let { (segment, _) -> document.audio.firstOrNull { it.segment == segment } }
                    val isPlaying = samplePerson == id && clip != null && playing == NotesClipRef(document.uid, clip.segment)
                    SpeakerRow(roster, id, draft(id), { drafts[id] = it.take(SpeakerRoster.MAX_NAME) }, focused == id,
                        { if (it) focused = id else if (focused == id) focused = null }, finish = ::finish,
                        sample = first?.second, playing = isPlaying, play = clip?.let { c ->
                            { if (isPlaying) player?.stop() else { samplePerson = id; player?.play(document.uid, c.segment, document.sampleOffset(id)) } }
                        },
                        suggestions = if (focused == id) suggestions(model.savedVoices.library?.voices.orEmpty().map { it.name } + model.recentNames, draft(id), used - draft(id).trim().lowercase()) else emptyList(),
                        merge = { into -> player?.stop(); drafts.remove(id); roster.merge(id, into); merges[id] = into },
                        others = people.filter { it != id })
                    if (model.voicesAvailable && model.rememberVoices) Row(Modifier.padding(start = 16.dp)
                        .clickable(role = Role.Checkbox) { rememberVoice[id] = rememberVoice[id] == false }, verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(rememberVoice[id] != false, { rememberVoice[id] = it })
                        Text(stringResource(R.string.notes_speakers_remember_voice), style = MaterialTheme.typography.bodyMedium)
                    }
                }
            }
            if (count > 0) Row(Modifier.padding(top = 8.dp).clickable(role = Role.Checkbox) { replace = !replace }, verticalAlignment = Alignment.CenterVertically) {
                Checkbox(replace, null)
                Text(pluralStringResource(R.plurals.notes_speakers_replace_all, count, count), style = MaterialTheme.typography.bodyMedium)
            }
        }
    }
    val windowWidth = with(LocalDensity.current) { LocalWindowInfo.current.containerSize.width.toDp() }
    if (windowWidth >= 600.dp) {
        Dialog(onDismissRequest = dismiss) {
            Surface(Modifier.widthIn(max = 640.dp).heightIn(max = 680.dp).testTag("name_speakers_dialog"),
                shape = MaterialTheme.shapes.extraLarge) { content() }
        }
    } else {
        ModalBottomSheet(dismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) { content() }
    }
}

/** Recent names that start like what is typed (any, when nothing is), not already used in this sheet; at most four. */
internal fun suggestions(recent: List<String>, typed: String, used: Set<String>): List<String> {
    val prefix = typed.trim().lowercase()
    return recent.filter { it.lowercase() !in used && it.lowercase() != prefix && it.lowercase().startsWith(prefix) }.take(4)
}

@Composable
private fun SpeakerRow(roster: SpeakerRoster, id: Int, name: String, change: (String) -> Unit, focused: Boolean, focus: (Boolean) -> Unit,
                       finish: () -> Unit, sample: String?, playing: Boolean, play: (() -> Unit)?, suggestions: List<String>,
                       merge: (Int) -> Unit, others: List<Int>) {
    val dark = MaterialTheme.colorScheme.surface.luminance() < 0.5f
    val color = SpeakerColors.of(roster.colorIndex(id), dark)
    val fieldDescription = stringResource(R.string.notes_speakers_name_for, id)
    Column(Modifier.testTag("name_speaker_$id"), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(12.dp).clip(CircleShape).background(color))
            Spacer(Modifier.width(10.dp))
            OutlinedTextField(name, change, Modifier.weight(1f).onFocusChanged { focus(it.isFocused) }.semantics { contentDescription = fieldDescription },
                label = { Text(stringResource(R.string.notes_speakers_person, id), color = color) }, placeholder = { Text(stringResource(R.string.notes_speakers_person, id)) }, singleLine = true,
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words, imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { finish() }))
        }
        if (suggestions.isNotEmpty()) Row(Modifier.padding(start = 22.dp).horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            suggestions.forEach { SuggestionChip({ change(it) }, { Text(it) }) }
        }
        Row(Modifier.padding(start = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            if (play != null) IconButton(play, Modifier.size(40.dp)) {
                Icon(painterResource(if (playing) R.drawable.ic_stop else R.drawable.ic_play), if (playing) stringResource(R.string.notes_speakers_stop_sample) else stringResource(R.string.notes_speakers_play_sample, id), tint = MaterialTheme.colorScheme.primary)
            }
            Text(sample?.let { stringResource(R.string.notes_speakers_sample, it) }.orEmpty(), Modifier.weight(1f), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 2, overflow = TextOverflow.Ellipsis)
            if (others.isNotEmpty()) {
                var open by remember { mutableStateOf(false) }
                Box {
                    TextButton({ open = true }) { Text(stringResource(R.string.notes_speakers_same_as)) }
                    DropdownMenu(open, { open = false }) {
                        others.forEach { other -> DropdownMenuItem({ Text(roster.displayName(other)) }, { open = false; merge(other) }) }
                    }
                }
            }
        }
    }
}
