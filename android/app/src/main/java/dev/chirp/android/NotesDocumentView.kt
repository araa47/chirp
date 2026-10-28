package dev.chirp.android

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.*
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.OffsetMapping
import androidx.compose.ui.text.input.TransformedText
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp

/** The notes' reading width: a comfortable line on an unfolded Fold or a tablet. */
internal val NOTES_READING_WIDTH = 680.dp

/** Reading type for the notes: a little larger and airier than the app's body text. */
internal object NotesType {
    val body @Composable get() = MaterialTheme.typography.bodyLarge.copy(fontSize = 17.sp, lineHeight = 27.sp)
    @Composable fun heading(level: Int): TextStyle = when (level) {
        1 -> MaterialTheme.typography.headlineMedium.copy(fontWeight = FontWeight.SemiBold, fontFamily = FontFamily.Serif)
        2 -> MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.SemiBold, fontSize = 22.sp, lineHeight = 30.sp)
        3 -> MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.SemiBold, fontSize = 18.sp, lineHeight = 26.sp)
        else -> MaterialTheme.typography.titleSmall.copy(fontWeight = FontWeight.SemiBold, fontSize = 16.sp, lineHeight = 24.sp)
    }
}

@Composable
private fun inline(text: String): AnnotatedString {
    val scheme = MaterialTheme.colorScheme
    return remember(text, scheme) {
        notesInline(text, SpanStyle(fontFamily = FontFamily.Monospace, fontSize = 0.9.em, background = scheme.surfaceContainerHighest),
            SpanStyle(color = scheme.primary, textDecoration = TextDecoration.Underline))
    }
}

/**
 * One rendered block. A tap on its words edits the notes there ([edit]); a task's box ticks it ([toggle]), which writes
 * `[x]` back into the Markdown. Ripple-free, as in a notes app: the page is text, not buttons.
 */
@Composable
internal fun NotesBlockView(block: NotesBlock, edit: (NotesBlock) -> Unit, toggle: (NotesBlock.Task) -> Unit, modifier: Modifier = Modifier) {
    val scheme = MaterialTheme.colorScheme
    val editLabel = stringResource(R.string.notes_block_edit)
    val tickLabel = stringResource(if ((block as? NotesBlock.Task)?.checked == true) R.string.notes_task_untick else R.string.notes_task_tick)
    val tap = Modifier.testTag("notes-block").clickable(remember { MutableInteractionSource() }, null, onClickLabel = editLabel) { edit(block) }
    val indent = Modifier.padding(start = (24 * ((block as? NotesBlock.Item)?.depth ?: (block as? NotesBlock.Task)?.depth ?: (block as? NotesBlock.Callout)?.depth ?: 0)).dp)
    when (block) {
        is NotesBlock.Heading -> Text(inline(block.text), modifier.then(tap).padding(top = if (block.level <= 2) 20.dp else 14.dp, bottom = 4.dp).semantics { heading() },
            style = NotesType.heading(block.level), color = if (block.level >= 3) scheme.onSurfaceVariant else scheme.onSurface)
        is NotesBlock.Paragraph -> Text(inline(block.text), modifier.then(tap).padding(vertical = 6.dp), style = NotesType.body)
        is NotesBlock.Item -> Row(modifier.then(tap).then(indent).padding(vertical = 3.dp)) {
            Marker(Modifier.width(26.dp)) {
                if (block.number != null) Text(block.number, style = NotesType.body.copy(fontFeatureSettings = "tnum"), color = scheme.onSurfaceVariant)
                else Bullet(block.depth)
            }
            Text(inline(block.text), Modifier.weight(1f), style = NotesType.body)
        }
        // One node for TalkBack: a checkbox named by its words, with Edit as an action. By touch the box ticks and the words edit.
        is NotesBlock.Task -> Row(modifier.then(indent).padding(vertical = 1.dp).testTag("notes-block").clearAndSetSemantics {
            role = Role.Checkbox; text = AnnotatedString(block.text); toggleableState = ToggleableState(block.checked)
            onClick(tickLabel) { toggle(block); true }
            customActions = listOf(CustomAccessibilityAction(editLabel) { edit(block); true })
        }, verticalAlignment = Alignment.Top) {
            Marker(Modifier.width(34.dp).toggleable(block.checked, role = Role.Checkbox) { toggle(block) }) { TaskBox(block.checked) }
            Text(inline(block.text), Modifier.weight(1f).clickable(remember { MutableInteractionSource() }, null) { edit(block) }.padding(vertical = 2.dp),
                style = NotesType.body.copy(textDecoration = if (block.checked) TextDecoration.LineThrough else null),
                color = if (block.checked) scheme.onSurfaceVariant else scheme.onSurface)
        }
        is NotesBlock.Callout -> {
            val decision = block.kind == NotesBlock.Callout.Kind.DECISION
            val accent = if (decision) dev.chirp.android.ui.LocalChirpRoles.current.lily else dev.chirp.android.ui.LocalChirpRoles.current.moon
            // A tint of the accent over the page, the same weight in light and dark and with any wallpaper colours.
            val tint = accent.copy(alpha = if (scheme.surface.luminance() < .5f) .16f else .10f)
            Row(modifier.then(indent).padding(vertical = 6.dp).clip(MaterialTheme.shapes.medium).background(tint).then(tap)
                .padding(start = 12.dp, end = 14.dp, top = 10.dp, bottom = 10.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Icon(painterResource(if (decision) R.drawable.ic_check_circle else R.drawable.ic_help), null, Modifier.padding(top = 2.dp).size(18.dp), tint = accent)
                Column(Modifier.weight(1f)) {
                    Text(block.kind.label, style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.SemiBold, letterSpacing = .6.sp), color = accent)
                    Text(inline(block.text), style = NotesType.body)
                }
            }
        }
        is NotesBlock.Quote -> Row(modifier.then(tap).padding(vertical = 6.dp).height(IntrinsicSize.Min)) {
            Box(Modifier.width(3.dp).fillMaxHeight().clip(CircleShape).background(scheme.outlineVariant))
            Text(inline(block.text), Modifier.padding(start = 14.dp), style = NotesType.body, color = scheme.onSurfaceVariant)
        }
        is NotesBlock.Code -> Text(block.text, modifier.then(tap).padding(vertical = 6.dp).clip(MaterialTheme.shapes.small).background(scheme.surfaceContainerHigh)
            .horizontalScroll(rememberScrollState()).padding(12.dp), style = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace), softWrap = false)
        is NotesBlock.Note -> Text(block.text, modifier.then(tap).padding(vertical = 6.dp), style = MaterialTheme.typography.bodyMedium,
            fontStyle = FontStyle.Italic, color = scheme.onSurfaceVariant)
        is NotesBlock.Rule -> HorizontalDivider(modifier.padding(vertical = 14.dp), color = scheme.outlineVariant)
    }
}

/** The marker column of a list line: one body line tall, so the bullet sits on the first line of the words. */
@Composable
private fun Marker(modifier: Modifier, content: @Composable BoxScope.() -> Unit) {
    val line = with(LocalDensity.current) { NotesType.body.lineHeight.toDp() }
    Box(modifier.height(line), contentAlignment = Alignment.CenterStart, content = content)
}

@Composable
private fun Bullet(depth: Int) {
    val color = MaterialTheme.colorScheme.onSurfaceVariant
    val shape = if (depth % 3 == 2) RoundedCornerShape(1.dp) else CircleShape
    Box(Modifier.padding(start = 6.dp).size(if (depth == 0) 6.dp else 5.dp).clip(shape)
        .then(if (depth % 3 == 1) Modifier.border(1.25.dp, color, shape) else Modifier.background(color)))
}

@Composable
private fun TaskBox(checked: Boolean) {
    val scheme = MaterialTheme.colorScheme
    val shape = RoundedCornerShape(6.dp)
    Box(Modifier.padding(start = 2.dp).size(20.dp).clip(shape)
        .then(if (checked) Modifier.background(scheme.primary) else Modifier.border(2.dp, scheme.outline, shape)), contentAlignment = Alignment.Center) {
        if (checked) Icon(painterResource(R.drawable.ic_check), null, Modifier.size(16.dp), tint = scheme.onPrimary)
    }
}

/** What is being said and not yet in the notes: quiet, italic, at the end of the page, with a breathing dot while the mic is open. */
@Composable
internal fun HearingLine(text: String, listening: Boolean, modifier: Modifier = Modifier) {
    val scheme = MaterialTheme.colorScheme
    val description = stringResource(R.string.notes_hearing_description, text)
    Row(modifier.testTag("notes-hearing").padding(vertical = 8.dp).semantics(mergeDescendants = true) { contentDescription = description },
        horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        val pulse = if (listening) rememberInfiniteTransition(label = "hearing").animateFloat(.35f, 1f,
            infiniteRepeatable(tween(900), RepeatMode.Reverse), label = "dot").value else .35f
        Box(Modifier.height(with(LocalDensity.current) { NotesType.body.lineHeight.toDp() }), contentAlignment = Alignment.Center) {
            Box(Modifier.size(8.dp).alpha(pulse).clip(CircleShape).background(scheme.primary))
        }
        Text(text, style = NotesType.body, fontStyle = FontStyle.Italic, color = scheme.onSurfaceVariant, maxLines = 4)
    }
}

/** Nothing in the notes yet. A tap starts typing. */
@Composable
internal fun NotesEmpty(recording: Boolean, type: () -> Unit, modifier: Modifier = Modifier) {
    val scheme = MaterialTheme.colorScheme
    Column(modifier.clickable(onClickLabel = stringResource(R.string.notes_empty_type), onClick = type).padding(top = 56.dp, bottom = 24.dp, start = 24.dp, end = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Box(Modifier.size(72.dp).clip(CircleShape).background(scheme.surfaceContainerHigh), contentAlignment = Alignment.Center) {
            Icon(painterResource(R.drawable.ic_notes_tab), null, Modifier.size(32.dp), tint = scheme.primary)
        }
        Text(stringResource(if (recording) R.string.notes_empty_recording_title else R.string.notes_empty_title), style = MaterialTheme.typography.titleLarge, textAlign = TextAlign.Center)
        Text(stringResource(if (recording) R.string.notes_empty_recording_detail else R.string.notes_empty_detail),
            style = MaterialTheme.typography.bodyMedium, color = scheme.onSurfaceVariant, textAlign = TextAlign.Center)
    }
}

/**
 * The editor's Markdown, lightly styled while typing: headings larger and bold, list and task markers quiet, Decision and
 * Question labels tinted. The characters are exactly the text, so the caret and the AI tail map one to one.
 */
internal class NotesSyntax(private val quiet: Color, private val accent: Color, private val headingSizes: List<Float> = listOf(1.35f, 1.2f, 1.08f)) : VisualTransformation {
    private val list = Regex("""^([ \t]*)([-*+] \[[ xX]] |[-*+] |\d{1,3}[.)] )""")
    private val label = Regex("""(\*\*|__)?(Decision|Question)s?:(\*\*|__)?""", RegexOption.IGNORE_CASE)

    override fun filter(text: AnnotatedString): TransformedText {
        val styled = buildAnnotatedString {
            append(text.text)
            var at = 0
            for (line in text.text.split('\n')) {
                val heading = line.takeWhile { it == '#' }.length
                val item = list.find(line)
                fun tint(from: Int) = label.find(line, from)?.takeIf { it.range.first == from }
                    ?.let { addStyle(SpanStyle(color = accent, fontWeight = FontWeight.SemiBold), at + from, at + it.range.last + 1) }
                when {
                    heading in 1..6 && line.getOrNull(heading) == ' ' -> {
                        addStyle(SpanStyle(color = quiet), at, at + heading + 1)
                        addStyle(SpanStyle(fontWeight = FontWeight.SemiBold, fontSize = headingSizes.getOrElse(heading - 1) { 1f }.em), at + heading + 1, at + line.length)
                    }
                    item != null -> {
                        val marker = item.groups[2]!!.range
                        addStyle(SpanStyle(color = if (marker.last - marker.first > 2) accent else quiet), at + marker.first, at + marker.last + 1)
                        tint(marker.last + 1)
                    }
                    else -> tint(0)
                }
                at += line.length + 1
            }
        }
        return TransformedText(styled, OffsetMapping.Identity)
    }

    override fun equals(other: Any?) = other is NotesSyntax && other.quiet == quiet && other.accent == accent
    override fun hashCode() = quiet.hashCode() * 31 + accent.hashCode()
}
