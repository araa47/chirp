package dev.chirp.android

import android.Manifest
import android.inputmethodservice.InputMethodService
import android.os.Looper
import android.speech.SpeechRecognizer
import android.view.ContextThemeWrapper
import android.view.View
import android.view.inputmethod.EditorInfo
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

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class PhoneFallbackTest {
    class Host : InputMethodService() {
        val editor = ChirpImeServiceTest.Editor()
        val info = EditorInfo().apply { inputType = android.text.InputType.TYPE_CLASS_TEXT; initialSelStart = 0; initialSelEnd = 0 }
        override fun getCurrentInputConnection() = editor.connection
        override fun getCurrentInputEditorInfo() = info
    }
    /** Holds the "microphone" from start until a result, an error or cancel, like the platform recogniser. */
    internal class FakeRecognizer : PhoneRecognizer {
        var listener: PhoneRecognizer.Listener? = null
        var pauseMs: Long? = null
        var listening = false
        var stops = 0
        var cancels = 0
        override fun start(listener: PhoneRecognizer.Listener, pauseMs: Long?) { this.listener = listener; this.pauseMs = pauseMs; listening = true }
        override fun stop() { stops++ }
        override fun cancel() { cancels++; listening = false }
        fun partial(text: String) = listener!!.partial(text)
        fun final(text: String) { listening = false; listener!!.final(text) }
        fun error(code: Int) { listening = false; listener!!.error(code) }
    }
    private class Recorder : HistoryRecorder {
        val entries = mutableListOf<Pair<String, Boolean>>()
        override fun record(text: String, raw: String?, info: EditorInfo?, partial: Boolean): String { entries += text to partial; return "id${entries.size}" }
        override fun usedRaw(id: String) = Unit
    }
    private val controller = Robolectric.buildService(Host::class.java)
    private lateinit var host: Host
    private lateinit var voice: KeyboardDictation
    private lateinit var strip: KeyboardStrip
    private lateinit var stream: ChirpImeServiceTest.FakeTransport
    private val recognizers = mutableListOf<FakeRecognizer>()
    private val recorder = Recorder()
    private var transports = 0
    private var enabled = true
    private var available = true
    private val recognizer get() = recognizers.last()
    private fun advance(ms: Long) = shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(ms))
    private fun tap() { voice.toggle(); advance(0) }
    private fun keyboard(prewarm: Boolean = true) {
        voice = KeyboardDictation(host, learning = EditLearning(host, io = { it() }),
            captureFactory = { frame, _, done -> ChirpImeServiceTest.FakeCapture(frame, done, mutableListOf()) },
            transportFactory = { _, _, event, failure -> transports++; ChirpImeServiceTest.FakeTransport(event, failure, mutableListOf()).also { stream = it } },
            prepare = {}, resync = { _, _ -> }, pairing = { Pairing.from("https://mac.example.test/chirp", "synthetic") }, checkHealth = false,
            history = recorder, tailscale = TailscalePromptTest.FakeTailscale(connected = true),
            policy = PrewarmPolicy().apply { if (prewarm) dictated(null) },
            fallback = PhoneFallback({ enabled }, { available }, { FakeRecognizer().also { recognizers += it } }, provider = "Synthetic Speech"))
        strip = KeyboardStrip(ContextThemeWrapper(host, R.style.Theme_Chirp)); voice.attach(strip)
        voice.input(host.info, false); voice.shown()
    }
    /** The prewarm fails for a reachability reason: the Mac is now known to be offline. */
    private fun macOffline() { stream.failureKind = ConnectionFailure.Kind.DNS; stream.failure(); advance(0) }
    private fun assertChip(shown: Boolean) {
        assertEquals(if (shown) View.VISIBLE else View.GONE, strip.style.visibility)
        if (shown) {
            assertEquals("on phone", strip.style.text.toString())
            assertEquals("Recognised on this phone by Synthetic Speech, not your computer", strip.style.contentDescription.toString())
        }
    }
    @Before fun setup() {
        controller.create(); host = controller.get()
        shadowOf(RuntimeEnvironment.getApplication()).grantPermissions(Manifest.permission.RECORD_AUDIO)
    }
    @After fun teardown() { if (::voice.isInitialized) voice.destroy(); controller.destroy() }

    @Test fun `the setting is off by default and the decision needs it, an on-device recogniser and a reachability failure`() {
        assertFalse(SettingsStore(host).phoneFallback)
        val fallback = PhoneFallback({ enabled }, { available }, { FakeRecognizer() })
        assertTrue(fallback.handsOver(ConnectionFailure.Kind.DOWN, moved = false))
        assertTrue(fallback.handsOver(ConnectionFailure.Kind.DNS, moved = false))
        assertTrue(fallback.handsOver(ConnectionFailure.Kind.OTHER, moved = false))
        assertFalse("TLS means the Mac answered", fallback.handsOver(ConnectionFailure.Kind.TLS, moved = false))
        assertFalse(fallback.handsOver(null, moved = false))
        assertFalse(fallback.handsOver(ConnectionFailure.Kind.DOWN, moved = true))
        enabled = false; assertFalse(fallback.usable()); assertFalse(fallback.handsOver(ConnectionFailure.Kind.DOWN, moved = false))
        enabled = true; available = false; assertFalse(fallback.usable())
        assertEquals("Recognised on this phone by the phone's own speech service, not your computer", fallback.disclosure(english))
    }
    @Test fun `a known-offline Mac dictates on the phone with raw text, an on-phone chip and history`() {
        keyboard(); macOffline(); val before = transports
        tap()
        assertTrue(voice.active); assertEquals(before, transports); assertEquals(1, recognizers.size)
        assertTrue(recognizer.listening); assertNull(recognizer.pauseMs)
        assertEquals("Listening on phone…", strip.status.text.toString()); assertChip(true)
        recognizer.partial("synthetic words"); advance(16)
        assertEquals("synthetic words", host.editor.composing)
        tap(); assertEquals(1, recognizer.stops); assertEquals("Finishing on phone…", strip.status.text.toString())
        recognizer.final("synthetic words here"); advance(0)
        assertFalse(voice.active); assertFalse(recognizer.listening)
        assertEquals("synthetic words here", host.editor.committed)
        assertEquals(listOf("synthetic words here" to false), recorder.entries)
        assertEquals(View.GONE, strip.raw.visibility); assertEquals(View.VISIBLE, strip.revert.visibility)
        assertChip(true)
        advance(5000); assertChip(false)
    }
    @Test fun `a connect failure before Ready hands over to the phone and says so`() {
        keyboard(prewarm = false)
        tap(); assertTrue(voice.active); assertEquals(1, transports); assertTrue(recognizers.isEmpty())
        stream.failureKind = ConnectionFailure.Kind.DOWN; stream.failure(); advance(0)
        assertEquals(1, recognizers.size); assertTrue(voice.active); assertTrue(recognizer.listening)
        assertEquals("Computer unavailable · listening on phone", strip.status.text.toString()); assertChip(true)
        assertNull(StatusLine.PHONE_HANDOVER.action)
        recognizer.final("synthetic"); advance(0)
        assertEquals("synthetic", host.editor.committed); assertEquals(1, transports)
    }
    @Test fun `no hand-over when off, when the Mac answered over TLS, or after the Mac heard something`() {
        enabled = false; keyboard(prewarm = false)
        tap(); stream.failureKind = ConnectionFailure.Kind.DOWN; stream.failure(); advance(0)
        assertTrue(recognizers.isEmpty()); assertFalse(voice.active)
        voice.destroy(); enabled = true; keyboard(prewarm = false)
        tap(); stream.failureKind = ConnectionFailure.Kind.TLS; stream.failure(); advance(0)
        assertTrue(recognizers.isEmpty()); assertFalse(voice.active)
        voice.cancel(); tap(); stream.ready(); stream.partial(); stream.failure(); advance(0)
        assertTrue(recognizers.isEmpty()); assertEquals("synthetic", host.editor.committed)
    }
    @Test fun `an unavailable on-device recogniser keeps the Mac path`() {
        available = false; keyboard(); macOffline()
        val before = transports
        tap(); assertTrue(recognizers.isEmpty()); assertTrue(voice.active); assertEquals(before + 1, transports)
    }
    @Test fun `password fields are refused before the phone recogniser starts`() {
        keyboard(); macOffline()
        host.info.inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD
        voice.input(host.info, false)
        tap()
        assertTrue(recognizers.isEmpty()); assertFalse(voice.active)
        assertEquals("Dictation unavailable in password fields", strip.status.text.toString()); assertChip(false)
    }
    @Test fun `cancel and hide release the microphone and late results never commit`() {
        keyboard(); macOffline()
        tap(); recognizer.partial("synthetic"); advance(16)
        strip.cancel.performClick()
        assertEquals(1, recognizer.cancels); assertFalse(recognizer.listening); assertFalse(voice.active)
        recognizer.listener!!.final("late"); advance(0)
        assertEquals("", host.editor.committed); assertEquals("", host.editor.composing)
        tap(); val second = recognizer; second.partial("synthetic"); advance(16)
        voice.hidden()
        assertEquals(1, second.cancels); assertFalse(second.listening); assertFalse(voice.active)
        second.listener!!.final("late"); advance(0)
        assertEquals("", host.editor.committed)
        voice.destroy(); assertEquals(2, recognizers.size)
    }
    @Test fun `hiding before the hand-over starts never opens the phone microphone`() {
        keyboard(prewarm = false)
        tap(); stream.failureKind = ConnectionFailure.Kind.DOWN; stream.failure()
        voice.hidden(); advance(0)
        assertTrue(recognizers.isEmpty()); assertFalse(voice.active)
    }
    @Test fun `a recogniser error keeps what was heard, and with nothing heard names the reason`() {
        keyboard(); macOffline()
        tap(); recognizer.partial("synthetic heard"); advance(16)
        recognizer.error(SpeechRecognizer.ERROR_SERVER_DISCONNECTED); advance(0)
        assertEquals("synthetic heard", host.editor.committed)
        assertEquals("Phone recogniser failed — kept what I heard", strip.status.text.toString())
        assertEquals(listOf(true), recorder.entries.map { it.second })
        voice.beforeEdit(); tap(); recognizer.error(SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE); advance(0)
        assertEquals("Phone has no offline speech for this language", strip.status.text.toString()); assertFalse(voice.active)
        tap(); recognizer.final("   "); advance(0)
        assertEquals("Didn't catch that", strip.status.text.toString())
    }
    @Test fun `a recogniser that never finishes is cancelled after the stop deadline`() {
        keyboard(); macOffline()
        tap(); recognizer.partial("synthetic"); advance(16); tap()
        // The test looper's clock can run ahead of idleFor, so check well inside and past the deadline.
        advance(1000); assertTrue(voice.active); assertEquals(0, recognizer.cancels)
        advance(PhoneDictation.FINISH_MS); assertFalse(voice.active); assertEquals(1, recognizer.cancels)
        assertEquals("synthetic", host.editor.committed)
    }
    @Test fun `moving the cursor stops the phone recogniser and the final lands where it was spoken`() {
        keyboard(); macOffline()
        tap(); recognizer.partial("synthetic"); advance(16)
        voice.selection(9, 9, 0, 0, -1, -1)
        assertEquals(1, recognizer.stops); assertEquals("Finishing on phone…", strip.status.text.toString())
        recognizer.final("synthetic"); advance(0)
        assertFalse(voice.active); assertFalse(recognizer.listening); assertEquals(1, recorder.entries.size)
    }
    @Test fun `pause mode passes the chosen pause to the phone recogniser`() {
        SettingsStore(host).apply { stopOnPause = true; pauseSeconds = 3.0 }
        keyboard(); macOffline(); tap()
        assertEquals(3000L, recognizer.pauseMs)
    }
    @Test fun `after a phone dictation the next Mac dictation shows no chip`() {
        keyboard(); macOffline(); tap(); recognizer.final("synthetic"); advance(5000)
        voice.hidden(); voice.shown(); advance(31000)
        tap(); assertTrue(voice.active); assertEquals(1, recognizers.size); assertChip(false)
    }
}
