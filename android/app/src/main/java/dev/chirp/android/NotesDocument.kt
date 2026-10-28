package dev.chirp.android

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.atomic.AtomicLong
import org.json.JSONArray
import org.json.JSONObject

/** One committed segment of a Notes recording: an utterance's final, or a gap where it failed. */
internal data class NotesSegment(
    val id: Int,
    /** Seconds from the start of the session to the segment's first audio. */
    val offset: Double,
    val raw: String,
    /** The corrected text, or the raw text when clean-up was off or failed. */
    val text: String = raw,
    val corrected: Boolean = false,
    /** Clean-up was asked for but did not deliver, so the raw text was kept. */
    val keptOriginal: Boolean = false,
    /** Set for a gap: why this stretch of audio was not transcribed. */
    val failure: String? = null,
    /** Who said what ("Label speakers"), in order; null when the segment is not labelled. */
    val turns: List<SpeakerTurn>? = null,
    val engine: String? = null,
) {
    val isGap get() = failure != null
    companion object { fun gap(id: Int, offset: Double, reason: String) = NotesSegment(id, offset, "", failure = reason) }
}

/** A capture boundary: the note was continued after [offset] seconds of audio, at wall-clock [time]. */
internal data class NotesBoundary(val offset: Double, val time: Long)

/** Part of a rejected window after it was split: structured Markdown, or a part that kept failing and stays raw. */
internal sealed interface NotesPiece {
    data class Markdown(val text: String) : NotesPiece
    data class Fallback(val text: String) : NotesPiece
}

/** One change to the notes text: `[start, end)` in the text before it becomes [replacement]. */
internal data class NotesChange(val start: Int, val end: Int, val replacement: String, val kind: Kind) {
    enum class Kind { USER, APPEND, REORGANIZE, ORGANIZE, REBUILD }
    fun applied(text: String) = text.substring(0, start) + replacement + text.substring(end)
    /** Where an offset in the old text lands in the new one (inside the replaced range: after the replacement). */
    fun map(offset: Int) = when {
        offset <= start -> offset
        offset >= end -> offset + replacement.length - (end - start)
        else -> start + replacement.length
    }
}

/** The small Markdown subset the server's notes guards allow, line by line. */
internal object NotesMarkdown {
    const val PLACEHOLDER = "_(nothing yet)_"

    /** `# `, `## ` or `### ` followed by text: (level, text). */
    fun heading(line: String): Pair<Int, String>? {
        val hashes = line.takeWhile { it == '#' }.length
        if (hashes !in 1..3 || line.getOrNull(hashes) != ' ') return null
        return line.substring(hashes + 1).trim().takeIf { it.isNotEmpty() }?.let { hashes to it }
    }

    fun headings(md: String) = md.replace("\r\n", "\n").replace('\r', '\n').split('\n').mapNotNull { heading(it.trim())?.second }

    /** Each heading starts a section; text before the first heading is one too. `[start, end)` and the heading. */
    fun sections(text: String): List<Pair<IntRange, String?>> {
        val result = mutableListOf<Pair<IntRange, String?>>()
        var start = 0; var location = 0; var current: String? = null
        for (line in text.split('\n')) {
            val title = heading(line)?.second
            if (title != null) {
                if (location > start || current != null) result += (start until location) to current
                start = location; current = title
            }
            location += line.length + 1
        }
        if (text.length > start || current != null) result += (start until text.length) to current
        return result
    }
}

/** Unicode scalars, as the server counts its limits. */
internal val String.scalars get() = codePointCount(0, length)

/**
 * Everything a Notes session holds, in memory only: the transcript segments and one Markdown string, the notes,
 * written by the user and by structuring passes. The AI owns only a suffix, the tail (`text[tailStart..]`): an append
 * only ever replaces the tail, and any user edit that touches the tail hands it to the user. A port of the Mac's
 * `NotesDocument`, speaker labels included; nothing here is logged.
 */
internal class NotesDocument(var startedAt: Long = System.currentTimeMillis(), text: String = "") {
    /** This document, as opposed to one New replaced: a late answer for a discarded document is never applied. */
    val id = ids.incrementAndGet()
    private val committed = mutableListOf<NotesSegment>()
    val segments: List<NotesSegment> get() = committed
    var text = text
        private set
    var tailStart = text.length
        private set
    /** +1 on every change to [text] (user or AI). */
    var version = 0
        private set
    /** +1 whenever the tail is claimed, settles or a reorganize lands: a pass asked for an earlier one is stale. */
    var windowGeneration = 0
        private set
    var windowStart = 0
        private set
    /** The last segment index the tail covers; below [windowStart] before any pass succeeded in this window. */
    var structuredEnd = -1
        private set
    var consecutiveFailures = 0
        private set
    var lastReorganizeVersion = 0
        private set
    /** Characters inserted (user or AI) since the last reorganize. */
    var charsSinceReorganize = 0
        private set
    /** The live partials of the segments still in flight. Display only: never exported. */
    var livePartial = ""
    /** The user's name for this session (Rename), else the title is the start time. */
    var name: String? = null
    /** Explicitly created typed notes stay in the library even before the first edit. */
    var typedNote = false
    /** Survives the recovery copy and kept sessions, so keeping it again replaces the earlier copy. */
    var uid: String = java.util.UUID.randomUUID().toString()
        private set
    private val boundaryList = mutableListOf<NotesBoundary>()
    /** Where a finished note was continued: a quiet divider in the transcript, with the capture clock at that moment. */
    val boundaries: List<NotesBoundary> get() = boundaryList
    private val clips = java.util.TreeMap<Int, NotesAudioClip>()
    /** Kept audio, by segment index (empty unless "Keep audio with notes" was on). Does not count as a text change. */
    val audio: List<NotesAudioClip> get() = clips.values.toList()
    /** The note's people (names and merges), when speakers were labelled. */
    var roster = SpeakerRoster()
        private set
    /** +1 on every rename, merge or separate: the note changed without its text changing. */
    var speakerVersion = 0
        private set
    /** Every fallback block appended, exactly as appended; one still found verbatim is one Organize may redo. */
    private val fallbackBlocks = mutableListOf<String>()

    val isEmpty get() = text.isBlank() && committed.none { !it.isGap && it.text.isNotEmpty() }
    val tail get() = text.substring(tailStart)
    val settledText get() = text.substring(0, tailStart)

    /** The first recording of an empty document starts now: the title uses this time. */
    fun stampStart(time: Long) { if (committed.isEmpty()) startedAt = time }

    fun append(segment: NotesSegment) { committed += segment.copy(id = committed.size) }

    var previousTranscript: PreviousTranscript? = null
        private set
    val transcriptEngine: TranscriptEngine get() = committed.map { it.engine }.distinct().let { when (it.size) { 0 -> TranscriptEngine.Unknown; 1 -> it.first()?.let(TranscriptEngine::Named) ?: TranscriptEngine.Unknown; else -> TranscriptEngine.Mixed } }

    /** Replace words only; all indices, clip boundaries, roster and manual speaker overrides stay in place. */
    fun applyRetranscription(results: Map<Int, RetranscribedSegment>, at: Long = System.currentTimeMillis()): Boolean {
        if (results.isEmpty()) return false
        val next = committed.map { old -> results[old.id]?.let { result ->
            val final = result.final
            old.copy(raw = final.raw, text = final.text, corrected = final.corrected,
                keptOriginal = final.correctionError != null && !final.corrected, failure = null,
                engine = result.engine, turns = reattribute(old.turns, result))
        } ?: old }
        previousTranscript = PreviousTranscript(at, transcriptEngine.wire, committed.toList())
        committed.clear(); committed.addAll(next); speakerVersion++
        return true
    }

    fun restorePreviousTranscript(): Boolean {
        val previous = previousTranscript ?: return false
        previousTranscript = PreviousTranscript(System.currentTimeMillis(), transcriptEngine.wire, committed.toList())
        committed.clear(); committed.addAll(previous.segments); speakerVersion++
        return true
    }

    private fun reattribute(turns: List<SpeakerTurn>?, result: RetranscribedSegment): List<SpeakerTurn>? {
        if (turns.isNullOrEmpty()) return turns
        val end = result.clip.offset + result.clip.duration
        val words = result.final.words?.takeIf { it.isNotEmpty() }
        val rawParts = Array(turns.size) { mutableListOf<String>() }
        val durations = turns.mapIndexed { i, turn -> ((turns.getOrNull(i + 1)?.start ?: end) - turn.start).coerceAtLeast(0.0) }
        fun proportional(text: String): List<String> {
            val tokens = text.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
            val total = durations.sum().takeIf { it > 0 } ?: turns.size.toDouble()
            var cursor = 0; var elapsed = 0.0
            return turns.indices.map { i ->
                elapsed += if (durations.sum() > 0) durations[i] else 1.0
                val until = if (i == turns.lastIndex) tokens.size else kotlin.math.round(tokens.size * elapsed / total).toInt().coerceIn(cursor, tokens.size)
                tokens.subList(cursor, until).joinToString(" ").also { cursor = until }
            }
        }
        if (words != null) for (word in words) {
            val midpoint = result.clip.offset + (word.start + word.end) / 2
            val index = turns.indices.firstOrNull { i -> midpoint >= turns[i].start && midpoint < (turns.getOrNull(i + 1)?.start ?: end) }
                ?: turns.indices.minBy { i -> kotlin.math.abs(midpoint - turns[i].start.coerceAtMost(end)) }
            rawParts[index] += word.text
        }
        val singlePerson = turns.map { it.effectivePerson }.distinct().size == 1
        val raw = if (words == null && singlePerson) turns.indices.map { if (it == 0) result.final.raw else "" } else if (words != null) rawParts.map { it.joinToString(" ") } else proportional(result.final.raw)
        // Timings describe raw speech; polished words are apportioned using the raw-word ownership boundaries.
        val text = if (result.final.text == result.final.raw) raw else if (words == null && singlePerson) turns.indices.map { if (it == 0) result.final.text else "" }
            else if (words != null) {
                val tokens = result.final.text.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
                var cursor = 0; var count = 0
                turns.indices.map { i ->
                    count += rawParts[i].size
                    val until = if (i == turns.lastIndex) tokens.size else kotlin.math.round(tokens.size.toDouble() * count / words.size).toInt().coerceIn(cursor, tokens.size)
                    tokens.subList(cursor, until).joinToString(" ").also { cursor = until }
                }
            } else proportional(result.final.text)
        return turns.mapIndexed { i, turn -> turn.copy(text = text[i], raw = raw[i], approximate = turn.approximate || (words == null && !singlePerson)) }
    }

    // Speakers

    /** What a segment said for structuring and fallbacks: a `Name: text` line per turn when labelled, else its text. */
    fun spoken(segment: NotesSegment) = segment.turns?.takeIf { it.isNotEmpty() }
        ?.filter { it.text.isNotBlank() }?.joinToString("\n") { roster.displayName(it.effectivePerson) + ": " + it.text } ?: segment.text

    /** Some segment is labelled: the transcript shows who said what. */
    val labelled get() = committed.any { !it.turns.isNullOrEmpty() }

    /** Where [person] (and anyone merged into them) first speaks: the segment's id and a line of what they said. Null when they never did. */
    fun firstTurn(person: Int): Pair<Int, String>? {
        for (segment in committed) for (turn in segment.turns.orEmpty()) {
            if (roster.resolve(turn.effectivePerson) == person && turn.text.isNotBlank()) return segment.id to turn.text.trim().take(120)
        }
        return null
    }

    /** Seek within the kept segment to this person's first spoken turn. */
    fun sampleOffset(person: Int): Int {
        val first = firstTurn(person) ?: return 0
        val segment = committed.first { it.id == first.first }
        val turn = segment.turns.orEmpty().first { roster.resolve(it.effectivePerson) == person && it.text.isNotBlank() }
        return ((turn.start - segment.offset).coerceAtLeast(0.0) * 1000).toInt()
    }

    /** Override one turn without changing its server identity or any other turn. Null creates a local person. */
    fun reassignTurn(segment: Int, turn: Int, person: Int?): Boolean {
        val row = committed.getOrNull(segment) ?: return false
        val turns = row.turns ?: return false
        val original = turns.getOrNull(turn) ?: return false
        if (person != null && roster.person(person) == null) return false
        val target = person?.let(roster::resolve) ?: roster.addPerson()
        committed[segment] = row.copy(turns = turns.toMutableList().apply { this[turn] = original.copy(overridePerson = target) })
        speakerVersion++
        return true
    }

    fun renameSpeaker(person: Int, name: String?) { roster.rename(person, name); speakerVersion++ }
    fun rejectVoice(person: Int) { roster.reject(person); speakerVersion++ }
    fun mergeSpeaker(person: Int, into: Int) { roster.merge(person, into); speakerVersion++ }
    fun separateSpeaker(person: Int) { roster.separate(person); speakerVersion++ }

    /** Places [name] appears as a whole word in the notes ("Also replace “Person 2” in the notes"). */
    fun nameCount(name: String) = if (name.isBlank()) 0 else nameRegex(name).findAll(text).count()

    /** The notes with every whole-word [old] replaced by [new]. */
    fun replacingName(old: String, new: String) = if (old.isBlank()) text else nameRegex(old).replace(text, Regex.escapeReplacement(new))

    private fun nameRegex(name: String) = namesRegex(listOf(name))

    private fun namesRegex(names: Collection<String>) =
        Regex("(?<![\\p{L}\\p{N}])(?:" + names.sortedByDescending { it.length }.joinToString("|") { Regex.escape(it) } + ")(?![\\p{L}\\p{N}])")

    /** Places any of [names] appears as a whole word in the notes: "Also replace names in the notes (N places)". */
    fun nameCount(names: Collection<String>): Int = names.filter { it.isNotBlank() }.let { if (it.isEmpty()) 0 else namesRegex(it).findAll(text).count() }

    /** The notes with every whole-word old name swapped for its new one, in one pass so a swap (Maya ↔ Sam) comes out right. */
    fun replacingNames(renames: Map<String, String>): String {
        val olds = renames.keys.filter { it.isNotBlank() }
        return if (olds.isEmpty()) text else namesRegex(olds).replace(text) { renames.getValue(it.value) }
    }

    /** Continue recording: a capture boundary at [offset] seconds of audio, [time] wall clock. */
    fun addBoundary(offset: Double, time: Long) { boundaryList += NotesBoundary(offset, time); version++ }

    fun addClip(clip: NotesAudioClip) { clips[clip.segment] = clip }
    fun clearClips() = clips.clear()

    // User edits

    /**
     * The editor changed the text. An edit wholly before the tail shifts it; an edit that touches a non-empty tail
     * claims it, so the whole tail becomes user text and the next pass starts a new tail after it.
     */
    fun userEdit(start: Int, end: Int, replacement: String): NotesChange {
        val change = NotesChange(start, end, replacement, NotesChange.Kind.USER)
        val claims = touchesTail(start, end)
        text = change.applied(text)
        if (claims) { settleTail(); consecutiveFailures = 0 } else tailStart += replacement.length - (end - start)
        changed(replacement.length)
        return change
    }

    /** Whether an edit of `[start, end)` would claim the tail (and so whether an append would land under a caret). */
    fun touchesTail(start: Int, end: Int): Boolean {
        if (tailStart >= text.length) return false
        if (end > tailStart) return true
        // An insertion right before the separator extends the user's line; right before AI text, it edits the tail.
        return start == tailStart && end == start && text[tailStart] != '\n'
    }

    private fun changed(inserted: Int) { version++; charsSinceReorganize += inserted }

    private fun settleTail() {
        tailStart = text.length
        if (structuredEnd >= windowStart) windowStart = structuredEnd + 1
        windowGeneration++
    }

    // The open window

    private val windowSegments get() = if (windowStart >= committed.size) emptyList()
        else committed.subList(windowStart, committed.size).filter { !it.isGap && it.text.isNotEmpty() }

    private fun windowTranscript(through: Int = Int.MAX_VALUE) = windowSegments.filter { it.id <= through }.joinToString("\n") { spoken(it) }

    fun windowChars(through: Int = Int.MAX_VALUE) = windowTranscript(through).scalars

    /** The window's text no pass has structured yet: the "Hearing" strip. */
    val unstructuredTail get() = windowSegments.filter { it.id > structuredEnd }.joinToString(" ") { it.text }

    val outline get() = capOutline(NotesMarkdown.headings(settledText))

    /** The next pass, or null when the window has nothing new or is over [MAX_WINDOW_CHARS] (until it overflows). */
    fun nextStructureRequest(final: Boolean = false): NotesStructureRequest? {
        val last = windowSegments.lastOrNull() ?: return null
        if (last.id <= structuredEnd) return null
        val transcript = windowTranscript()
        if (transcript.scalars > MAX_WINDOW_CHARS || transcript.isBlank()) return null
        return NotesStructureRequest(transcript, outline, final, committed.size - 1, version, windowGeneration, id)
    }

    /**
     * Takes a pass's answer: a success replaces the tail and settles it once the window is long enough; a failure keeps
     * the previous tail. A response for a tail that was claimed, settled or reorganized since is ignored.
     */
    fun apply(response: NotesStructureResponse, request: NotesStructureRequest): NotesChange? {
        if (!current(request)) return null
        return recording(NotesChange.Kind.APPEND) {
            val md = response.markdown?.trim()
            if (response.structured && !md.isNullOrEmpty()) {
                replaceTail(md)
                structuredEnd = request.windowEnd; consecutiveFailures = 0
                if (windowChars(request.windowEnd) >= FREEZE_CHARS) settleTail()
            } else consecutiveFailures++
            overflow()
        }
    }

    private fun current(request: NotesStructureRequest) = request.documentId == id && request.windowGeneration == windowGeneration &&
        request.windowEnd >= windowStart && request.windowEnd < committed.size && request.windowEnd > structuredEnd

    private val tailSeparator get() = settledText.let { if (it.isEmpty() || it.endsWith("\n\n")) "" else if (it.endsWith("\n")) "\n" else "\n\n" }

    private fun replaceTail(markdown: String) { text = settledText + tailSeparator + markdown }

    /** A window past [MAX_WINDOW_CHARS], or past [FREEZE_CHARS] after two failures, settles and falls back to raw text. */
    fun freezeOverflow() = recording(NotesChange.Kind.APPEND) { overflow() }

    private fun overflow() {
        fun qualifies(chars: Int) = chars > MAX_WINDOW_CHARS || (consecutiveFailures >= 2 && chars >= FREEZE_CHARS)
        if (!qualifies(windowChars())) return
        settleTail()
        if (!qualifies(windowChars())) return
        appendFallback(); consecutiveFailures = 0
    }

    /** At Stop, after the final pass: the tail settles and, with structuring on, whatever it did not cover falls back. */
    fun freezeAll(structuring: Boolean = true) = recording(NotesChange.Kind.APPEND) {
        settleTail()
        if (structuring) appendFallback()
        consecutiveFailures = 0
    }

    private fun appendFallback() {
        val rest = windowSegments
        if (rest.isNotEmpty()) {
            val block = fallbackBlock(rest.joinToString("\n\n") { spoken(it) })
            fallbackBlocks += block
            text = settledText + tailSeparator + block
        }
        windowStart = committed.size; structuredEnd = windowStart - 1
        settleTail()
    }

    /** Runs AI mutations (which only change a suffix) and returns the minimal change they made. */
    private fun recording(kind: NotesChange.Kind, body: () -> Unit): NotesChange? {
        val before = text
        body()
        return diff(before, text, kind)?.also { changed(it.replacement.length) }
    }

    /** The parts of a split window replace the tail in order and the tail settles. */
    fun applyPieces(pieces: List<NotesPiece>, request: NotesStructureRequest): NotesChange? {
        if (!current(request) || pieces.isEmpty()) return null
        return recording(NotesChange.Kind.APPEND) {
            replaceTail(render(pieces))
            pieces.filterIsInstance<NotesPiece.Fallback>().forEach { fallbackBlocks += fallbackBlock(it.text.trim()) }
            structuredEnd = request.windowEnd; consecutiveFailures = 0
            settleTail(); overflow()
        }
    }

    /** Fallback blocks still in the text exactly as appended: (block, raw text under its header). */
    val untouchedFallbacks get() = fallbackBlocks.filter { text.contains(it) }.map { it to it.drop(FALLBACK_HEADER.length + 2) }

    /** Organize: each untouched fallback block replaced in place, only when the text is still [expected]. */
    fun replaceFallbacks(replacements: List<Pair<String, List<NotesPiece>>>, expected: Int): List<NotesChange> {
        if (version != expected) return emptyList()
        val located = replacements.mapNotNull { (block, pieces) -> text.indexOf(block).takeIf { it >= 0 }?.let { Triple(it, block, pieces) } }
        val changes = mutableListOf<NotesChange>()
        var inserted = 0
        // From the end backwards, so every range is still where it was found when its change is replayed.
        for ((at, block, pieces) in located.sortedByDescending { it.first }) {
            val change = NotesChange(at, at + block.length, render(pieces), NotesChange.Kind.ORGANIZE)
            text = change.applied(text)
            if (change.end <= tailStart) tailStart += change.replacement.length - block.length else settleTail()
            fallbackBlocks.remove(block)
            pieces.filterIsInstance<NotesPiece.Fallback>().forEach { fallbackBlocks += fallbackBlock(it.text.trim()) }
            inserted += change.replacement.length
            changes += change
        }
        if (changes.isNotEmpty()) changed(inserted)
        return changes
    }

    // Reorganize

    /** The longest suffix of whole sections within [maxChars], and the headings above it (context only). */
    fun reorganizeScope(maxChars: Int = MAX_REORGANIZE_CHARS): Pair<IntRange, List<String>>? {
        var start = text.length; var chars = 0
        for ((range, _) in NotesMarkdown.sections(text).asReversed()) {
            val size = text.substring(range.first, range.last + 1).scalars
            if (chars + size > maxChars) break
            chars += size; start = range.first
        }
        if (start >= text.length || text.substring(start).trim().length < MIN_REORGANIZE_CHARS) return null
        return (start until text.length) to (if (start == 0) emptyList() else capOutline(NotesMarkdown.headings(text.substring(0, start))))
    }

    val reorganizeTooLong get() = NotesMarkdown.sections(text).lastOrNull()?.let { text.substring(it.first.first, it.first.last + 1).scalars > MAX_REORGANIZE_CHARS } == true

    fun reorganizeRequest(final: Boolean, manual: Boolean, maxChars: Int = MAX_REORGANIZE_CHARS): NotesReorganizeRequest? {
        if (!manual && version == lastReorganizeVersion) return null
        val (range, outline) = reorganizeScope(maxChars) ?: return null
        return NotesReorganizeRequest(text.substring(range.first), outline, final, version, range.first, text.length, id)
    }

    /** Takes a reorganize answer, only when the text is exactly what the request was made from. */
    fun applyReorganize(response: NotesReorganizeResponse, request: NotesReorganizeRequest): NotesChange? {
        if (request.documentId != id || request.version != version || request.end > text.length || !response.reorganized) return null
        val md = response.markdown?.trim()
        if (!response.changed || md.isNullOrEmpty()) { lastReorganizeVersion = version; charsSinceReorganize = 0; return null }
        val old = text.substring(request.start, request.end)
        // Keep the blank lines that frame the scope, so the sections around it stay separated as they were.
        val change = NotesChange(request.start, request.end, old.takeWhile { it == '\n' } + md + old.takeLastWhile { it.isWhitespace() },
            NotesChange.Kind.REORGANIZE)
        text = change.applied(text)
        settleTail()
        changed(change.replacement.length)
        lastReorganizeVersion = version; charsSinceReorganize = 0
        return change
    }

    // Export

    private fun format(pattern: String, zone: TimeZone) = SimpleDateFormat(pattern, Locale.US).apply { timeZone = zone }.format(Date(startedAt))

    fun title(zone: TimeZone = TimeZone.getDefault()) = "# " + (name ?: "Notes — " + format("yyyy-MM-dd HH:mm", zone))

    /** Save's suggested file name: the name, else the start time, without characters file systems refuse. */
    fun fileName(zone: TimeZone = TimeZone.getDefault()) =
        (name ?: "Notes " + format("yyyy-MM-dd HHmm", zone)).replace(Regex("[\\\\/:*?\"<>|\\p{Cntrl}]"), " ").trim().take(80) + ".md"

    /** The notes without placeholder lines, trimmed. */
    val notesBody get() = text.split('\n').filter { it.trim() != NotesMarkdown.PLACEHOLDER }.joinToString("\n").trim()

    // Library rows

    /** The note's meaningful lines, markdown markers stripped: no blanks, placeholders or "not structured" notices. */
    private fun meaningfulLines() = notesBody.split('\n').map { it.trim() }
        .filter { it.isNotEmpty() && it != FALLBACK_HEADER && !it.all { c -> c == '-' || c == '*' || c == '_' } }

    private fun plain(line: String) = line.replace(Regex("^(#{1,6}\\s+|>\\s*|[-*+]\\s+(\\[[ xX]]\\s+)?|\\d+[.)]\\s+)+"), "")
        .replace(Regex("[*_`]+"), "").trim()

    private fun titleLine(): Pair<Int, String>? {
        val lines = meaningfulLines()
        lines.forEachIndexed { i, line -> NotesMarkdown.heading(line)?.let { return i to it.second } }
        return lines.indices.firstNotNullOfOrNull { i -> plain(lines[i]).takeIf { it.isNotEmpty() }?.let { i to it.take(MAX_LIBRARY_TITLE) } }
    }

    /** "Note, 24 October" from the start time. */
    fun dateTitle(zone: TimeZone = TimeZone.getDefault(), locale: Locale = Locale.getDefault()) =
        "Note, " + SimpleDateFormat("d MMMM", locale).apply { timeZone = zone }.format(Date(startedAt))

    /** The library title: a rename wins forever, else the first heading, else the first meaningful line, else the date. */
    fun libraryTitle(zone: TimeZone = TimeZone.getDefault(), locale: Locale = Locale.getDefault()) =
        name?.trim()?.takeIf { it.isNotEmpty() } ?: titleLine()?.second?.take(MAX_LIBRARY_TITLE) ?: if (typedNote && isEmpty) "Untitled note" else dateTitle(zone, locale)

    /** A line or two of the note after its title line (else the start of the transcript), for the list. */
    val snippet: String get() {
        val lines = meaningfulLines()
        val used = if (name.isNullOrBlank()) titleLine()?.first else null
        val title = plain(libraryTitle())
        val body = lines.filterIndexed { i, line ->
            i != used && !(NotesMarkdown.heading(line) != null && plain(line).equals(title, ignoreCase = true))
        }.map(::plain).filter { it.isNotEmpty() }.joinToString(" · ")
        val text = body.ifEmpty { committed.firstOrNull { !it.isGap && it.text.isNotEmpty() }?.text.orEmpty().replace('\n', ' ') }
        return if (text.length > MAX_SNIPPET) text.take(MAX_SNIPPET).trimEnd() + "…" else text
    }

    /** Unchecked to-dos (`- [ ]`) in the notes. */
    val openTodos: Int get() = text.lineSequence().count { OPEN_TODO.containsMatchIn(it) }

    /** Nothing written and never named: a note like this is not kept. */
    val untouched get() = !typedNote && isEmpty && name.isNullOrBlank()

    /** One line per segment: `**[00:00:12]** text`, gaps and "kept original" marked; [raw] swaps in the raw text. */
    fun transcriptLines(raw: Boolean = false, zone: TimeZone = TimeZone.getDefault(), locale: Locale = Locale.US): List<String> {
        val lines = mutableListOf<String>()
        val pending = boundaryList.sortedBy { it.offset }.toMutableList()
        fun divider(b: NotesBoundary) = "_Continued · " + SimpleDateFormat("MMM d, h:mm a", locale).apply { timeZone = zone }.format(Date(b.time)) + "_"
        for (s in committed) {
            while (pending.isNotEmpty() && pending.first().offset <= s.offset) lines += divider(pending.removeAt(0))
            val stamp = "**[${timestamp(s.offset)}]** "
            val turns = s.turns
            lines += if (s.failure != null) stamp + "⚠︎ audio not transcribed (${s.failure})"
            else if (!turns.isNullOrEmpty()) {
                // A line per turn: `**[00:01:05] Maya:** text`.
                turns.filter { (if (raw) it.raw else it.text).isNotBlank() }.joinToString("\n\n") { t ->
                    "**[${timestamp(t.start)}] ${roster.displayName(t.effectivePerson)}:** " + (if (raw) t.raw else t.text) +
                        if ((t.keptOriginal || s.keptOriginal) && !raw) " _(kept original)_" else ""
                }
            }
            else stamp + (if (raw) s.raw else s.text) + if (s.keptOriginal && !raw) " _(kept original)_" else ""
        }
        pending.forEach { lines += divider(it) }
        return lines
    }

    fun transcriptMarkdown(raw: Boolean = false) = (listOf("## Transcript") + transcriptLines(raw)).joinToString("\n\n")

    /** Copy and Share: the title, the notes, then the transcript appendix (only the transcript without notes). */
    fun exportMarkdown(includeNotes: Boolean = true, zone: TimeZone = TimeZone.getDefault()): String {
        val parts = mutableListOf(title(zone))
        val body = if (includeNotes) notesBody else ""
        if (body.isNotEmpty()) parts += listOf(body, "---")
        parts += transcriptMarkdown()
        return parts.joinToString("\n\n") + "\n"
    }

    // Recovery copy

    /** Everything but the live partial and the reorganize bookkeeping, for [NotesJournal]. */
    fun toJson(): JSONObject = JSONObject().put("startedAt", startedAt).put("text", text).put("tailStart", tailStart)
        .put("typedNote", typedNote).put("windowStart", windowStart).put("structuredEnd", structuredEnd).put("fallbacks", JSONArray(fallbackBlocks)).put("uid", uid)
        .put("boundaries", JSONArray().apply { boundaryList.forEach { put(JSONObject().put("offset", it.offset).put("time", it.time)) } })
        .put("audio", JSONArray().apply { clips.values.forEach { put(it.toJson()) } })
        .put("segments", JSONArray().apply {
            committed.forEach { s ->
                put(JSONObject().put("offset", s.offset).put("raw", s.raw).put("text", s.text).put("corrected", s.corrected)
                    .put("kept", s.keptOriginal).put("engine", s.engine).apply { s.failure?.let { put("failure", it) } }
                    .apply { s.turns?.let { turns -> put("turns", JSONArray().apply { turns.forEach { put(it.toJson()) } }) } })
            }
        }).apply { previousTranscript?.let { p -> put("previousTranscript", JSONObject().put("at", p.at).put("engine", p.engine)
            .put("segments", NotesDocument().apply { p.segments.forEach(::append) }.toJson().getJSONArray("segments"))) }; name?.let { put("name", it) }; if (roster.people.isNotEmpty()) put("people", roster.toJson()) }

    companion object {
        fun fromJson(json: JSONObject): NotesDocument = NotesDocument(json.getLong("startedAt"), json.getString("text")).apply {
            typedNote = json.optBoolean("typedNote")
            name = json.optString("name").takeIf { json.has("name") }
            json.optString("uid").takeIf { it.isNotEmpty() }?.let { uid = it }
            val list = json.getJSONArray("segments")
            for (i in 0 until list.length()) list.getJSONObject(i).let { s ->
                committed += NotesSegment(i, s.getDouble("offset"), s.getString("raw"), s.getString("text"), s.optBoolean("corrected"),
                    s.optBoolean("kept"), s.optString("failure").takeIf { s.has("failure") },
                    s.optJSONArray("turns")?.let { a -> (0 until a.length()).map { SpeakerTurn.fromJson(a.getJSONObject(it)) } }, s.text("engine"))
            }
            json.optJSONObject("previousTranscript")?.let { previous ->
                val copy = JSONObject(json.toString()).apply { remove("previousTranscript"); put("segments", previous.getJSONArray("segments")) }
                previousTranscript = PreviousTranscript(previous.getLong("at"), previous.optString("engine", "unknown"), fromJson(copy).segments.toList())
            }
            roster = SpeakerRoster.fromJson(json.optJSONArray("people"))
            tailStart = json.getInt("tailStart").coerceIn(0, text.length)
            windowStart = json.getInt("windowStart").coerceIn(0, committed.size)
            structuredEnd = json.getInt("structuredEnd").coerceIn(windowStart - 1, committed.size - 1)
            json.optJSONArray("fallbacks")?.let { a -> for (i in 0 until a.length()) fallbackBlocks += a.getString(i) }
            json.optJSONArray("boundaries")?.let { a -> for (i in 0 until a.length()) a.getJSONObject(i).let { boundaryList += NotesBoundary(it.getDouble("offset"), it.getLong("time")) } }
            json.optJSONArray("audio")?.let { a -> for (i in 0 until a.length()) NotesAudioClip.fromJson(a.getJSONObject(i)).let { clips[it.segment] = it } }
        }

        /** The tail settles once a pass succeeded on this many transcript characters. */
        const val FREEZE_CHARS = 1600
        /** The open window never grows past this; it falls back to raw text instead. */
        const val MAX_WINDOW_CHARS = 3600
        /** The most notes one reorganize sends (the server's limit), Unicode scalars. */
        const val MAX_REORGANIZE_CHARS = 3500
        const val MIN_REORGANIZE_CHARS = 80
        /** An automatic reorganize while recording: small enough to fit between two segment cuts. */
        const val RECORDING_REORGANIZE_CHARS = 1200
        const val MAX_OUTLINE_ITEMS = 24
        const val MAX_OUTLINE_ITEM_CHARS = 120
        const val MAX_OUTLINE_CHARS = 1500
        const val MIN_SPLIT_CHARS = 400
        const val MAX_LIBRARY_TITLE = 80
        const val MAX_SNIPPET = 160
        private val OPEN_TODO = Regex("^\\s*[-*+]\\s+\\[ ]")
        const val FALLBACK_HEADER = "_Not structured — see transcript_"
        private val ids = AtomicLong()

        fun capOutline(headings: List<String>): List<String> {
            val items = headings.takeLast(MAX_OUTLINE_ITEMS).map { it.take(MAX_OUTLINE_ITEM_CHARS) }.toMutableList()
            while (items.sumOf { it.length } > MAX_OUTLINE_CHARS) items.removeAt(0)
            return items
        }

        fun fallbackBlock(body: String) = "$FALLBACK_HEADER\n\n$body"

        fun render(pieces: List<NotesPiece>) = pieces.map {
            when (it) { is NotesPiece.Markdown -> it.text.trim(); is NotesPiece.Fallback -> fallbackBlock(it.text.trim()) }
        }.filter { it.isNotEmpty() }.joinToString("\n\n")

        /** Splits at the sentence end nearest the middle (else the nearest space), each part at least [minPart]. */
        fun split(text: String, minPart: Int = MIN_SPLIT_CHARS): Pair<String, String>? {
            if (text.length < 2 * minPart) return null
            val middle = text.length / 2
            fun cut(boundary: (Int) -> Boolean) = (minPart..(text.length - minPart)).filter(boundary).minByOrNull { kotlin.math.abs(it - middle) }
            val at = cut { i -> text[i].isWhitespace() && text[i - 1] in ".?!\n" } ?: cut { text[it].isWhitespace() } ?: return null
            val a = text.substring(0, at).trim(); val b = text.substring(at).trim()
            return if (a.isEmpty() || b.isEmpty()) null else a to b
        }

        /** The smallest single replacement that turns [old] into [new], never splitting a surrogate pair. */
        fun diff(old: String, new: String, kind: NotesChange.Kind): NotesChange? {
            if (old == new) return null
            var prefix = 0
            while (prefix < old.length && prefix < new.length && old[prefix] == new[prefix]) prefix++
            var suffix = 0
            while (suffix < old.length - prefix && suffix < new.length - prefix && old[old.length - 1 - suffix] == new[new.length - 1 - suffix]) suffix++
            fun splits(s: String, i: Int) = i < s.length && s[i].isLowSurrogate()
            while (prefix > 0 && (splits(old, prefix) || splits(new, prefix))) prefix--
            while (suffix > 0 && (splits(old, old.length - suffix) || splits(new, new.length - suffix))) suffix--
            return NotesChange(prefix, old.length - suffix, new.substring(prefix, new.length - suffix), kind)
        }

        /** `hh:mm:ss` from the session start. */
        fun timestamp(offset: Double): String {
            val s = maxOf(0, offset.toInt())
            return "%02d:%02d:%02d".format(Locale.US, s / 3600, s / 60 % 60, s % 60)
        }
    }
}

internal data class PreviousTranscript(val at: Long, val engine: String, val segments: List<NotesSegment>)
internal data class RetranscribedSegment(val clip: NotesAudioClip, val final: ServerEvent.Final, val engine: String?)
