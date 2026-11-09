package dev.chirp.android

import android.Manifest
import android.inputmethodservice.InputMethodService
import android.os.Looper
import android.text.Editable
import android.text.Selection
import android.text.SpannableStringBuilder
import android.view.ContextThemeWrapper
import android.view.MotionEvent
import android.view.View
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
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

/** Dictated text is never lost: failures keep what was heard, caret moves stop, every final can be undone. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class KeepDictationTest {
    class Editor : BaseInputConnection(View(RuntimeEnvironment.getApplication()), true) {
        val buffer = SpannableStringBuilder()
        override fun getEditable(): Editable = buffer
        val text get() = buffer.toString()
        val caret get() = Selection.getSelectionStart(buffer)
        fun reset(value: String, at: Int, end: Int) { buffer.replace(0, buffer.length, value); Selection.setSelection(buffer, at, end) }
    }
    class Host : InputMethodService() {
        val editor = Editor()
        val info = EditorInfo().apply { inputType = android.text.InputType.TYPE_CLASS_TEXT }
        override fun getCurrentInputConnection() = editor
        override fun getCurrentInputEditorInfo() = info
    }
    private class Recorder : HistoryRecorder {
        val partials = mutableListOf<Boolean>()
        override fun record(text: String, raw: String?, info: EditorInfo?, partial: Boolean): String { partials += partial; return "id" }
        override fun usedRaw(id: String) = Unit
    }
    private val controller = Robolectric.buildService(Host::class.java)
    private lateinit var host: Host
    private lateinit var voice: KeyboardDictation
    private lateinit var strip: KeyboardStrip
    private lateinit var stream: ChirpImeServiceTest.FakeTransport
    private val history = Recorder()
    private val editor get() = host.editor
    private fun advance(ms: Long) = shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(ms))
    private fun tap() { voice.touch(MotionEvent.ACTION_DOWN); advance(40); voice.touch(MotionEvent.ACTION_UP) }
    private fun start(value: String, at: Int = value.length, end: Int = at) {
        editor.reset(value, at, end)
        host.info.initialSelStart = at; host.info.initialSelEnd = end
        // toggle, not a touch: this harness's clock passes MicGesture's 300 ms hold during start, and a hold's release stops.
        voice.input(host.info, false); voice.toggle(); stream.ready()
    }
    private fun partial(text: String = "synthetic", seq: Long = 1) { stream.partial(seq, text); advance(16) }
    /** The user taps somewhere else in the field, as reported through onUpdateSelection. */
    private fun moveCaret(to: Int) {
        val old = editor.caret
        Selection.setSelection(editor.buffer, to)
        voice.selection(old, old, to, to, BaseInputConnection.getComposingSpanStart(editor.buffer), BaseInputConnection.getComposingSpanEnd(editor.buffer))
        advance(0)
    }
    @Before fun setup() {
        controller.create(); host = controller.get()
        shadowOf(RuntimeEnvironment.getApplication()).grantPermissions(Manifest.permission.RECORD_AUDIO, LOCAL_NETWORK_PERMISSION)
        voice = KeyboardDictation(host, learning = EditLearning(host, io = { it() }),
            captureFactory = { frame, _, done -> ChirpImeServiceTest.FakeCapture(frame, done, mutableListOf()) },
            transportFactory = { _, _, event, failure -> ChirpImeServiceTest.FakeTransport(event, failure, mutableListOf()).also { stream = it } },
            prepare = {}, resync = { _, _ -> },
            pairing = { Pairing.from("https://mac.example.test", "synthetic") }, checkHealth = false, history = history)
        strip = KeyboardStrip(ContextThemeWrapper(host, R.style.Theme_Chirp)); voice.attach(strip)
        voice.input(host.info, false); voice.shown()
    }
    @After fun teardown() { voice.destroy(); controller.destroy() }

    @Test fun `transport failure keeps what was heard and Undo restores the original`() {
        start("Previous.")
        partial(); assertEquals("Previous. synthetic", editor.text)
        stream.failure()
        assertFalse(voice.active)
        assertEquals("Previous. synthetic", editor.text); assertEquals(-1, BaseInputConnection.getComposingSpanStart(editor.buffer))
        assertEquals("Connection lost — kept what I heard", strip.status.text.toString())
        assertEquals(View.VISIBLE, strip.revert.visibility); assertEquals(View.GONE, strip.raw.visibility)
        assertEquals(listOf(true), history.partials)
        strip.revert.performClick()
        assertEquals("Previous.", editor.text); assertEquals(9, editor.caret)
        assertEquals(View.GONE, strip.revert.visibility)
        advance(5000); assertEquals(View.GONE, strip.status.visibility)
    }
    @Test fun `server errors after partials keep the text and name the reason`() {
        start("")
        partial(); tap(); advance(0)
        stream.event(ServerEvent.Failure("too_long"))
        assertEquals("synthetic", editor.text)
        assertEquals("Dictation limit is 120 seconds — kept what I heard", strip.status.text.toString())
    }
    @Test fun `failure before any partial keeps nothing and offers recovery`() {
        start("Previous.")
        stream.failure()
        assertEquals("Previous.", editor.text)
        assertEquals("Check Tailscale", strip.status.text.toString())
        assertEquals(View.GONE, strip.revert.visibility); assertTrue(history.partials.isEmpty())
    }
    @Test fun `explicit cancel still discards`() {
        start("Previous.")
        partial(); strip.cancel.performClick()
        assertFalse(voice.active); assertEquals("Previous.", editor.text)
        stream.failure(); stream.final()
        assertEquals("Previous.", editor.text); assertEquals(View.GONE, strip.revert.visibility)
        assertTrue(history.partials.isEmpty())
    }
    @Test fun `moving the caret stops and the final lands where it was spoken`() {
        start("Start. End", 6)
        partial(); assertEquals("Start. synthetic End", editor.text)
        assertEquals(0, stream.stops); moveCaret(0)
        assertEquals(1, stream.stops); assertTrue(voice.active)
        partial("synthetic words", 2) // Late partials no longer touch the editor or the caret.
        assertEquals("Start. synthetic End", editor.text); assertEquals(0, editor.caret)
        stream.final()
        assertEquals("Start. Synthetic. End", editor.text); assertEquals(0, editor.caret)
        assertEquals(-1, BaseInputConnection.getComposingSpanStart(editor.buffer))
        assertEquals(View.VISIBLE, strip.revert.visibility)
        strip.revert.performClick()
        assertEquals("Start. End", editor.text); assertEquals(0, editor.caret)
    }
    @Test fun `caret after the utterance shifts with the final`() {
        start("Start. End", 6)
        partial(); moveCaret(editor.text.length)
        stream.final(corrected = true)
        assertEquals("Start. Synthetic. End", editor.text); assertEquals(editor.text.length, editor.caret)
        strip.raw.performClick()
        assertEquals("Start. synthetic End", editor.text); assertEquals(editor.text.length, editor.caret)
    }
    @Test fun `failure after a caret move keeps the partial in place`() {
        start("Start. End", 6)
        partial(); moveCaret(0); stream.failure()
        assertEquals("Start. synthetic End", editor.text); assertEquals(0, editor.caret)
        assertEquals("Connection lost — kept what I heard", strip.status.text.toString())
    }
    @Test fun `when the editor dropped the utterance the final lands at the new caret`() {
        start("Start. End", 6)
        partial(); moveCaret(0)
        editor.buffer.delete(6, 16); BaseInputConnection.removeComposingSpans(editor.buffer)
        Selection.setSelection(editor.buffer, editor.text.length)
        voice.selection(0, 0, editor.text.length, editor.text.length, -1, -1)
        stream.final()
        assertEquals("Start. End Synthetic.", editor.text)
        strip.revert.performClick(); assertEquals("Start. End", editor.text)
    }
    @Test fun `undo after a plain final removes the span including its separator`() {
        start("Previous.")
        partial(); tap(); advance(0); stream.final()
        assertEquals("Previous. Synthetic.", editor.text)
        assertEquals(View.VISIBLE, strip.revert.visibility); assertEquals(View.GONE, strip.raw.visibility)
        strip.revert.performClick()
        assertEquals("Previous.", editor.text); assertEquals(9, editor.caret)
        assertEquals("Dictation removed", strip.status.text.toString())
    }
    @Test fun `undo restores a selection the dictation replaced`() {
        start("Keep this word", 10, 14)
        partial(); tap(); advance(0); stream.final()
        assertEquals("Keep this Synthetic.", editor.text)
        strip.revert.performClick()
        assertEquals("Keep this word", editor.text)
    }
    @Test fun `cleaned final offers both Use raw and Undo until the caret moves`() {
        start("")
        partial(); tap(); advance(0); stream.final(corrected = true)
        assertEquals(View.VISIBLE, strip.raw.visibility); assertEquals(View.VISIBLE, strip.revert.visibility)
        voice.selection(10, 10, 0, 0, -1, -1)
        assertEquals(View.GONE, strip.raw.visibility); assertEquals(View.GONE, strip.revert.visibility)
        assertEquals("Synthetic.", editor.text)
    }
    /** The editor reports our own edit back later, as onUpdateSelection does; [region] false models editors that report no composing span. */
    private fun echo(old: Int, region: Boolean = true) {
        val caret = editor.caret
        voice.selection(old, old, caret, caret, if (region) BaseInputConnection.getComposingSpanStart(editor.buffer) else -1,
            if (region) BaseInputConnection.getComposingSpanEnd(editor.buffer) else -1)
        advance(0)
    }
    @Test fun `an editor that reports no composing region does not stop dictation at the first partial (381)`() {
        start("Hello.")
        partial("one"); echo(6, region = false)
        assertTrue(voice.active); assertEquals(0, stream.stops)
        partial("one two", 2); echo(10, region = false)
        assertTrue(voice.active); assertEquals(0, stream.stops)
        tap(); advance(0); stream.final()
        assertEquals("Hello. Synthetic.", editor.text)
    }
    @Test fun `a late echo of an earlier partial is not a caret move (381)`() {
        start("Hello.")
        partial("one"); partial("one two three", 2)
        // The report for "one" arrives after "one two three" is already in: the caret it names is inside our text.
        voice.selection(6, 6, 10, 10, -1, -1); advance(0)
        assertTrue(voice.active); assertEquals(0, stream.stops)
        // ...and so is one for a longer partial the server then revised to something shorter.
        partial("one two three four", 3); partial("one two", 4)
        voice.selection(20, 20, 25, 25, -1, -1); advance(0)
        assertTrue(voice.active); assertEquals(0, stream.stops)
    }
    @Test fun `a fully stable partial leaves no composing region and is not a caret move (381)`() {
        start("Hello.")
        stream.event(ServerEvent.Partial(1, "one", "one")); advance(16)
        assertEquals("Hello. one", editor.text); assertEquals(-1, BaseInputConnection.getComposingSpanStart(editor.buffer))
        echo(6)
        assertTrue(voice.active); assertEquals(0, stream.stops)
    }
    @Test fun `selecting text or moving past the utterance still stops (381)`() {
        start("Start. End", 6)
        partial(); val caret = editor.caret; assertEquals(0, stream.stops)
        Selection.setSelection(editor.buffer, 7, 10)
        voice.selection(caret, caret, 7, 10, -1, -1); advance(0)
        assertEquals(1, stream.stops)
    }
    @Test fun `undo expires after five seconds`() {
        start("")
        partial(); tap(); advance(0); stream.final()
        advance(5000)
        assertEquals(View.GONE, strip.revert.visibility)
        strip.revert.performClick(); assertEquals("Synthetic.", editor.text)
    }
}
