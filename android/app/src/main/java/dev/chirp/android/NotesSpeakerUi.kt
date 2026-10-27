package dev.chirp.android

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SuggestionChip
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp

/** The transcript's speaker chips and their fix-ups: rename, merge and separate. [NameSpeakersSheet] names everyone at once. */
internal object SpeakerColors {
    /** Pond-safe hues, each at least 4.5:1 on the light surface; the dark set is the same hues lifted for the night pond. */
    private val light = listOf(0xFFC2410C, 0xFF2F7A4F, 0xFF4F46E5, 0xFFA21CAF, 0xFF0F766E, 0xFF8A5A00, 0xFF0369A1, 0xFFBE123C)
    private val dark = listOf(0xFFFF8A4C, 0xFF7CCB9B, 0xFFA5B4FC, 0xFFF0ABFC, 0xFF5EEAD4, 0xFFF5C566, 0xFF7DD3FC, 0xFFFDA4AF)

    fun of(index: Int, dark: Boolean) = Color((if (dark) this.dark else light)[index.mod(SpeakerRoster.PALETTE)])
}

/** The capsule that starts a person's turn: their colour, their name. A tap opens [SpeakerMenu]. */
@Composable
internal fun SpeakerChip(name: String, colorIndex: Int, onClick: () -> Unit, modifier: Modifier = Modifier, recognized: Boolean = false) {
    val dark = MaterialTheme.colorScheme.surface.luminance() < 0.5f
    val color = SpeakerColors.of(colorIndex, dark)
    Box(modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp).clickable(onClick = onClick)
        .semantics(mergeDescendants = true) { role = Role.Button; contentDescription = "$name${if (recognized) ", recognised" else ""}. Rename, merge or reassign this speaker" },
        contentAlignment = Alignment.CenterStart) {
    Row(Modifier.clip(CircleShape).background(color.copy(alpha = if (dark) .18f else .12f))
        .padding(horizontal = 10.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(8.dp).clip(CircleShape).background(color))
        Spacer(Modifier.width(6.dp))
        Text(name + if (recognized) " ✓" else "", style = MaterialTheme.typography.labelLarge, color = color)
    }
    }
}

/** Person actions, plus a second menu for changing just the selected transcript turn. */
@Composable
internal fun SpeakerMenu(open: Boolean, dismiss: () -> Unit, roster: SpeakerRoster, person: Int, rename: () -> Unit,
                         merge: (Int) -> Unit, separate: (Int) -> Unit, nameAll: (() -> Unit)? = null, reject: (() -> Unit)? = null, update: (() -> Unit)? = null, reassign: ((Int?) -> Unit)? = null) {
    val target = roster.resolve(person)
    val others = roster.active.filter { it != target }
    val merged = roster.merged(target)
    var assigning by remember(open) { mutableStateOf(false) }
    DropdownMenu(open, dismiss) {
        if (assigning && reassign != null) {
            DropdownMenuItem({ Text("This turn is") }, { assigning = false })
            HorizontalDivider()
            others.forEach { id -> DropdownMenuItem({ Text(roster.displayName(id)) }, { dismiss(); reassign(id) }) }
            DropdownMenuItem({ Text("New person") }, { dismiss(); reassign(null) })
            return@DropdownMenu
        }
        if (reassign != null) DropdownMenuItem({ Text("This turn is…") }, { assigning = true })
        DropdownMenuItem({ Text("Rename “${roster.displayName(target)}”…") }, { dismiss(); rename() })
        if (roster.person(target)?.recognized != null && reject != null)
            DropdownMenuItem({ Text("Not ${roster.displayName(target)}") }, { dismiss(); reject() })
        if (roster.person(target)?.name != null && update != null)
            DropdownMenuItem({ Text("Update ${roster.displayName(target)}’s voice") }, { dismiss(); update() })
        if (nameAll != null) DropdownMenuItem({ Text("Name speakers…") }, { dismiss(); nameAll() })
        if (others.isNotEmpty()) {
            HorizontalDivider()
            Text("Same person as", Modifier.padding(horizontal = 12.dp, vertical = 8.dp), style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            others.forEach { id -> DropdownMenuItem({ Text(roster.displayName(id)) }, { dismiss(); merge(id) }) }
        }
        if (merged.isNotEmpty()) {
            HorizontalDivider()
            merged.forEach { id ->
                DropdownMenuItem({ Text("Separate " + (roster.person(id)?.name ?: "Person $id")) }, { dismiss(); separate(id) })
            }
        }
    }
}

/**
 * Rename everywhere in this note; blank goes back to "Person N". Offers to replace the old name in the notes too.
 * Remember voice is on by default only while the server's library is on, and the field suggests the same saved and
 * recent names as Name speakers.
 */
@Composable
internal fun RenameSpeakerDialog(model: NotesModel, person: Int, dismiss: () -> Unit, rename: (String, Boolean, Boolean) -> Unit) {
    val document = model.document
    val roster = document.roster
    val resolved = roster.resolve(person)
    val old = roster.displayName(person)
    var name by remember(person) { mutableStateOf(roster.person(resolved)?.name.orEmpty()) }
    var replace by remember(person) { mutableStateOf(true) }
    var rememberVoice by remember(person) { mutableStateOf(true) }
    var focused by remember(person) { mutableStateOf(false) }
    LaunchedEffect(person) { model.loadRecentNames() }
    val count = remember(document.version, old) { document.nameCount(old) }
    val new = name.trim().ifEmpty { "Person $resolved" }
    val offerRemember = model.voicesAvailable && model.rememberVoices
    val used = roster.active.filter { it != resolved }.map { roster.displayName(it).trim().lowercase() }.toSet()
    val ideas = if (focused) suggestions(
        model.savedVoices.library?.voices.orEmpty().map { it.name } + model.recentNames, name, used) else emptyList()
    fun commit() { rename(name, replace && count > 0 && new != old, offerRemember && rememberVoice) }
    AlertDialog(onDismissRequest = dismiss,
        title = { Text("Rename “$old”") },
        text = {
            Column {
                OutlinedTextField(name, { name = it.take(SpeakerRoster.MAX_NAME) }, Modifier.onFocusChanged { focused = it.isFocused },
                    label = { Text("Name") }, singleLine = true,
                    placeholder = { Text("Person $resolved") },
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words, imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { commit() }))
                if (ideas.isNotEmpty()) Row(Modifier.padding(top = 8.dp).horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    ideas.forEach { SuggestionChip({ name = it }, { Text(it) }) }
                }
                Text("Used everywhere in this note: the transcript, the notes Chirp writes and exports.", Modifier.padding(top = 8.dp),
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (offerRemember) Row(Modifier.padding(top = 4.dp).clickable(role = Role.Checkbox) { rememberVoice = !rememberVoice },
                    verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(rememberVoice, { rememberVoice = it })
                    Text("Remember voice", style = MaterialTheme.typography.bodyMedium)
                }
                if (count > 0 && new != old) Row(Modifier.padding(top = 4.dp).clickable(role = Role.Checkbox) { replace = !replace },
                    verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(replace, null)
                    Text("Also replace “$old” with “$new” in the notes (${if (count == 1) "1 place" else "$count places"})",
                        style = MaterialTheme.typography.bodyMedium)
                }
            }
        },
        confirmButton = { TextButton(::commit) { Text("Rename") } },
        dismissButton = { TextButton(dismiss) { Text("Cancel") } })
}

/** Model preparation can coexist with recovery and connection notices. */
@Composable
internal fun SpeakerModelStatus(model: NotesSpeakerModel, modifier: Modifier = Modifier) {
    val status = model.status ?: return
    androidx.compose.material3.Surface(modifier.fillMaxWidth(), shape = MaterialTheme.shapes.large,
        color = if (model.retryable) MaterialTheme.colorScheme.errorContainer else MaterialTheme.colorScheme.surfaceContainer) {
        Column(Modifier.padding(12.dp)) {
            Text(status, style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.semantics { liveRegion = androidx.compose.ui.semantics.LiveRegionMode.Polite })
            Row {
                if (model.retryable) TextButton(model::retry) { Text("Retry") }
                if (model.enabled) TextButton({ model.setLabels(false) }) { Text("Turn off") }
            }
        }
    }
}
