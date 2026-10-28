package dev.chirp.android

import android.Manifest
import android.app.Notification
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.os.Looper
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.lifecycle.viewmodel.initializer
import java.io.File
import org.junit.After
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Structure calls answered from a list; reorganize answers "already tidy". Blocking, like the HTTP client. */
internal class ScriptedNotesApi : NotesApi {
    val structures = mutableListOf<NotesStructureRequest>()
    val answers = ArrayDeque<NotesStructureResponse>()
    override fun structure(request: NotesStructureRequest): NotesStructureResponse {
        structures += request; return answers.removeFirstOrNull() ?: NotesStructureResponse.failed("timeout")
    }
    val reorganizations = mutableListOf<NotesReorganizeRequest>()
    override fun reorganize(request: NotesReorganizeRequest): NotesReorganizeResponse {
        reorganizations += request; return NotesReorganizeResponse(request.notes, true, false)
    }
    val edits = mutableListOf<NotesEditRequest>()
    val editAnswers = ArrayDeque<NotesEditResponse>()
    override fun edit(request: NotesEditRequest): NotesEditResponse {
        edits += request; return editAnswers.removeFirstOrNull() ?: NotesEditResponse.failed("timeout")
    }
}

/** A library that is switched off, so a test sees only the recovery copy. */
internal fun libraryOff(context: Context) = NotesSessions(context, SoftwareHistoryKeys()).apply { disable() }

internal class NotesModelRig(context: Context, health: Health? = notesMac, paired: Boolean = true, val keys: SoftwareHistoryKeys = SoftwareHistoryKeys(),
                             val sessions: NotesSessions = NotesSessions(context, SoftwareHistoryKeys()),
                             voices: (VoiceAction?) -> SavedVoices = { SavedVoices(true, "synthetic", emptyList()) }, mic: Boolean = true, decoder: AudioDecoder = MediaCodecAacDecoder(), server: String = "mac.example.test") {
    val wires = mutableListOf<NotesWire>()
    val captures = mutableListOf<FakeNotesCapture>()
    val foreground = mutableListOf<Boolean>()
    val api = ScriptedNotesApi()
    val model: NotesModel
    init {
        val store = SettingsStore(context)
        if (health != null) store.health = health
        model = NotesModel(context, store,
            captureFactory = { frame, _, done -> FakeNotesCapture(frame, done).also { captures += it } },
            transportFactory = { _, _, event, failure -> NotesWire(event, failure).also { wires += it } },
            apiFactory = { _, _ -> api }, micGranted = { mic },
            pairing = { if (paired) Pairing.from("https://$server/chirp", "synthetic") else null },
            fetchHealth = { _, _ -> null }, voicesRequest = { _, _, action -> voices(action) }, tailscale = TailscalePromptTest.FakeTailscale(),
            foreground = { foreground += it }, io = { it() }, journal = NotesJournal(context, keys, store, io = { it() }),
            sessions = sessions, background = { it() }, audioWork = { it() }, audioDecoder = decoder)
    }
    val wire get() = wires.last()
    fun idle() = shadowOf(Looper.getMainLooper()).idle()
    /** One 45 s segment from Record, cut to a fresh socket; returns the finished segment's socket. */
    fun record(): NotesWire {
        model.toggle(); wire.ready(); idle()
        repeat(1125) { model.recorder.handleFrame(ByteArray(1280), 0.1f) }
        wire.ready(); idle()
        return wires[wires.size - 2]
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class NotesModelTest {
    private val context get() = RuntimeEnvironment.getApplication()

    @Test fun `recording runs the foreground service from Record until the notes are final`() {
        val rig = NotesModelRig(context)
        rig.api.answers += NotesStructureResponse("## Plan\n- Ship it", true)
        val first = rig.record()
        assertEquals(listOf(true), rig.foreground)
        assertEquals("Listening…", rig.model.status)
        first.final("we will ship it"); rig.idle()
        assertEquals("## Plan\n- Ship it", rig.model.field.text)
        rig.model.toggle(); rig.idle()
        assertEquals(listOf(true), rig.foreground)
        rig.wire.final("and that is all"); rig.idle()
        assertEquals(NotesRecorder.State.STOPPED, rig.model.state)
        assertEquals(listOf(true, false), rig.foreground)
        assertTrue(rig.model.export().contains("**[00:00:45]** and that is all"))
    }

    @Test fun `an AI update keeps the caret where the user is typing`() {
        val rig = NotesModelRig(context)
        rig.model.edit(TextFieldValue("My line", TextRange(2)))
        rig.model.focused = true
        rig.api.answers += NotesStructureResponse("- Point one", true)
        rig.record().final("point one"); rig.idle()
        assertEquals("My line\n\n- Point one", rig.model.field.text)
        assertEquals(TextRange(2), rig.model.field.selection)
        // Typing inside the AI tail makes it the user's: a later answer starts a new tail after it.
        val end = rig.model.field.text.length
        rig.model.edit(TextFieldValue(rig.model.field.text + "!", TextRange(end + 1)))
        assertEquals(rig.model.document.text.length, rig.model.document.tailStart)
    }

    @Test fun `leaving the screen stops a recording and the service with it`() {
        val rig = NotesModelRig(context)
        rig.record()
        val store = androidx.lifecycle.ViewModelStore()
        androidx.lifecycle.ViewModelProvider(store, androidx.lifecycle.viewmodel.viewModelFactory {
            initializer { rig.model } })[NotesModel::class.java]
        store.clear()
        assertEquals(listOf(true, false), rig.foreground)
        assertTrue(rig.wires.all { it.closed })
        assertTrue(rig.captures.single().stopped)
    }

    @Test fun `without a pairing Record explains instead of starting`() {
        val rig = NotesModelRig(context, paired = false)
        rig.model.toggle()
        assertEquals("Pair your computer in Chirp settings", rig.model.status)
        assertEquals(DictationAction.PAIR, statusOf(rig.model.status).action)
        assertTrue(rig.wires.isEmpty())
    }

    @Test fun `structuring that would leave the Mac is off until the user turns it on`() {
        val rig = NotesModelRig(context, health = notesMac.copy(correctionLeavesMachine = true, correctionHost = "helper.example.test"))
        assertFalse(rig.model.structureEnabled)
        assertEquals("helper.example.test", rig.model.structureHost)
        assertEquals(Structuring.Off(StructuringOff.DISABLED), rig.model.structuring)
        rig.model.setStructure(true)
        assertEquals(Structuring.Idle, rig.model.structuring)
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class NotesActivityTest {
    class TestNotes : NotesActivity() {
        internal lateinit var rig: NotesModelRig
        override val tailscale: TailscaleControl = TailscalePromptTest.FakeTailscale()
        override fun createModel(): NotesModel { rig = NotesModelRig(applicationContext); return rig.model }
    }
    private val app get() = RuntimeEnvironment.getApplication()
    private val controller = Robolectric.buildActivity(TestNotes::class.java)
    private lateinit var activity: TestNotes
    private fun open() { activity = controller.setup().get() }
    @After fun tearDown() { if (!activity.isDestroyed) controller.pause().stop().destroy() }

    @Test fun `the notification's Stop finishes the recording, and copy exports Markdown marked sensitive`() {
        shadowOf(app).grantPermissions(Manifest.permission.RECORD_AUDIO, Manifest.permission.POST_NOTIFICATIONS)
        open()
        activity.record()
        activity.rig.wire.ready(); activity.rig.idle()
        assertTrue(activity.model.recording)
        controller.newIntent(NotesActivity.intent(app).setAction(NotesService.ACTION_STOP))
        activity.rig.idle()
        assertEquals(NotesRecorder.State.STOPPING, activity.model.state)
        activity.rig.wire.final("synthetic words"); activity.rig.idle()
        assertEquals(NotesRecorder.State.STOPPED, activity.model.state)
        activity.copy()
        val clip = app.getSystemService(ClipboardManager::class.java).primaryClip!!
        assertTrue(clip.getItemAt(0).text.toString().contains("## Transcript\n\n**[00:00:00]** synthetic words"))
        assertTrue(clip.description.extras!!.getBoolean("android.content.extra.IS_SENSITIVE"))
    }

    @Test fun `back while recording keeps it running in the background`() {
        shadowOf(app).grantPermissions(Manifest.permission.RECORD_AUDIO, Manifest.permission.POST_NOTIFICATIONS)
        open(); activity.record(); activity.rig.wire.ready(); activity.rig.idle()
        activity.leave(false)
        assertFalse(activity.isFinishing)
        assertTrue(activity.model.recording)
    }

    @Test fun `record asks for the microphone first`() {
        shadowOf(app).denyPermissions(Manifest.permission.RECORD_AUDIO)
        open(); activity.record()
        assertTrue(activity.rig.wires.isEmpty())
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37])
class NotesServiceTest {
    @Test fun `the service is a microphone foreground service whose notification has no notes text`() {
        val app = RuntimeEnvironment.getApplication()
        val service = Robolectric.buildService(NotesService::class.java).create().startCommand(0, 1).get()
        val shadow = shadowOf(service)
        assertFalse(shadow.isStoppedBySelf)
        assertEquals(ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE, service.foregroundServiceType)
        val notification = shadow.lastForegroundNotification!!
        assertEquals("Chirp Notes is recording", notification.extras.getString(Notification.EXTRA_TITLE))
        assertNull(notification.extras.getCharSequence(Notification.EXTRA_TEXT))
        assertTrue(notification.flags and Notification.FLAG_ONGOING_EVENT != 0)
        assertEquals(Notification.VISIBILITY_PUBLIC, notification.visibility)
        assertEquals(listOf("Pause", "Stop"), notification.actions.map { it.title.toString() })
        // The buttons reach the session through the running service, without opening the screen.
        for ((action, expected) in notification.actions.zip(listOf(NotesService.ACTION_PAUSE, NotesService.ACTION_STOP))) {
            val pending = shadowOf(action.actionIntent)
            assertTrue(pending.isServiceIntent)
            assertEquals(expected, pending.savedIntent.action)
            assertEquals(NotesService::class.java.name, pending.savedIntent.component?.className)
        }
        assertEquals(NotesActivity::class.java.name, shadowOf(notification.contentIntent).savedIntent.component?.className)
        NotesService.set(app, true)
        assertEquals(NotesService::class.java.name, shadowOf(app).nextStartedService.component?.className)
        NotesService.set(app, false)
        assertEquals(NotesService::class.java.name, shadowOf(app).nextStoppedService.component?.className)
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class NotesRenderTest {
    @org.junit.Before fun noMotion() {
        android.provider.Settings.Global.putFloat(RuntimeEnvironment.getApplication().contentResolver, android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 0f)
    }

    @get:Rule val compose = createComposeRule()

    private fun render(width: String) {
        val output = File(System.getProperty("chirp.screenshots")).apply { mkdirs() }
        val rig = NotesModelRig(RuntimeEnvironment.getApplication())
        val dark = mutableStateOf(false)
        // A fixed name: the default title is the start time, which would change every capture.
        fun name() = rig.model.rename("Launch sync")
        name()
        compose.setContent { ChirpTheme(dark.value) { NotesScreen(rig.model, rig.model::toggle, {}, {}, {}, {}) } }
        fun shot(name: String) {
            // Let the last tap's ripple fade before the capture.
            compose.mainClock.advanceTimeBy(2000); compose.waitForIdle()
            val target = if (name == "transcript") compose.onNode(isRoot() and hasAnyDescendant(hasText("Show raw"))) else compose.onRoot()
            val bitmap = notesScreenshot(target)
            File(output, "notes-$width-$name-${if (dark.value) "dark" else "light"}.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
        val notes = NotesStructureResponse("## Launch plan\n- Beta goes to **ten** design partners first\n  - Then open the waitlist\n" +
            "- **Decision:** Ship the beta on Friday\n\n## Follow-ups\n- [x] Book the review room\n- [ ] Draft the invite email\n" +
            "- [ ] Check pricing with finance\n- **Question:** Do we need a waitlist?", true)
        for (night in listOf(false, true)) {
            rig.api.answers += notes
            compose.runOnIdle { dark.value = night }
            shot("idle")
            compose.runOnIdle {
                rig.record().final("Synthetic example: the beta goes to ten design partners first, and we ship it on Friday.")
                rig.wire.partial("Someone should draft the invite email")
            }
            shot("recording")
            compose.onNodeWithContentDescription("Organize").assertIsDisplayed().assertIsEnabled()
            shot("organize-toolbar")
            compose.runOnIdle { rig.model.command(); rig.idle(); rig.wire.ready(); rig.wire.partial("remove the question about the waitlist"); rig.idle() }
            shot("command")
            compose.runOnIdle {
                val command = rig.wire
                val shorter = rig.model.document.text.lines().dropLast(1).joinToString("\n")
                rig.api.editAnswers += NotesEditResponse(shorter, true)
                rig.model.command(); rig.idle(); rig.wire.ready(); rig.idle()
                command.final("remove the question about the waitlist"); rig.idle()
                rig.wires.filter { it !== command && it.stops > 0 && it.finals == 0 }.forEach { it.final("later words") }; rig.idle()
            }
            shot("edited")
            compose.runOnIdle { rig.model.pause(); rig.idle() }
            shot("paused")
            compose.onNodeWithContentDescription("Edit notes").performClick()
            shot("editing")
            compose.onNodeWithText("Done").performClick()
            if (width == "cover") { compose.onNodeWithText("Transcript").performClick(); shot("transcript"); compose.onNodeWithContentDescription("Close transcript").performClick() }
            compose.runOnIdle { rig.model.recorder.cancel(); rig.model.clear(); name() }
        }
    }

    @Test @Config(qualifiers = "w411dp-h891dp-mdpi") fun `render notes on the cover screen in light and dark`() = render("cover")
    @Test @Config(qualifiers = "w832dp-h749dp-land-mdpi") fun `render notes side by side on the inner screen in light and dark`() = render("inner")

    @Test @Config(qualifiers = "w360dp-h740dp-mdpi") fun `render the recording dock at twice the font size`() = largeText("cover")
    @Test @Config(qualifiers = "w840dp-h900dp-mdpi") fun `render the unfolded dock at twice the font size`() = largeText("inner")

    private fun largeText(width: String) {
        RuntimeEnvironment.setFontScale(2f)
        val output = File(System.getProperty("chirp.screenshots")).apply { mkdirs() }
        val rig = NotesModelRig(RuntimeEnvironment.getApplication())
        val dark = mutableStateOf(false)
        compose.setContent { ChirpTheme(dark.value) { NotesScreen(rig.model, rig.model::toggle, {}, {}, {}, {}) } }
        rig.api.answers += NotesStructureResponse("## Launch plan\n- [ ] Draft the invite email", true)
        fun shot(name: String) {
            compose.mainClock.advanceTimeBy(2000); compose.waitForIdle()
            val target = if (name == "transcript") compose.onNode(isRoot() and hasAnyDescendant(hasText("Show raw"))) else compose.onRoot()
            val bitmap = notesScreenshot(target)
            File(output, "notes-$width-font-200-$name-${if (dark.value) "dark" else "light"}.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
        for (night in listOf(false, true)) {
            compose.runOnIdle { dark.value = night }
            compose.runOnIdle { rig.record().final("Synthetic example at twice the font size."); rig.wire.partial("Someone should draft the invite email") }
            shot("recording")
            compose.runOnIdle { rig.model.pause(); rig.idle() }
            shot("paused")
            val dock = compose.onNodeWithTag("notes-recording-dock").fetchSemanticsNode().boundsInRoot
            for (label in listOf("Resume recording notes", "Stop recording notes")) {
                val control = compose.onNodeWithContentDescription(label)
                control.assertIsDisplayed().assertIsEnabled()
                val bounds = control.fetchSemanticsNode().boundsInRoot
                assertTrue("$label inside dock", bounds.left >= dock.left && bounds.right <= dock.right && bounds.bottom <= dock.bottom)
                assertTrue("$label has 48dp target", bounds.height >= 48 && bounds.width >= 48)
            }
            // Hold to edit keeps its own full-size target beside or above the pill, never under it.
            val command = compose.onNodeWithContentDescription("Edit notes by voice. Hold, say the change, let go.").fetchSemanticsNode().boundsInRoot
            assertFalse("Hold to edit clear of the pill", command.overlaps(dock))
            assertTrue("Hold to edit has 48dp height", command.height >= 48)
            compose.onNodeWithContentDescription("Resume recording notes").performClick()
            assertTrue(rig.model.recording)
            compose.onNodeWithText("Transcript").performClick()
            shot("transcript")
            compose.onNodeWithContentDescription("Close transcript").performClick()
            compose.onNodeWithContentDescription("Stop recording notes").performClick()
            compose.runOnIdle { rig.model.recorder.cancel(); rig.model.clear() }
        }
    }
}
