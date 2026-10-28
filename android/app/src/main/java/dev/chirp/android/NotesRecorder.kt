package dev.chirp.android

import android.os.SystemClock
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Why structuring does not run. WAITING: health is unknown, so where the text would go is unknown: fail closed. */
internal enum class StructuringOff { DISABLED, CORRECTION_OFF, UNSUPPORTED, WAITING }

internal sealed interface Structuring {
    data class Off(val why: StructuringOff) : Structuring
    data object Idle : Structuring
    data object Running : Structuring
    /** The last pass failed with this label (`timeout`, `busy`, `rejected: novel_name`…); the next segment retries. */
    data class Failed(val label: String) : Structuring
    companion object {
        fun availability(health: Health?, enabled: Boolean): Structuring = when {
            health == null -> Off(StructuringOff.WAITING)
            !health.correctionAvailable -> Off(StructuringOff.CORRECTION_OFF)
            !health.notesStructure -> Off(StructuringOff.UNSUPPORTED)
            else -> if (enabled) Idle else Off(StructuringOff.DISABLED)
        }
    }
}

internal sealed interface Reorganizing {
    data class Unavailable(val why: StructuringOff) : Reorganizing
    data object Idle : Reorganizing
    data object Running : Reorganizing
    data class Organizing(val step: Int, val of: Int) : Reorganizing
    /** A reorganize or Organize changed the notes; Undo restores the text from before it. */
    data class Applied(val at: Long) : Reorganizing
    data class Failed(val label: String) : Reorganizing
    data class Organized(val failed: Int, val reason: String?) : Reorganizing
    /** The notes changed while it ran, so its result was discarded. */
    data object Conflict : Reorganizing
    data object TooLong : Reorganizing
    /** Organize found too little to reorganize (under [NotesDocument.MIN_REORGANIZE_CHARS]). */
    data object TooShort : Reorganizing
    val running get() = this == Running || this is Organizing
}

/**
 * A Notes session: one long recording cut into ordinary `/v1/stream` utterances over rolling sockets, plus the
 * structuring passes that turn the transcript into Markdown. A port of the Mac's `NotesRecorder`; speaker labels come from
 * the Mac's server with each final ([labelSpeakers]). Every edge (sockets, microphone, the notes calls, time) is injected; runs on the main thread. Nothing here
 * is logged or persisted.
 */
internal class NotesRecorder(
    private val transportFactory: ((ServerEvent) -> Unit, () -> Unit) -> ImeTransport,
    private val captureFactory: (frame: (ByteArray, Float) -> Unit, level: (Double) -> Unit, done: (DictationStatus?) -> Unit) -> Capture,
    private val structure: suspend (NotesStructureRequest) -> NotesStructureResponse,
    private val reorganize: suspend (NotesReorganizeRequest) -> NotesReorganizeResponse,
    var options: Options,
    health: Health?,
    structuringEnabled: Boolean,
    var autoReorganize: Boolean = true,
    private val editNotes: suspend (NotesEditRequest) -> NotesEditResponse = { throw NotesHttpError(404) },
    private val now: () -> Long = SystemClock::uptimeMillis,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
) {
    data class Options(val correction: Boolean, val profile: String = "default", val prompt: String? = null)
    enum class State { IDLE, STARTING, RECORDING, PAUSED, STOPPING, STOPPED, ERROR;
        val capturing get() = this == STARTING || this == RECORDING
        /** Segments still commit and appends still run: recording, or paused with the microphone closed. */
        val live get() = capturing || this == PAUSED
        /** The session holds the microphone service: recording, paused or finishing. */
        val active get() = live || this == STOPPING
    }
    enum class PassKind { APPEND, REORGANIZE, EDIT }

    var state = State.IDLE
        private set(value) { if (field != value) { field = value; changed() } }
    var error: RecordingFailure? = null
        private set
    var document = NotesDocument()
        private set
    var structuring: Structuring
        private set
    var debugRetention = false
        private set
    var passKind: PassKind? = null
        private set
    var level = 0.0
        private set
    /**
     * Battery saver: nothing is on screen, so the level meter and live partials are not dispatched to the main thread.
     * Segments, structuring and reorganize run as always; turning it off brings the partial line up to date.
     */
    @Volatile var quiet = false
        set(value) { if (field != value) { field = value; if (!value) updateLivePartial() } }
    /** Structure and reorganize calls made, for the numbers-only Notes timings. */
    var passes = 0
        private set
    /**
     * The last thing that went wrong since Record, for Diagnostics: an app status or a server code (`structure: auth`),
     * never notes, transcript or hosts.
     */
    var problem: String? = null
        private set
    /** AI changes to [document] the editor has not replayed yet, oldest first. */
    private val pending = mutableListOf<NotesChange>()
    var onChange: (() -> Unit)? = null
    /** "Keep audio with notes": each segment's audio is copied while it records and handed to [audioSink] when it commits. */
    @Volatile var keepAudio = false
    /**
     * A committed segment's audio: the document it belongs to, the segment's index in it, its offset in seconds and its PCM16
     * mono 16 kHz bytes (the receiver owns them). Called on the main thread; encode and store off it.
     */
    var audioSink: ((documentId: Long, segment: Int, offset: Double, pcm: ByteArray) -> Unit)? = null
    /** "Label speakers": segments ask the server who spoke (read at each segment's start). */
    var labelSpeakers = false
    var recognizeVoices = false
    /** Why the last segment came without labels (`unavailable`: no speaker model on the Mac), else null. */
    var speakerError: String? = null
        private set
    /** This note's speaker session on the server: random, memory only, new for every document. */
    internal var speakerSession = newSpeakerSession()

    private inner class Segment(val transport: ImeTransport, val buffer: PreReadyBuffer, val pcm: java.io.ByteArrayOutputStream? = null) {
        var seq = -1
        var offset = 0.0
        var end: Double? = null
        var partial = ""
        var engine: String? = null
        var correcting = false
        var ready = false
        /** Finalize came before Ready (a pause or cut right after the swap): `stop` goes out with Ready. */
        var stopOnReady = false
        var timeout: Job? = null
        @Volatile var lost = false
    }

    private val router = FrameRouter<Segment> { segment, frame ->
        // Kept audio: a copy of the speech frames, taken before the buffer takes (and wipes) them. Memory only, until committed.
        segment.pcm?.let { synchronized(it) { it.write(frame) } }
        if (!segment.buffer.offer(frame) && !segment.lost) { segment.lost = true; scope.launch { lost(segment) } }
    }
    private var capture: Capture? = null
    private val segments = HashMap<Int, Segment>()
    /** Finished segments waiting for an earlier one, so the transcript stays in order. A null value: an empty final. */
    private val results = HashMap<Int, NotesSegment?>()
    /** Speaker labels of finished segments waiting for their turn: people are numbered in transcript order. */
    private val labels = HashMap<Int, SpeakersResult>()
    /** Audio of finished segments waiting for their turn to commit (only with [keepAudio]). */
    private val finishedAudio = HashMap<Int, ByteArray>()
    private var nextSeq = 0
    private var nextCommit = 0
    private var current: Int? = null
    private var failureStreak = 0
    private var sawReady = false
    /** The capturing socket came from Resume and is not Ready yet: failing it goes back to paused. */
    private var resuming = false

    private var passJob: Job? = null
    private var waiting = false
    private var lastPassEnd: Long? = null
    private var timer: Job? = null
    private var timerDeadline: Long? = null
    private var operationDeadlines = health?.operationDeadlines
    private var allowed: Structuring = Structuring.availability(health, structuringEnabled)
    private var epoch = 0

    private var reorganizeSupported = health?.notesReorganize == true
    private var reorganizeMissing = false
    private var reorganizeState: Reorganizing = Reorganizing.Idle
    private var manualReorganize = false
    private var lastReorganizeEnd: Long? = null
    private var reorganizeRetry = false
    private var lastKeystroke: Long? = null
    private var editorInTail = false
    private var editorComposing = false
    private var held: Pair<NotesStructureRequest, NotesStructureResponse>? = null
    private var holdJob: Job? = null
    private var lastCommit: Long? = null
    private var versionAtReorganizeEnd: Int? = null
    private var stoppingSince: Long? = null
    /** The text before the last applied reorganize or Organize, while nothing else changed it since. */
    private var undo: Pair<String, Int>? = null
    var undoKind = NotesChange.Kind.ORGANIZE
        private set
    private var organizeBase: String? = null
    private val waiters = mutableListOf<Pair<() -> Boolean, CompletableDeferred<Unit>>>()
    /** Voice edit: the spoken command's socket while capture is diverted to it, the edit waiting for the pass slot, and the undo. */
    private var diverted: Segment? = null
    private var editSupported = health?.notesEdit == true
    private var editMissing = false
    private var pendingEdit: PendingEdit? = null
    private var editRun = 0
    private var editUndo: Pair<String, Int>? = null

    init { structuring = allowed }

    /** Audio recorded into this document so far, seconds. */
    val elapsed get() = router.seconds
    val stoppingElapsed get() = stoppingSince?.let { now() - it }
    /** Segments cut from capture whose final has not landed. A pass waits for them: clean-up needs the model first. */
    val finalizingCount get() = segments.keys.count { it != current }
    val passInFlight get() = passJob != null
    val holding get() = held != null
    val reorganizeStatus: Reorganizing get() = when {
        structuring is Structuring.Off -> Reorganizing.Unavailable((structuring as Structuring.Off).why)
        !reorganizeSupported -> Reorganizing.Unavailable(StructuringOff.UNSUPPORTED)
        else -> reorganizeState
    }
    val canUndo get() = undo?.second == document.version
    /** The server has `POST /v1/notes/edit` (health), and it did not answer 404 this session. */
    val canEdit get() = editSupported
    /** A voice edit is waiting for the pass slot or running. */
    val isEditing get() = pendingEdit != null
    val canUndoEdit get() = editUndo?.second == document.version

    fun takePendingChanges(): List<NotesChange> = pending.toList().also { pending.clear() }
    val pendingCount get() = pending.size

    private fun publish(change: NotesChange?) {
        change ?: return
        pending += change
        if ((reorganizeState is Reorganizing.Applied || reorganizeState == Reorganizing.TooShort) && change.kind != NotesChange.Kind.REORGANIZE) reorganizeState = Reorganizing.Idle
    }

    /** The user's "Structure notes" switch or new health. Turning it on schedules a pass for what is waiting. */
    fun configure(enabled: Boolean, health: Health?) {
        operationDeadlines = health?.operationDeadlines
        allowed = Structuring.availability(health, enabled)
        reorganizeSupported = health?.notesReorganize == true && !reorganizeMissing
        editSupported = health?.notesEdit == true && !editMissing
        if (allowed is Structuring.Off) structuring = allowed
        else if (structuring is Structuring.Off) {
            structuring = if (passJob == null) Structuring.Idle else Structuring.Running
            if (state.live) schedule()
        }
        changed()
    }

    // Recording

    /** Starts recording into the document (a stopped document continues with a new window). */
    fun start() {
        if (state.active) return
        epoch++
        failureStreak = 0; sawReady = false; lastPassEnd = null; error = null; problem = null
        if (lastReorganizeEnd == null) lastReorganizeEnd = now()
        if (structuring is Structuring.Off && allowed !is Structuring.Off) structuring = Structuring.Idle
        document.stampStart(System.currentTimeMillis())
        capture()
    }

    /** Pause: the current segment finalizes as at a cut and the microphone closes; passes go on, nothing freezes. */
    fun pause() {
        if (state != State.RECORDING) return
        releaseMicrophone()
        state = State.PAUSED
    }

    /** Resume: a fresh socket continues the same document and tail; the clock goes on from where it paused. */
    fun resume() {
        if (state != State.PAUSED) return
        error = null; resuming = true
        capture()
    }

    /** A recovered session: its document, stopped (Record continues it), with the audio clock where it ended. */
    fun restore(restored: NotesDocument, seconds: Double) {
        if (state.active) return
        reset()
        document = restored
        speakerSession = newSpeakerSession()
        router.resetTime(seconds)
        state = if (restored.isEmpty) State.IDLE else State.STOPPED
        changed()
    }

    private fun capture() {
        state = State.STARTING
        val segment = open()
        val (_, offset) = router.swap(segment)
        val seq = nextSeq++
        segment.seq = seq; segment.offset = offset; current = seq; segments[seq] = segment
        lateinit var made: Capture
        made = captureFactory({ frame, rms -> if (router.route(frame, rms)) scope.launch { cut() } },
            { value -> if (!quiet) scope.launch { if (capture === made && state.capturing) { level = value; changed() } } },
            { problem -> scope.launch { if (capture === made) captureEnded(problem) } })
        capture = made
        made.start()
        if (!startSegment(segment)) segmentFailed(segment, RecordingFailure.Connection(segment.transport.failureKind))
    }

    private fun startSegment(segment: Segment) =
        segment.transport.start(options.correction, options.profile, "", options.prompt, speakerSession.takeIf { labelSpeakers })

    private fun open(): Segment {
        lateinit var segment: Segment
        val buffer = PreReadyBuffer(send = { segment.transport.audio(it) }, maxBytes = PRE_READY_BYTES)
        val kept = if (keepAudio && audioSink != null) java.io.ByteArrayOutputStream() else null
        val transport = transportFactory({ event -> handle(segment, event) },
            { segmentFailed(segment, RecordingFailure.Connection(segment.transport.failureKind)) })
        segment = Segment(transport, buffer, kept)
        return segment
    }

    /** One frame from a test or a non-microphone source, as the capture thread would route it. */
    internal fun handleFrame(frame: ByteArray, rms: Float) { if (router.route(frame, rms)) scope.launch { cut() } }

    fun stop() {
        if (state == State.STARTING && resuming) current?.let { abandonResume(it, null) }
        if (state == State.STARTING && !sawReady) { cancel(); return }
        finishRecording(null)
    }

    /** Ends recording with an error (lost microphone…): finishes like Stop and keeps the content. */
    fun fail(failure: RecordingFailure) = finishRecording(failure)

    private fun captureEnded(problem: DictationStatus?) {
        capture = null
        val message = RecordingFailure.Capture(problem)
        if (state == State.STARTING && resuming) current?.let { abandonResume(it, message) }
        else if (state == State.STARTING && !sawReady) { cancel(); error = message; state = State.ERROR }
        else if (state.capturing) finishRecording(message)
    }

    private fun stopCapture() { val stopping = capture; capture = null; level = 0.0; stopping?.stop() }

    /** Closes the microphone and lets the capturing segment finalize as at a cut. */
    private fun releaseMicrophone() {
        stopCapture()
        diverted = null
        val (old, end) = router.swap(null)
        current?.let { seq -> segments[seq]?.let { it.end = end; if (it === old) finalize(it) } }
        current = null
    }

    /** A Resume whose socket never got Ready: back to paused, the socket dropped as an empty segment. */
    private fun abandonResume(seq: Int, reason: RecordingFailure?) {
        stopCapture(); router.swap(null); current = null; resuming = false
        error = reason; state = State.PAUSED
        finish(seq, null)
    }

    /** Drops everything in flight at once. The document is kept. */
    fun cancel() {
        epoch++
        stopCapture()
        router.swap(null); diverted = null
        segments.values.forEach { close(it, cancel = true) }
        segments.clear(); results.clear(); labels.clear(); wipeAudio(); nextCommit = nextSeq; current = null; resuming = false
        passJob?.cancel(); passJob = null
        timer?.cancel(); timer = null
        waiting = false; manualReorganize = false
        dropHeld()
        if (reorganizeState.running) reorganizeState = Reorganizing.Idle
        passKind = null
        editRun++; failEdit(NotesEditOutcome.Conflict)
        document.livePartial = ""
        if (state.active) state = if (document.isEmpty) State.IDLE else State.STOPPED
        if (structuring == Structuring.Running) structuring = if (allowed is Structuring.Off) allowed else Structuring.Idle
        waiters.toList().also { waiters.clear() }.forEach { it.second.complete(Unit) }
        changed()
    }

    /** New: an empty document (only while not recording). */
    fun reset() {
        if (state.active) return
        epoch++
        passJob?.cancel(); passJob = null; passKind = null; manualReorganize = false
        timer?.cancel(); timer = null; timerDeadline = null; waiting = false
        document = NotesDocument()
        speakerSession = newSpeakerSession(); speakerError = null; labels.clear()
        wipeAudio()
        router.resetTime()
        failureStreak = 0; pending.clear(); dropHeld()
        reorganizeState = Reorganizing.Idle; reorganizeRetry = false; lastReorganizeEnd = null; versionAtReorganizeEnd = null
        lastKeystroke = null; lastCommit = null; undo = null; error = null
        editRun++; failEdit(NotesEditOutcome.Conflict); editUndo = null
        state = State.IDLE
        if (allowed !is Structuring.Off) structuring = Structuring.Idle
        changed()
    }

    private fun wipeAudio() { finishedAudio.values.forEach { it.fill(0) }; finishedAudio.clear() }

    fun dispose() { cancel(); scope.cancel() }

    // Segments

    /**
     * The rolling hand-off: capture swaps to the next socket at once (its audio held until Ready), then the old one
     * finalizes. The next socket cannot be Ready before that: the Mac transcribes one utterance at a time, and only
     * the old segment's final frees the engine for it.
     */
    private fun cut() {
        if (state != State.RECORDING || diverted != null) return
        val next = open()
        if (!startSegment(next)) {
            close(next, cancel = true)
            // The current socket keeps the audio meanwhile; a server that stays down ends the session.
            val myEpoch = epoch
            if (++failureStreak >= MAX_SEGMENT_FAILURES) finishRecording(RecordingFailure.Stopped(RecordingFailure.Connection(next.transport.failureKind)))
            else scope.launch { delay(RETRY_CUT_MS); if (epoch == myEpoch) cut() }
            return
        }
        // The sequence number is taken at the swap, so transcript order is capture order.
        val seq = nextSeq++
        val (old, offset) = router.swap(next)
        next.seq = seq; next.offset = offset
        val previous = current
        current = seq; segments[seq] = next
        if (previous != null) segments[previous]?.end = offset
        if (old != null && previous != null && segments[previous] === old) finalize(old)
        changed()
    }

    private fun finalize(segment: Segment) {
        val myEpoch = epoch
        segment.timeout = scope.launch {
            delay(FINAL_TIMEOUT_MS)
            if (epoch == myEpoch && segments[segment.seq] === segment) segmentFailed(segment, RecordingFailure.TimedOut)
        }
        // Not Ready yet: the Mac is still finishing the segment before it, and this one's audio waits in its buffer.
        if (!segment.ready) segment.stopOnReady = true
        else if (!segment.transport.stop()) segmentFailed(segment, RecordingFailure.ConnectionClosed)
    }

    private fun handle(segment: Segment, event: ServerEvent) {
        if (segment.seq >= 0 && segments[segment.seq] !== segment) return
        when (event) {
            is ServerEvent.Ready -> {
                segment.engine = event.engine; debugRetention = event.debugRetention; sawReady = true; segment.ready = true
                if (!segment.buffer.ready()) { lost(segment); return }
                if (segment.stopOnReady && !segment.transport.stop()) { segmentFailed(segment, RecordingFailure.ConnectionClosed); return }
                if (state == State.STARTING && segment.seq == current) { resuming = false; state = State.RECORDING }
                changed()
            }
            is ServerEvent.Partial -> if (segment.seq >= 0) { segment.partial = event.text; if (!quiet) updateLivePartial() }
            is ServerEvent.Correcting -> if (segment.seq >= 0) {
                segment.partial = event.raw; segment.correcting = true
                val operation = if (options.profile == "live_notes") "notes_correction" else "dictation"
                operationDeadlines?.advertisedTimeoutMs(operation)?.let { timeout ->
                    segment.timeout?.cancel()
                    val myEpoch = epoch
                    segment.timeout = scope.launch {
                        delay(timeout)
                        if (epoch == myEpoch && segments[segment.seq] === segment) segmentFailed(segment, RecordingFailure.TimedOut)
                    }
                }
                if (!quiet) updateLivePartial()
            }
            is ServerEvent.Final -> if (segment.seq >= 0) {
                val text = event.text.trim(); val raw = event.raw.trim()
                val kept = options.correction && !event.corrected && event.correctionError != null
                failureStreak = 0
                event.speakers?.let { labels[segment.seq] = it }
                finish(segment.seq, if (text.isEmpty()) null else NotesSegment(segment.seq, segment.offset, raw.ifEmpty { text }, text, event.corrected, kept, engine = event.engine ?: segment.engine))
            }
            is ServerEvent.Failure -> segmentFailed(segment, RecordingFailure.Server.of(event.code))
            ServerEvent.Unknown -> Unit
        }
    }

    /** A frame could not be sent (backpressure, a dead socket, Ready too late): the segment becomes a gap. */
    private fun lost(segment: Segment) {
        segmentFailed(segment, if (segment.ready) RecordingFailure.ConnectionLost else RecordingFailure.Connection(segment.transport.failureKind, timedOut = true))
    }

    private fun segmentFailed(segment: Segment, reason: RecordingFailure) {
        val seq = segment.seq
        if (segments[seq] !== segment) return
        problem = "segment: ${reason.english}"
        if (state == State.STARTING && resuming && seq == current) { abandonResume(seq, reason); return }
        if (state == State.STARTING && !sawReady && seq == current) {
            // The very first socket never got going: nothing is recording yet.
            drop(seq); stopCapture(); router.swap(null); current = null; results.clear(); labels.clear(); wipeAudio(); nextCommit = nextSeq
            error = reason; state = State.ERROR
            changed()
            return
        }
        failureStreak++
        finish(seq, NotesSegment.gap(seq, segment.offset, reason.english))
        if (state != State.RECORDING) return
        if (failureStreak >= MAX_SEGMENT_FAILURES) finishRecording(RecordingFailure.Stopped(reason))
        else if (seq == current) scope.launch { cut() } // The capturing socket died: roll to a fresh one.
    }

    private fun close(segment: Segment, cancel: Boolean) {
        segment.timeout?.cancel(); segment.buffer.cancel()
        segment.transport.close(cancel = cancel, immediate = cancel)
    }

    private fun drop(seq: Int) { segments.remove(seq)?.let { close(it, cancel = false) } }

    /** A segment is done: commit every finished segment that is next in order, then see whether a pass can run. */
    private fun finish(seq: Int, segment: NotesSegment?) {
        segments[seq]?.pcm?.let { stream -> finishedAudio[seq] = synchronized(stream) { stream.toByteArray() } }
        drop(seq)
        results[seq] = segment
        while (results.containsKey(nextCommit)) {
            val done = results.remove(nextCommit)?.let { labelled(it, labels[nextCommit]) }
            labels.remove(nextCommit)
            val pcm = finishedAudio.remove(nextCommit)
            if (done != null) {
                val index = document.segments.size
                document.append(done)
                if (pcm != null) audioSink?.invoke(document.id, index, done.offset, pcm)
            } else pcm?.fill(0)
            nextCommit++
            lastCommit = now()
        }
        updateLivePartial()
        schedule()
        changed()
    }

    /** The segment with its turns: the server's slots become the note's people, numbered in transcript order. */
    private fun labelled(segment: NotesSegment, result: SpeakersResult?): NotesSegment {
        result ?: return segment
        speakerError = result.error
        if (result.error != null || segment.isGap) return segment
        val turns = mutableListOf<SpeakerTurn>()
        for (t in result.turns) {
            val text = t.text.trim().takeIf { it.isNotEmpty() } ?: continue
            val person = document.roster.id(t.speaker, result.generation)
            val last = turns.lastOrNull()
            // Turns of one person in a row are one turn.
            if (last != null && last.person == person) turns[turns.size - 1] = last.copy(text = last.text + " " + text, raw = (last.raw + " " + t.raw.trim()).trim())
            else turns += SpeakerTurn(person, segment.offset + t.start, text, t.raw.trim(), t.approximate, t.keptOriginal)
        }
        if (recognizeVoices) for (match in result.matches) document.roster.recognize(match)
        return if (turns.isEmpty()) segment else segment.copy(turns = turns)
    }

    private fun updateLivePartial() {
        document.livePartial = segments.keys.sorted().mapNotNull { segments[it]?.partial?.takeIf(String::isNotEmpty) }.joinToString(" ")
        changed()
    }

    // Editing

    /** The editor changed the text. A claim of the tail drops a held append and may unblock the next pass. */
    fun userEdit(start: Int, end: Int, replacement: String) {
        val generation = document.windowGeneration
        document.userEdit(start, end, replacement)
        lastKeystroke = now()
        if (document.windowGeneration != generation) dropHeld()
        if (reorganizeState is Reorganizing.Applied || reorganizeState == Reorganizing.TooShort) reorganizeState = Reorganizing.Idle
        if (held != null) armHold()
        schedule()
        changed()
    }

    /** The caret is in the tail (with focus), or IME is composing: appends wait; leaving releases a held one. */
    fun editorFocus(inTail: Boolean, composing: Boolean) {
        editorInTail = inTail; editorComposing = composing
        if (held != null && !inTail && !composing) releaseHeld()
    }

    /** Organize: runs at the first moment the pass slot is free, whatever the thresholds say. */
    fun organize() {
        if (state == State.STOPPING || structuring is Structuring.Off || !reorganizeSupported) return
        manualReorganize = true
        schedule(); changed()
    }

    /** Restores the text from before the last applied reorganize or Organize, as the user's own edit. */
    /** A detached rebuild uses live recording’s bounded windows, reject splitting, outlines and fallback blocks. */
    suspend fun rebuildNotes(source: NotesDocument): String? {
        val windows = mutableListOf<String>()
        var window = ""
        for (segment in source.segments.filter { !it.isGap && it.text.isNotBlank() }) {
            val line = source.spoken(segment)
            if (window.isNotEmpty() && (window + "\n" + line).scalars > NotesDocument.MAX_WINDOW_CHARS) {
                windows += window; window = ""
            }
            window += (if (window.isEmpty()) "" else "\n") + line
        }
        if (window.isNotEmpty()) windows += window
        val pieces = mutableListOf<NotesPiece>()
        for ((index, transcript) in windows.withIndex()) {
            pieces += structurePieces(transcript, NotesDocument.capOutline(headings(pieces)), index == windows.lastIndex, 0, PieceOutcome())
        }
        return if (pieces.none { it is NotesPiece.Markdown }) null else NotesDocument.render(pieces)
    }

    fun applyRebuild(text: String) {
        val before = document.text
        val change = NotesDocument.diff(before, text, NotesChange.Kind.REBUILD) ?: return
        document.userEdit(change.start, change.end, change.replacement)
        pending += change; undo = before to document.version; undoKind = NotesChange.Kind.REBUILD; changed()
    }

    fun undoOrganize() {
        val (text, version) = undo ?: return
        if (version != document.version) return
        undo = null
        val change = NotesDocument.diff(document.text, text, NotesChange.Kind.USER) ?: return
        userEdit(change.start, change.end, change.replacement)
        pending += change
        reorganizeState = Reorganizing.Idle
        changed()
    }

    fun setAuto(on: Boolean) { autoReorganize = on; schedule(); changed() }

    private val holdsAppends get() = editorComposing || (editorInTail && typedRecently)
    private val typedRecently get() = lastKeystroke?.let { now() - it < HOLD_MAX_MS } == true

    private fun dropHeld() { held = null; holdJob?.cancel(); holdJob = null }

    private fun releaseHeld() {
        val (request, response) = held ?: return
        dropHeld(); applyAppend(request, response); schedule(); changed()
    }

    private fun armHold() {
        if (held == null) return
        holdJob?.cancel()
        val wait = if (typedRecently) HOLD_MAX_MS - (now() - (lastKeystroke ?: now())) else HOLD_MAX_MS
        val myEpoch = epoch
        holdJob = scope.launch {
            delay(wait)
            if (epoch != myEpoch || held == null) return@launch
            holdJob = null
            if (!holdsAppends) releaseHeld() else armHold()
        }
    }

    // Voice edit

    /**
     * Capture goes to a spoken command's socket ([transport] and its [buffer]) instead of the notes, from now until
     * [endDivert]: the segment before it finalizes as at a pause and nothing the command hears reaches the transcript.
     * False unless recording.
     */
    fun divert(transport: ImeTransport, buffer: PreReadyBuffer): Boolean {
        if (state != State.RECORDING || diverted != null) return false
        val command = Segment(transport, buffer).also { diverted = it }
        val (old, end) = router.swap(command)
        current?.let { seq -> segments[seq]?.let { it.end = end; if (it === old) finalize(it) } }
        current = null
        changed()
        return true
    }

    /** Back to the notes after a command: capture swaps to a fresh notes socket at once (held until Ready), so nothing is dropped. */
    fun endDivert() {
        if (diverted == null) return
        diverted = null
        cut()
    }

    private class PendingEdit(val instruction: String, val selection: Pair<Int, Int>?, val done: (NotesEditOutcome) -> Unit) { var attempts = 0 }

    /**
     * Applies [instruction] to the selected lines (`[start, end)`), the whole notes or the trailing sections of long ones.
     * It runs in the pass slot ahead of any other pass, and its answer applies only to the text it was made from, as one
     * change. One at a time: another request meanwhile gets `busy`.
     */
    fun edit(instruction: String, selection: Pair<Int, Int>?, done: (NotesEditOutcome) -> Unit) {
        if (!editSupported) { done(NotesEditOutcome.Failed("unsupported")); return }
        if (pendingEdit != null) { done(NotesEditOutcome.Failed("busy")); return }
        pendingEdit = PendingEdit(instruction, selection, done)
        schedule(); changed()
    }

    private fun failEdit(outcome: NotesEditOutcome) { pendingEdit?.let { pendingEdit = null; it.done(outcome) } }

    private fun runEdit() {
        val e = pendingEdit ?: return
        val range = when (val scope = document.editScope(e.selection)) {
            is NotesEditScope.Range -> scope
            is NotesEditScope.None -> { failEdit(NotesEditOutcome.Skipped(scope.why)); changed(); return }
        }
        val request = document.editRequest(e.instruction, range.start, range.end)
        val run = ++editRun
        val myEpoch = epoch
        pass(PassKind.EDIT) {
            val response = try { editNotes(request) } catch (c: CancellationException) { throw c } catch (x: Exception) { NotesEditResponse.failed(HttpNotesApi.code(x)) }
            if (epoch == myEpoch && editRun == run) editFinished(request, response)
        }
        changed()
    }

    private fun editFinished(request: NotesEditRequest, response: NotesEditResponse) {
        endPass()
        val e = pendingEdit
        // A segment clean-up took the model: the edit stays first in line and runs again when the slot is free.
        if (e != null && response.preempted && ++e.attempts < EDIT_ATTEMPTS) { schedule(); changed(); return }
        if (response.error == "unsupported") { editSupported = false; editMissing = true }
        val refusal = response.refusal
        val outcome = when {
            refusal != null -> NotesEditOutcome.Refused(refusal)
            !response.edited -> NotesEditOutcome.Failed(if (response.preempted) "busy" else response.failureLabel)
            !response.changed -> NotesEditOutcome.Unchanged
            !document.canApplyEdit(request) || editorComposing -> NotesEditOutcome.Conflict
            else -> {
                val before = document.text
                val change = document.applyEdit(response, request)
                if (change == null) NotesEditOutcome.Unchanged else {
                    dropHeld(); publish(change)
                    editUndo = before to document.version
                    if (reorganizeState is Reorganizing.Applied) reorganizeState = Reorganizing.Idle
                    NotesEditOutcome.Applied
                }
            }
        }
        failEdit(outcome)
        schedule(); changed()
    }

    /** Restores the text from before the last voice edit, as the user's own edit, while nothing else changed it since. */
    fun undoEdit() {
        val (text, version) = editUndo ?: return
        if (version != document.version) return
        editUndo = null
        val change = NotesDocument.diff(document.text, text, NotesChange.Kind.USER) ?: return
        userEdit(change.start, change.end, change.replacement)
        pending += change
        changed()
    }

    // Passes

    /**
     * The single pass slot, shared by append and reorganize. Nothing runs while a pass is in flight or a segment is
     * still finalizing. Then: an append when due, else Organize, else an automatic reorganize once enough was added,
     * enough time passed and the user stopped typing.
     */
    private fun schedule() {
        if (pendingEdit != null) {
            // A voice edit goes first, once the segment before its command is in (its clean-up would preempt it).
            if (passJob != null || finalizingCount > 0) waiting = true else { waiting = false; runEdit() }
            return
        }
        if (structuring is Structuring.Off) return
        if (passJob != null || finalizingCount > 0) { waiting = true; return }
        waiting = false
        var appendWaiting = false
        if (state.live) {
            publish(document.freezeOverflow())
            val next = document.nextStructureRequest()
            if (next != null && next.windowEnd > (held?.first?.windowEnd ?: -1)) {
                val last = lastPassEnd
                if (last != null && now() - last < MIN_INTERVAL_MS) {
                    appendWaiting = true; waiting = true
                    armTimer(MIN_INTERVAL_MS - (now() - last))
                } else { run(next); return }
            }
        }
        if (manualReorganize && state != State.STOPPING) { manualReorganize = false; runOrganize(); return }
        // Auto, while recording: only in the quiet stretch right after a segment commit, on the trailing sections.
        val t = now()
        val commit = lastCommit ?: return
        if (appendWaiting || !autoReorganize || !reorganizeSupported || state != State.RECORDING || held != null ||
            t - commit > REORGANIZE_AFTER_COMMIT_MS || document.charsSinceReorganize < REORGANIZE_EVERY_CHARS ||
            lastReorganizeEnd?.let { t - it < if (reorganizeRetry) REORGANIZE_RETRY_MS else REORGANIZE_MIN_INTERVAL_MS } == true ||
            lastKeystroke?.let { t - it < TYPING_IDLE_MS } == true) return
        val request = document.reorganizeRequest(final = false, manual = false, maxChars = NotesDocument.RECORDING_REORGANIZE_CHARS) ?: return
        runReorganize(request, manual = false)
    }

    private fun armTimer(after: Long) {
        val deadline = now() + after
        if (timer != null && (timerDeadline ?: Long.MAX_VALUE) <= deadline) return
        timer?.cancel(); timerDeadline = deadline
        val myEpoch = epoch
        timer = scope.launch {
            delay(after)
            if (epoch != myEpoch) return@launch
            timer = null; timerDeadline = null
            if (waiting) { schedule(); changed() }
        }
    }

    /** Starts [body] in the pass slot; the slot is taken before the body can run (and free itself). */
    private fun pass(kind: PassKind, body: suspend () -> Unit) {
        passKind = kind; passes++
        val job = scope.launch(start = CoroutineStart.LAZY) { body() }
        passJob = job
        job.start()
    }

    private fun endPass() { passJob = null; passKind = null }

    private fun run(request: NotesStructureRequest) {
        structuring = Structuring.Running
        changed()
        val myEpoch = epoch
        pass(PassKind.APPEND) {
            val (response, disable) = callStructure(request)
            if (epoch != myEpoch) return@pass
            // A rejected window is retried in halves (then quarters) before any of it falls back to raw text.
            val halves = if (disable == null && response.error == "rejected") NotesDocument.split(request.transcript) else null
            if (halves != null) {
                val outcome = PieceOutcome()
                val first = structurePieces(halves.first, request.outline, request.final, 1, outcome)
                val second = structurePieces(halves.second, request.outline + headings(first), request.final, 1, outcome)
                if (epoch != myEpoch) return@pass
                splitFinished(request, first + second, outcome)
            } else passFinished(request, response, disable)
        }
    }

    private suspend fun callStructure(request: NotesStructureRequest): Pair<NotesStructureResponse, StructuringOff?> = try {
        structure(request) to null
    } catch (e: CancellationException) { throw e } catch (e: Exception) {
        val disable = (e as? NotesHttpError)?.let { if (it.off) StructuringOff.CORRECTION_OFF else if (it.unsupported) StructuringOff.UNSUPPORTED else null }
        NotesStructureResponse.failed(HttpNotesApi.code(e)) to disable
    }

    private suspend fun callReorganize(request: NotesReorganizeRequest): Pair<NotesReorganizeResponse, NotesHttpError?> = try {
        reorganize(request) to null
    } catch (e: CancellationException) { throw e } catch (e: Exception) {
        NotesReorganizeResponse.failed(HttpNotesApi.code(e)) to e as? NotesHttpError
    }

    private class PieceOutcome {
        var depth = 0
        val failures = mutableListOf<String>()
        /** A part failed for a reason splitting cannot help (timeout, busy, http): the whole text keeps the retry. */
        var transient: String? = null
        var disable: StructuringOff? = null
        val usable get() = transient == null && disable == null
    }

    /** Structures [text] as one or more parts, splitting a rejected part (halves, then quarters, never under 400). */
    private suspend fun structurePieces(text: String, outline: List<String>, final: Boolean, depth: Int, outcome: PieceOutcome): List<NotesPiece> {
        if (!outcome.usable) return listOf(NotesPiece.Fallback(text))
        if (text.scalars > NotesDocument.MAX_WINDOW_CHARS) NotesDocument.split(text)?.let { (a, b) ->
            val first = structurePieces(a, outline, final, depth, outcome)
            return first + structurePieces(b, outline + headings(first), final, depth, outcome)
        }
        val (response, disable) = callStructure(NotesStructureRequest(text, NotesDocument.capOutline(outline), final))
        if (disable != null) { outcome.disable = disable; return listOf(NotesPiece.Fallback(text)) }
        val md = response.markdown?.trim()
        if (response.structured && !md.isNullOrEmpty()) { outcome.depth = maxOf(outcome.depth, depth); return listOf(NotesPiece.Markdown(md)) }
        if (response.error != "rejected") { outcome.transient = response.failureLabel; return listOf(NotesPiece.Fallback(text)) }
        if (depth < MAX_SPLIT_DEPTH) NotesDocument.split(text)?.let { (a, b) ->
            val first = structurePieces(a, outline, final, depth + 1, outcome)
            return first + structurePieces(b, outline + headings(first), final, depth + 1, outcome)
        }
        outcome.depth = maxOf(outcome.depth, depth)
        outcome.failures += response.failureLabel
        return listOf(NotesPiece.Fallback(text))
    }

    private fun headings(pieces: List<NotesPiece>) = pieces.filterIsInstance<NotesPiece.Markdown>().flatMap { NotesMarkdown.headings(it.text) }

    private fun splitFinished(request: NotesStructureRequest, pieces: List<NotesPiece>, outcome: PieceOutcome) {
        outcome.transient?.let { passFinished(request, NotesStructureResponse.failed(it), null); return }
        endPass(); lastPassEnd = now()
        val disable = outcome.disable
        failedPass("structure", disable, outcome.failures.firstOrNull())
        if (disable != null) { allowed = Structuring.Off(disable); structuring = allowed } else {
            dropHeld()
            publish(document.applyPieces(pieces, request))
            if (structuring !is Structuring.Off) structuring = outcome.failures.firstOrNull()?.let { Structuring.Failed(it) } ?: Structuring.Idle
        }
        if (waiting || state.live) schedule()
        changed()
    }

    private fun passFinished(request: NotesStructureRequest, response: NotesStructureResponse, disable: StructuringOff?) {
        endPass(); lastPassEnd = now()
        failedPass("structure", disable, response.takeUnless { it.structured }?.failureLabel)
        if (disable != null) { allowed = Structuring.Off(disable); structuring = allowed }
        else if (response.structured && holdsAppends && state != State.STOPPING) {
            // The caret is in the tail: keep the newest answer until it leaves (or the user goes quiet).
            held = request to response; armHold(); structuring = Structuring.Idle
        } else {
            if (response.structured) dropHeld()
            applyAppend(request, response)
        }
        if (waiting || state.live) schedule()
        changed()
    }

    private fun failedPass(kind: String, disable: StructuringOff?, label: String?) {
        val code = when (disable) { StructuringOff.UNSUPPORTED -> "unsupported"; StructuringOff.CORRECTION_OFF -> "notes_off"; else -> label }
        if (code != null) problem = "$kind: $code"
    }

    private fun applyAppend(request: NotesStructureRequest, response: NotesStructureResponse) {
        publish(document.apply(response, request))
        if (structuring !is Structuring.Off) structuring = if (response.structured) Structuring.Idle else Structuring.Failed(response.failureLabel)
    }

    private fun runReorganize(request: NotesReorganizeRequest, manual: Boolean) {
        reorganizeState = Reorganizing.Running
        organizeBase = document.text
        changed()
        val myEpoch = epoch
        pass(PassKind.REORGANIZE) {
            val (response, failure) = callReorganize(request)
            if (epoch != myEpoch) return@pass
            endPass()
            if (applyReorganizeResult(request, response, manual, failure)) {
                // Not run: a segment clean-up took the model. No note and no backoff; the next commit tries again.
                lastCommit = null
                if (manual) manualReorganize = true
            }
            schedule(); changed()
        }
    }

    /**
     * Organize (the button): structure what automatic passes left raw — the pending window and every fallback block the
     * user has not edited, each replaced in place — then reorganize. Without anything raw it is a plain reorganize.
     */
    private fun runOrganize() {
        publish(document.freezeOverflow())
        val window = if (state != State.STOPPING) document.nextStructureRequest() else null
        val blocks = document.untouchedFallbacks
        if (window == null && blocks.isEmpty()) {
            val request = document.reorganizeRequest(final = false, manual = true)
            if (request != null) runReorganize(request, manual = true)
            else { reorganizeState = if (document.reorganizeTooLong) Reorganizing.TooLong else Reorganizing.TooShort; changed() }
            return
        }
        val total = (if (window == null) 0 else 1) + blocks.size + 1
        reorganizeState = Reorganizing.Organizing(1, total)
        organizeBase = document.text
        changed()
        val myEpoch = epoch
        pass(PassKind.REORGANIZE) {
            val failures = mutableListOf<String>()
            var step = 1
            fun advance() { step++; reorganizeState = Reorganizing.Organizing(minOf(step, total), total); changed() }
            fun failed(outcome: PieceOutcome) { failures += outcome.transient ?: outcome.failures.firstOrNull() ?: "rejected" }
            fun structured(pieces: List<NotesPiece>) = pieces.any { it is NotesPiece.Markdown }
            if (window != null) {
                val outcome = PieceOutcome()
                val pieces = structurePieces(window.transcript, window.outline, false, 0, outcome)
                if (epoch != myEpoch) return@pass
                if (outcome.usable && structured(pieces)) {
                    dropHeld(); publish(document.applyPieces(pieces, window)); failures += outcome.failures
                } else failed(outcome)
                advance()
            }
            val version = document.version
            val replacements = mutableListOf<Pair<String, List<NotesPiece>>>()
            for ((block, body) in blocks) {
                val outcome = PieceOutcome()
                val pieces = structurePieces(body, document.outline, false, 0, outcome)
                if (epoch != myEpoch) return@pass
                if (outcome.usable && structured(pieces)) { replacements += block to pieces; failures += outcome.failures } else failed(outcome)
                advance()
            }
            var conflict = false
            if (replacements.isNotEmpty()) {
                // Version-checked as one batch: an edit (or a composition) while it ran discards all of it.
                val changes = if (editorComposing) emptyList() else document.replaceFallbacks(replacements, version)
                if (changes.isEmpty()) conflict = true else changes.forEach(::publish)
            }
            if (!conflict && reorganizeSupported) document.reorganizeRequest(final = false, manual = true)?.let { request ->
                val (response, failure) = callReorganize(request)
                if (epoch != myEpoch) return@pass
                applyReorganizeResult(request, response, true, failure)
                when (val r = reorganizeState) { is Reorganizing.Failed -> failures += r.label; Reorganizing.Conflict -> conflict = true; else -> Unit }
            }
            endPass()
            val base = organizeBase
            if (base != null && base != document.text) { undo = base to document.version; undoKind = NotesChange.Kind.ORGANIZE }
            reorganizeState = when {
                conflict -> Reorganizing.Conflict
                reorganizeState is Reorganizing.Applied && failures.isEmpty() -> reorganizeState
                else -> Reorganizing.Organized(failures.size, failures.firstOrNull())
            }
            schedule(); changed()
        }
    }

    /** Records a reorganize answer and applies it when the text is still what it was made from. True when preempted. */
    private fun applyReorganizeResult(request: NotesReorganizeRequest, response: NotesReorganizeResponse, manual: Boolean, failure: NotesHttpError?): Boolean {
        if (response.preempted && failure == null) { reorganizeState = Reorganizing.Idle; return true }
        lastReorganizeEnd = now(); versionAtReorganizeEnd = document.version; reorganizeRetry = true
        if (failure != null || !response.reorganized) problem = "reorganize: " + (failure?.code ?: response.failureLabel)
        when {
            failure?.unsupported == true -> { reorganizeMissing = true; reorganizeSupported = false; reorganizeState = Reorganizing.Idle }
            failure?.off == true -> { allowed = Structuring.Off(StructuringOff.CORRECTION_OFF); structuring = allowed; reorganizeState = Reorganizing.Idle }
            request.version != document.version || request.documentId != document.id || editorComposing ->
                reorganizeState = if (manual) Reorganizing.Conflict else Reorganizing.Idle
            !response.reorganized -> reorganizeState = Reorganizing.Failed(response.failureLabel)
            else -> {
                reorganizeRetry = false
                val base = document.text
                val change = document.applyReorganize(response, request)
                if (change != null) {
                    dropHeld(); publish(change)
                    undo = (organizeBase ?: base) to document.version; undoKind = NotesChange.Kind.ORGANIZE
                    reorganizeState = Reorganizing.Applied(now())
                } else reorganizeState = Reorganizing.Idle
            }
        }
        return false
    }

    // Stopping

    private fun finishRecording(problem: RecordingFailure?) {
        if (!state.live) return
        val myEpoch = epoch
        stoppingSince = now()
        state = State.STOPPING
        timer?.cancel(); timer = null; waiting = false; manualReorganize = false
        releaseMicrophone()
        scope.launch {
            waitUntil { segments.isEmpty() && passJob == null }
            if (epoch != myEpoch) return@launch
            held?.let { (request, response) -> dropHeld(); applyAppend(request, response) }
            publish(document.freezeOverflow())
            if (structuring !is Structuring.Off) document.nextStructureRequest(final = true)?.let {
                run(it)
                waitUntil { passJob == null }
                if (epoch != myEpoch) return@launch
            }
            publish(document.freezeAll(structuring !is Structuring.Off))
            document.livePartial = ""
            // One final reorganize, unless one just ran on this very text.
            val justTried = versionAtReorganizeEnd == document.version && lastReorganizeEnd?.let { now() - it < STOP_REORGANIZE_SKIP_MS } == true
            if (structuring !is Structuring.Off && autoReorganize && reorganizeSupported && !justTried && document.version != document.lastReorganizeVersion) {
                document.reorganizeRequest(final = true, manual = false)?.let {
                    runReorganize(it, manual = false)
                    waitUntil { passJob == null }
                    if (epoch != myEpoch) return@launch
                }
            }
            stoppingSince = null
            error = problem
            if (problem != null) this@NotesRecorder.problem = problem.english
            state = if (problem != null) State.ERROR else State.STOPPED
            changed()
        }
    }

    private suspend fun waitUntil(condition: () -> Boolean) {
        if (condition()) return
        val done = CompletableDeferred<Unit>()
        waiters += condition to done
        done.await()
    }

    private fun changed() {
        if (waiters.isNotEmpty()) waiters.filter { it.first() }.forEach { waiters.remove(it); it.second.complete(Unit) }
        onChange?.invoke()
    }

    companion object {
        private val random = java.security.SecureRandom()
        /** 32 hex characters: what `start.speakers.session` accepts. */
        fun newSpeakerSession(): String = ByteArray(16).also(random::nextBytes).joinToString("") { "%02x".format(it) }
        /** A pass starts at most this often (from the end of the last one). */
        const val MIN_INTERVAL_MS = 15000L
        /** How long a segment may take from `stop` to its final. */
        const val FINAL_TIMEOUT_MS = 25000L
        /**
         * Audio a segment holds until its socket is Ready: the Mac queues a start for up to 10 s while the previous
         * segment finishes, then answers `busy`.
         */
        const val PRE_READY_BYTES = 16000 * 2 * 12
        /** A Notes socket's send queue holds a whole pre-ready buffer flushed at Ready, plus 5 s of live audio. */
        const val MAX_QUEUED_BYTES = PRE_READY_BYTES + 160000L
        const val RETRY_CUT_MS = 2000L
        /** Segments (or next sockets) in a row that may fail before recording stops. */
        const val MAX_SEGMENT_FAILURES = 3
        const val REORGANIZE_EVERY_CHARS = 1200
        const val REORGANIZE_MIN_INTERVAL_MS = 180000L
        const val TYPING_IDLE_MS = 15000L
        const val MAX_SPLIT_DEPTH = 2
        const val REORGANIZE_RETRY_MS = 60000L
        /** A held append is applied after this long without a keystroke, even with the caret in the tail. */
        const val HOLD_MAX_MS = 10000L
        const val REORGANIZE_AFTER_COMMIT_MS = 5000L
        const val STOP_REORGANIZE_SKIP_MS = 30000L
        /** The edit attempts a segment clean-up may preempt before it gives up. */
        const val EDIT_ATTEMPTS = 3
    }
}
