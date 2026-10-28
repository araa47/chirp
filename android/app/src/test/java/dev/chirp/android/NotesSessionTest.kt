package dev.chirp.android

import android.Manifest
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.os.Looper
import android.service.quicksettings.Tile
import java.io.ByteArrayOutputStream
import java.io.File
import java.time.Duration
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** Pause/Resume on the recorder: the microphone closes, segments still commit and appends still run. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37])
class NotesPauseTest {
    @Test fun `pause finalizes the segment and closes the microphone, structuring goes on, resume continues the tail`() {
        val rig = NotesRig()
        rig.recorder.start(); rig.wire.ready(); rig.idle()
        rig.speak(5.0)
        rig.recorder.pause(); rig.idle()
        assertEquals(NotesRecorder.State.PAUSED, rig.recorder.state)
        assertTrue("the microphone is closed", rig.captures.single().stopped)
        assertEquals("the segment finalizes as at a cut", 1, rig.wire.stops)
        assertEquals(5.0, rig.recorder.elapsed, 1e-9)
        rig.wire.final("we ship on friday"); rig.idle()
        assertEquals(listOf("we ship on friday"), rig.recorder.document.segments.map { it.text })
        val append = rig.calls.structures.single().first
        assertFalse("paused is not stopped: no final pass", append.final)
        rig.structured("- Ship on Friday")
        assertEquals("- Ship on Friday", rig.recorder.document.tail)
        rig.idle(120)
        assertEquals("the clock stands still while paused", 5.0, rig.recorder.elapsed, 1e-9)
        assertEquals("nothing froze", 0, rig.recorder.document.tailStart)

        rig.recorder.resume(); rig.idle()
        assertEquals(NotesRecorder.State.STARTING, rig.recorder.state)
        assertEquals(2, rig.wires.size); assertEquals(2, rig.captures.size)
        rig.wire.ready(); rig.idle()
        assertEquals(NotesRecorder.State.RECORDING, rig.recorder.state)
        rig.speak(2.0)
        assertEquals(7.0, rig.recorder.elapsed, 1e-9)
        rig.recorder.pause(); rig.idle()
        rig.wire.final("and the beta first"); rig.idle()
        assertEquals(listOf(0.0, 5.0), rig.recorder.document.segments.map { it.offset })
        rig.idle(15)
        assertEquals("the new window continues the same tail", "we ship on friday\nand the beta first", rig.calls.structures.last().first.transcript)
        rig.structured("- Ship on Friday\n- Beta first")

        // Stop from paused finishes as from recording.
        rig.recorder.stop(); rig.idle()
        assertEquals(NotesRecorder.State.STOPPED, rig.recorder.state)
        assertEquals("- Ship on Friday\n- Beta first", rig.recorder.document.text)
    }

    @Test fun `a resume that cannot connect goes back to paused and keeps what came before`() {
        val rig = NotesRig()
        rig.recorder.start(); rig.wire.ready(); rig.idle()
        rig.speak(3.0)
        rig.recorder.pause(); rig.idle()
        val paused = rig.wire
        rig.recorder.resume(); rig.idle()
        rig.wire.error("busy"); rig.idle()
        assertEquals(NotesRecorder.State.PAUSED, rig.recorder.state)
        assertEquals(RecordingFailure.Server.BUSY, rig.recorder.error)
        assertEquals("Chirp server is busy", rig.recorder.error!!.ui.notesEnglish())
        assertTrue(rig.captures.last().stopped)
        paused.final("kept words"); rig.idle()
        assertEquals(listOf("kept words"), rig.recorder.document.segments.map { it.text })
        assertTrue("no gap for the failed resume", rig.recorder.document.segments.none { it.isGap })
        // Stop while a resume is still connecting finishes without a gap either.
        rig.recorder.resume(); rig.idle()
        rig.recorder.stop(); rig.idle()
        rig.calls.structures.forEach { if (!it.second.isCompleted) it.second.complete(NotesStructureResponse("- Kept words", true)) }
        rig.idle()
        assertEquals(NotesRecorder.State.STOPPED, rig.recorder.state)
        assertTrue(rig.recorder.document.segments.none { it.isGap })
    }
}

/** The sealed recovery copy: written while unsaved, restored after the process dies, gone on Save/Discard. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class NotesRecoveryTest {
    private val context get() = RuntimeEnvironment.getApplication()
    private val file get() = File(context.noBackupFilesDir, NotesJournal.FILE_NAME)
    private fun idleFor(seconds: Long) = shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(seconds))

    @Test fun `a killed session comes back stopped and unsaved from an encrypted copy, and Discard deletes it`() {
        val first = NotesModelRig(context, sessions = libraryOff(context))
        first.api.answers += NotesStructureResponse("## Plan\n- Ship it", true)
        first.record().final("synthetic plan words"); first.idle()
        first.model.rename("Weekly sync")
        assertTrue(file.exists())
        val sealed = file.readBytes().toString(Charsets.ISO_8859_1)
        assertFalse("the copy is encrypted", sealed.contains("synthetic") || sealed.contains("Ship") || sealed.contains("Weekly"))

        // A new process: the old model is gone without Save or Discard.
        val second = NotesModelRig(context, keys = first.keys, sessions = libraryOff(context))
        val model = second.model
        assertEquals(NotesRecorder.State.STOPPED, model.state)
        assertEquals("## Plan\n- Ship it", model.field.text)
        assertEquals(listOf("synthetic plan words"), model.document.segments.map { it.text })
        assertEquals("Weekly sync", model.title)
        assertEquals(45.0, model.elapsed, 1e-9)
        assertTrue(model.dirty)
        assertTrue(model.recovered!!.notesEnglish().startsWith("Recovered unsaved notes from"))
        // Record continues the same notes, on the clock where it stopped.
        model.toggle(); second.wire.ready(); second.idle()
        assertEquals(NotesRecorder.State.RECORDING, model.state)
        assertNull(model.recovered)
        model.recorder.cancel(); second.idle()
        model.clear()
        assertFalse("Discard deletes the copy", file.exists())
        assertNull(first.keys.key)
    }

    @Test fun `Save marks the notes saved and removes the copy, later edits bring it back`() {
        val rig = NotesModelRig(context, sessions = libraryOff(context))
        rig.model.edit(androidx.compose.ui.text.input.TextFieldValue("My own line"))
        idleFor(3)
        assertTrue(file.exists())
        val out = ByteArrayOutputStream()
        rig.model.save { out }; rig.idle()
        assertTrue(out.toString(Charsets.UTF_8).contains("My own line"))
        assertFalse(rig.model.dirty)
        assertFalse(file.exists())
        assertEquals(NotesStatus.SAVED, rig.model.status)
        assertEquals("Saved", rig.model.status.notesEnglish())
        rig.model.edit(androidx.compose.ui.text.input.TextFieldValue("My own line, edited"))
        assertTrue(rig.model.dirty)
        idleFor(3)
        assertTrue(file.exists())
        rig.model.save { null }; rig.idle()
        assertTrue(rig.model.dirty)
        assertEquals(NotesStatus.SAVE_FAILED, rig.model.status)
        assertTrue(rig.model.status.notesEnglish().startsWith("Couldn’t save"))
    }

    @Test fun `with the switch off nothing is written and turning it off deletes the copy`() {
        val rig = NotesModelRig(context, sessions = libraryOff(context))
        rig.model.edit(androidx.compose.ui.text.input.TextFieldValue("Typed"))
        idleFor(3)
        assertTrue(file.exists())
        val store = SettingsStore(context)
        store.notesRecovery = false
        NotesJournal(context, rig.keys, store, io = { it() }).delete()
        assertFalse(file.exists())
        rig.model.edit(androidx.compose.ui.text.input.TextFieldValue("Typed more"))
        idleFor(3)
        assertFalse(file.exists())
        assertNull(NotesModelRig(context, keys = rig.keys, sessions = libraryOff(context)).model.recovered)
    }

    @Test fun `a damaged copy is dropped, never restored`() {
        val keys = SoftwareHistoryKeys()
        NotesModelRig(context, keys = keys, sessions = libraryOff(context)).model.edit(androidx.compose.ui.text.input.TextFieldValue("Typed"))
        idleFor(3)
        file.writeBytes(file.readBytes().also { it[it.size - 1] = (it[it.size - 1] + 1).toByte() })
        val model = NotesModelRig(context, keys = keys, sessions = libraryOff(context)).model
        assertNull(model.recovered)
        assertFalse(model.hasContent)
        assertFalse(file.exists())
    }

    @Test fun `the document round-trips through JSON`() {
        val document = NotesDocument(1_800_000_000_000L, "## Heading\n- Point 😀\r\nmore")
        document.append(NotesSegment(0, 0.0, "raw words", "Clean words", corrected = true))
        document.append(NotesSegment.gap(1, 45.0, "timed out"))
        document.append(NotesSegment(2, 90.0, "kept", keptOriginal = true))
        document.name = "Sync: Q4/plan"
        val copy = NotesDocument.fromJson(org.json.JSONObject(document.toJson().toString()))
        assertEquals(document.text, copy.text)
        assertEquals(document.tailStart, copy.tailStart)
        assertEquals(document.segments.map { it.copy(id = 0) }, copy.segments.map { it.copy(id = 0) })
        assertEquals(document.exportMarkdown(), copy.exportMarkdown())
        assertEquals("# Sync: Q4/plan", copy.title())
        assertEquals("Sync  Q4 plan.md", copy.fileName())
    }
}

/** The notification's buttons and the Quick Settings tile reach the session without opening the screen. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class NotesControlsTest {
    class TestTile : NotesTileService() {
        val opened = mutableListOf<Pair<Intent, PendingIntent>>()
        override fun locked() = false
        override fun unlock(then: Runnable) = then.run()
        override fun open(intent: Intent, pending: PendingIntent) { opened += intent to pending }
    }
    private val app get() = RuntimeEnvironment.getApplication()
    private fun posted() = shadowOf(app.getSystemService(NotificationManager::class.java)).getNotification(NotesService.ID)

    @Before fun noSession() { NotesControls.session?.let { NotesControls.release(app, it) } }

    @Test fun `Pause, Resume and Stop from the notification act on the session and the notification follows`() {
        val rig = NotesModelRig(app)
        rig.record()
        assertSame(rig.model, NotesControls.session)
        assertTrue(NotesControls.act(NotesService.ACTION_PAUSE)); rig.idle()
        assertEquals(NotesRecorder.State.PAUSED, rig.model.state)
        assertEquals("Paused", rig.model.status.notesEnglish()); assertEquals("00:45", rig.model.elapsedText.notesEnglish())
        assertEquals("Chirp Notes is paused", posted().extras.getString(Notification.EXTRA_TITLE))
        assertEquals(listOf("Resume", "Command", "Stop"), posted().actions.map { it.title.toString() })
        assertEquals(listOf(true), rig.foreground)
        // The service routes a button to the session.
        Robolectric.buildService(NotesService::class.java, Intent(app, NotesService::class.java).setAction(NotesService.ACTION_RESUME))
            .create().startCommand(0, 1)
        rig.wire.ready(); rig.idle()
        assertEquals(NotesRecorder.State.RECORDING, rig.model.state)
        assertEquals("Chirp Notes is recording", posted().extras.getString(Notification.EXTRA_TITLE))
        assertTrue(NotesControls.act(NotesService.ACTION_STOP)); rig.idle()
        assertEquals(NotesRecorder.State.STOPPING, rig.model.state)
        rig.wires.forEach { it.final("synthetic") }; rig.idle()
        assertEquals(NotesRecorder.State.STOPPED, rig.model.state)
        assertNull(NotesControls.session)
        assertFalse(NotesControls.act(NotesService.ACTION_PAUSE))
    }

    @Test fun `a stale button with no session stops the service it started`() {
        val service = Robolectric.buildService(NotesService::class.java, Intent(app, NotesService::class.java).setAction(NotesService.ACTION_STOP))
            .create().startCommand(0, 1).get()
        assertTrue(shadowOf(service).isStoppedBySelf)
        assertNull(shadowOf(service).lastForegroundNotification)
    }

    @Test fun `the tile opens Notes to record, shows the session and stops it`() {
        val tile = Robolectric.buildService(TestTile::class.java).create().get()
        tile.onClick()
        val (intent, pending) = tile.opened.single()
        assertEquals(NotesActivity::class.java.name, intent.component!!.className)
        assertEquals(NotesService.ACTION_RECORD, intent.action)
        assertTrue(shadowOf(pending).flags and PendingIntent.FLAG_IMMUTABLE != 0)

        val rig = NotesModelRig(app)
        rig.record()
        tile.onClick(); rig.idle()
        assertEquals("a tap while recording stops", NotesRecorder.State.STOPPING, rig.model.state)
        assertEquals(1, tile.opened.size)
    }

    @Test fun `the tile state names recording and paused`() {
        val rig = NotesModelRig(app)
        val tile = Robolectric.buildService(TestTile::class.java).create().get()
        fun shown(): Pair<Int, CharSequence?> { tile.onStartListening(); return tile.qsTile.state to tile.qsTile.subtitle }
        assertEquals(Tile.STATE_INACTIVE to null, shown())
        rig.record()
        assertEquals(Tile.STATE_ACTIVE to "Recording", shown())
        rig.model.pause(); rig.idle()
        assertEquals(Tile.STATE_ACTIVE to "Paused", shown())
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37])
class NotesRecordIntentTest {
    private val app get() = RuntimeEnvironment.getApplication()
    @After fun noSession() { NotesControls.session?.let { NotesControls.release(app, it) } }

    @Test fun `the tile's Record intent starts recording once the screen is visible`() {
        shadowOf(app).grantPermissions(Manifest.permission.RECORD_AUDIO, Manifest.permission.POST_NOTIFICATIONS)
        val controller = Robolectric.buildActivity(NotesActivityTest.TestNotes::class.java,
            NotesActivity.intent(app).setAction(NotesService.ACTION_RECORD))
        val activity = controller.setup().get()
        assertEquals(1, activity.rig.wires.size)
        assertEquals(NotesRecorder.State.STARTING, activity.model.state)
        assertNull("handled once", activity.intent.action)
        activity.model.recorder.cancel()
        controller.pause().stop().destroy()
    }
}
