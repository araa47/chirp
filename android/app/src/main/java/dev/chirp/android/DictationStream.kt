package dev.chirp.android

import android.os.Handler
import android.os.Looper

/** One utterance, no idle connection. Capture completion precedes STOP, including pre-ready stops. */
internal class DictationStream(
    private val transportFactory: ((ServerEvent) -> Unit, () -> Unit) -> ImeTransport,
    private val captureFactory: ((ByteArray) -> Boolean, (Double) -> Unit, (DictationStatus?) -> Unit) -> Capture,
    private val changed: (DictationStatus, ServerEvent.Partial?) -> Unit,
    private val level: (Double) -> Unit,
    private val retention: (Boolean) -> Unit,
    private val final: (ServerEvent.Final) -> Unit,
    private val ended: () -> Unit,
    private val handler: Handler = Handler(Looper.getMainLooper()),
    private val correcting: (ServerEvent.Correcting) -> Unit = {},
    /** A failure after partials hands over what was heard (text, reason) instead of discarding it. */
    private val kept: ((String, DictationStatus) -> Unit)? = null,
    private val pauseSeconds: Double? = null,
    private val countdown: (Int) -> Unit = {},
    private val deadlines: OperationDeadlines = OperationDeadlines(),
    private val timing: SessionTimer? = null,
) {
    private var transport: ImeTransport? = null
    private var capture: Capture? = null
    private var buffer: PreReadyBuffer? = null
    private var live = false
    private var ready = false
    private var released = false
    private var stopSent = false
    private var sequence = -1L
    private var raw: String? = null
    private var heard: String? = null
    private var polishingAt = 0L
    private var pendingFinal: Runnable? = null
    var polishing = false
        private set
    var stopping = false
        private set
    private fun unreachable(timedOut: Boolean = false) = ConnectionFailure.status(transport?.failureKind, timedOut)
    private val timeout = Runnable { fail(if (stopSent) StatusLine.SERVER_SLOW else unreachable(true)) }

    fun start(correction: Boolean, profile: String = "default", instructions: String = "", prompt: String? = null, learned: LearnedPayload? = null) {
        check(!live && transport == null)
        live = true
        changed(StatusLine.CONNECTING, null)
        val pending = PreReadyBuffer(send = { transport?.audio(it) == true })
        buffer = pending
        transport = transportFactory({ if (live) event(it) }, { if (live) fail(unreachable()) })
        transport?.learned(learned)
        capture = captureFactory(pending::offer, { value -> handler.post { if (live && !stopping) level(value) } }, { error ->
            handler.post {
                if (live) {
                    capture = null; released = true
                    // A full pre-Ready buffer reports the generic message; before Ready that is a connect timeout.
                    if (error != null) fail(if (error == ConnectionFailure.Kind.OTHER) unreachable(true) else error) else {
                        stopping = true; timing?.stopped(); changed(StatusLine.FINISHING, null); sendStop()
                    }
                }
            }
        })
        deadline(PRE_READY_MS)
        capture?.let { it.pauseSeconds = pauseSeconds; it.countdown = { left -> handler.post { if (live && !stopping) countdown(left) } } }
        capture?.start()
        if (transport?.start(correction, profile, instructions, prompt) != true) fail(unreachable())
    }
    fun stop() {
        if (!live || stopping) return
        stopping = true; timing?.stopped()
        changed(StatusLine.FINISHING, null)
        capture?.stop()
    }
    private fun sendStop() {
        if (!live || !ready || !released || stopSent) return
        if (transport?.stop() != true) { fail(unreachable()); return }
        stopSent = true; deadline(60000)
    }
    private fun event(event: ServerEvent) {
        when (event) {
            is ServerEvent.Ready -> {
                if (ready) { fail(StatusLine.UNEXPECTED); return }
                ready = true; timing?.ready(); retention(event.debugRetention)
                if (buffer?.ready() != true) { fail(StatusLine.CONNECTION_SLOW); return }
                handler.removeCallbacks(timeout)
                if (!stopping) changed(StatusLine.LISTENING, null)
                if (released) sendStop() else deadline(125000)
            }
            is ServerEvent.Partial -> if (ready && !polishing && event.seq > sequence) {
                sequence = event.seq; heard = event.text; timing?.partial(); changed(if (stopping) StatusLine.FINISHING else StatusLine.LISTENING, event)
            }
            is ServerEvent.Correcting -> if (stopSent && !polishing && event.seq > sequence && event.raw.isNotEmpty()) {
                sequence = event.seq; raw = event.raw; polishing = true; polishingAt = android.os.SystemClock.uptimeMillis(); timing?.polishing()
                correcting(event); changed(StatusLine.POLISHING, null); deadline(deadlines.timeoutMs("dictation", 12000))
            }
            is ServerEvent.Final -> {
                if (!stopSent) { fail(StatusLine.UNEXPECTED); return }
                if (pendingFinal != null) return
                handler.removeCallbacks(timeout); timing?.final(event.text.isBlank())
                val finish = Runnable {
                    if (live) {
                        close(false)
                        try {
                            if (event.text.isBlank()) changed(StatusLine.NO_SPEECH, null) else final(event)
                        } finally { ended() }
                    }
                }
                val remaining = if (polishing) (450 - (android.os.SystemClock.uptimeMillis() - polishingAt)).coerceAtLeast(0) else 0
                if (remaining > 0) { pendingFinal = finish; handler.postDelayed(finish, remaining) } else finish.run()
            }
            is ServerEvent.Failure -> { timing?.code(event.code); fail(when (event.code) {
                "auth" -> StatusLine.PAIRING_REFUSED
                "bad_audio" -> StatusLine.NO_SPEECH
                "engine" -> StatusLine.ENGINE_HICCUP
                "busy" -> StatusLine.BUSY
                "too_long" -> StatusLine.TOO_LONG
                "bad_request" -> StatusLine.PROMPT_TOO_LONG
                else -> StatusLine.ENGINE_UNAVAILABLE
            }) }
            ServerEvent.Unknown -> Unit
        }
    }
    private fun deadline(ms: Long) { handler.removeCallbacks(timeout); handler.postDelayed(timeout, ms) }
    fun fail(message: DictationStatus) {
        if (!live || pendingFinal != null) return
        val original = raw; val partial = heard?.takeIf { it.isNotBlank() }
        timing?.failed(original != null || (partial != null && kept != null))
        close(true)
        try {
            if (original != null) final(ServerEvent.Final(original, original, false, "unavailable"))
            else if (partial != null && kept != null) kept(partial, message)
            else changed(message, null)
        } finally { ended() }
    }
    fun cancel() { if (live) { timing?.cancelled(); close(true); ended() } }
    private fun close(cancel: Boolean) {
        live = false; raw = null; heard = null
        pendingFinal?.let(handler::removeCallbacks); pendingFinal = null
        handler.removeCallbacks(timeout)
        capture?.stop(); capture = null
        buffer?.cancel(); buffer = null
        transport?.close(cancel = cancel, immediate = !cancel); transport = null
    }
    private companion object {
        /** Connect + Ready budget; PreReadyBuffer only holds 5 s of audio, so waiting longer cannot save the utterance. */
        const val PRE_READY_MS = 7000L
    }
}
