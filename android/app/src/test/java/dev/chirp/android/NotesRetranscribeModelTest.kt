package dev.chirp.android

import android.os.Looper
import androidx.compose.ui.text.input.TextFieldValue
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37])
class NotesRetranscribeModelTest {
    private val context get() = RuntimeEnvironment.getApplication()
    private fun rig(): NotesModelRig {
        RetranscribeGate.owner = null; RetranscribeGate.progress = null; RetranscribeGate.allowed.value = true
        val library = NotesSessions(context, SoftwareHistoryKeys(), encoder = FakeAudioEncoder())
        return NotesModelRig(context, health = notesMac.copy(notesRetranscribe = true), sessions = library, decoder = FakeAudioDecoder()).also { rig ->
            rig.model.document.append(NotesSegment(0, 0.0, "WRONG TEXT"))
            rig.model.edit(TextFieldValue("My own notes")); rig.model.rename("My title"); rig.model.keepSession()
            rig.model.document.addClip(library.saveClip(rig.model.document.uid, 0, 0.0, ByteArray(6400) { 1 })!!)
        }
    }
    @After fun reset() { RetranscribeGate.rebuilds.clear(); RetranscribeGate.owner?.cancelRetranscribe(); RetranscribeGate.owner = null; RetranscribeGate.progress = null; RetranscribeGate.allowed.value = true }

    @Test fun `model applies atomically preserves body edits and persists restore across reopen`() {
        val rig = rig(); val model = rig.model
        model.startRetranscribe(); rig.idle(); rig.wire.ready(); rig.idle()
        assertTrue(model.retranscribing)
        model.edit(TextFieldValue("My later edits"))
        rig.wire.final("new words"); rig.idle()
        assertFalse(model.retranscribing)
        assertEquals("new words", model.document.segments.single().text)
        assertEquals(model.document.toJson().getJSONObject("previousTranscript").toString(), rig.sessions.open(model.document.uid)!!.document.getJSONObject("previousTranscript").toString())
        assertEquals("My later edits", model.field.text)
        assertEquals("My title", model.document.name)
        assertEquals("WRONG TEXT", NotesDocument.fromJson(rig.sessions.open(model.document.uid)!!.document).previousTranscript!!.segments.single().text)
        model.restoreTranscript(); rig.idle()
        assertEquals("WRONG TEXT", model.document.segments.single().text)
        assertEquals("My later edits", model.field.text)
    }

    @Test fun `cancel and off switch leave sealed record byte identical`() {
        val rig = rig(); val model = rig.model
        val file = java.io.File(context.filesDir, "notes/${model.document.uid}.bin")
        for (off in listOf(false, true)) {
            val before = file.readBytes()
            model.startRetranscribe(); rig.idle(); rig.wire.ready(); rig.idle()
            if (off) SettingsStore(context).notesAllowRetranscribe = false else model.cancelRetranscribe()
            rig.idle()
            assertFalse(model.retranscribing)
            assertArrayEquals(before, file.readBytes())
            assertEquals("WRONG TEXT", model.document.segments.single().text)
        }
    }

    @Test fun `rebuild asks before replacing edits and undo preserves user title`() {
        val rig = rig(); val model = rig.model
        model.rebuildChoice = true
        rig.api.answers += NotesStructureResponse("## Rebuilt\n- A new point", true)
        model.startRetranscribe(); rig.idle(); rig.wire.ready(); rig.idle()
        model.edit(TextFieldValue("Edited during re-transcription"))
        rig.wire.final("a new point"); rig.idle()
        assertEquals("Edited during re-transcription", model.field.text)
        assertEquals("## Rebuilt\n- A new point", model.rebuildReview)
        assertTrue(rig.api.structures.last().final)
        model.acceptRebuild(); rig.idle()
        assertEquals("## Rebuilt\n- A new point", model.field.text)
        assertTrue(model.canUndo)
        model.undo(); rig.idle()
        assertEquals("Edited during re-transcription", model.field.text)
        assertEquals("My title", model.document.name)
    }

    @Test fun `all structure windows failing leaves body alone`() {
        val rig = rig(); val model = rig.model; model.rebuildChoice = true
        model.startRetranscribe(); rig.idle(); rig.wire.ready(); rig.idle(); rig.wire.final("new speech"); rig.idle()
        assertEquals("My own notes", model.field.text)
        assertEquals(RetranscribeNotice.RebuildFailed, model.retranscribeNotice)
        assertEquals("Couldn’t rebuild the notes. Transcript updated.", model.retranscribeNotice!!.ui.notesEnglish())
    }

    @Test fun `rebuild review belongs to its note when browsing another document`() {
        val rig = rig(); val model = rig.model; val id = model.document.uid
        model.rebuildReview = "## Reviewed replacement"
        model.newNote(); rig.idle()
        assertNull(model.rebuildReview)
        model.open(id); rig.idle()
        assertEquals("## Reviewed replacement", model.rebuildReview)
        model.acceptRebuild(); rig.idle()
        assertEquals("## Reviewed replacement", model.field.text)
        assertNull(model.rebuildReview)
    }

    @Test fun `interrupted notice appears once after process restart without staging on disk`() {
        SettingsStore(context).notesRetranscribeInterrupted = true
        val one = NotesModelRig(context).model
        assertEquals(RetranscribeNotice.Interrupted, one.retranscribeNotice)
        assertEquals("Re-transcribe was interrupted. Nothing changed.", one.retranscribeNotice!!.ui.notesEnglish())
        assertNull(NotesModelRig(context).model.retranscribeNotice)
    }
}
