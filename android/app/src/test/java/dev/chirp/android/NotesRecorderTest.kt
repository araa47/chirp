package dev.chirp.android

import android.os.Looper
import java.time.Duration
import kotlinx.coroutines.CompletableDeferred
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** One fake `/v1/stream` socket: what the recorder sent, and the server's side to drive. */
internal class NotesWire(val event: (ServerEvent) -> Unit, val failure: () -> Unit) : ImeTransport {
    var profile = ""
    var correction: Boolean? = null
    /** The speaker session `start` carried (labels on), else null. */
    var speakers: String? = null
    var frames = 0
    var stops = 0
    var closed = false
    private var ready = false
    override fun connect() {}
    override fun start(correction: Boolean, profile: String, instructions: String, prompt: String?): Boolean {
        this.correction = correction; this.profile = profile; return true
    }
    override fun start(correction: Boolean, profile: String, instructions: String, prompt: String?, speakers: String?): Boolean {
        this.speakers = speakers; return start(correction, profile, instructions, prompt)
    }
    override fun start(correction: Boolean) = start(correction, "default", "", null)
    override fun audio(bytes: ByteArray): Boolean { if (ready && !closed) frames++; return ready && !closed }
    override fun stop(): Boolean { stops++; return ready && !closed }
    override fun close(cancel: Boolean, immediate: Boolean) { closed = true }
    fun ready() { ready = true; event(ServerEvent.Ready(false)) }
    fun partial(text: String) = event(ServerEvent.Partial(1, text, ""))
    var finals = 0
    fun final(text: String, raw: String = text, speakers: SpeakersResult? = null) { finals++; event(ServerEvent.Final(text, raw, text != raw, speakers = speakers)) }
    fun error(code: String) = event(ServerEvent.Failure(code))
}

internal class FakeNotesCapture(val frame: (ByteArray, Float) -> Unit, val done: (DictationStatus?) -> Unit) : Capture {
    var started = false
    var stopped = false
    override fun start() { started = true }
    override fun stop() { if (!stopped) { stopped = true; done(null) } }
}

/** Structure and reorganize calls the test answers by hand. */
internal class FakeNotesCalls {
    val structures = mutableListOf<Pair<NotesStructureRequest, CompletableDeferred<NotesStructureResponse>>>()
    val reorganizes = mutableListOf<Pair<NotesReorganizeRequest, CompletableDeferred<NotesReorganizeResponse>>>()
    suspend fun structure(r: NotesStructureRequest) = CompletableDeferred<NotesStructureResponse>().also { structures += r to it }.await()
    suspend fun reorganize(r: NotesReorganizeRequest) = CompletableDeferred<NotesReorganizeResponse>().also { reorganizes += r to it }.await()
    val edits = mutableListOf<Pair<NotesEditRequest, CompletableDeferred<NotesEditResponse>>>()
    suspend fun edit(r: NotesEditRequest) = CompletableDeferred<NotesEditResponse>().also { edits += r to it }.await()
}

internal val notesMac = Health(true, false, true, false, null, "synthetic", notesStructure = true, notesReorganize = true, notesCorrection = true, notesEdit = true)

internal class NotesRig(health: Health? = notesMac) {
    val wires = mutableListOf<NotesWire>()
    val captures = mutableListOf<FakeNotesCapture>()
    val calls = FakeNotesCalls()
    val recorder = NotesRecorder({ event, failure -> NotesWire(event, failure).also { wires += it } },
        { frame, _, done -> FakeNotesCapture(frame, done).also { captures += it } },
        calls::structure, calls::reorganize, NotesRecorder.Options(true, "live_notes"), health, structuringEnabled = true, editNotes = calls::edit)
    val wire get() = wires.last()
    fun idle(seconds: Long = 0) = shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(seconds))
    /** [seconds] of loud audio (no pause), 40 ms frames, as the capture thread would hand them over. */
    fun speak(seconds: Double, rms: Float = 0.1f) = repeat((seconds / 0.04).toInt()) { recorder.handleFrame(ByteArray(1280), rms) }
    fun structured(md: String, index: Int = calls.structures.lastIndex) { calls.structures[index].second.complete(NotesStructureResponse(md, true)); idle() }
    /** Starts and records one 45 s segment, then cuts to a fresh ready socket. Returns the segment's wire. */
    fun segment(): NotesWire {
        val old = wire
        speak(45.0); idle()
        wire.ready(); idle()
        return old
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37])
class NotesRecorderTest {
    @Test fun `rolling hand-off swaps to the next socket at once, routes every frame once and commits in order`() {
        val rig = NotesRig()
        rig.recorder.start(); rig.idle()
        assertEquals(NotesRecorder.State.STARTING, rig.recorder.state)
        assertEquals("live_notes", rig.wire.profile)
        rig.speak(1.0) // before Ready: held in the first socket's pre-ready buffer
        rig.wire.ready(); rig.idle()
        assertEquals(NotesRecorder.State.RECORDING, rig.recorder.state)
        assertEquals(25, rig.wires[0].frames)
        rig.speak(44.0)
        assertEquals("the cut opened a second socket", 2, rig.wires.size)
        assertEquals("and asked the first for its final at once", 1, rig.wires[0].stops)
        rig.speak(2.0)
        assertEquals("audio after the cut is held for the second until it is ready", 1125, rig.wires[0].frames)
        rig.wires[1].ready(); rig.idle()
        assertEquals(50, rig.wires[1].frames)
        rig.speak(1.0)
        assertEquals(1125, rig.wires[0].frames); assertEquals(75, rig.wires[1].frames)
        assertEquals(48.0, rig.recorder.elapsed, 1e-9)
        // The second segment's final arrives first; the transcript still follows capture order.
        rig.speak(45.0); rig.wires[2].ready(); rig.idle()
        rig.wires[1].final("second part")
        assertEquals(0, rig.recorder.document.segments.size)
        rig.wires[0].final("first part"); rig.idle()
        assertEquals(listOf("first part", "second part"), rig.recorder.document.segments.map { it.text })
        assertEquals(listOf(0.0, 45.0), rig.recorder.document.segments.map { it.offset })
    }

    /** The Mac transcribes one utterance at a time: a socket is Ready only once the one before it has its final (#134). */
    @Test fun `cuts never wait for a Ready the Mac gives only after the previous segment's final`() {
        val rig = NotesRig()
        rig.recorder.start(); rig.wire.ready(); rig.idle()
        repeat(4) { n ->
            val old = rig.wire
            rig.speak(if (n == 0) 45.0 else 35.0); rig.idle()
            assertEquals("cut $n asked the old segment for its final at once", 1, old.stops)
            rig.speak(10.0) // the Mac finishing the old segment: up to its 10 s queue limit, held for the next socket
            rig.idle(12) // past any wait for Ready, within the final's own deadline
            old.final("part $n"); rig.idle()
            rig.wire.ready(); rig.idle()
            assertEquals("every held frame went on", 250, rig.wire.frames)
        }
        assertEquals(NotesRecorder.State.RECORDING, rig.recorder.state)
        assertEquals((0..3).map { "part $it" }, rig.recorder.document.segments.map { it.text })
        assertTrue(rig.recorder.document.segments.none { it.failure != null })
    }

    @Test fun `a socket's send queue takes a whole pre-ready buffer flushed at Ready`() {
        // Audio held while the Mac finishes the previous segment goes out at once; a smaller queue bound dropped it.
        assertTrue(NotesRecorder.PRE_READY_BYTES + 1280 <= NotesRecorder.MAX_QUEUED_BYTES)
        assertTrue("the Mac answers busy after 10 s in its queue", NotesRecorder.PRE_READY_BYTES >= 16000 * 2 * 10)
    }

    @Test fun `a pause right after a cut, before the next socket is ready, still lands that segment`() {
        val rig = NotesRig()
        rig.recorder.start(); rig.wire.ready(); rig.idle()
        val first = rig.wire
        rig.speak(45.0); rig.idle()
        val second = rig.wire
        rig.speak(1.0)
        rig.recorder.pause(); rig.idle()
        assertEquals("no stop before Ready: the socket could not take it", 0, second.stops)
        first.final("first part"); rig.idle()
        second.ready(); rig.idle()
        assertEquals("the held second went on, then the stop", 25, second.frames)
        assertEquals(1, second.stops)
        second.final("second part"); rig.idle()
        assertEquals(listOf("first part", "second part"), rig.recorder.document.segments.map { it.text })
        assertEquals(NotesRecorder.State.PAUSED, rig.recorder.state)
    }

    @Test fun `a failed segment leaves a marked gap and recording rolls on, three in a row stop with nothing lost`() {
        val rig = NotesRig()
        rig.recorder.start(); rig.wire.ready(); rig.idle()
        val first = rig.segment()
        first.final("kept words"); rig.idle()
        rig.wire.error("engine"); rig.idle()
        assertEquals(3, rig.wires.size)
        rig.wire.ready(); rig.idle()
        assertEquals(NotesRecorder.State.RECORDING, rig.recorder.state)
        assertEquals("speech engine hiccup", rig.recorder.document.segments.last().failure)
        assertTrue(rig.recorder.document.transcriptLines().last().contains("⚠︎ audio not transcribed"))
        rig.wire.failure(); rig.idle()
        rig.wire.ready(); rig.idle()
        rig.wire.error("busy"); rig.idle()
        assertEquals(NotesRecorder.State.STOPPING, rig.recorder.state)
        assertTrue(rig.captures.single().stopped)
        rig.calls.structures.forEach { it.second.complete(NotesStructureResponse("- Kept words", true)) }
        rig.idle()
        assertEquals(NotesRecorder.State.ERROR, rig.recorder.state)
        assertEquals(RecordingFailure.Stopped(RecordingFailure.Server.BUSY), rig.recorder.error)
        assertEquals("Notes stopped: Chirp server is busy", rig.recorder.error!!.ui.notesEnglish())
        assertEquals("diagnostics keep the English", "Notes stopped: Chirp server is busy", rig.recorder.problem)
        assertEquals(listOf("kept words"), rig.recorder.document.segments.filter { !it.isGap }.map { it.text })
        assertTrue(rig.recorder.document.text.contains("Kept words"))
    }

    @Test fun `a socket that never gets ready at a cut keeps audio on the current one and retries`() {
        val rig = NotesRig()
        rig.recorder.start(); rig.wire.ready(); rig.idle()
        rig.speak(45.0)
        rig.wires[1].failure(); rig.idle()
        assertTrue(rig.wires[1].closed)
        rig.idle(3)
        assertEquals("retried after two seconds", 3, rig.wires.size)
        rig.wires[2].ready(); rig.idle()
        assertEquals(1, rig.wires[0].stops)
        assertEquals(NotesRecorder.State.RECORDING, rig.recorder.state)
    }

    @Test fun `the first socket failing ends the start with the reason`() {
        val rig = NotesRig()
        rig.recorder.start(); rig.idle()
        rig.wire.failure(); rig.idle()
        assertEquals(NotesRecorder.State.ERROR, rig.recorder.state)
        assertEquals(RecordingFailure.Connection(ConnectionFailure.Kind.OTHER), rig.recorder.error)
        assertEquals(ConnectionFailure.Kind.OTHER.english(), rig.recorder.error!!.english)
        assertTrue(rig.captures.single().stopped)
    }

    @Test fun `structuring waits for finalizing segments, applies to the tail and holds while the user types there`() {
        val rig = NotesRig()
        rig.recorder.start(); rig.wire.ready(); rig.idle()
        val first = rig.segment()
        assertTrue("nothing to structure yet", rig.calls.structures.isEmpty())
        first.final("we agreed to ship on friday"); rig.idle()
        assertEquals("we agreed to ship on friday", rig.calls.structures.single().first.transcript)
        rig.structured("## Launch\n- **Decision:** Ship on Friday")
        assertEquals("## Launch\n- **Decision:** Ship on Friday", rig.recorder.document.text)
        val changes = rig.recorder.takePendingChanges()
        assertEquals(NotesChange.Kind.APPEND, changes.single().kind)
        // A second pass waits out the 15 s interval.
        rig.segment().final("and the budget is fine"); rig.idle()
        assertEquals(1, rig.calls.structures.size)
        rig.idle(16)
        assertEquals(2, rig.calls.structures.size)
        // The caret is in the tail and a key was just pressed: the answer is held, then released when the caret leaves.
        // An input method composing in the tail holds the answer until the composition ends.
        val doc = rig.recorder.document
        rig.recorder.editorFocus(inTail = true, composing = true)
        rig.structured("## Launch\n- **Decision:** Ship on Friday\n- Budget is fine")
        assertTrue(rig.recorder.holding)
        assertFalse(doc.text.contains("Budget"))
        rig.recorder.editorFocus(inTail = false, composing = false)
        assertTrue(doc.text.endsWith("- Budget is fine"))
    }

    @Test fun `busy and rejected answers are retried, rejected ones in halves`() {
        val rig = NotesRig()
        rig.recorder.start(); rig.wire.ready(); rig.idle()
        rig.segment().final("first point"); rig.idle()
        rig.calls.structures[0].second.completeExceptionally(NotesHttpError(503)); rig.idle()
        assertEquals(Structuring.Failed("busy"), rig.recorder.structuring)
        assertEquals("Diagnostics name the failure by its code only", "structure: busy", rig.recorder.problem)
        val sentences = (1..80).joinToString(" ") { "Sentence number $it is here." }
        rig.segment().final(sentences); rig.idle()
        assertEquals("busy waits out the interval, then retries with the newer text", 1, rig.calls.structures.size)
        rig.idle(16)
        val request = rig.calls.structures.last().first
        assertTrue(request.transcript.startsWith("first point\n"))
        rig.calls.structures.last().second.complete(NotesStructureResponse(null, false, "rejected", "novel_name")); rig.idle()
        assertEquals("split in two", 3, rig.calls.structures.size)
        rig.structured("- First half")
        assertEquals(4, rig.calls.structures.size)
        rig.calls.structures[3].second.complete(NotesStructureResponse(null, false, "rejected")); rig.idle()
        // The second half is split once more; a quarter that still fails stays as raw text under the fallback header.
        rig.structured("- Third quarter", 4)
        rig.calls.structures[5].second.complete(NotesStructureResponse(null, false, "rejected")); rig.idle()
        val text = rig.recorder.document.text
        assertTrue(text.startsWith("- First half\n\n- Third quarter\n\n" + NotesDocument.FALLBACK_HEADER))
        assertEquals(Structuring.Failed("rejected"), rig.recorder.structuring)
    }

    @Test fun `organize applies only if the notes are unchanged, and undo restores them`() {
        val rig = NotesRig()
        val notes = "## Budget\n- Travel costs are too high this year\n\n## Budget\n- Cut travel by a third next quarter\n"
        rig.recorder.userEdit(0, 0, notes)
        rig.recorder.organize()
        val (request, answer) = rig.calls.reorganizes.single()
        assertEquals(notes, request.notes)
        rig.recorder.userEdit(notes.length, notes.length, "- typed meanwhile")
        answer.complete(NotesReorganizeResponse("## Budget\n- Travel costs are too high\n- Cut travel by a third", true, true)); rig.idle()
        assertEquals(Reorganizing.Conflict, rig.recorder.reorganizeStatus)
        assertTrue(rig.recorder.document.text.endsWith("- typed meanwhile"))
        rig.recorder.organize()
        rig.calls.reorganizes.last().second.complete(NotesReorganizeResponse("## Budget\n- Travel costs are too high\n- Cut travel by a third\n- typed meanwhile", true, true))
        rig.idle()
        assertTrue(rig.recorder.reorganizeStatus is Reorganizing.Applied)
        assertEquals("## Budget\n- Travel costs are too high\n- Cut travel by a third\n- typed meanwhile", rig.recorder.document.text)
        assertTrue(rig.recorder.canUndo)
        rig.recorder.takePendingChanges()
        rig.recorder.undoOrganize()
        assertEquals(notes + "- typed meanwhile", rig.recorder.document.text)
        assertEquals(NotesChange.Kind.USER, rig.recorder.takePendingChanges().single().kind)
        assertFalse(rig.recorder.canUndo)
    }

    @Test fun `organize on notes too short to reorganize says so instead of doing nothing, until the notes change`() {
        val rig = NotesRig()
        rig.recorder.userEdit(0, 0, "- Ship it Friday")
        rig.recorder.organize(); rig.idle()
        assertTrue(rig.calls.reorganizes.isEmpty())
        assertEquals(Reorganizing.TooShort, rig.recorder.reorganizeStatus)
        rig.recorder.userEdit(16, 16, "\n- Review the budget with finance before the launch review on Monday")
        assertEquals(Reorganizing.Idle, rig.recorder.reorganizeStatus)
        rig.recorder.organize(); rig.idle()
        assertEquals(1, rig.calls.reorganizes.size)
    }

    @Test fun `organize structures raw fallback blocks in place and a preempted reorganize is not a failure`() {
        val rig = NotesRig()
        rig.recorder.start(); rig.wire.ready(); rig.idle()
        val first = rig.segment()
        rig.recorder.stop(); rig.idle()
        first.final("a long thought about the roadmap and the hiring plan for next year"); rig.idle()
        rig.wires.last().final("and one more thing"); rig.idle()
        rig.calls.structures.single().second.complete(NotesStructureResponse(null, false, "timeout")); rig.idle()
        assertEquals("Stop runs one last reorganize", NotesRecorder.State.STOPPING, rig.recorder.state)
        rig.calls.reorganizes.single().second.complete(NotesReorganizeResponse(null, false, false, "rejected")); rig.idle()
        assertEquals(NotesRecorder.State.STOPPED, rig.recorder.state)
        assertTrue(rig.recorder.document.text.startsWith(NotesDocument.FALLBACK_HEADER))
        rig.recorder.organize()
        val md = "## Roadmap\n- A long thought about the roadmap\n- The hiring plan for next year\n- One more thing"
        rig.structured(md)
        assertEquals(md, rig.recorder.document.text)
        rig.calls.reorganizes.last().second.complete(NotesReorganizeResponse(null, false, false, "preempted")); rig.idle()
        assertEquals(Reorganizing.Organized(0, null), rig.recorder.reorganizeStatus)
        assertTrue(rig.recorder.canUndo)
    }

    @Test fun `structuring is off until health says where the text goes`() {
        assertEquals(Structuring.Off(StructuringOff.WAITING), NotesRig(health = null).recorder.structuring)
        assertEquals(Structuring.Off(StructuringOff.CORRECTION_OFF), Structuring.availability(notesMac.copy(correctionAvailable = false), true))
        assertEquals(Structuring.Off(StructuringOff.UNSUPPORTED), Structuring.availability(notesMac.copy(notesStructure = false), true))
        val rig = NotesRig(health = null)
        rig.recorder.start(); rig.wire.ready(); rig.idle()
        rig.segment().final("words"); rig.idle()
        assertTrue(rig.calls.structures.isEmpty())
        rig.recorder.configure(true, notesMac)
        assertEquals(1, rig.calls.structures.size)
    }

    @Test fun `a 409 turns structuring off and the notes stay a plain editor`() {
        val rig = NotesRig()
        rig.recorder.start(); rig.wire.ready(); rig.idle()
        rig.segment().final("words"); rig.idle()
        rig.calls.structures.single().second.completeExceptionally(NotesHttpError(409)); rig.idle()
        assertEquals("structure: notes_off", rig.recorder.problem)
        assertEquals(Structuring.Off(StructuringOff.CORRECTION_OFF), rig.recorder.structuring)
        rig.recorder.userEdit(0, 0, "my own line")
        assertEquals("my own line", rig.recorder.document.text)
    }

    @Test fun `stop before the first ready drops the session, and cancel keeps the document`() {
        val rig = NotesRig()
        rig.recorder.start(); rig.recorder.stop(); rig.idle()
        assertEquals(NotesRecorder.State.IDLE, rig.recorder.state)
        assertTrue(rig.wire.closed)
        rig.recorder.start(); rig.wire.ready(); rig.idle()
        rig.segment().final("kept"); rig.idle()
        rig.recorder.cancel()
        assertEquals(NotesRecorder.State.STOPPED, rig.recorder.state)
        assertTrue(rig.wires.all { it.closed })
        assertEquals("kept", rig.recorder.document.segments.single().text)
        rig.recorder.reset()
        assertTrue(rig.recorder.document.isEmpty)
    }
}
