package dev.chirp.android

import android.Manifest
import android.content.res.Configuration
import android.os.Binder
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.text.InputType
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.widget.Button
import android.widget.TextView
import java.lang.reflect.Proxy
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
import org.robolectric.android.controller.ServiceController
import org.robolectric.util.ReflectionHelpers
import org.robolectric.util.ReflectionHelpers.ClassParameter

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class ChirpImeServiceTest {
    class Editor {
        var committed = ""
        var composing = ""
        var commits = 0
        var available = true
        var acceptCommit = true
        var acceptComposition = true
        var disconnectOnRegion = false
        var region: IntRange? = null
        val connection = Proxy.newProxyInstance(InputConnection::class.java.classLoader,
            arrayOf(InputConnection::class.java)) { _, method, args ->
            when (method.name) {
                "getSelectedText" -> ""
                "getTextAfterCursor" -> ""
                "getCursorCapsMode" -> 0
                "requestCursorUpdates" -> false
                "getExtractedText" -> android.view.inputmethod.ExtractedText().apply { selectionStart = committed.length; selectionEnd = committed.length }
                "setComposingText" -> { if (available && acceptComposition) composing = args!![0].toString(); available && acceptComposition }
                "setComposingRegion" -> { if (disconnectOnRegion) throw IllegalStateException("synthetic private editor detail"); if (available) region = (args!![0] as Int) until (args[1] as Int); available }
                "commitText" -> { if (available && acceptCommit) {
                    committed = region?.let { committed.replaceRange(it, args!![0].toString()) } ?: (committed + args!![0])
                    region = null; composing = ""; commits++
                }; available && acceptCommit }
                "finishComposingText" -> { committed += composing; composing = ""; region = null; true }
                "getTextBeforeCursor" -> committed.takeLast(args!![0] as Int)
                "deleteSurroundingText" -> { committed = committed.dropLast(args!![0] as Int); true }
                "beginBatchEdit", "endBatchEdit" -> true
                else -> throw UnsupportedOperationException(method.name)
            }
        } as InputConnection
    }
    internal class FakeCapture(val frame: (ByteArray) -> Boolean, val done: (DictationStatus?) -> Unit,
                      val order: MutableList<String>) : Capture {
        var started = false
        var stopRequested = false
        var released = false
        var deferRelease = false
        override var pauseSeconds: Double? = null
        override var countdown: ((Int) -> Unit)? = null
        override var limitSeconds = CaptureLimit.CAP_SECONDS
        override fun start() { started = true; order += "capture.start" }
        override fun stop() { stopRequested = true; if (!deferRelease) finish() }
        fun finish(error: DictationStatus? = null) {
            if (released) return
            released = true; order += "capture.release"; done(error)
        }
    }
    internal class FakeTransport(val event: (ServerEvent) -> Unit, val failure: () -> Unit,
                        val order: MutableList<String>) : ImeTransport {
        var learnedPayload: LearnedPayload? = null
        override fun learned(payload: LearnedPayload?) { learnedPayload = payload }
        var connected = false
        var starts = 0
        var correctionRequested = false
        var stops = 0
        var closed = false
        var cancelled = false
        var immediate = false
        override var failureKind = ConnectionFailure.Kind.OTHER
        val frames = mutableListOf<ByteArray>()
        override fun connect() { connected = true }
        override fun start(correction: Boolean): Boolean { correctionRequested = correction; starts++; order += "stream.start"; return !closed }
        override fun audio(bytes: ByteArray): Boolean { frames += bytes.copyOf(); return !closed }
        override fun stop(): Boolean { stops++; order += "stream.stop"; return !closed }
        override fun close(cancel: Boolean, immediate: Boolean) { closed = true; cancelled = cancel; this.immediate = immediate }
        fun ready() = event(ServerEvent.Ready(false))
        fun partial(seq: Long = 1, text: String = "synthetic") = event(ServerEvent.Partial(seq, text, ""))
        fun final(corrected: Boolean = false) = event(ServerEvent.Final("Synthetic.", "synthetic", corrected))
    }
    internal class TestIme : LegacyVoiceImeService() {
        var editor = Editor()
        var info = EditorInfo().apply { inputType = InputType.TYPE_CLASS_TEXT; initialSelStart = 0; initialSelEnd = 0 }
        var paired = true
        var returns = 0
        val order = mutableListOf<String>()
        val captures = mutableListOf<FakeCapture>()
        val streams = mutableListOf<FakeTransport>()
        lateinit var latestView: View
        var viewsCreated = 0
        var inputRestarts = 0
        override fun onCreateInputView(): View = super.onCreateInputView().also { latestView = it; viewsCreated++ }
        override fun onStartInput(attribute: EditorInfo?, restarting: Boolean) {
            if (restarting) inputRestarts++
            super.onStartInput(attribute, restarting)
        }
        override fun getCurrentInputConnection() = editor.connection
        override fun getCurrentInputEditorInfo() = info
        override fun loadPairing() = if (paired) Pairing.from("https://mac.example.test/chirp", "synthetic") else null
        override fun refreshHealth() { /* No network, including background health checks. */ }
        override fun previousKeyboard() { returns++ }
        public override fun onCurrentInputMethodSubtypeChanged(newSubtype: android.view.inputmethod.InputMethodSubtype?) {
            super.onCurrentInputMethodSubtypeChanged(newSubtype)
        }
        override fun createCapture(frame: (ByteArray) -> Boolean, level: (Double) -> Unit,
                                   done: (DictationStatus?) -> Unit): Capture = FakeCapture(frame, done, order).also { captures += it }
        override fun createTransport(paired: Pairing, event: (ServerEvent) -> Unit,
                                     failure: () -> Unit): ImeTransport = FakeTransport(event, failure, order).also { streams += it }
    }
    private lateinit var controller: ServiceController<TestIme>
    private lateinit var service: TestIme
    private lateinit var view: View
    private val stream get() = service.streams.last()
    private val capture get() = service.captures.last()
    private val mic get() = descendants(view).filterIsInstance<Button>().single { it.contentDescription?.toString()?.startsWith("Microphone:") == true }
    private val raw get() = button("Use raw")
    private fun descendants(root: View): List<View> = listOf(root) + if (root is ViewGroup)
        (0 until root.childCount).flatMap { descendants(root.getChildAt(it)) } else emptyList()
    private fun button(text: String) = descendants(view).filterIsInstance<Button>().single { it.text.toString() == text }
    private fun shows(text: String) = descendants(view).filterIsInstance<TextView>().any { it.text.toString().contains(text) }
    private fun advance(ms: Long) { shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(ms)) }
    private fun touch(action: Int) {
        val now = SystemClock.uptimeMillis()
        MotionEvent.obtain(now, now, action, 20f, 20f, 0).also { mic.dispatchTouchEvent(it); it.recycle() }
    }
    private fun tap() { touch(MotionEvent.ACTION_DOWN); advance(50); touch(MotionEvent.ACTION_UP) }
    private fun start() { tap(); stream.ready() }
    private fun finish(corrected: Boolean = false) { tap(); advance(0); stream.final(corrected) }

    @Before fun setUp() {
        shadowOf(RuntimeEnvironment.getApplication()).grantPermissions(Manifest.permission.RECORD_AUDIO)
        controller = Robolectric.buildService(TestIme::class.java).create()
        service = controller.get()
        SettingsStore(service).returnToPrevious = false
        view = service.onCreateInputView()
        service.onStartInput(service.info, false)
        service.onStartInputView(service.info, false)
    }
    @After fun tearDown() { controller.destroy() }

    @Test fun `tap starts capture immediately and stop waits for recorder release before stop frame`() {
        assertTrue(service.streams.isEmpty()); assertTrue(service.captures.isEmpty())
        touch(MotionEvent.ACTION_DOWN)
        assertTrue(capture.started)
        assertEquals(listOf("capture.start", "stream.start"), service.order)
        advance(50); touch(MotionEvent.ACTION_UP)
        assertFalse(capture.stopRequested)
        val frame = byteArrayOf(1, 2)
        assertTrue(capture.frame(frame)); assertTrue(stream.frames.isEmpty())
        stream.ready()
        assertArrayEquals(byteArrayOf(1, 2), stream.frames.single()); assertArrayEquals(byteArrayOf(0, 0), frame)
        capture.deferRelease = true
        tap()
        assertTrue(capture.stopRequested); assertFalse(capture.released); assertEquals(0, stream.stops)
        capture.finish(); advance(0)
        assertEquals(1, stream.stops)
        assertTrue(service.order.indexOf("capture.release") < service.order.indexOf("stream.stop"))
        stream.final(); assertEquals("Synthetic.", service.editor.committed)
        assertTrue(stream.closed)
    }
    @Test fun `hold release before Ready flushes buffered audio then stops`() {
        touch(MotionEvent.ACTION_DOWN)
        capture.frame(byteArrayOf(3, 4))
        advance(300); touch(MotionEvent.ACTION_UP); advance(0)
        assertTrue(capture.released); assertEquals(0, stream.stops)
        stream.ready()
        assertArrayEquals(byteArrayOf(3, 4), stream.frames.single()); assertEquals(1, stream.stops)
        stream.final(); assertEquals(1, service.editor.commits)
    }
    @Test fun `partials compose in order and final commits once`() {
        start(); stream.partial(); stream.partial(2, "synthetic phrase"); stream.partial(1, "stale")
        assertEquals("synthetic phrase", service.editor.composing); assertEquals("", service.editor.committed)
        finish()
        assertEquals("", service.editor.composing); assertEquals("Synthetic.", service.editor.committed)
        stream.final(); assertEquals(1, service.editor.commits)
        assertEquals(0, service.returns)
        tap(); assertEquals(1, stream.starts); assertEquals(2, service.streams.size)
    }
    @Test fun `cancel releases resources erases composition and ignores late events`() {
        start(); stream.partial()
        val old = stream
        button("✕").performClick(); advance(0)
        assertTrue(capture.released); assertTrue(old.closed); assertTrue(old.cancelled)
        assertEquals("", service.editor.composing)
        old.partial(2, "late"); old.final()
        assertEquals("", service.editor.committed); assertEquals(0, service.editor.commits)
    }
    @Test fun `touch cancellation discards rather than commits`() {
        touch(MotionEvent.ACTION_DOWN); stream.ready(); stream.partial()
        touch(MotionEvent.ACTION_CANCEL); advance(0)
        assertTrue(capture.released); assertTrue(stream.closed); assertEquals("", service.editor.composing)
        assertEquals(0, service.editor.commits)
    }
    @Test fun `finish input view during utterance releases mic and socket`() {
        start(); stream.partial()
        service.onFinishInputView(true); advance(0)
        assertHidden()
    }
    @Test fun `window hidden during utterance releases mic and socket`() {
        start(); stream.partial()
        service.onWindowHidden(); advance(0)
        assertHidden()
    }
    private fun assertHidden() {
        assertTrue(capture.released); assertTrue(stream.closed)
        assertEquals("", service.editor.composing); stream.final(); assertEquals(0, service.editor.commits)
        tap(); assertEquals(1, service.captures.size)
    }
    @Test fun `fold configuration and view recreation preserve active utterance`() {
        // Let InputMethodService own the view so its configuration callback exercises
        // input restart/view recreation, as a real fold does, rather than replacing it ourselves.
        // Robolectric has no system IME manager to initialize the configuration tracker
        // or attach the window token. Supply those prerequisites without a Binder service.
        val tracker: Any = ReflectionHelpers.getField(service, "mConfigTracker")
        ReflectionHelpers.callInstanceMethod<Unit>(tracker, "onInitialize", ClassParameter.from(Int::class.javaPrimitiveType, 0))
        val window: Any = ReflectionHelpers.getField(service, "mWindow")
        ReflectionHelpers.callInstanceMethod<Unit>(window, "setToken", ClassParameter.from(IBinder::class.java, Binder()))
        ReflectionHelpers.callInstanceMethod<Unit>(service, "doStartInput",
            ClassParameter.from(InputConnection::class.java, service.editor.connection),
            ClassParameter.from(EditorInfo::class.java, service.info), ClassParameter.from(Boolean::class.javaPrimitiveType, false))
        service.showWindow(true)
        view = service.latestView
        start(); stream.partial()
        val originalCapture = capture; val originalStream = stream
        val created = service.viewsCreated; val restarts = service.inputRestarts
        val folded = Configuration(service.resources.configuration).apply { screenWidthDp = 360; orientation = Configuration.ORIENTATION_PORTRAIT }
        service.onConfigurationChanged(folded)
        view = service.latestView
        assertTrue("Framework recreated the input view", service.viewsCreated > created)
        assertTrue("Framework restarted the same editor", service.inputRestarts > restarts)
        assertSame(originalCapture, capture); assertFalse(capture.stopRequested)
        assertSame(originalStream, stream); assertFalse(stream.closed)
        assertTrue(shows("synthetic"))
        stream.partial(2, "synthetic phrase"); finish()
        assertEquals("Synthetic.", service.editor.committed); assertEquals(1, service.editor.commits)
    }
    @Test fun `field change cancels old composition and late final cannot reach new editor`() {
        start(); stream.partial()
        val oldEditor = service.editor; val oldStream = stream
        service.editor = Editor()
        service.info = EditorInfo().apply { inputType = InputType.TYPE_CLASS_TEXT; initialSelStart = 0; initialSelEnd = 0; fieldId = 2 }
        service.onStartInput(service.info, false); advance(0)
        assertTrue(capture.released); assertTrue(oldStream.closed); assertEquals("", oldEditor.composing)
        oldStream.final(); assertEquals("", service.editor.committed); assertEquals("", oldEditor.committed)
    }
    @Test fun `all password field variations refuse capture and start`() {
        listOf(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD,
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD,
            InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD).forEach { type ->
            service.info.inputType = type
            service.onStartInput(service.info, false); tap()
            assertTrue(shows("password fields")); assertTrue(service.captures.isEmpty()); assertTrue(service.streams.isEmpty())
        }
    }
    @Test fun `missing microphone permission refuses capture`() {
        shadowOf(RuntimeEnvironment.getApplication()).denyPermissions(Manifest.permission.RECORD_AUDIO)
        tap(); assertTrue(service.captures.isEmpty()); assertTrue(service.streams.isEmpty())
        assertTrue(shows("Grant microphone permission"))
    }
    @Test fun `auto return enabled switches after uncorrected final`() {
        SettingsStore(service).returnToPrevious = true
        start(); finish(); assertEquals(1, service.returns)
    }
    @Test fun `corrected final allows raw once and auto return waits for it`() {
        SettingsStore(service).returnToPrevious = true
        start(); finish(true)
        assertEquals(0, service.returns); assertEquals(View.VISIBLE, raw.visibility)
        advance(4999); assertEquals(View.VISIBLE, raw.visibility)
        raw.performClick()
        assertEquals("synthetic", service.editor.committed); assertEquals(1, service.returns)
        assertEquals(View.GONE, raw.visibility)
        raw.performClick(); assertEquals("synthetic", service.editor.committed); assertEquals(1, service.returns)
        advance(1); assertEquals(1, service.returns)
    }
    @Test fun `raw undo expires after five seconds and returns only when enabled`() {
        SettingsStore(service).returnToPrevious = true
        start(); finish(true); advance(5000)
        assertEquals(View.GONE, raw.visibility); assertEquals(1, service.returns)
        raw.performClick(); assertEquals("Synthetic.", service.editor.committed)
        SettingsStore(service).returnToPrevious = false
        start(); finish(true); advance(5000)
        assertEquals(View.GONE, raw.visibility); assertEquals(1, service.returns)
    }
    @Test fun `rejected raw replacement keeps corrected text and permits retry within undo window`() {
        SettingsStore(service).returnToPrevious = true
        start(); finish(true)
        service.editor.acceptCommit = false
        raw.performClick()
        assertEquals("Synthetic.", service.editor.committed); assertEquals(View.VISIBLE, raw.visibility)
        assertEquals(0, service.returns)
        service.editor.acceptCommit = true
        raw.performClick()
        assertEquals("synthetic", service.editor.committed); assertEquals(View.GONE, raw.visibility)
        assertEquals(1, service.returns)
    }
    @Test fun `cursor move invalidates raw undo`() {
        start(); finish(true)
        service.onUpdateSelection(10, 10, 0, 0, -1, -1)
        assertEquals(View.GONE, raw.visibility)
        raw.performClick(); assertEquals("Synthetic.", service.editor.committed)
    }
    @Test fun `hidden keyboard cancels raw expiry and prevents delayed auto return`() {
        SettingsStore(service).returnToPrevious = true
        start(); finish(true); service.onWindowHidden(); advance(5000)
        assertEquals(View.GONE, raw.visibility); assertEquals(0, service.returns)
        assertTrue(stream.closed)
    }
    @Test fun `field change forgets raw undo without overwriting the new field`() {
        start(); finish(true)
        val oldEditor = service.editor
        service.editor = Editor(); service.onStartInput(service.info, false)
        assertEquals(View.GONE, raw.visibility); raw.performClick()
        assertEquals("", service.editor.committed); assertEquals("Synthetic.", oldEditor.committed)
    }
    @Test fun `startup timeout releases capture and retires socket`() {
        tap(); advance(18000)
        assertTrue(capture.released); assertTrue(stream.closed); assertTrue(shows("Computer unreachable"))
    }
    @Test fun `idle panel has no socket or microphone`() {
        advance(30000)
        assertTrue(service.streams.isEmpty()); assertTrue(service.captures.isEmpty())
        start(); finish()
        assertTrue(stream.closed); assertTrue(stream.immediate)
    }
    @Test fun `voice subtype starts once on launch and cancels back to previous keyboard`() {
        service.onWindowHidden()
        SettingsStore(service).returnToPrevious = true
        service.onCurrentInputMethodSubtypeChanged(android.view.inputmethod.InputMethodSubtype.InputMethodSubtypeBuilder().setSubtypeMode("voice").build())
        service.onStartInputView(service.info, false)
        assertEquals(1, service.captures.size); assertEquals(1, stream.starts)
        service.onStartInputView(service.info, true)
        assertEquals(1, service.captures.size)
        button("✕").performClick(); advance(0)
        assertTrue(capture.released); assertEquals(1, service.returns)
    }
    @Test fun `editor without composition shows partials in panel and commits final once`() {
        service.editor.acceptComposition = false
        start(); stream.partial()
        assertTrue(shows("synthetic")); assertEquals("", service.editor.composing)
        finish(); assertEquals("Synthetic.", service.editor.committed); assertEquals(1, service.editor.commits)
    }
    @Test fun `microphone is operable with accessibility click`() {
        mic.performClick(); stream.ready()
        mic.performClick(); advance(0); stream.final()
        assertEquals("Synthetic.", service.editor.committed); assertTrue(capture.released)
    }
    @Test fun `transport failure during capture cancels composition`() {
        start(); stream.partial(); stream.failure(); advance(0)
        assertTrue(capture.released); assertEquals("", service.editor.composing)
        assertTrue(shows("Computer unreachable"))
    }
}
