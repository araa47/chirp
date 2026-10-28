package dev.chirp.android

import android.Manifest
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.Button
import android.widget.TextView
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
import org.robolectric.shadows.ShadowToast
import org.robolectric.util.ReflectionHelpers

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class ChirpAccessibilityServiceTest {
    class TestService : ChirpAccessibilityService() {
        var editorOptions = 0
        internal val learnedStore by lazy { LearnedStore(this, SoftwareHistoryKeys()) }
        override fun learningEditorInfo() = android.view.inputmethod.EditorInfo().apply {
            inputType = android.text.InputType.TYPE_CLASS_TEXT; packageName = "com.example.chat"; imeOptions = editorOptions
        }
        override fun createLearning() = EditLearning(this, learnedStore, io = { it() })
        var paired = true
        var pairingUrl = "https://mac.example.test"
        var vpn = TailscalePromptTest.FakeTailscale(connected = true)
        internal val captures = mutableListOf<ChirpImeServiceTest.FakeCapture>()
        internal val streams = mutableListOf<ChirpImeServiceTest.FakeTransport>()
        private val order = mutableListOf<String>()
        override fun loadPairing() = if (paired) Pairing.from(pairingUrl, "synthetic") else null
        override fun tailscale(): TailscaleControl = vpn
        override fun createCapture(frame: (ByteArray) -> Boolean, level: (Double) -> Unit, done: (DictationStatus?) -> Unit): Capture =
            ChirpImeServiceTest.FakeCapture(frame, done, order).also { captures += it }
        override fun createTransport(client: okhttp3.OkHttpClient, pairing: Pairing, event: (ServerEvent) -> Unit, failure: () -> Unit): ImeTransport =
            ChirpImeServiceTest.FakeTransport(event, failure, order).also { streams += it }
    }
    private val app get() = RuntimeEnvironment.getApplication()
    private lateinit var service: TestService
    private lateinit var node: AccessibilityNodeInfo
    private var writes = 0
    private val overlay get() = ReflectionHelpers.getField<FloatingMicOverlay?>(service, "overlay")
    private val panel get() = overlay?.panel
    private val bubbleShown get() = overlay?.bubbleShown == true
    private fun descendants(root: View): List<View> = listOf(root) + if (root is ViewGroup)
        (0 until root.childCount).flatMap { descendants(root.getChildAt(it)) } else emptyList()
    private fun button(text: String) = descendants(panel!!).filterIsInstance<Button>().single { (it.text.toString() == text || it.text.toString().startsWith("$text (")) && it.visibility == View.VISIBLE }
    private fun visibleButtons() = descendants(panel!!).filterIsInstance<Button>().filter { it.isShown }.map { it.text.toString() }
    private fun shows(text: String) = panel?.let { p -> descendants(p).filterIsInstance<TextView>().any { it.isShown && it.text.toString().contains(text) } } == true
    private fun advance(ms: Long = 0) { shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(ms)) }
    private fun focus() {
        ReflectionHelpers.setField(service, "focused", node)
        ReflectionHelpers.callInstanceMethod<Unit>(service, "refresh")
        advance()
    }
    private fun touch(action: Int, x: Float, y: Float, at: Long) {
        MotionEvent.obtain(at, at, action, x, y, 0).also { overlay!!.bubble.dispatchTouchEvent(it); it.recycle() }
    }
    private fun tapBubble() {
        val now = SystemClock.uptimeMillis()
        touch(MotionEvent.ACTION_DOWN, 20f, 20f, now); advance(40); touch(MotionEvent.ACTION_UP, 20f, 20f, now + 40); advance()
    }
    private fun serve() {
        val intent = shadowOf(app).nextStartedService
        assertNotNull("dictation never asked for the microphone service", intent)
        service.onStartCommand(intent, 0, 1)
        service.streams.last().ready()
    }
    private fun start() { tapBubble(); serve() }
    private fun stopAndFinal(corrected: Boolean = false) { button("Stop").performClick(); advance(); service.streams.last().final(corrected) }

    @Before fun setup() {
        // Android grants this app-owned signature permission at install; Robolectric needs it explicitly at API 31.
        shadowOf(app).grantPermissions(Manifest.permission.RECORD_AUDIO, "dev.chirp.android.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION")
        service = Robolectric.buildService(TestService::class.java).create().get()
        node = AccessibilityNodeInfo().apply {
            isFocused = true; isEditable = true; isEnabled = true; packageName = "com.example.chat"
            text = "prefix suffix"; setTextSelection(7, 7); setBoundsInScreen(android.graphics.Rect(40, 300, 400, 380))
            addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SET_TEXT)
        }
        shadowOf(node).setRefreshReturnValue(true)
        shadowOf(node).setOnPerformActionListener { action, args ->
            when (action) {
                AccessibilityNodeInfo.ACTION_SET_TEXT -> { writes++; node.text = args.getCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE); true }
                AccessibilityNodeInfo.ACTION_SET_SELECTION -> {
                    node.setTextSelection(args.getInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT),
                        args.getInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT)); true
                }
                else -> false
            }
        }
        focus()
    }
    @After fun cleanup() { service.onDestroy() }

    @Test fun `floating corrections activate after two windows and respect real editor privacy flags`() {
        val original = "Try Acme Cloud today."
        val corrected = "Try AcmeCloud today."
        repeat(2) {
            start(); button("Stop").performClick(); advance()
            service.streams.last().event(ServerEvent.Final(original, original, false))
            advance(1300)
            node.text = node.text.toString().replace(original, corrected)
            node.setTextSelection(node.text.length, node.text.length)
            advance(500)
        }
        start()
        val payload = service.streams.last().learnedPayload!!
        assertEquals("AcmeCloud", payload.terms.single().term)
        assertEquals(2, service.learnedStore.all().single().count)
        service.onInterrupt(); focus()
        service.editorOptions = android.view.inputmethod.EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING
        start()
        assertTrue(service.streams.last().learnedPayload!!.isEmpty)
    }

    @Config(sdk = [37])
    @Test fun `accessibility editor callback preserves actual incognito flags and clears them at finish`() {
        val controller = Robolectric.buildService(ChirpAccessibilityService::class.java).create()
        val plain = controller.get()
        val method = plain.onCreateInputMethod()
        method.onStartInput(android.view.inputmethod.EditorInfo().apply {
            inputType = android.text.InputType.TYPE_CLASS_TEXT
            packageName = "com.example.chat"
            imeOptions = android.view.inputmethod.EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING
        }, false)
        assertFalse(DictationHistory.allowed(plain.learningEditorInfo()))
        method.onFinishInput(); assertNull(plain.learningEditorInfo())
        controller.destroy()
    }

    @Test fun `idle bubble has no microphone socket or foreground notification`() {
        assertTrue(bubbleShown); assertNull(panel); advance(30000)
        assertTrue(service.captures.isEmpty()); assertTrue(service.streams.isEmpty())
        assertNull(shadowOf(service).lastForegroundNotification)
        assertEquals("Chirp microphone: tap to dictate, hold to talk", overlay!!.bubble.contentDescription)
    }
    @Test fun `tap dictates partials in the panel then inserts at the caret and collapses`() {
        start(); service.streams.last().partial()
        assertTrue(shows("Listening")); assertTrue(shows("synthetic")); assertEquals(0, writes)
        // The notification while listening never carries dictated text.
        val notification = shadowOf(service).lastForegroundNotification!!
        assertEquals("Chirp is listening", shadowOf(notification).contentTitle)
        assertEquals("Tap Cancel to discard", shadowOf(notification).contentText)
        stopAndFinal()
        assertEquals("prefix Synthetic.suffix", node.text.toString()); assertEquals(1, writes)
        assertEquals(17, node.textSelectionStart)
        assertTrue(service.captures.last().released); assertTrue(service.streams.last().closed)
        assertTrue(shadowOf(service).isForegroundStopped)
        assertTrue(shows("Finished"))
        advance(1200)
        assertNull(panel); assertTrue(bubbleShown)
    }
    @Test fun `field changed while finishing keeps the final ready to copy as a sensitive clip`() {
        start(); button("Stop").performClick(); advance()
        node.text = "user changed field"; service.streams.last().final()
        assertEquals(0, writes); assertEquals("user changed field", node.text.toString())
        assertTrue(shows("Couldn't put this in the field")); assertTrue(shows("Synthetic."))
        assertEquals(listOf("Copy", "Open in Scratchpad", "Done"), visibleButtons())
        button("Copy").performClick(); advance()
        val clip = app.getSystemService(ClipboardManager::class.java).primaryClip!!
        assertEquals("Synthetic.", clip.getItemAt(0).text.toString())
        assertTrue(clip.description.extras.getBoolean(ClipDescription.EXTRA_IS_SENSITIVE))
        assertEquals("Copied — long-press the field to paste", ShadowToast.getTextOfLatestToast())
        assertNull(panel); assertTrue(bubbleShown)
    }
    @Test fun `the floating mic never copies on its own`() {
        app.getSystemService(ClipboardManager::class.java).setPrimaryClip(android.content.ClipData.newPlainText("x", "untouched"))
        start(); button("Stop").performClick(); advance(); node.text = "changed"; service.streams.last().final()
        advance(ChirpAccessibilityService.KEPT_MS)
        assertEquals("untouched", app.getSystemService(ClipboardManager::class.java).primaryClip!!.getItemAt(0).text.toString())
        // Two minutes untouched clears the kept words.
        assertNull(panel)
    }
    @Test fun `polished final offers Use raw for five seconds and raw replaces only the dictated range`() {
        start(); stopAndFinal(corrected = true)
        assertTrue(shows("Polished")); assertTrue(button("Use raw").isShown)
        button("Use raw").performClick(); advance()
        assertEquals("prefix syntheticsuffix", node.text.toString())
        assertNull(panel)
        node.text = "prefix suffix"; node.setTextSelection(7, 7)
        start(); stopAndFinal(corrected = true)
        advance(ChirpAccessibilityService.UNDO_MS)
        assertNull(panel); assertTrue(bubbleShown)
    }
    @Test fun `an edit after a polished insert closes Use raw`() {
        start(); stopAndFinal(corrected = true)
        // The node is detached here, so drive the text-changed handler directly.
        node.text = "user edit"
        ReflectionHelpers.callInstanceMethod<Unit>(service, "edited"); advance()
        assertNull(panel)
        assertEquals("user edit", node.text.toString())
    }
    @Test fun `cancel and interrupt release resources and fence late finals`() {
        start(); service.streams.last().partial(); button("Cancel").performClick(); advance()
        assertTrue(service.captures.last().released); assertTrue(service.streams.last().cancelled)
        service.streams.last().final(); assertEquals(0, writes)
        assertTrue(shadowOf(service).isForegroundStopped)
        start(); service.onInterrupt(); advance()
        assertNull(overlay); assertTrue(service.captures.last().released)
        service.streams.last().final(); assertEquals(0, writes)
    }
    @Test fun `switching apps mid-dictation stops listening and the final waits to be copied`() {
        start(); service.streams.last().partial()
        node.isFocused = false
        service.onAccessibilityEvent(AccessibilityEvent().apply { eventType = AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED; packageName = "com.example.other" })
        advance()
        assertTrue(service.captures.last().stopRequested); assertTrue(service.captures.last().released)
        service.streams.last().final()
        assertEquals(0, writes); assertTrue(shows("Synthetic.")); assertTrue(button("Copy").isShown)
        assertTrue(shadowOf(service).isForegroundStopped)
    }
    @Test fun `screen off releases the microphone and discards everything`() {
        start(); button("Stop").performClick(); advance(); node.text = "changed"; service.streams.last().final()
        assertTrue(shows("Synthetic."))
        service.sendBroadcast(Intent(Intent.ACTION_SCREEN_OFF)); advance()
        assertNull(overlay); assertEquals("", ReflectionHelpers.getField<String>(service, "kept"))
    }
    @Test fun `password disabled and non-editable fields have no bubble`() {
        node.isPassword = true; focus(); assertFalse(bubbleShown)
        node.isPassword = false; node.isEnabled = false; focus(); assertFalse(bubbleShown)
        node.isEnabled = true; node.isEditable = false; focus(); assertFalse(bubbleShown)
        node.isEditable = true; focus(); assertTrue(bubbleShown)
    }
    @Test fun `bubble steps aside while Chirp Keyboard is the input method`() {
        Settings.Secure.putString(app.contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD, "${app.packageName}/.ChirpImeService")
        focus(); assertFalse(bubbleShown)
        Settings.Secure.putString(app.contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD, "com.example.keyboard/.Ime")
        focus(); assertTrue(bubbleShown)
    }
    @Test fun `copy mode field shows the badge and dictation ends ready to copy or in the Scratchpad`() {
        node.removeAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SET_TEXT); focus()
        assertTrue(bubbleShown); assertTrue(overlay!!.bubble.copyMode)
        assertEquals("Chirp microphone — this field can't be filled automatically; your words will be ready to copy",
            overlay!!.bubble.contentDescription)
        start(); stopAndFinal()
        assertEquals(0, writes); assertTrue(shows("This field can't be filled automatically"))
        button("Open in Scratchpad").performClick(); advance()
        val opened = shadowOf(app).nextStartedActivity
        assertEquals(ScratchpadActivity::class.java.name, opened.component?.className)
        assertNull("text never travels in the Intent", opened.extras)
        assertEquals("Synthetic.", ScratchpadHandoff.take())
        assertNull(panel)
    }
    @Test fun `a very long field is copy mode`() {
        node.text = "x".repeat(FocusedInsertion.MAX_TEXT + 1); node.setTextSelection(0, 0); focus()
        assertTrue(overlay!!.bubble.copyMode)
    }
    @Test fun `a drag never opens the microphone and its drop is remembered per posture`() {
        val bubble = overlay!!.bubble
        val now = SystemClock.uptimeMillis()
        touch(MotionEvent.ACTION_DOWN, 20f, 20f, now)
        touch(MotionEvent.ACTION_MOVE, -200f, 120f, now + 60)
        touch(MotionEvent.ACTION_MOVE, -400f, 160f, now + 120)
        advance(400)
        touch(MotionEvent.ACTION_UP, -400f, 160f, now + 500); advance(400)
        assertNull(shadowOf(app).nextStartedService); assertTrue(service.captures.isEmpty())
        assertNull(panel); assertTrue(bubbleShown)
        val prefs = app.getSharedPreferences(SettingsStore.FILE, Context.MODE_PRIVATE).all
        assertEquals(BubbleEdge.LEFT.name, prefs.entries.single { it.key.startsWith("bubble_edge_") }.value)
        assertEquals(BubbleEdge.LEFT, bubble.edge)
    }
    @Test fun `hold to talk starts on 250 ms still and release stops`() {
        val now = SystemClock.uptimeMillis()
        touch(MotionEvent.ACTION_DOWN, 20f, 20f, now)
        advance(100); assertNull(shadowOf(app).nextStartedService)
        advance(200)
        assertTrue(overlay!!.holding); assertNull(panel)
        serve(); service.streams.last().partial()
        touch(MotionEvent.ACTION_UP, 22f, 22f, now + 900); advance()
        assertTrue(service.captures.last().stopRequested)
        service.streams.last().final(); advance()
        assertEquals("prefix Synthetic.suffix", node.text.toString())
        advance(1200); assertFalse(overlay!!.holding); assertTrue(bubbleShown)
    }
    @Test fun `each error shows exactly one fix`() {
        shadowOf(app).denyPermissions(Manifest.permission.RECORD_AUDIO)
        tapBubble(); assertTrue(shows("Allow the microphone for Chirp")); assertEquals(listOf("Allow"), errorActions())
        assertTrue(service.captures.isEmpty())
        button("Allow").performClick(); advance()
        assertEquals(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, shadowOf(app).nextStartedActivity.action)
        shadowOf(app).grantPermissions(Manifest.permission.RECORD_AUDIO)
        service.paired = false; focus(); tapBubble()
        assertTrue(shows("Pair your computer to dictate")); assertEquals(listOf("Pair computer"), errorActions())
        panel!!.hide.performClick(); advance()
        service.paired = true; service.pairingUrl = "https://mac.tail0000.ts.net"; service.vpn = TailscalePromptTest.FakeTailscale(connected = false)
        focus(); tapBubble()
        assertTrue(shows("Tailscale is off")); assertEquals(listOf("Turn on"), errorActions())
        panel!!.hide.performClick(); advance()
        service.pairingUrl = "https://mac.example.test"; focus(); start()
        service.streams.last().failure(); advance()
        assertTrue(shows(ConnectionFailure.Kind.OTHER.english())); assertEquals(listOf("Check again"), errorActions())
        assertTrue(shadowOf(service).isForegroundStopped); assertTrue(service.captures.last().released)
        button("Check again").performClick(); advance()
        assertNotNull(shadowOf(app).nextStartedService)
    }
    private fun errorActions() = descendants(panel!!.error).filterIsInstance<Button>().filter { it.isShown }.map { it.text.toString() }
    @Test fun `a failure after partials keeps what was heard`() {
        start(); service.streams.last().partial(text = "synthetic words")
        service.streams.last().failure(); advance()
        assertTrue(shows("synthetic words")); assertTrue(button("Copy").isShown)
        assertEquals(listOf("Check again"), errorActions())
    }
    @Test fun `hide here hides the bubble in this app until another app is in front`() {
        overlay!!.bubble.performAccessibilityAction(R.id.bubble_hide_here, null); advance()
        assertFalse(bubbleShown); assertEquals("Floating mic hidden in this app", ShadowToast.getTextOfLatestToast())
        focus(); assertFalse(bubbleShown)
        service.onAccessibilityEvent(AccessibilityEvent().apply { eventType = AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED; packageName = "com.android.systemui" })
        focus(); assertTrue(bubbleShown)
        assertFalse(app.getSharedPreferences(SettingsStore.FILE, Context.MODE_PRIVATE).all.values.any { it.toString().contains("com.example") })
    }
    @Test fun `talkback gets a button with move and hide actions`() {
        val info = AccessibilityNodeInfo()
        overlay!!.bubble.onInitializeAccessibilityNodeInfo(info)
        assertEquals(Button::class.java.name, info.className)
        assertEquals(listOf("Move to other side", "Hide in this app"),
            info.actionList.filter { it.id == R.id.bubble_move_side || it.id == R.id.bubble_hide_here }.map { it.label.toString() })
        val before = overlay!!.bubble.edge
        overlay!!.bubble.performAccessibilityAction(R.id.bubble_move_side, null); advance(400)
        assertNotEquals(before, overlay!!.bubble.edge)
        // Double tap is a click: it opens the panel and starts dictating.
        overlay!!.bubble.performClick(); advance()
        assertNotNull(panel); assertNotNull(shadowOf(app).nextStartedService)
    }
    @Test fun `no dictated or field text reaches preferences`() {
        start(); service.streams.last().partial(); stopAndFinal(corrected = true)
        val prefsDir = File(app.applicationInfo.dataDir, "shared_prefs")
        val all = app.getSharedPreferences(SettingsStore.FILE, Context.MODE_PRIVATE).all.values.joinToString() +
            (prefsDir.listFiles()?.joinToString { it.readText() } ?: "")
        assertFalse(all.contains("ynthetic")); assertFalse(all.contains("prefix"))
    }
    @Test fun `Chirp default hides floating mic in both input modes and window transitions stop capture without writing`() {
        for (mode in InputMode.entries) {
            SettingsStore(service).inputMode = mode
            android.provider.Settings.Secure.putString(service.contentResolver, android.provider.Settings.Secure.DEFAULT_INPUT_METHOD, "dev.chirp.android/.ChirpImeService")
            focus(); assertFalse(bubbleShown)
            android.provider.Settings.Secure.putString(service.contentResolver, android.provider.Settings.Secure.DEFAULT_INPUT_METHOD, "com.google.android.inputmethod.latin/com.android.inputmethod.latin.LatinIME")
            focus(); assertTrue(bubbleShown)
            start()
            android.provider.Settings.Secure.putString(service.contentResolver, android.provider.Settings.Secure.DEFAULT_INPUT_METHOD, "dev.chirp.android/.ChirpImeService")
            service.onAccessibilityEvent(AccessibilityEvent().apply { eventType = AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED })
            advance()
            assertFalse(bubbleShown); assertTrue(service.captures.last().released)
            // The final never lands in the field after a window change; it waits in Ready to copy instead.
            service.streams.last().final(); assertEquals(0, writes); assertTrue(shows("Synthetic."))
            panel!!.done.performClick(); advance()
        }
    }
    @Test fun `Accessibility event types timeout and flags keep their narrow scope`() {
        val xml = service.resources.getXml(R.xml.accessibility_service)
        while (xml.next() != org.xmlpull.v1.XmlPullParser.START_TAG) { }
        val ns = "http://schemas.android.com/apk/res/android"
        assertEquals(AccessibilityEvent.TYPE_VIEW_FOCUSED or AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED or AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED or AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED, xml.getAttributeIntValue(ns, "accessibilityEventTypes", 0))
        assertEquals("100", xml.getAttributeValue(ns, "notificationTimeout"))
        assertNull(xml.getAttributeValue(ns, "accessibilityFlags"))
        assertEquals("false", xml.getAttributeValue(ns, "isAccessibilityTool"))
        xml.close()
    }

    @Test fun `no overlay permission is added and the description promises no automatic copy`() {
        val requested = app.packageManager.getPackageInfo(app.packageName, android.content.pm.PackageManager.GET_PERMISSIONS).requestedPermissions.orEmpty()
        assertFalse(requested.contains(Manifest.permission.SYSTEM_ALERT_WINDOW))
        assertFalse(requested.contains(Manifest.permission.RECEIVE_BOOT_COMPLETED))
        assertFalse(requested.contains(Manifest.permission.WAKE_LOCK))
        assertTrue(app.getString(R.string.accessibility_description).contains("never copies on its own"))
    }
}
