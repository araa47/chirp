package dev.chirp.android

import android.Manifest
import android.os.Looper
import android.text.Selection
import android.view.ContextThemeWrapper
import android.view.View
import android.view.inputmethod.BaseInputConnection
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

/** The keyboard side of a dictation past the 120 s cap: each segment's final lands at the caret, the next composes after it. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class LongDictationTest {
    private val controller = Robolectric.buildService(KeepDictationTest.Host::class.java)
    private lateinit var host: KeepDictationTest.Host
    private lateinit var voice: KeyboardDictation
    private lateinit var strip: KeyboardStrip
    private lateinit var capture: ChirpImeServiceTest.FakeCapture
    private val streams = mutableListOf<ChirpImeServiceTest.FakeTransport>()
    private val editor get() = host.editor
    private fun advance(ms: Long) = shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(ms))
    private fun composing() = BaseInputConnection.getComposingSpanStart(editor.buffer) to BaseInputConnection.getComposingSpanEnd(editor.buffer)
    private fun speak(seconds: Double, loud: Boolean) = repeat((seconds * 25).toInt()) {
        capture.frame(ByteArray(1280) { i -> if (!loud) 0 else if (i % 2 == 0) 0x40 else 0x1f })
    }
    private fun rollOver() { speak(DictationSegmenter.MIN_SEGMENT, true); speak(DictationSegmenter.PAUSE_CUT, false); advance(0) }
    private fun final(stream: ChirpImeServiceTest.FakeTransport, text: String) { stream.event(ServerEvent.Final(text, text, false)); advance(0) }
    /** Starts in "Hello.", speaks one segment's partial and rolls into a second segment with its own partial. */
    private fun twoSegments() {
        editor.reset("Hello.", 6, 6); host.info.initialSelStart = 6; host.info.initialSelEnd = 6
        voice.input(host.info, false); voice.toggle(); streams[0].ready()
        streams[0].partial(1, "one"); advance(16)
        assertEquals("Hello. one", editor.text)
        rollOver(); streams[1].ready(); streams[1].partial(1, "two"); advance(16)
    }
    @Before fun setup() {
        controller.create(); host = controller.get()
        shadowOf(RuntimeEnvironment.getApplication()).grantPermissions(Manifest.permission.RECORD_AUDIO, LOCAL_NETWORK_PERMISSION)
        voice = KeyboardDictation(host, learning = EditLearning(host, io = { it() }),
            captureFactory = { frame, _, done -> ChirpImeServiceTest.FakeCapture(frame, done, mutableListOf()).also { capture = it } },
            transportFactory = { _, _, event, failure -> ChirpImeServiceTest.FakeTransport(event, failure, mutableListOf()).also { streams += it } },
            prepare = {}, resync = { _, _ -> },
            pairing = { Pairing.from("https://mac.example.test", "synthetic") }, checkHealth = false)
        strip = KeyboardStrip(ContextThemeWrapper(host, R.style.Theme_Chirp)); voice.attach(strip)
        voice.input(host.info, false); voice.shown()
    }
    @After fun teardown() { voice.destroy(); controller.destroy() }

    @Test fun `each final lands at the caret in order and the next segment composes after it`() {
        twoSegments()
        assertEquals(2, streams.size); assertEquals(CaptureLimit.ROLLING_SECONDS, capture.limitSeconds)
        assertEquals("Hello. one", editor.text) // the second segment waits for the first to land
        assertEquals("Listening…", strip.status.text.toString())
        final(streams[0], "One."); advance(16)
        assertEquals("Hello. One. two", editor.text); assertEquals(11 to 15, composing())
        assertTrue(voice.active); assertEquals(View.GONE, strip.revert.visibility)
        // The editor reports our own commit afterwards, as onUpdateSelection does: that is not the user moving the caret.
        voice.selection(10, 10, 11, 11, -1, -1)
        assertTrue(voice.active); assertEquals(0, streams[1].stops)
        streams[1].partial(2, "two more"); advance(16)
        assertEquals("Hello. One. two more", editor.text)
        voice.toggle(); advance(0); final(streams[1], "Two more.")
        assertFalse(voice.active)
        assertEquals("Hello. One. Two more.", editor.text); assertEquals(-1, composing().first)
        // Undo takes back the last segment only; earlier ones are already the field's text.
        strip.revert.performClick()
        assertEquals("Hello. One.", editor.text)
    }
    @Test fun `a later segment that finishes first waits and both land in order`() {
        TimingLog(host).clear()
        twoSegments(); voice.toggle(); advance(0)
        final(streams[1], "Two.")
        assertEquals("Hello. one", editor.text); assertTrue(voice.active)
        final(streams[0], "One.")
        assertEquals("Hello. One. Two.", editor.text); assertFalse(voice.active)
        // Each utterance logs its own content-free timings.
        assertEquals(listOf(TimingOutcome.FINAL, TimingOutcome.FINAL), TimingLog(host).entries().map { it.outcome })
    }
    @Test fun `cancel discards only what has not landed`() {
        twoSegments(); final(streams[0], "One.")
        strip.cancel.performClick()
        assertFalse(voice.active); assertEquals("Hello. One.", editor.text)
        assertTrue(streams[1].cancelled)
    }
    @Test fun `a failing live segment keeps earlier finals and what it heard`() {
        twoSegments()
        streams[1].failure(); advance(0)
        assertEquals("Hello. one", editor.text); assertTrue(voice.active)
        final(streams[0], "One.")
        assertFalse(voice.active)
        assertEquals("Hello. One. two", editor.text); assertEquals(-1, composing().first)
        assertEquals("Connection lost — kept what I heard", strip.status.text.toString())
    }
    @Test fun `keep listening rolls through silence past ten minutes with no countdown or error, then stops on tap (381)`() {
        SettingsStore(host).apply { continuousListening = true; stopOnPause = true; pauseSeconds = 1.0 }
        editor.reset("", 0, 0); host.info.initialSelStart = 0; host.info.initialSelEnd = 0
        voice.input(host.info, false); voice.toggle(); streams[0].ready()
        assertNull(capture.pauseSeconds); assertEquals(CaptureLimit.UNLIMITED, capture.limitSeconds)
        streams[0].partial(1, "one"); advance(16)
        var readied = 1; var landed = 0
        repeat(700) {
            speak(1.0, loud = false)
            while (readied < streams.size) streams[readied++].ready()
            // Each cut segment finalizes: the first with its words, every later one empty.
            while (landed < streams.size - 1 && streams[landed].stops > 0) { final(streams[landed], if (landed == 0) "One." else ""); landed++ }
            advance(0)
            assertTrue(voice.active); assertEquals("Listening…", strip.status.text.toString())
        }
        assertTrue("${streams.size} segments", streams.size >= 700 / DictationSegmenter.MAX_SEGMENT.toInt())
        assertEquals("One.", editor.text)
        voice.toggle(); advance(0)
        assertEquals(1, streams.last().stops); final(streams.last(), "")
        assertFalse(voice.active); assertEquals("One.", editor.text)
        assertNotEquals("Didn't catch that", strip.status.text.toString())
    }
    @Test fun `keep listening still cancels at once (381)`() {
        SettingsStore(host).continuousListening = true
        twoSegments()
        strip.cancel.performClick()
        assertFalse(voice.active); assertTrue(streams.all { it.closed })
    }
    @Test fun `moving the caret after a hand-off still stops the dictation`() {
        twoSegments(); final(streams[0], "One."); advance(16)
        Selection.setSelection(editor.buffer, 2)
        voice.selection(15, 15, 2, 2, 11, 15); advance(0)
        assertEquals(1, streams[1].stops)
        final(streams[1], "Two.")
        assertEquals("Hello. One. Two.", editor.text); assertEquals(2, editor.caret)
    }
}
