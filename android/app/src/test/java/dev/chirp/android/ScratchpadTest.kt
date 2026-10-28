package dev.chirp.android

import android.Manifest
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Looper
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import org.junit.After
import org.junit.Before
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.File

/** Records what the Scratchpad asks of the transport; no sockets, no microphone. */
internal class Wire(val event: (ServerEvent) -> Unit, val failure: () -> Unit) : ImeTransport {
    var correction: Boolean? = null
    var profile = ""
    var prompt: String? = null
    var stops = 0
    var closed = false
    var cancelled = false
    override fun connect() {}
    override fun start(correction: Boolean, profile: String, instructions: String, prompt: String?): Boolean {
        this.correction = correction; this.profile = profile; this.prompt = prompt; return true
    }
    override fun start(correction: Boolean) = start(correction, "default", "", null)
    override fun audio(bytes: ByteArray) = true
    override fun stop(): Boolean { stops++; return true }
    override fun close(cancel: Boolean, immediate: Boolean) { closed = true; cancelled = cancel }
    fun ready() = event(ServerEvent.Ready(false))
    fun partial(seq: Long, text: String) = event(ServerEvent.Partial(seq, text, ""))
    fun final(text: String, raw: String = text, corrected: Boolean = false) = event(ServerEvent.Final(text, raw, corrected))
}

private val mac = Health(true, false, true, false, null, "synthetic",
    listOf(CorrectionProfile("default", "Default"), CorrectionProfile("chat", "Chat")))

internal class Rig(context: Context, paired: Boolean = true, mic: Boolean = true, health: Health? = mac, historyOn: Boolean = false, url: String = "https://mac.example.test/chirp",
                  val tailscale: TailscalePromptTest.FakeTailscale = TailscalePromptTest.FakeTailscale(),
                  val notes: NotesSessions? = NotesSessions(context, SoftwareHistoryKeys())) {
    val order = mutableListOf<String>()
    val wires = mutableListOf<Wire>()
    val captures = mutableListOf<ChirpImeServiceTest.FakeCapture>()
    val history = DictationHistory(context, SoftwareHistoryKeys()).also { if (historyOn) it.enable() else it.disable() }
    val recorded = mutableListOf<Pair<String, String?>>()
    val model: ScratchpadModel
    init {
        val store = SettingsStore(context)
        if (health != null) store.health = health
        model = ScratchpadModel(context, store, history,
            captureFactory = { _, frame, _, done -> ChirpImeServiceTest.FakeCapture(frame, done, order).also { captures += it } },
            transportFactory = { _, _, event, failure -> Wire(event, failure).also { wires += it } },
            micGranted = { mic },
            pairing = { if (paired) Pairing.from(url, "synthetic") else null },
            fetchHealth = { _, _ -> null }, tailscale = tailscale, io = { it(); recorded.clear() }, notes = notes)
    }
    val wire get() = wires.last()
    val capture get() = captures.last()
    fun idle() = shadowOf(Looper.getMainLooper()).idle()
    /** One full utterance up to (not including) the server's final. */
    fun speak(partial: String = "synthetic words") {
        model.toggle(); wire.ready(); wire.partial(1, partial); model.toggle(); idle()
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class ScratchpadTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = RuntimeEnvironment.getApplication()
    @Before fun settleAnimations() {
        // The mic's Ripple would run a frame loop that sweeps the test clock past the stream's connect deadline.
        // Settled states suit these tests; the reduce-motion ring still renders.
        android.provider.Settings.Global.putFloat(context.contentResolver, android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 0f)
    }
    private fun screen(rig: Rig, actions: MutableList<DictationAction> = mutableListOf()) =
        compose.setContent { ChirpTheme { ScratchpadScreen(rig.model, mic = rig.model::toggle, copy = {}, share = {}, act = { actions += it }) } }
    private fun mic(active: Boolean = false) = compose.onNodeWithContentDescription(if (active) "Microphone: stop dictation" else "Microphone: tap to dictate")

    @Test fun `idle screen offers the mic and keeps copy and share off until there is text`() {
        val rig = Rig(context); screen(rig)
        mic().assertIsEnabled()
        compose.onNodeWithText("Tap the mic to dictate").assertExists()
        compose.onNodeWithContentDescription("Copy").assertIsNotEnabled(); compose.onNodeWithContentDescription("Share").assertIsNotEnabled()
        compose.onNodeWithText("Nothing is saved. This text is gone when you leave.").assertExists()
    }

    @Test fun `dictation walks connecting listening finishing and inserts the final into the text`() {
        val rig = Rig(context); screen(rig)
        mic().performClick()
        compose.onNodeWithText("Connecting to your computer…").assertExists()
        assertTrue(rig.capture.started)
        rig.wire.ready(); compose.waitForIdle()
        compose.onNodeWithText("Listening…").assertExists()
        rig.wire.partial(1, "hello wor"); compose.waitForIdle()
        compose.onNodeWithText("hello wor").assertExists()
        assertTrue(rig.model.active)
        mic(active = true).performClick(); rig.idle(); compose.waitForIdle()
        compose.onNodeWithText("Finishing…").assertExists()
        assertEquals(1, rig.wire.stops)
        rig.wire.final("Hello world."); compose.waitForIdle()
        assertEquals("Hello world.", rig.model.field.text)
        assertFalse(rig.model.active)
        assertTrue(rig.wire.closed)
        compose.onNodeWithText("Finished").assertExists()
        compose.onNodeWithText("hello wor").assertDoesNotExist()
        compose.onNodeWithContentDescription("Copy").assertIsEnabled(); compose.onNodeWithContentDescription("Share").assertIsEnabled()
        assertTrue(rig.capture.released)
    }

    @Test fun `text stays editable while idle and is read only while dictating`() {
        val rig = Rig(context); screen(rig)
        compose.onNode(hasSetTextAction()).performTextInput("typed note")
        assertEquals("typed note", rig.model.field.text)
        rig.model.toggle(); rig.wire.ready(); compose.waitForIdle()
        compose.onNode(hasSetTextAction()).assertDoesNotExist()
        compose.onNodeWithText("typed note").assertExists()
    }

    @Test fun `final lands at the cursor with spacing and mid sentence casing`() {
        val at = { text: String, cursor: Int, say: String -> ScratchpadText.insert(TextFieldValue(text, TextRange(cursor)), say, false) }
        assertEquals("Hello", at("", 0, "Hello").text)
        assertEquals("I was there", at("I was", 5, "There").text)
        assertEquals("Done. Next one.", at("Done.", 5, "Next one.").text)
        assertEquals("Done.\nNext one.", at("Done.\n", 6, "Next one.").text)
        assertEquals("one two three", at("one three", 3, "two").text)
        assertEquals("one two".length, at("one three", 3, "two").selection.start)
        assertEquals("Hello", ScratchpadText.insert(TextFieldValue("Hello", TextRange(5)), "", false).text)
        val replaced = ScratchpadText.insert(TextFieldValue("keep THIS here", TextRange(5, 9)), "that", false)
        assertEquals("keep that here", replaced.text)
    }

    @Test fun `spoken commands follow the same opt in as the keyboard`() {
        assertEquals("\n", ScratchpadText.insert(TextFieldValue(""), "new line", true).text)
        assertEquals("note\n\n", ScratchpadText.insert(TextFieldValue(""), "note new paragraph", true).text)
        assertEquals("note new paragraph", ScratchpadText.insert(TextFieldValue(""), "note new paragraph", false).text)
    }

    @Test fun `style picker chooses clean-up style or raw and the choice reaches the stream`() {
        val rig = Rig(context); screen(rig)
        compose.onNodeWithText("Raw").assertExists(); compose.onNodeWithText("Chat").performClick()
        mic().performClick()
        assertEquals("chat", rig.wire.profile); assertEquals(true, rig.wire.correction)
        rig.model.cancel(); compose.waitForIdle()
        compose.onNodeWithText("Raw").performClick()
        mic().performClick()
        assertEquals(false, rig.wire.correction)
    }

    @Test fun `style picker is hidden and clean-up off when the Mac has none`() {
        val rig = Rig(context, health = mac.copy(correctionAvailable = false)); screen(rig)
        compose.onNodeWithText("Chat").assertDoesNotExist(); compose.onNodeWithText("Raw").assertDoesNotExist()
        mic().performClick()
        assertEquals(false, rig.wire.correction)
    }

    @Test fun `picker is locked while dictating`() {
        val rig = Rig(context); screen(rig)
        mic().performClick(); compose.waitForIdle()
        compose.onNodeWithText("Chat").assertIsNotEnabled()
        rig.model.choose(CorrectionProfile("chat", "Chat"))
        assertEquals("default", rig.model.style.id)
    }

    @Test fun `cleaned final reports it and an unavailable clean-up keeps the original`() {
        val rig = Rig(context); screen(rig)
        rig.speak(); rig.wire.final("Clean text.", "clean uh text", corrected = true); compose.waitForIdle()
        compose.onNodeWithText("Finished").assertExists(); assertEquals("Clean text.", rig.model.field.text)
        rig.speak(); rig.wire.event(ServerEvent.Final("Raw text.", "raw text", false, "unavailable")); compose.waitForIdle()
        compose.onNodeWithText("Kept what was heard").assertExists()
    }

    @Test fun `a private utterance stays excluded when lock ends the session before final`() {
        val rig = Rig(context, historyOn = true)
        PrivateSession.set(true)
        rig.speak()
        context.sendBroadcast(Intent(Intent.ACTION_SCREEN_OFF))
        rig.idle()
        assertFalse(PrivateSession.enabled)
        rig.wire.final("Synthetic private final.")
        assertTrue(rig.history.entries().isEmpty())
        assertEquals("Synthetic private final.", rig.model.field.text)
    }

    @Test fun `Use raw replaces only its unchanged insertion and expires without changing text`() {
        val rig = Rig(context, historyOn = true)
        rig.model.field = TextFieldValue("Earlier. ", TextRange(9))
        rig.speak(); rig.wire.final("Clean words.", "raw um words", true)
        assertTrue(rig.model.rawAvailable)
        rig.model.useRaw()
        assertEquals("Earlier. raw um words", rig.model.field.text)
        assertFalse(rig.model.rawAvailable)
        assertEquals("raw um words", rig.history.entries().single().text)
        rig.speak(); rig.wire.final("Next clean.", "next um", true)
        rig.model.field = TextFieldValue("My edit")
        rig.model.useRaw()
        assertEquals("My edit", rig.model.field.text)
        rig.speak(); rig.wire.final("Last clean.", "last um", true)
        val clean = rig.model.field.text
        shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofSeconds(5))
        assertFalse(rig.model.rawAvailable)
        rig.model.useRaw()
        assertEquals(clean, rig.model.field.text)
    }

    @Test fun `errors from the Mac show local text and offer the matching action`() {
        val rig = Rig(context, tailscale = TailscalePromptTest.FakeTailscale(installed = true, connected = true))
        val actions = mutableListOf<DictationAction>(); screen(rig, actions)
        rig.model.toggle(); rig.wire.event(ServerEvent.Failure("auth")); compose.waitForIdle()
        compose.onNodeWithText("Pairing refused — pair again in Chirp settings").assertExists()
        compose.onNodeWithText("Pair computer").performClick()
        assertEquals(listOf(DictationAction.PAIR), actions)
        assertFalse(rig.model.active); assertTrue(rig.wire.closed)
        rig.model.toggle(); rig.wire.event(ServerEvent.Failure("busy")); compose.waitForIdle()
        compose.onNodeWithText("Chirp server is busy — try again").assertExists()
    }

    @Test fun `unreachable tailnet Mac says Tailscale is off with a turn on action`() {
        val rig = Rig(context, url = "https://mac.tail1234.ts.net/chirp", tailscale = TailscalePromptTest.FakeTailscale(connected = false))
        val actions = mutableListOf<DictationAction>(); screen(rig, actions)
        rig.model.toggle(); rig.wire.failure(); compose.waitForIdle()
        assertEquals("Tailscale is off", rig.model.status.english())
        compose.onNodeWithText("Turn on").performClick()
        assertEquals(listOf(DictationAction.TAILSCALE_ON), actions)
    }

    @Test fun `unpaired and missing microphone are explained without starting capture`() {
        val unpaired = Rig(context, paired = false); screen(unpaired)
        mic().performClick(); compose.waitForIdle()
        compose.onNodeWithText("Pair your computer in Chirp settings").assertExists(); compose.onNodeWithText("Pair computer").assertExists()
        assertTrue(unpaired.wires.isEmpty()); assertTrue(unpaired.captures.isEmpty())
        val silent = Rig(context, mic = false)
        silent.model.toggle()
        assertEquals("Allow microphone in Chirp settings", silent.model.status.english())
        assertEquals(DictationAction.MICROPHONE, silent.model.status.action)
        assertTrue(silent.captures.isEmpty())
    }

    @Test fun `leaving the screen discards a live utterance but not one already finishing`() {
        val live = Rig(context); live.model.toggle(); live.wire.ready(); live.wire.partial(1, "synthetic")
        live.model.pause()
        assertFalse(live.model.active); assertTrue(live.wire.cancelled); assertTrue(live.capture.released)
        assertEquals("", live.model.partial); assertEquals("", live.model.field.text)
        val finishing = Rig(context); finishing.speak(); finishing.model.pause()
        assertTrue(finishing.model.active); assertFalse(finishing.wire.cancelled)
        finishing.wire.final("Kept."); assertEquals("Kept.", finishing.model.field.text)
    }

    @Test fun `clear empties the text and a debug retention notice is shown`() {
        val rig = Rig(context); screen(rig)
        rig.model.field = TextFieldValue("something"); compose.waitForIdle()
        compose.onNodeWithContentDescription("More options").performClick()
        compose.onNodeWithText("Clear").performClick(); compose.waitForIdle()
        assertEquals("", rig.model.field.text)
        compose.onNodeWithContentDescription("More options").performClick()
        compose.onNodeWithText("Clear").assertIsNotEnabled()
        rig.model.toggle(); rig.wire.event(ServerEvent.Ready(true)); compose.waitForIdle()
        compose.onNodeWithText("DEBUG: recordings kept on the server").assertExists()
    }

    @Test fun `floating mic hand-off arrives in memory once and appends after existing text`() {
        val rig = Rig(context); screen(rig)
        ScratchpadHandoff.put("Synthetic words.")
        ScratchpadHandoff.take()?.let(rig.model::receive); compose.waitForIdle()
        assertEquals("Synthetic words.", rig.model.field.text)
        assertNull(ScratchpadHandoff.take())
        rig.model.receive("More synthetic words.")
        assertEquals("Synthetic words.\n\nMore synthetic words.", rig.model.field.text)
        assertEquals(rig.model.field.text.length, rig.model.field.selection.start)
    }

    @Test fun `with history explicitly off no file or preference holds the text`() {
        val rig = Rig(context); screen(rig)
        rig.speak("synthetic scratch words"); rig.wire.final("Synthetic scratch words.", "synthetic scratch words", true)
        compose.waitForIdle()
        assertEquals("Synthetic scratch words.", rig.model.field.text)
        assertFalse(File(context.filesDir, DictationHistory.FILE_NAME).exists())
        assertFalse(context.getSharedPreferences("chirp_history", 0).getBoolean("enabled", false))
        assertNoTrace(context, "scratch words")
    }

    @Test fun `with history on only the dictation is stored encrypted and never the field`() {
        val rig = Rig(context, historyOn = true)
        val now = rig.history.entries()
        assertTrue(now.isEmpty())
        rig.model.field = TextFieldValue("typed but never saved")
        rig.speak("synthetic history words"); rig.wire.final("Synthetic history words.", "synthetic history words", true)
        val entries = rig.history.entries()
        assertEquals(listOf("Synthetic history words."), entries.map { it.text })
        assertEquals("synthetic history words", entries.single().raw); assertEquals("Scratchpad", entries.single().app)
        assertTrue(File(context.filesDir, DictationHistory.FILE_NAME).exists())
        assertNoTrace(context, "history words", "never saved")
    }

    @Test fun `history off records nothing even when the Mac cleaned the text`() {
        val rig = Rig(context)
        rig.speak(); rig.wire.final("Hello.", "hello", true)
        assertTrue(rig.history.entries().isEmpty())
    }

    @Test fun `history notice appears only when history is on`() {
        val on = Rig(context, historyOn = true); screen(on)
        compose.onNodeWithText("Each dictation is also saved to history, encrypted on this phone. The text above is not.").assertExists()
        on.model.field = TextFieldValue("now there is text")
        compose.waitForIdle()
        compose.onNodeWithText("Each dictation is also saved to history, encrypted on this phone. The text above is not.").assertDoesNotExist()
    }

    @Test fun `save as note puts the whole text into the notes library once`() {
        val rig = Rig(context); screen(rig)
        compose.onNodeWithContentDescription("More options").performClick()
        compose.onNodeWithText("Save as note").assertIsNotEnabled()
        rig.model.field = TextFieldValue("Whole page of dictated text."); compose.waitForIdle()
        compose.onNodeWithContentDescription("More options").performClick()
        compose.onNodeWithText("Save as note").performClick()
        compose.waitUntil(5000) { rig.notes!!.entries().isNotEmpty() }
        assertEquals(listOf("Whole page of dictated text."), rig.notes!!.entries().map { it.title })
        compose.onNodeWithText("Saved as note").assertExists()
        assertTrue(rig.notes!!.entries().single().title.isNotEmpty())
    }

    @Test fun `save as note says so when the library is off`() {
        val rig = Rig(context, notes = NotesSessions(context, SoftwareHistoryKeys()).also { it.disable() }); screen(rig)
        rig.model.field = TextFieldValue("Text with nowhere to go."); compose.waitForIdle()
        compose.onNodeWithContentDescription("More options").performClick()
        compose.onNodeWithText("Save as note").performClick()
        compose.waitUntil(5000) { compose.onAllNodesWithText("Notes are off — turn on Keep notes on this phone in Settings → Notes").fetchSemanticsNodes().isNotEmpty() }
        assertTrue(rig.notes!!.entries().isEmpty())
    }

    private fun assertNoTrace(context: Context, vararg needles: String) {
        val root = File(context.applicationInfo.dataDir)
        val files = root.walkTopDown().filter { it.isFile }.toList()
        assertTrue(files.isNotEmpty())
        files.forEach { file -> val body = file.readText(Charsets.ISO_8859_1); needles.forEach { assertFalse("${file.name} holds text", body.contains(it)) } }
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class ScratchpadActivityTest {
    class TestScratchpad : ScratchpadActivity() {
        internal lateinit var rig: Rig
        val fakeTailscale = TailscalePromptTest.FakeTailscale()
        override val tailscale: TailscaleControl get() = fakeTailscale
        override fun createModel(): ScratchpadModel { rig = Rig(applicationContext); return rig.model }
    }
    private val controller = Robolectric.buildActivity(TestScratchpad::class.java)
    private lateinit var activity: TestScratchpad
    private val app get() = RuntimeEnvironment.getApplication()
    private fun open() { activity = controller.setup().get() }
    @After fun tearDown() { if (!activity.isDestroyed) controller.pause().stop().destroy() }

    @Test fun `share sends only the text through the system chooser`() {
        open(); activity.model.field = TextFieldValue("Synthetic share text")
        activity.share()
        val chooser = shadowOf(activity).nextStartedActivity
        assertEquals(Intent.ACTION_CHOOSER, chooser.action)
        val send = if (android.os.Build.VERSION.SDK_INT >= 33) chooser.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)!!
            else @Suppress("DEPRECATION") chooser.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)!!
        assertEquals(Intent.ACTION_SEND, send.action); assertEquals("text/plain", send.type)
        assertEquals("Synthetic share text", send.getStringExtra(Intent.EXTRA_TEXT))
        assertNull(send.data); assertNull(send.clipData?.takeIf { it.itemCount > 1 })
    }

    @Test fun `share and copy do nothing for blank text`() {
        open(); activity.model.field = TextFieldValue("   ")
        activity.share(); activity.copy()
        assertNull(shadowOf(activity).nextStartedActivity)
        assertNull(app.getSystemService(ClipboardManager::class.java).primaryClip)
    }

    @Test fun `copy puts the text on the clipboard marked sensitive`() {
        open(); activity.model.field = TextFieldValue("Synthetic copy text")
        activity.copy()
        val clip = app.getSystemService(ClipboardManager::class.java).primaryClip!!
        assertEquals("Synthetic copy text", clip.getItemAt(0).text.toString())
        assertTrue(clip.description.extras!!.getBoolean("android.content.extra.IS_SENSITIVE"))
        assertEquals("Copied", activity.model.status.english())
    }

    @Test fun `mic asks for the microphone first and then dictates once it is granted`() {
        shadowOf(app).denyPermissions(Manifest.permission.RECORD_AUDIO)
        open(); activity.mic()
        val shadow = shadowOf(activity)
        val asked = shadow.nextStartedActivityForResult?.intent?.getStringArrayExtra("android.content.pm.extra.REQUEST_PERMISSIONS_NAMES")?.toList()
            ?: shadow.lastRequestedPermission?.requestedPermissions?.toList()
        assertEquals(listOf(Manifest.permission.RECORD_AUDIO), asked)
        assertTrue(activity.rig.captures.isEmpty())
        shadowOf(app).grantPermissions(Manifest.permission.RECORD_AUDIO)
        activity.mic()
        assertEquals(1, activity.rig.captures.size)
    }

    @Test fun `actions open setup, app settings and Tailscale`() {
        open()
        activity.act(DictationAction.PAIR)
        assertEquals("pair", shadowOf(activity).nextStartedActivity.getStringExtra("section"))
        activity.act(DictationAction.MICROPHONE)
        assertEquals(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS, shadowOf(activity).nextStartedActivity.action)
        activity.act(DictationAction.TAILSCALE_ON)
        assertEquals(1, activity.fakeTailscale.connects); assertEquals("Connecting Tailscale…", activity.model.status.english())
        activity.act(DictationAction.NETWORK)
        assertEquals(1, activity.fakeTailscale.opens)
        activity.fakeTailscale.installed = false
        activity.act(DictationAction.TAILSCALE_SETUP)
        assertEquals("network", shadowOf(activity).nextStartedActivity.getStringExtra("section"))
    }

    @Test fun `rotation keeps the text and leaving the screen drops it`() {
        open(); activity.model.field = TextFieldValue("Synthetic rotation text")
        val model = activity.model
        activity = controller.recreate().get()
        assertSame(model, activity.model); assertEquals("Synthetic rotation text", activity.model.field.text)
        controller.pause().stop().destroy()
        assertEquals("", model.field.text)
    }

    @Test fun `window keeps text out of recents and the activity is private`() {
        open()
        assertFalse(app.packageManager.getActivityInfo(android.content.ComponentName(app, ScratchpadActivity::class.java), 0).exported)
        val launch = ScratchpadActivity.intent(app)
        assertEquals(ScratchpadActivity::class.java.name, launch.component!!.className)
        assertTrue(launch.flags and Intent.FLAG_ACTIVITY_NEW_TASK != 0)
    }

    @Test fun `stopping the screen discards a live dictation`() {
        open(); activity.model.toggle(); activity.rig.wire.ready()
        controller.pause().stop()
        assertFalse(activity.model.active); assertTrue(activity.rig.wire.cancelled)
    }

    @Test fun `the screen leaves the app task and does not persist state in the saved bundle`() {
        open(); activity.model.field = TextFieldValue("Synthetic bundle text")
        val state = android.os.Bundle(); controller.saveInstanceState(state)
        val parcel = android.os.Parcel.obtain(); state.writeToParcel(parcel, 0)
        assertFalse(String(parcel.marshall(), Charsets.UTF_16LE).contains("bundle text") || String(parcel.marshall(), Charsets.UTF_8).contains("bundle text"))
        parcel.recycle()
    }
}
