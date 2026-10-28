package dev.chirp.android

import android.Manifest
import android.app.Notification
import android.graphics.Bitmap
import android.os.Looper
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import java.io.File
import java.time.Duration
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

private const val NOTES = "## Pricing\n- Tier one is free\n- Tier two is ten dollars\n\n## Plan\n- Ship on Friday"
private const val EDITED = "## Plan\n- Ship on Friday"

private fun NotesRig.command(voice: NotesVoiceEdit, words: String) {
    // Structuring passes an earlier edit let through are over (they would hold the pass slot).
    calls.structures.filter { !it.second.isCompleted }.forEach { it.second.complete(NotesStructureResponse.failed("timeout")) }
    idle()
    voice.start()
    val command = wire
    command.ready(); idle()
    voice.finish()
    if (recorder.state == NotesRecorder.State.RECORDING) { wire.ready(); idle() }
    command.final(words); idle()
    wires.filter { it !== command && it.stops > 0 && it.finals == 0 }.forEach { it.final("earlier words") }
    idle()
}

/** A recorder rig with the voice edit on fake sockets and a fake microphone for commands outside a recording. */
private class VoiceRig(health: Health? = notesMac) {
    val rig = NotesRig(health)
    val recorder get() = rig.recorder
    val voice = NotesVoiceEdit(rig.recorder, { event, failure -> NotesWire(event, failure).also { rig.wires += it } },
        microphone = { sink, ended -> FakeNotesCapture({ bytes, _ -> sink(bytes) }, ended).also { rig.captures += it; it.start() } })
    val outcomes = mutableListOf<NotesEditOutcome>()

    /** Recording, with [NOTES] typed in and 3 s spoken whose final is still to come. Returns that segment's socket. */
    fun recording(): NotesWire {
        recorder.userEdit(0, 0, NOTES)
        recorder.start(); rig.wire.ready(); rig.idle()
        rig.speak(3.0)
        return rig.wire
    }

    /**
     * A command from start to the instruction's final. The notes socket comes back as soon as it is ready, and the
     * notes sockets the command cut off get their finals (the edit waits for them).
     */
    fun command(words: String) = rig.command(voice, words)
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37])
class NotesVoiceEditRecorderTest {
    @Test fun `a command goes to its own socket, never into the transcript, and capture returns to the notes after`() {
        val v = VoiceRig(); val rig = v.rig
        val first = v.recording()
        v.voice.start()
        val command = rig.wires[1]
        assertFalse("raw speech: the clean-up model stays free for the edit", command.correction!!)
        assertEquals("default", command.profile)
        assertTrue(v.voice.status.isListening)
        assertEquals("the segment before it finalizes as at a pause", 1, first.stops)
        rig.speak(2.0)
        assertEquals("held for the command, not sent to the notes", 75, first.frames)
        command.ready(); rig.idle()
        assertEquals("the held audio went on once the command socket was ready", 50, command.frames)
        rig.speak(1.0)
        assertEquals(75, command.frames); assertEquals(75, first.frames)

        v.voice.finish(); rig.idle()
        assertEquals("a fresh notes socket takes capture at once", 3, rig.wires.size)
        assertEquals("the command stops at once: the Mac readies the notes socket only after its final", 1, command.stops)
        rig.speak(0.5)
        assertEquals(75, command.frames)
        rig.wires[2].ready(); rig.idle()
        assertEquals("the notes audio meanwhile was held, then sent", 12, rig.wires[2].frames)
        rig.speak(1.0)
        assertEquals(75, command.frames); assertEquals(37, rig.wires[2].frames)

        command.final("remove the pricing section"); rig.idle()
        assertEquals(VoiceEditStatus.Editing("remove the pricing section"), v.voice.status)
        assertTrue("the edit waits for the segment before the command to be in", rig.calls.edits.isEmpty())
        first.final("we agreed on pricing"); rig.idle()
        assertEquals(listOf("we agreed on pricing"), v.recorder.document.segments.map { it.text })
        val (request, answer) = rig.calls.edits.single()
        assertEquals("remove the pricing section", request.instruction)
        assertEquals(NOTES, request.notes)
        assertEquals("the edit goes ahead of the structuring pass", 0, rig.calls.structures.size)
        answer.complete(NotesEditResponse(EDITED, true)); rig.idle()
        assertEquals(VoiceEditStatus.Done(NotesEditOutcome.Applied), v.voice.status)
        assertEquals(EDITED, v.recorder.document.text)
        assertEquals(listOf("we agreed on pricing"), v.recorder.document.segments.map { it.text })
        assertEquals("the editor replays it onto the old text", EDITED, v.recorder.takePendingChanges().fold(NOTES) { text, change -> change.applied(text) })
        assertEquals(1, rig.calls.structures.size)
        assertEquals(NotesRecorder.State.RECORDING, v.recorder.state)
    }

    @Test fun `one change, undone while nothing else changed it`() {
        val v = VoiceRig(); val rig = v.rig
        v.recording()
        v.command("remove the pricing section")
        rig.calls.edits.single().second.complete(NotesEditResponse(EDITED, true)); rig.idle()
        assertTrue(v.recorder.canUndoEdit)
        v.recorder.takePendingChanges()
        v.recorder.undoEdit()
        assertEquals(NOTES, v.recorder.document.text)
        assertEquals(NOTES, v.recorder.takePendingChanges().fold(EDITED) { text, change -> change.applied(text) })
        assertFalse(v.recorder.canUndoEdit)

        // Typing after an edit takes the undo away: it would drop the typing.
        v.command("tidy it")
        rig.calls.edits.last().second.complete(NotesEditResponse("## Pricing\n- Tier one is free", true)); rig.idle()
        assertTrue(v.recorder.canUndoEdit)
        v.recorder.userEdit(0, 0, "x")
        assertFalse(v.recorder.canUndoEdit)
    }

    @Test fun `typing while the edit runs, or a composition, leaves the notes untouched with a conflict`() {
        val v = VoiceRig(); val rig = v.rig
        v.recording()
        v.command("remove the pricing section")
        v.recorder.userEdit(NOTES.length, NOTES.length, "!")
        rig.calls.edits.single().second.complete(NotesEditResponse(EDITED, true)); rig.idle()
        assertEquals(VoiceEditStatus.Done(NotesEditOutcome.Conflict), v.voice.status)
        assertEquals("$NOTES!", v.recorder.document.text)
        assertFalse(v.recorder.canUndoEdit)
        assertEquals("Notes changed while editing — try again", NotesVoiceEditText.note(NotesEditOutcome.Conflict)?.notesEnglish())

        v.voice.dismiss()
        v.command("tidy")
        v.recorder.editorFocus(inTail = false, composing = true)
        rig.calls.edits.last().second.complete(NotesEditResponse(EDITED, true)); rig.idle()
        assertEquals(VoiceEditStatus.Done(NotesEditOutcome.Conflict), v.voice.status)
        assertEquals("$NOTES!", v.recorder.document.text)
    }

    @Test fun `an edit that touches the AI tail makes the tail the user's`() {
        val v = VoiceRig(); val rig = v.rig
        v.recorder.start(); rig.wire.ready(); rig.idle()
        rig.segment().final("ship it on friday"); rig.idle()
        rig.structured("## Plan\n- Ship it on Friday")
        assertTrue(v.recorder.document.tail.isNotEmpty())
        v.command("make that a task")
        val request = rig.calls.edits.single().first
        assertEquals("## Plan\n- Ship it on Friday", request.notes)
        rig.calls.edits.single().second.complete(NotesEditResponse("## Plan\n- [ ] Ship it on Friday", true)); rig.idle()
        assertEquals("## Plan\n- [ ] Ship it on Friday", v.recorder.document.text)
        assertEquals("the tail is the user's now; the next answer starts a new one", v.recorder.document.text.length, v.recorder.document.tailStart)
    }

    @Test fun `refusals and rejections say why, and a preempted edit runs again up to three times`() {
        for ((response, note) in listOf(
            NotesEditResponse(null, false, false, "refused", "adds_content") to "Can’t add new content by voice — ask to remove, move, tidy or reword",
            NotesEditResponse(null, false, false, "refused", "unclear") to "Couldn’t tell what to change — try naming the section",
            NotesEditResponse(null, false, false, "refused", "not_an_edit") to "That didn’t sound like an edit to the notes",
            NotesEditResponse(null, false, false, "refused", "Free text, not a code") to "Couldn’t tell what to change — try naming the section",
            NotesEditResponse(null, false, false, "rejected", "dropped_unasked") to "Couldn’t edit notes (rejected: dropped_unasked)",
            NotesEditResponse(null, false, false, "timeout") to "Couldn’t edit notes (timeout)",
            NotesEditResponse(NOTES, true, false) to "The edit changed nothing",
        )) {
            val v = VoiceRig(); val rig = v.rig
            v.recording()
            v.command("do it")
            rig.calls.edits.single().second.complete(response); rig.idle()
            val outcome = (v.voice.status as VoiceEditStatus.Done).outcome
            assertEquals(note, NotesVoiceEditText.note(outcome)?.notesEnglish())
            assertEquals("a refusal changes nothing", NOTES, v.recorder.document.text)
            assertFalse(v.recorder.canUndoEdit)
        }
        val v = VoiceRig(); val rig = v.rig
        v.recording()
        v.command("do it")
        repeat(2) { n ->
            assertEquals(n + 1, rig.calls.edits.size)
            rig.calls.edits.last().second.complete(NotesEditResponse(null, false, false, "preempted")); rig.idle()
            assertEquals("still first in line", VoiceEditStatus.Editing("do it"), v.voice.status)
        }
        assertEquals(3, rig.calls.edits.size)
        rig.calls.edits.last().second.complete(NotesEditResponse(null, false, false, "preempted")); rig.idle()
        assertEquals(VoiceEditStatus.Done(NotesEditOutcome.Failed("busy")), v.voice.status)
        assertEquals(3, rig.calls.edits.size)
    }

    @Test fun `a server without the endpoint ends the edit and hides it, and an old server never offers it`() {
        val v = VoiceRig(); val rig = v.rig
        v.recording()
        v.command("do it")
        assertTrue(v.recorder.canEdit)
        // The call fails like a 404: the endpoint is gone for this session.
        rig.calls.edits.single().second.completeExceptionally(NotesHttpError(404)); rig.idle()
        assertEquals(VoiceEditStatus.Done(NotesEditOutcome.Failed("unsupported")), v.voice.status)
        assertFalse(v.recorder.canEdit)
        v.recorder.configure(true, notesMac)
        assertFalse("a refresh does not bring it back", v.recorder.canEdit)

        val old = VoiceRig(notesMac.copy(notesEdit = false))
        assertFalse(old.voice.canStart)
        old.voice.start()
        assertEquals(VoiceEditStatus.Idle, old.voice.status)
    }

    @Test fun `Cancel drops the command and capture goes back to the notes while recording goes on`() {
        val v = VoiceRig(); val rig = v.rig
        val first = v.recording()
        v.voice.start(); rig.wire.ready(); rig.idle()
        rig.wire.partial("remove the")
        assertEquals(VoiceEditStatus.Listening("remove the"), v.voice.status)
        assertEquals("“remove the”", NotesVoiceEditText.status(v.voice.status)?.notesEnglish())
        v.voice.cancel(); rig.idle()
        assertEquals(VoiceEditStatus.Idle, v.voice.status)
        assertTrue(rig.wires[1].closed)
        assertEquals(3, rig.wires.size)
        rig.wires[2].ready(); rig.idle()
        rig.speak(1.0)
        assertEquals(25, rig.wires[2].frames)
        assertTrue(rig.calls.edits.isEmpty())
        first.final("kept words"); rig.idle()
        assertEquals(listOf("kept words"), v.recorder.document.segments.map { it.text })
        assertEquals(NotesRecorder.State.RECORDING, v.recorder.state)
    }

    @Test fun `nothing heard, a dead socket and a missing final each end it with their own note`() {
        val v = VoiceRig(); val rig = v.rig
        v.recording()
        v.command("   ")
        assertEquals(VoiceEditStatus.Done(NotesEditOutcome.Skipped("not_heard")), v.voice.status)
        assertEquals("Didn’t catch an edit — try again", NotesVoiceEditText.note((v.voice.status as VoiceEditStatus.Done).outcome)?.notesEnglish())
        v.voice.dismiss()

        v.voice.start(); rig.wire.ready(); rig.idle()
        rig.wire.failure(); rig.idle()
        rig.wires.last().ready(); rig.idle()
        assertEquals(VoiceEditStatus.Done(NotesEditOutcome.Failed("connection")), v.voice.status)
        v.voice.dismiss()

        v.voice.start(); val silent = rig.wire; silent.ready(); rig.idle()
        v.voice.finish(); rig.wires.last().ready(); rig.idle()
        rig.idle(11)
        assertEquals(VoiceEditStatus.Done(NotesEditOutcome.Failed("timeout")), v.voice.status)
        assertTrue(rig.calls.edits.isEmpty())
        assertEquals(NotesRecorder.State.RECORDING, v.recorder.state)
    }

    @Test fun `a command ends by itself after 20 seconds`() {
        val v = VoiceRig(); val rig = v.rig
        v.recording()
        v.voice.start(); rig.wire.ready(); rig.idle()
        rig.idle(19)
        assertTrue(v.voice.status.isListening)
        rig.idle(2)
        assertEquals(VoiceEditStatus.Editing(""), v.voice.status)
    }

    @Test fun `a command that ends before its socket is ready waits for Ready and still sends what was said`() {
        val v = VoiceRig(); val rig = v.rig
        v.recording()
        v.voice.start()
        val command = rig.wire
        rig.speak(1.0)
        v.voice.finish(); rig.idle()
        rig.wires[2].ready(); rig.idle()
        assertEquals("not ready: nothing to stop yet", 0, command.stops)
        command.ready(); rig.idle()
        assertEquals(25, command.frames)
        assertEquals(1, command.stops)
    }

    @Test fun `outside a recording the command opens the microphone itself and closes it after`() {
        val v = VoiceRig(); val rig = v.rig
        v.recorder.userEdit(0, 0, NOTES)
        v.voice.start()
        val mic = rig.captures.single()
        assertTrue(mic.started); assertTrue(v.voice.holdsMicrophone)
        mic.frame(ByteArray(1280), 0.1f)
        val command = rig.wire
        command.ready(); rig.idle()
        assertEquals("the held frame went on Ready", 1, command.frames)
        mic.frame(ByteArray(1280), 0.1f)
        assertEquals(2, command.frames)
        v.voice.finish(); rig.idle()
        assertTrue(mic.stopped); assertFalse(v.voice.holdsMicrophone)
        assertEquals(1, command.stops)
        command.final("remove the pricing section"); rig.idle()
        assertEquals(1, rig.wires.size)
        rig.calls.edits.single().second.complete(NotesEditResponse(EDITED, true)); rig.idle()
        assertEquals(EDITED, v.recorder.document.text)
        assertTrue("no segment, no transcript", v.recorder.document.segments.isEmpty())
    }

    @Test fun `a lost microphone drops the command with a note`() {
        val v = VoiceRig(); val rig = v.rig
        v.recorder.userEdit(0, 0, NOTES)
        v.voice.start()
        rig.captures.single().done(statusOf("Microphone unavailable")); rig.idle()
        assertEquals(VoiceEditStatus.Done(NotesEditOutcome.Failed("microphone")), v.voice.status)
        assertTrue(rig.wires.single().closed)
    }

    @Test fun `paused notes open the microphone for a command, and Pause or Stop mid-command end it cleanly`() {
        val v = VoiceRig(); val rig = v.rig
        v.recording()
        v.recorder.pause(); rig.idle()
        v.voice.start()
        assertEquals(2, rig.captures.size)
        v.voice.cancel(); rig.idle()
        assertTrue(rig.captures.last().stopped)
        v.recorder.resume(); rig.wire.ready(); rig.idle()

        // Stop from the notification while the command listens: the command ends with what it has, the notes finish.
        v.voice.start(); rig.wire.ready(); rig.idle()
        v.recorder.stop(); rig.idle()
        v.voice.finish(); rig.idle()
        assertEquals("the notes socket is not reopened after Stop", 4, rig.wires.size)
    }

    @Test fun `the selection limits the scope, and an empty or too long scope says so`() {
        val doc = NotesDocument(text = NOTES)
        val pricing = NOTES.indexOf("Tier one")
        assertEquals(NotesEditScope.Range(0, NOTES.length), doc.editScope(null))
        assertEquals(NotesEditScope.Range(0, NOTES.length), doc.editScope(5 to 5))
        // A selection inside two lines takes those whole lines, with their line ends.
        val range = doc.editScope(pricing + 3 to NOTES.indexOf("ten") + 1) as NotesEditScope.Range
        assertEquals("- Tier one is free\n- Tier two is ten dollars\n", NOTES.substring(range.start, range.end))
        val request = doc.editRequest("say it shorter", range.start, range.end)
        assertEquals("- Tier one is free\n- Tier two is ten dollars", request.notes)
        assertEquals("a selection ending at a line start does not take the next line", NotesEditScope.Range(0, NOTES.indexOf("- Tier one")),
            doc.editScope(0 to NOTES.indexOf("- Tier one")))
        assertEquals(NotesEditScope.None("empty"), NotesDocument(text = " \n").editScope(null))
        assertEquals(NotesEditScope.None("empty"), NotesDocument(text = "a\n\n\nb").editScope(2 to 3))
        val long = (1..400).joinToString("\n\n") { "## Section $it\n- some words in section number $it" }
        val scope = NotesDocument(text = long).editScope(null) as NotesEditScope.Range
        assertTrue("the trailing whole sections that fit", scope.end == long.length && scope.start > 0 && long.substring(scope.start).startsWith("## Section"))
        assertEquals(NotesEditScope.None("too_long"), NotesDocument(text = "x".repeat(4000)).editScope(null))
        assertEquals(NotesEditScope.None("too_long"), NotesDocument(text = "x".repeat(4000)).editScope(0 to 10))
    }

    @Test fun `an answer is applied as the smallest change and keeps the blank lines around the scope`() {
        val doc = NotesDocument(text = "Intro\n\n## Pricing\n- one\n- two\n\n## Plan\n- ship\n")
        val start = doc.text.indexOf("## Pricing")
        val end = doc.text.indexOf("## Plan")
        val request = doc.editRequest("remove the second price", start, end)
        val change = doc.applyEdit(NotesEditResponse("## Pricing\n- one", true), request)!!
        assertEquals("Intro\n\n## Pricing\n- one\n\n## Plan\n- ship\n", doc.text)
        assertEquals(NotesChange.Kind.USER, change.kind)
        assertEquals("one version bump", 1, doc.version)
        assertNull("the request is stale once the text changed", doc.applyEdit(NotesEditResponse("x", true), request))
        assertFalse(doc.canApplyEdit(request))
    }

    @Test fun `the answer decodes in every shape the server sends`() {
        val ok = NotesEditResponse.decode("""{"markdown":"- a","edited":true,"changed":true,"error":null,"timings_ms":{"edit":12.5}}""")
        assertEquals(NotesEditResponse("- a", true, true), ok)
        assertEquals(false, NotesEditResponse.decode("""{"markdown":"- a","edited":true,"changed":false}""").changed)
        val refused = NotesEditResponse.decode("""{"markdown":null,"edited":false,"changed":false,"error":"refused","reason":"adds_content"}""")
        assertEquals("adds_content", refused.refusal); assertNull(refused.markdown); assertFalse(refused.edited)
        assertEquals("rejected: dropped_unasked", NotesEditResponse.decode("""{"markdown":null,"edited":false,"error":"rejected","reason":"dropped_unasked"}""").failureLabel)
        assertTrue(NotesEditResponse.decode("""{"markdown":null,"edited":false,"error":"preempted"}""").preempted)
        // A claim of success without Markdown fails closed.
        assertFalse(NotesEditResponse.decode("""{"markdown":null,"edited":true,"changed":true}""").edited)
        assertEquals("""{"notes":"n","instruction":"i"}""", NotesEditRequest("n", "i", 1, 2, 3, 4).json())
    }

    @Test fun `the health report says whether the Mac can edit by voice`() {
        assertTrue(Protocol.health("""{"ok":true,"ready":true,"debug_retention":false,"notes_edit":true}""").notesEdit)
        assertFalse(Protocol.health("""{"ok":true,"ready":true,"debug_retention":false}""").notesEdit)
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37])
class NotesVoiceEditModelTest {
    private val context get() = RuntimeEnvironment.getApplication()

    /** Recording with [NOTES] typed in; returns the rig. */
    private fun recording(): NotesModelRig {
        val rig = NotesModelRig(context)
        rig.model.edit(TextFieldValue(NOTES))
        rig.model.toggle(); rig.wire.ready(); rig.idle()
        return rig
    }

    private fun NotesModelRig.command(words: String) {
        model.command(); idle()
        val command = wire
        command.ready(); idle()
        model.command(); idle()
        wire.ready(); idle()
        command.final(words); idle()
        wires.filter { it !== command && it.stops > 0 && it.finals == 0 }.forEach { it.final("earlier words") }
        idle()
    }

    @Test fun `with the screen off the edit still runs, applies at once in the document and reaches the editor when it is back`() {
        val rig = recording()
        rig.model.visible(false)
        assertTrue(rig.model.quiet)
        rig.api.editAnswers += NotesEditResponse(EDITED, true)
        rig.command("remove the pricing section")
        assertEquals(NOTES, rig.api.edits.single().notes)
        assertEquals("remove the pricing section", rig.api.edits.single().instruction)
        assertEquals("applied in the notes at once", EDITED, rig.model.document.text)
        assertEquals("the editor waits for the screen", NOTES, rig.model.field.text)
        rig.model.visible(true); rig.idle()
        assertEquals(EDITED, rig.model.field.text)
        assertTrue(rig.model.showEditedChip)
        assertTrue(rig.model.recording)
    }

    @Test fun `the editor's caret stays where the user left it, and Undo restores the text`() {
        val rig = recording()
        rig.model.edit(TextFieldValue(NOTES, TextRange(NOTES.length)))
        rig.model.focused = true
        rig.api.editAnswers += NotesEditResponse("## Pricing\n- Tier one is free\n- Tier two is ten dollars\n\n## Plan\n- Ship on Thursday", true)
        rig.command("change Friday to Thursday")
        assertTrue(rig.model.field.text.endsWith("Thursday"))
        assertEquals(rig.model.field.text.length, rig.model.field.selection.end)
        assertTrue(rig.model.showEditedChip)
        rig.model.undoVoiceEdit(); rig.idle()
        assertEquals(NOTES, rig.model.field.text)
        assertEquals(NOTES, rig.model.document.text)
        assertFalse(rig.model.showEditedChip)
    }

    @Test fun `typing takes the chip away, and a selection is what gets edited`() {
        val rig = recording()
        val start = NOTES.indexOf("## Plan")
        rig.model.edit(TextFieldValue(NOTES, TextRange(start, NOTES.length)))
        rig.api.editAnswers += NotesEditResponse("## Plan\n- Ship on Thursday", true)
        rig.command("change Friday to Thursday")
        assertEquals("## Plan\n- Ship on Friday", rig.api.edits.single().notes)
        assertEquals("## Pricing\n- Tier one is free\n- Tier two is ten dollars\n\n## Plan\n- Ship on Thursday", rig.model.field.text)
        assertTrue(rig.model.showEditedChip)
        rig.model.edit(TextFieldValue(rig.model.field.text + "!"))
        assertFalse(rig.model.showEditedChip)
        assertNull(rig.model.voiceEditNote)
    }

    @Test fun `the status line follows the command and a failed edit leaves a note`() {
        val rig = recording()
        rig.model.command(); rig.idle()
        assertEquals("Say the edit…", rig.model.status.notesEnglish())
        rig.wire.ready(); rig.wire.partial("remove the"); rig.idle()
        assertEquals("“remove the”", rig.model.status.notesEnglish())
        rig.model.command(); rig.idle(); rig.wire.ready(); rig.idle()
        assertEquals("Editing notes…", rig.model.status.notesEnglish())
        rig.wires[1].final("make it a poem"); rig.idle()
        assertEquals("the edit waits for the segment before the command", "Editing notes…", rig.model.status.notesEnglish())
        rig.wires[0].final("earlier words"); rig.idle()
        // The server's answer was never scripted: it fails like a timeout.
        assertEquals("Listening…", rig.model.status.notesEnglish())
        assertEquals("Couldn’t edit notes (timeout)", rig.model.voiceEditNote?.notesEnglish())
        assertEquals(NOTES, rig.model.field.text)
        rig.model.dismissVoiceEdit()
        assertNull(rig.model.voiceEditNote)
    }

    @Test fun `a hold sends on release and a tap latches until the next press`() {
        val rig = recording()
        rig.model.commandPress(); rig.idle()
        assertTrue(rig.model.listeningForCommand)
        rig.model.commandRelease(100); rig.idle()
        assertTrue("a short press latches the command", rig.model.listeningForCommand)
        rig.model.commandPress(); rig.idle()
        assertEquals("the next press sends it", "Editing notes…", rig.model.status.notesEnglish())
        rig.model.commandRelease(50); rig.idle()
        assertFalse(rig.model.listeningForCommand)

        rig.wire.ready(); rig.idle()
        rig.model.dismissVoiceEdit()
        rig.model.commandPress(); rig.idle()
        rig.model.commandRelease(NotesVoiceEdit.HOLD_MS + 1); rig.idle()
        assertEquals("a hold sends on release", "Editing notes…", rig.model.status.notesEnglish())
    }

    @Test fun `Record and Resume wait while a command has the microphone`() {
        val rig = NotesModelRig(context)
        rig.model.edit(TextFieldValue(NOTES))
        rig.model.command(); rig.idle()
        assertTrue(rig.model.listeningForCommand)
        rig.model.toggle(); rig.idle()
        assertEquals(NotesStatus.FINISH_EDIT, rig.model.message)
        assertEquals("Finish the spoken edit first", rig.model.message!!.notesEnglish())
        assertEquals(NotesRecorder.State.IDLE, rig.model.state)
        // Leaving the screen ends a command on its own microphone: Android would silence it anyway.
        rig.model.visible(false); rig.idle()
        assertFalse(rig.model.listeningForCommand)
        assertTrue(rig.captures.single().stopped)
    }

    @Test fun `the notification's Command action starts and ends a command from the lock screen`() {
        val rig = recording()
        assertEquals(false, rig.model.commanding)
        assertTrue(NotesControls.act(NotesService.ACTION_COMMAND)); rig.idle()
        assertEquals(true, rig.model.commanding)
        assertEquals(2, rig.wires.size)
        val shown = shadowOf(context.getSystemService(android.app.NotificationManager::class.java)).getNotification(NotesService.ID)
        assertEquals(listOf("Pause", "Send", "Stop"), shown.actions.map { it.title.toString() })
        assertEquals(NotesService.ACTION_COMMAND, shadowOf(shown.actions[1].actionIntent).savedIntent.action)
        assertNull("the notification never carries notes or command text", shown.extras.getCharSequence(Notification.EXTRA_TEXT))
        rig.wire.ready(); rig.idle()
        assertTrue(NotesControls.act(NotesService.ACTION_COMMAND)); rig.idle()
        assertEquals(false, rig.model.commanding)
        val after = shadowOf(context.getSystemService(android.app.NotificationManager::class.java)).getNotification(NotesService.ID)
        assertEquals(listOf("Pause", "Command", "Stop"), after.actions.map { it.title.toString() })
    }

    @Test fun `the notification offers no Command when the Mac cannot edit by voice`() {
        val app = context
        assertEquals(listOf("Pause", "Stop"), NotesService.notification(app).actions.map { it.title.toString() })
        assertEquals(listOf("Pause", "Command", "Stop"), NotesService.notification(app, command = false).actions.map { it.title.toString() })
        assertEquals(listOf("Pause", "Send", "Stop"), NotesService.notification(app, command = true).actions.map { it.title.toString() })
        val rig = NotesModelRig(context, health = notesMac.copy(notesEdit = false))
        assertFalse(rig.model.voiceEditAvailable)
        assertNull(rig.model.commanding)
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37], qualifiers = "w411dp-h891dp-mdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class NotesVoiceEditScreenTest {
    @org.junit.Before fun noMotion() {
        android.provider.Settings.Global.putFloat(RuntimeEnvironment.getApplication().contentResolver, android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 0f)
    }

    @get:Rule val compose = createComposeRule()
    private val hold = "Edit notes by voice. Hold, say the change, let go."

    private fun screen(health: Health? = notesMac): NotesModelRig {
        val rig = NotesModelRig(RuntimeEnvironment.getApplication(), health)
        rig.model.edit(TextFieldValue(NOTES))
        compose.setContent { ChirpTheme(false) { NotesScreen(rig.model, rig.model::toggle, {}, {}, {}, {}) } }
        return rig
    }

    @Test fun `pressing the button listens and says to let go`() {
        val rig = screen()
        compose.runOnIdle { rig.model.toggle(); rig.wire.ready(); rig.idle() }
        compose.onNodeWithText("Hold to edit").assertIsDisplayed()
        compose.onNodeWithContentDescription(hold).performTouchInput { down(center) }
        compose.runOnIdle { rig.idle() }
        compose.onNodeWithText("Release to send").assertIsDisplayed()
        compose.onNodeWithText("Cancel").assertIsDisplayed()
        assertEquals("Say the edit…", rig.model.status.notesEnglish())
    }

    @Test fun `holding the button and letting go sends, then Edited and Undo`() {
        val rig = screen()
        compose.runOnIdle { rig.model.toggle(); rig.wire.ready(); rig.idle() }
        rig.api.editAnswers += NotesEditResponse(EDITED, true)
        compose.onNodeWithContentDescription(hold).performTouchInput { down(center); advanceEventTime(NotesVoiceEdit.HOLD_MS + 200); up() }
        compose.runOnIdle { rig.idle() }
        val command = rig.wires[1]
        compose.runOnIdle { command.ready(); rig.idle(); rig.wires.last().ready(); rig.idle(); command.final("remove the pricing section"); rig.idle()
            rig.wires.filter { it !== command && it.stops > 0 && it.finals == 0 }.forEach { it.final("earlier words") }; rig.idle() }
        compose.waitForIdle()
        compose.onNodeWithText("Edited").assertIsDisplayed()
        assertEquals(EDITED, rig.model.document.text)
        compose.onNodeWithText("Undo").performClick()
        compose.runOnIdle { rig.idle() }
        assertEquals(NOTES, rig.model.document.text)
        compose.onNodeWithText("Edited").assertDoesNotExist()
    }

    @Test fun `a tap latches it, the accessibility click sends it and Cancel drops it`() {
        val rig = screen()
        compose.runOnIdle { rig.model.toggle(); rig.wire.ready(); rig.idle() }
        compose.onNodeWithContentDescription(hold).performTouchInput { down(center); advanceEventTime(80); up() }
        compose.runOnIdle { rig.idle() }
        compose.onNodeWithText("Tap to send").assertIsDisplayed()
        compose.onNodeWithText("Cancel").performClick()
        compose.runOnIdle { rig.idle() }
        compose.onNodeWithText("Hold to edit").assertIsDisplayed()
        assertTrue(rig.api.edits.isEmpty())

        // TalkBack's double tap is a click: it starts, and the next one sends.
        compose.onNodeWithContentDescription(hold).performClick()
        compose.runOnIdle { rig.idle() }
        compose.onNodeWithContentDescription("Send the spoken edit").performClick()
        compose.runOnIdle { rig.idle() }
        assertEquals("Editing notes…", rig.model.status.notesEnglish())
    }

    @Test fun `the button is not offered when the Mac cannot edit by voice`() {
        screen(notesMac.copy(notesEdit = false))
        compose.onNodeWithText("Hold to edit").assertDoesNotExist()
    }

    @Test fun `a refusal shows its note under the editor`() {
        val rig = screen()
        compose.runOnIdle { rig.model.toggle(); rig.wire.ready(); rig.idle() }
        rig.api.editAnswers += NotesEditResponse(null, false, false, "refused", "adds_content")
        compose.runOnIdle { rig.command("summarise the meeting") }
        compose.onNodeWithText("Can’t add new content by voice — ask to remove, move, tidy or reword").assertIsDisplayed()
    }

    private fun NotesModelRig.command(words: String) {
        model.command(); idle()
        val command = wire
        command.ready(); idle()
        model.command(); idle()
        wire.ready(); idle()
        command.final(words); idle()
        wires.filter { it !== command && it.stops > 0 && it.finals == 0 }.forEach { it.final("earlier words") }
        idle()
    }
}
