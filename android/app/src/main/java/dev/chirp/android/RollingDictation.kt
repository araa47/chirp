package dev.chirp.android

import android.os.Handler
import android.os.Looper
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.sqrt

/**
 * Port of the Mac's `NotesSegmenter` for keyboard dictation: where one long dictation is cut into ordinary utterances
 * under the server's 120 s cap. Never before [MIN_SEGMENT], then at the first [PAUSE_CUT] of quiet ([RELAXED_PAUSE]
 * past [RELAXED_AFTER]), and at [MAX_SEGMENT] whatever is being said. Dictations shorter than [MIN_SEGMENT] are one utterance.
 */
internal class DictationSegmenter(
    private val minSegment: Double = MIN_SEGMENT, private val pauseCut: Double = PAUSE_CUT, private val relaxedAfter: Double = RELAXED_AFTER,
    private val relaxedPause: Double = RELAXED_PAUSE, private val maxSegment: Double = MAX_SEGMENT,
) {
    var elapsed = 0.0
        private set
    private var quiet = 0.0

    /** Adds one frame; true means cut after it. The caller cuts and then calls [reset]. */
    fun feed(rms: Float, duration: Double): Boolean {
        elapsed += duration
        quiet = if (rms < QUIET_RMS) quiet + duration else 0.0
        if (elapsed + EPSILON >= maxSegment) return true
        if (elapsed + EPSILON < minSegment) return false
        return quiet + EPSILON >= if (elapsed + EPSILON >= relaxedAfter) relaxedPause else pauseCut
    }
    fun reset() { elapsed = 0.0; quiet = 0.0 }

    companion object {
        const val MIN_SEGMENT = 45.0
        const val PAUSE_CUT = 0.6
        const val RELAXED_AFTER = 70.0
        const val RELAXED_PAUSE = 0.3
        const val MAX_SEGMENT = 90.0
        /** A frame is quiet below this RMS (0…1). */
        const val QUIET_RMS = 0.015f
        private const val EPSILON = 1e-6
        fun rms(pcm: ByteArray): Float {
            var energy = 0.0
            for (i in 0 until pcm.size / 2) { val sample = (pcm[i * 2].toInt() and 0xff) or (pcm[i * 2 + 1].toInt() shl 8); energy += sample.toDouble() * sample }
            return if (pcm.size < 2) 0f else (sqrt(energy / (pcm.size / 2)) / 32768.0).toFloat()
        }
    }
}

/** One segment's view of the shared microphone: frames arrive only while the router points at it. */
private class SegmentCapture(val frame: (ByteArray) -> Boolean, private val done: (DictationStatus?) -> Unit,
                             private val started: (SegmentCapture) -> Unit, private val stopped: (SegmentCapture) -> Unit) : Capture {
    private val finished = AtomicBoolean(false)
    override fun start() = started(this)
    override fun stop() = stopped(this)
    fun finish(error: DictationStatus?) { if (finished.compareAndSet(false, true)) done(error) }
}

/** Routes capture frames to the current segment and runs the segmenter on the capture thread. A swap is atomic, so every frame lands on exactly one segment, in order. */
private class SegmentRouter(private val cut: () -> Unit) {
    private val lock = Any()
    private var target: SegmentCapture? = null
    private val segmenter = DictationSegmenter()
    private var cutRequested = false
    private var ended = false

    fun route(bytes: ByteArray): Boolean {
        val rms = DictationSegmenter.rms(bytes) // Measured first: the segment owns (and wipes) the frame once sent.
        var ask = false
        val sent = synchronized(lock) {
            val segment = target ?: run { bytes.fill(0); return false }
            segment.frame(bytes).also {
                ask = !cutRequested && segmenter.feed(rms, bytes.size / 32000.0)
                if (ask) cutRequested = true
            }
        }
        if (ask) cut()
        return sent
    }
    /** Points capture at [next]; false once capture has ended. */
    fun swap(next: SegmentCapture): Boolean = synchronized(lock) {
        if (ended) return false
        target = next; segmenter.reset(); cutRequested = false
        true
    }
    fun current(segment: SegmentCapture) = synchronized(lock) { target === segment }
    /** Capture ended: the current segment finishes with its reason, and no later swap is accepted. */
    fun end(error: DictationStatus?) = synchronized(lock) { ended = true; target }?.finish(error)
}

/**
 * A dictation past the 120 s cap: one microphone, cut at pauses into ordinary utterances over rolling sockets (the Mac's
 * Live Notes design). The next segment buffers from the cut while the previous one finalizes, so nothing is dropped. Only
 * the oldest unfinished segment reaches the editor; its final (or what was heard before it failed) lands, then [next]
 * hands the caret to the following segment, so finals always land in order. A failed segment never touches earlier ones.
 */
internal class RollingDictation(
    private val transportFactory: ((ServerEvent) -> Unit, () -> Unit) -> ImeTransport,
    private val captureFactory: ((ByteArray) -> Boolean, (Double) -> Unit, (DictationStatus?) -> Unit) -> Capture,
    private val changed: (DictationStatus, ServerEvent.Partial?) -> Unit,
    private val level: (Double) -> Unit,
    private val retention: (Boolean) -> Unit,
    private val final: (ServerEvent.Final) -> Unit,
    private val ended: () -> Unit,
    private val handler: Handler = Handler(Looper.getMainLooper()),
    private val correcting: (ServerEvent.Correcting) -> Unit = {},
    private val kept: ((String, DictationStatus) -> Unit)? = null,
    private val pauseSeconds: Double? = null,
    private val countdown: (Int) -> Unit = {},
    /** The editor's next utterance starts after the segment that just landed (or was dropped). */
    private val next: () -> Unit = {},
    private val limitSeconds: Int = CaptureLimit.ROLLING_SECONDS,
    /** A fresh timer per segment, before its transport is made: each utterance logs its own timings. */
    private val deadlines: OperationDeadlines = OperationDeadlines(),
    private val timing: () -> SessionTimer? = { null },
) : Utterance {
    private inner class Segment {
        lateinit var stream: DictationStream
        var status: DictationStatus = StatusLine.CONNECTING
        var partial: ServerEvent.Partial? = null
        var raw: ServerEvent.Correcting? = null
        var outcome: (() -> Unit)? = null
        var done = false
    }
    private val segments = ArrayDeque<Segment>()
    private val router = SegmentRouter { handler.post(::cut) }
    private var capture: Capture? = null
    private var captureStarted = false
    private var live = false
    private var begin: (DictationStream) -> Unit = {}
    override var stopping = false
        private set
    override val polishing get() = segments.firstOrNull()?.stream?.polishing == true && (stopping || segments.size == 1)
    /** False while an earlier segment lands and the dictation goes on: no done cue then. */
    override var landingLast = true
        private set

    fun start(correction: Boolean, profile: String = "default", instructions: String = "", prompt: String? = null, learned: LearnedPayload? = null) {
        check(!live && capture == null)
        live = true
        capture = captureFactory(router::route, { value -> handler.post { if (live && !stopping) level(value) } }, { error ->
            router.end(error)
            handler.post { if (live) { stopping = true; drain() } }
        }).also { real ->
            real.pauseSeconds = pauseSeconds; real.limitSeconds = limitSeconds
            real.countdown = { left -> handler.post { if (live && !stopping) countdown(left) } }
        }
        begin = { it.start(correction, profile, instructions, prompt, learned) }
        open()
    }
    private fun open() {
        val segment = Segment()
        segments.addLast(segment)
        segment.stream = DictationStream(
            transportFactory = transportFactory,
            captureFactory = { frame, _, done -> SegmentCapture(frame, done, ::attach, ::detach) },
            changed = { status, partial ->
                if (live) {
                    segment.status = status
                    if (partial != null) segment.partial = partial
                    if (segment === segments.firstOrNull()) emit(segment, partial)
                }
            },
            level = {}, retention = { if (live) retention(it) },
            final = { segment.outcome = { final(it) } },
            ended = { if (live) { segment.done = true; drain() } },
            handler = handler,
            correcting = { if (live) { segment.raw = it; if (segment === segments.firstOrNull()) correcting(it) } },
            kept = kept?.let { keep -> { heard, reason -> segment.outcome = { keep(heard, reason) } } },
            timing = timing(), deadlines = deadlines,
        )
        begin(segment.stream)
    }
    private fun attach(segment: SegmentCapture) {
        if (!router.swap(segment)) { segment.finish(null); return }
        if (!captureStarted) { captureStarted = true; capture?.start() }
    }
    /** The capturing segment stopping (Stop, or its own failure) ends the microphone; a cut-off one just finishes. */
    private fun detach(segment: SegmentCapture) {
        if (router.current(segment)) { stopping = true; capture?.stop() } else segment.finish(null)
    }
    /** The rolling hand-off: the next segment takes the microphone first, then the old one is asked for its final. */
    private fun cut() {
        if (!live || stopping) return
        val old = segments.last()
        open()
        old.stream.stop()
    }
    override fun stop() {
        if (!live || stopping) return
        stopping = true
        segments.last().stream.stop()
        if (segments.size > 1) emit(segments.first(), null)
    }
    private fun emit(segment: Segment, partial: ServerEvent.Partial?) =
        changed(if (!stopping && segments.size > 1) StatusLine.LISTENING else segment.status, partial)
    /** Lands finished segments oldest first; a later one waits until every earlier one has landed. */
    private fun drain() {
        while (live) {
            val segment = segments.firstOrNull() ?: break
            if (!segment.done) break
            segments.removeFirst()
            val outcome = segment.outcome
            landingLast = segments.isEmpty()
            if (outcome != null) outcome() else if (segments.isEmpty()) changed(segment.status, null)
            val following = segments.firstOrNull() ?: break
            next()
            if (!following.done) { following.raw?.let(correcting); emit(following, following.partial.takeIf { following.raw == null }) }
        }
        if (live && segments.isEmpty() && stopping) { live = false; capture = null; ended() }
    }
    /** Discards every segment that has not landed; text already inserted stays. */
    override fun cancel() {
        if (!live) return
        live = false
        segments.forEach { it.stream.cancel() }; segments.clear()
        capture?.stop(); capture = null
        ended()
    }
}
