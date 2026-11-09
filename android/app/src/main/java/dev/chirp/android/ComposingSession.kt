package dev.chirp.android

import android.view.inputmethod.InputConnection

/** Own only this utterance's composing span. Never keep editor text outside memory. */
class ComposingSession(private val connection: InputConnection, private val anchor: Int = -1,
                       private val decorate: (String) -> CharSequence = { it }) {
    private var live = true
    private var replacedSelection = editor("") { connection.getSelectedText(0)?.toString().orEmpty() }
    // Snapshot the boundary before any partial moves the cursor into our composing span.
    // Retain only the decision, not surrounding editor text.
    private val needsSpace = editor(false) { spaceBefore() }
    private fun spaceBefore() = connection.getTextBeforeCursor(1, 0)?.lastOrNull()?.let { previous ->
        !previous.isWhitespace() && previous != '\'' && previous != '"' &&
            Character.getType(previous) != Character.START_PUNCTUATION.toInt() &&
            Character.getType(previous) != Character.INITIAL_QUOTE_PUNCTUATION.toInt()
    } ?: false
    private var shaping = false
    private var midSentence = false
    private var commands = false
    private var seq = -1L
    private var composing = false
    private var rendered = ""
    private var regionOwned = false
    private var finalText: String? = null
    private var rawText: String? = null
    private var restore = ""
    var committedLength = 0
        private set
    /** After a final: where the committed text ends and the selection left behind (-1 when unknown), for Undo and Use raw. */
    var spanEnd = -1
        private set
    var selectionStart = -1
        private set
    var selectionEnd = -1
        private set
    val committedText get() = finalText
    val rawAvailable get() = rawText != null
    // Where this utterance's recent partials left the caret: their selection reports may arrive after newer edits.
    private val carets = ArrayDeque<Int>()
    /** Where the composed text ends, or -1 without a known anchor. */
    val end get() = if (anchor >= 0) anchor + rendered.length else -1

    /** True when an editor's caret report at [caret] is one of our own edits coming back: at a place a recent partial left it. */
    fun echo(caret: Int) = anchor >= 0 && caret in carets

    /** Opt this utterance's final into mid-sentence casing (and spoken commands). Call before the first partial. */
    fun shapeFinal(spokenCommands: Boolean) {
        shaping = true; commands = spokenCommands
        midSentence = editor(false) { FinalCasing.midSentence(connection.getTextBeforeCursor(FinalCasing.LOOKBEHIND, 0)) }
    }

    private fun atBoundary(text: String, space: Boolean = needsSpace): String =
        if (space && text.isNotEmpty() && !text.first().isWhitespace()) " $text" else text

    fun partial(event: ServerEvent.Partial): Boolean {
        if (!live || event.seq <= seq) return true
        seq = event.seq
        val next = atBoundary(event.text)
        val stable = event.stable.takeIf { event.text.startsWith(it) }.orEmpty()
        val nextStable = if (stable.isEmpty()) 0 else atBoundary(stable).length
        val accepted = editor(false) {
            connection.beginBatchEdit()
            try {
                var common = rendered.commonPrefixWith(next).length
                // Never split a UTF-16 surrogate pair or detach a combining mark.
                if (common > 0 && (Character.isHighSurrogate(rendered[common - 1]) ||
                        (common < next.length && Character.getType(next[common]) == Character.NON_SPACING_MARK.toInt()))) common--
                val suffix = composing && anchor >= 0 && common > 0 &&
                    connection.getTextBeforeCursor(rendered.length, 0)?.toString() == rendered &&
                    connection.setComposingRegion(anchor + common, anchor + rendered.length)
                val inserted = if (next == rendered && composing) true
                    else connection.setComposingText(decorate(if (suffix) next.substring(common) else next), 1)
                if (inserted && anchor >= 0 && connection.getTextBeforeCursor(next.length, 0)?.toString() == next) {
                    // A reported stable prefix becomes normal editor text; only the tail composes.
                    // Re-mark the whole utterance on final/cancel so cleanup and rollback stay atomic.
                    regionOwned = connection.setComposingRegion(anchor + nextStable, anchor + next.length)
                }
                inserted
            } finally { connection.endBatchEdit() }
        }
        if (accepted) {
            composing = true; rendered = next
            if (anchor >= 0) { carets.addLast(anchor + next.length); if (carets.size > ECHOES) carets.removeFirst() }
        }
        return accepted
    }
    private fun wholeRegion() {
        if (composing && regionOwned && anchor >= 0) editor(false) { connection.setComposingRegion(anchor, anchor + rendered.length) }
    }

    /** A selection (selStart >= 0) means the user moved the caret away: replace the span where it was and keep their caret. */
    fun final(event: ServerEvent.Final, selStart: Int = -1, selEnd: Int = selStart): Boolean {
        if (!live) return false
        if (event.text.isBlank()) { cancel(selStart, selEnd); return false }
        // Without a known anchor the composing region is replaced wherever it is; the caret follows it.
        if (selStart >= 0 && anchor >= 0) return away(event, minOf(selStart, selEnd), maxOf(selStart, selEnd))
        live = false
        val text = atBoundary(shaped(event.text, midSentence))
        wholeRegion()
        val inserted = editor(false) { connection.commitText(text, 1) }
        if (!inserted && composing) editor(false) { connection.setComposingText(replacedSelection, 1) }
        editor(false) { connection.finishComposingText() }
        if (inserted) { restore = replacedSelection; landed(text, rawOf(event, needsSpace), if (anchor >= 0) anchor + text.length else -1) }
        replacedSelection = ""
        composing = false; rendered = ""; regionOwned = false
        return inserted
    }
    private fun away(event: ServerEvent.Final, selStart: Int, selEnd: Int): Boolean {
        live = false
        val previous = rendered.takeIf { composing }.orEmpty()
        composing = false; rendered = ""; regionOwned = false
        if (previous.isNotEmpty() && editor(null) { connection.textAt(anchor, previous.length, selStart, selEnd) } == previous) {
            val text = atBoundary(shaped(event.text, midSentence))
            val selection = editor(null) { connection.replaceAt(anchor, previous.length, text, selStart, selEnd) } ?: return false
            restore = replacedSelection; replacedSelection = ""
            landed(text, rawOf(event, needsSpace), anchor + text.length, selection)
            return true
        }
        // Our span is gone (the editor dropped it): the text lands at the user's caret instead.
        replacedSelection = ""
        editor(false) { connection.finishComposingText() }
        val space = editor(false) { spaceBefore() }
        val text = atBoundary(shaped(event.text, editor(false) { FinalCasing.midSentence(connection.getTextBeforeCursor(FinalCasing.LOOKBEHIND, 0)) }), space)
        val replaced = editor("") { connection.getSelectedText(0)?.toString().orEmpty() }
        if (!editor(false) { connection.commitText(text, 1) }) return false
        restore = replaced; landed(text, rawOf(event, space), selStart + text.length)
        return true
    }
    private fun shaped(text: String, sentence: Boolean) = if (shaping) FinalCasing.shape(text, sentence, commands) else text
    private fun rawOf(event: ServerEvent.Final, space: Boolean) = if (event.corrected && event.raw != event.text) atBoundary(event.raw, space) else null
    private fun landed(text: String, raw: String?, end: Int, selection: IntArray = intArrayOf(end, end)) {
        committedLength = text.length; finalText = text; rawText = raw
        spanEnd = end; selectionStart = selection[0]; selectionEnd = selection[1]
    }
    /** A selection (selStart >= 0) removes the span where it was without moving the user's caret. */
    fun cancel(selStart: Int = -1, selEnd: Int = selStart) {
        if (live && composing) {
            val first = minOf(selStart, selEnd); val last = maxOf(selStart, selEnd)
            if (selStart < 0 || anchor < 0) {
                wholeRegion()
                editor(false) { connection.setComposingText(replacedSelection, 1) }
                editor(false) { connection.finishComposingText() }
            } else if (editor(null) { connection.textAt(anchor, rendered.length, first, last) } == rendered) {
                editor(null) { connection.replaceAt(anchor, rendered.length, replacedSelection, first, last) }
            } else editor(false) { connection.finishComposingText() }
        }
        live = false
        replacedSelection = ""
        composing = false; rendered = ""; regionOwned = false
        forgetUndo()
    }
    // An editor may disappear between verification, region marking and commit (IME switch,
    // app close or fold). No editor exception may escape onto the IME's main thread.
    private fun <T> editor(fallback: T, action: () -> T): T = try { action() } catch (_: RuntimeException) { fallback }

    fun forgetUndo() { finalText = null; rawText = null; restore = "" }
    private companion object { const val ECHOES = 8 }
    /** Removes exactly the committed text (separator included) and restores any selection it replaced. */
    fun undo(selStart: Int, selEnd: Int): Boolean = swap(restore, spanEnd, selStart, selEnd)
    fun useRaw(selStart: Int, selEnd: Int): Boolean = swap(rawText ?: return false, spanEnd, selStart, selEnd)
    fun useRaw(cursor: Int): Boolean = swap(rawText ?: return false, cursor, cursor, cursor)
    private fun swap(replacement: String, end: Int, selStart: Int, selEnd: Int): Boolean {
        val text = finalText ?: return false
        val first = minOf(selStart, selEnd); val last = maxOf(selStart, selEnd)
        // Refuse if the text changed after commit. The service also invalidates on selection changes.
        if (end < text.length || editor<String?>(null) { connection.textAt(end - text.length, text.length, first, last) } != text) {
            forgetUndo(); return false
        }
        // Mark the verified final for a single replacement. Never delete it first:
        // a rejected commit must leave the final text in the editor.
        val selection = editor(null) { connection.replaceAt(end - text.length, text.length, replacement, first, last) } ?: return false
        forgetUndo()
        committedLength = replacement.length; spanEnd = end - text.length + replacement.length
        selectionStart = selection[0]; selectionEnd = selection[1]
        return true
    }
}
