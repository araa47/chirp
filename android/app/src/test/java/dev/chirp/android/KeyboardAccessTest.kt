package dev.chirp.android

import android.Manifest
import android.os.Looper
import android.text.InputType
import android.view.ContextThemeWrapper
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
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
import java.time.Duration

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class KeyboardAccessTest {
    internal class FakeCues(context: android.content.Context) : Cues(context, {}) {
        val played = mutableListOf<Cue>()
        override fun play(cue: Cue) { played += cue }
    }
    private val controller = Robolectric.buildService(KeyboardDictationTest.Host::class.java)
    private lateinit var host: KeyboardDictationTest.Host
    private lateinit var voice: KeyboardDictation
    private lateinit var strip: KeyboardStrip
    private lateinit var stream: ChirpImeServiceTest.FakeTransport
    private lateinit var cues: FakeCues
    private lateinit var capture: ChirpImeServiceTest.FakeCapture
    private val chord = HardwareShortcut.Action.TOGGLE
    private fun advance(ms: Long) = shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(ms))
    private fun descendants(root: View): List<View> = listOf(root) + if (root is ViewGroup)
        (0 until root.childCount).flatMap { descendants(root.getChildAt(it)) } else emptyList()
    private fun listen() { assertTrue(voice.hardware(chord)); stream.ready() }
    private fun finish(corrected: Boolean = false) { assertTrue(voice.hardware(chord)); advance(0); stream.final(corrected) }
    @Before fun setup() {
        controller.create(); host = controller.get()
        shadowOf(RuntimeEnvironment.getApplication()).grantPermissions(Manifest.permission.RECORD_AUDIO, LOCAL_NETWORK_PERMISSION)
        cues = FakeCues(host)
        voice = KeyboardDictation(host, learning = EditLearning(host, io = { it() }),
            captureFactory = { frame, _, done -> ChirpImeServiceTest.FakeCapture(frame, done, mutableListOf()).also { capture = it } },
            transportFactory = { _, _, event, failure -> ChirpImeServiceTest.FakeTransport(event, failure, mutableListOf()).also { stream = it } },
            prepare = {}, resync = { _, _ -> }, pairing = { Pairing.from("https://mac.example.test", "synthetic") },
            checkHealth = false, cues = cues)
        strip = KeyboardStrip(ContextThemeWrapper(host, R.style.Theme_Chirp)); voice.attach(strip)
        voice.input(host.info, false)
    }
    @After fun teardown() { voice.destroy(); controller.destroy() }

    @Test fun `chord starts and stops dictation even before the input view was shown`() {
        listen(); assertTrue(voice.active)
        stream.partial(); advance(16); assertEquals("synthetic", host.editor.composing)
        finish(); assertFalse(voice.active); assertEquals("Synthetic.", host.editor.committed)
    }
    @Test fun `Esc cancels while listening and is left alone otherwise`() {
        assertFalse(voice.hardware(HardwareShortcut.Action.CANCEL))
        listen(); stream.partial(); advance(16)
        assertTrue(voice.hardware(HardwareShortcut.Action.CANCEL)); assertFalse(voice.active)
        assertEquals("", host.editor.composing); stream.final(); assertEquals("", host.editor.committed)
        assertFalse(voice.hardware(HardwareShortcut.Action.CANCEL))
    }
    @Test fun `chord is ignored in password fields`() {
        host.info.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
        voice.input(host.info, false)
        assertFalse(voice.hardware(chord)); assertFalse(voice.active)
        assertTrue(cues.played.isEmpty()); assertEquals("", host.editor.composing)
    }
    @Test fun `chord while finishing does nothing`() {
        listen(); assertTrue(voice.hardware(chord)); advance(0)
        assertTrue(voice.hardware(chord)); assertEquals(1, stream.stops)
    }
    @Test fun `settings default to chord on, cues off and larger mic off`() {
        val store = SettingsStore(host)
        assertTrue(store.hardwareShortcut); assertFalse(store.soundCues); assertFalse(store.largerMic)
    }

    @Test fun `cues are silent by default and follow start stop inserted`() {
        listen(); finish(); assertTrue(cues.played.isEmpty())
        SettingsStore(host).soundCues = true
        listen(); finish()
        assertEquals(listOf(Cue.START, Cue.STOP, Cue.INSERTED), cues.played)
    }
    @Test fun `cue plays for server errors and setup errors but not for cancel`() {
        SettingsStore(host).soundCues = true
        listen(); voice.cancel(StatusLine.CANCELLED); assertEquals(listOf(Cue.START), cues.played)
        listen(); stream.event(ServerEvent.Failure("engine")); assertTrue(Cue.ERROR in cues.played)
        cues.played.clear()
        shadowOf(RuntimeEnvironment.getApplication()).denyPermissions(Manifest.permission.RECORD_AUDIO)
        voice.hardware(chord); assertEquals(listOf(Cue.ERROR), cues.played)
    }

    @Test fun `status is silent while listening and one announcement is spoken per final`() {
        listen(); stream.partial(); advance(16)
        assertEquals(View.ACCESSIBILITY_LIVE_REGION_NONE, strip.status.accessibilityLiveRegion)
        assertTrue(voice.hardware(chord)); advance(0)
        assertEquals(View.ACCESSIBILITY_LIVE_REGION_NONE, strip.status.accessibilityLiveRegion)
        stream.final()
        assertEquals(View.ACCESSIBILITY_LIVE_REGION_POLITE, strip.status.accessibilityLiveRegion)
        assertEquals("Inserted, 1 word", strip.status.contentDescription.toString())
        assertEquals(1, descendants(strip).count { it.accessibilityLiveRegion != View.ACCESSIBILITY_LIVE_REGION_NONE })
        advance(5000); assertFalse(strip.status.contentDescription.toString().startsWith("Inserted"))
    }
    @Test fun `time limit countdown is still spoken while listening`() {
        listen(); stream.partial(); advance(16)
        assertEquals(View.ACCESSIBILITY_LIVE_REGION_NONE, strip.status.accessibilityLiveRegion)
        capture.countdown!!(15); advance(0)
        assertEquals(View.ACCESSIBILITY_LIVE_REGION_POLITE, strip.status.accessibilityLiveRegion)
        assertEquals("Listening… · 15 s left", strip.status.contentDescription.toString())
        assertTrue(voice.hardware(chord)); advance(0)
        assertEquals(View.ACCESSIBILITY_LIVE_REGION_NONE, strip.status.accessibilityLiveRegion)
    }
    @Test fun `cleaned final announces use raw once and the chip is not a second live region`() {
        listen(); finish(corrected = true)
        assertEquals("Polished, Use raw available", strip.status.contentDescription.toString())
        assertEquals(View.VISIBLE, strip.raw.visibility)
        assertEquals(View.ACCESSIBILITY_LIVE_REGION_NONE, strip.raw.accessibilityLiveRegion)
        assertEquals(View.ACCESSIBILITY_LIVE_REGION_NONE, strip.revert.accessibilityLiveRegion)
        voice.beforeEdit(); assertFalse(strip.status.contentDescription.toString().startsWith("Polished"))
    }
    @Test fun `announcement counts words in the final`() {
        listen(); assertTrue(voice.hardware(chord)); advance(0)
        stream.event(ServerEvent.Final("One two three.", "one two three", false))
        assertEquals("Inserted, 3 words", strip.status.contentDescription.toString())
    }

    @Test fun `strip controls keep at least 48 dp touch width and the prompt button fills the row`() {
        val min = host.dp(48)
        for (control in listOf(strip.cancel, strip.history, strip.mic, strip.raw)) assertTrue(control.layoutParams.width >= min)
        assertEquals(ViewGroup.LayoutParams.MATCH_PARENT, strip.action.layoutParams.height)
        assertTrue(strip.action.minWidth >= min)
    }
}
