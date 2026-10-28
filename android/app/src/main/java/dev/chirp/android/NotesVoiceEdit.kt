package dev.chirp.android

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Where a voice edit is. */
internal sealed interface VoiceEditStatus {
    data object Idle : VoiceEditStatus
    /** Capturing the instruction; [heard] is the live partial. */
    data class Listening(val heard: String = "") : VoiceEditStatus
    /** The command ended and the edit runs ([instruction] is empty until its final is in). */
    data class Editing(val instruction: String = "") : VoiceEditStatus
    /** The last edit ended (the chip and the note time out from here). */
    data class Done(val outcome: NotesEditOutcome) : VoiceEditStatus

    val isListening get() = this is Listening
    val isBusy get() = this is Listening || this is Editing
}

/**
 * Live Notes' command mode, port of the Mac's Edit by Voice: the Command button (hold it, or tap to start and tap again
 * to finish) or the notification's Command action starts it. What is said meanwhile goes to its own `/v1/stream`
 * socket, never the transcript: while recording the recorder diverts capture to it from the first instant (the audio
 * waits for the socket's Ready) and back to a fresh notes socket after; otherwise the command opens the microphone
 * itself. The final is the instruction, sent to `/v1/notes/edit` through the recorder's pass slot and applied only to
 * unchanged notes. The command uses raw speech (no clean-up) so the model stays free for the edit. Main thread only;
 * nothing here is logged.
 */
internal class NotesVoiceEdit(
    private val recorder: NotesRecorder,
    private val transportFactory: ((ServerEvent) -> Unit, () -> Unit) -> ImeTransport,
    /** Opens the microphone for a command while Notes is not capturing: frames go to the sink; null when it cannot. */
    private val microphone: (sink: (ByteArray) -> Boolean, ended: (DictationStatus?) -> Unit) -> Capture?,
    /** The editor's selection `[start, end)` when the command ends (null or empty: the whole notes). */
    private val selection: () -> Pair<Int, Int>? = { null },
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
) {
    var status: VoiceEditStatus = VoiceEditStatus.Idle
        private set(value) { if (field != value) { field = value; onChange?.invoke() } }
    var onChange: (() -> Unit)? = null

    private var run = 0
    private var wire: ImeTransport? = null
    private var buffer: PreReadyBuffer? = null
    private var capture: Capture? = null
    private var diverted = false
    private var ready = false
    private var stopRequested = false
    private var stopSent = false
    private var final: String? = null
    /** The command socket failed or closed before its final. */
    private var dropped = false
    private var gate: CompletableDeferred<Unit>? = null
    private var listenJob: Job? = null

    /** The command holds the microphone (Notes is not recording), so Record and Resume wait for it. */
    val holdsMicrophone get() = capture != null

    /** The server edits and nothing else is in the way. */
    val canStart get() = recorder.canEdit && !status.isBusy && recorder.state != NotesRecorder.State.STOPPING && recorder.state != NotesRecorder.State.STARTING

    /** The notification action and the accessibility click: start a command, or end the one listening. */
    fun toggle() { if (status.isListening) finish() else start() }

    fun start() {
        if (!canStart) return
        val mine = ++run
        final = null; dropped = false; ready = false; stopRequested = false; stopSent = false
        lateinit var socket: ImeTransport
        // Like a notes segment, it is Ready only once the Mac has finished the segment before it.
        val audio = PreReadyBuffer(send = { socket.audio(it) }, maxBytes = NotesRecorder.PRE_READY_BYTES)
        socket = try { transportFactory({ handle(mine, it) }, { ended(mine, null) }) } catch (_: RuntimeException) {
            status = VoiceEditStatus.Done(NotesEditOutcome.Failed("connection")); return
        }
        wire = socket; buffer = audio
        status = VoiceEditStatus.Listening()
        // From this instant the command's audio goes to its own socket (held until Ready) and never into the notes.
        val capturing = when {
            recorder.divert(socket, audio) -> { diverted = true; true }
            recorder.state != NotesRecorder.State.RECORDING -> openMicrophone(audio, mine)
            else -> false
        }
        if (!capturing) { abandon(NotesEditOutcome.Failed("busy")); return }
        if (!socket.start(false, "default", "", null)) { abandon(NotesEditOutcome.Failed("connection")); return }
        listenJob = scope.launch { delay(MAX_LISTEN_MS); if (run == mine && status.isListening) finish() }
    }

    private fun openMicrophone(audio: PreReadyBuffer, mine: Int): Boolean {
        lateinit var made: Capture
        made = microphone({ audio.offer(it) }, { scope.launch { if (run == mine && capture === made && status.isListening) abandon(NotesEditOutcome.Failed("microphone")) } })
            ?: return false
        capture = made
        return true
    }

    /** End listening: capture goes back to the notes (or the microphone closes), the final arrives, the edit runs. */
    fun finish() { if (status.isListening) scope.launch { finishNow() } }

    private suspend fun finishNow() {
        val mine = run
        val socket = wire ?: return
        if (!status.isListening) return
        listenJob?.cancel()
        status = VoiceEditStatus.Editing()
        release()
        if (run != mine) return
        stopRequested = true
        sendStop()
        if (final == null && !dropped) {
            val wait = CompletableDeferred<Unit>().also { gate = it }
            val timeout = scope.launch { delay(FINAL_TIMEOUT_MS); wait.complete(Unit) }
            wait.await()
            timeout.cancel(); gate = null
        }
        if (run != mine) return
        val heard = final
        wire = null; buffer?.cancel(); buffer = null
        socket.close(cancel = false, immediate = true)
        val instruction = heard?.trim().orEmpty()
        if (instruction.isEmpty()) {
            status = VoiceEditStatus.Done(if (heard == null) NotesEditOutcome.Failed(if (dropped) "connection" else "timeout") else NotesEditOutcome.Skipped("not_heard"))
            return
        }
        status = VoiceEditStatus.Editing(instruction)
        recorder.edit(instruction, selection()) { outcome -> if (run == mine) status = VoiceEditStatus.Done(outcome) }
    }

    /** The command is dropped (its words go nowhere) and capture goes back to the notes. */
    fun cancel() { if (status.isListening) abandon(null) }

    /** The chip or note went away. */
    fun dismiss() { if (status is VoiceEditStatus.Done) status = VoiceEditStatus.Idle }

    private fun abandon(outcome: NotesEditOutcome?) {
        run++
        listenJob?.cancel(); gate?.complete(Unit)
        val socket = wire; wire = null
        buffer?.cancel(); buffer = null
        status = outcome?.let { VoiceEditStatus.Done(it) } ?: VoiceEditStatus.Idle
        socket?.close(cancel = true, immediate = true)
        scope.launch { release() }
    }

    private suspend fun release() {
        if (diverted) { diverted = false; recorder.endDivert() }
        capture?.let { capture = null; it.stop() }
    }

    private fun sendStop() {
        val socket = wire ?: return
        if (!ready || stopSent) return
        stopSent = true
        if (!socket.stop()) ended(run, null)
    }

    private fun handle(mine: Int, event: ServerEvent) {
        if (run != mine) return
        when (event) {
            is ServerEvent.Ready -> {
                if (buffer?.ready() != true) { ended(mine, null); return }
                ready = true
                if (stopRequested) sendStop()
            }
            is ServerEvent.Partial -> if (status.isListening) status = VoiceEditStatus.Listening(event.text)
            is ServerEvent.Final -> ended(mine, event.text)
            is ServerEvent.Failure -> ended(mine, null)
            else -> Unit
        }
    }

    /** The command socket is done: with its final's text, or null when it failed or closed first. */
    private fun ended(mine: Int, text: String?) {
        if (run != mine || final != null || dropped) return
        if (text != null) final = text else dropped = true
        val waiting = gate
        // It ended while still listening (a drop, the server's cap): end the command with what it has.
        if (waiting != null) waiting.complete(Unit) else if (status.isListening) finish()
    }

    companion object {
        /** A command ends by itself after this long. */
        const val MAX_LISTEN_MS = 20000L
        /** How long the instruction's final may take after the end. */
        const val FINAL_TIMEOUT_MS = 10000L
        /** A press shorter than this latches the command (tap to start, tap again to finish); a longer hold ends it on release. */
        const val HOLD_MS = 450L
        /** The note and the chip stay this long. */
        const val NOTE_MS = 12000L
        const val CHIP_MS = 20000L
    }
}

/** The words of a voice edit in the Notes screen. */
internal object NotesVoiceEditText {
    /** The note under the editor for an edit that did not apply; null for one that did. */
    fun note(outcome: NotesEditOutcome): UiText? = when (outcome) {
        NotesEditOutcome.Applied -> null
        NotesEditOutcome.Unchanged -> UiText.Res(R.string.notes_status_edit_unchanged)
        is NotesEditOutcome.Refused -> UiText.Res(when (outcome.reason) {
            "adds_content" -> R.string.notes_status_edit_adds_content
            "not_an_edit" -> R.string.notes_status_edit_not_an_edit
            else -> R.string.notes_status_edit_unclear
        })
        NotesEditOutcome.Conflict -> UiText.Res(R.string.notes_status_edit_conflict)
        is NotesEditOutcome.Skipped -> UiText.Res(when (outcome.why) {
            "not_heard" -> R.string.notes_status_edit_not_heard
            "too_long" -> R.string.notes_status_edit_too_long
            else -> R.string.notes_status_edit_nothing
        })
        is NotesEditOutcome.Failed -> UiText.Res(R.string.notes_status_edit_failed, UiText.Raw(outcome.code))
    }

    fun status(status: VoiceEditStatus): UiText? = when (status) {
        is VoiceEditStatus.Listening -> status.heard.ifEmpty { null }?.let { UiText.Res(R.string.notes_status_heard, UiText.Raw(it)) } ?: UiText.Res(R.string.notes_status_say_edit)
        is VoiceEditStatus.Editing -> UiText.Res(R.string.notes_status_editing)
        else -> null
    }
}
