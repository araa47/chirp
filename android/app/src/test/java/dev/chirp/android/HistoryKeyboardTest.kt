package dev.chirp.android

import android.Manifest
import android.content.ClipboardManager
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.os.Looper
import android.view.ContextThemeWrapper
import android.view.MotionEvent
import android.view.View
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
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
import java.io.File
import java.time.Duration

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class HistoryKeyboardTest {
    private val controller = Robolectric.buildService(KeyboardDictationTest.Host::class.java)
    private lateinit var host: KeyboardDictationTest.Host
    private lateinit var voice: KeyboardDictation
    private lateinit var history: KeyboardHistory
    private lateinit var store: DictationHistory
    private lateinit var strip: KeyboardStrip
    private lateinit var stream: ChirpImeServiceTest.FakeTransport
    private lateinit var keys: View
    private val keyStore = SoftwareHistoryKeys()
    private val now = 1_800_000_000_000L
    private val file get() = File(host.filesDir, DictationHistory.FILE_NAME)
    private val panel get() = history.panel!!
    private fun advance(ms: Long) = shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(ms))
    private fun tap() { voice.touch(MotionEvent.ACTION_DOWN); advance(40); voice.touch(MotionEvent.ACTION_UP) }
    private fun dictate(text: String = "Synthetic.", raw: String = "synthetic", corrected: Boolean = false) {
        tap(); stream.ready(); stream.partial(text = raw); advance(16); tap(); advance(0)
        stream.event(ServerEvent.Final(text, raw, corrected))
    }
    private fun rows() = (0 until panel.list.childCount).map { panel.list.getChildAt(it) }.filter { it is LinearLayout && it.isClickable }
    private fun texts(view: View): List<String> = when (view) {
        is TextView -> listOf(view.text.toString())
        is android.view.ViewGroup -> (0 until view.childCount).flatMap { texts(view.getChildAt(it)) }
        else -> emptyList()
    }

    @Before fun setup() {
        controller.create(); host = controller.get()
        shadowOf(RuntimeEnvironment.getApplication()).grantPermissions(Manifest.permission.RECORD_AUDIO)
        store = DictationHistory(host, keyStore) { now }
        store.disable()
        history = KeyboardHistory(host, insert = { voice.insertText(it) }, store = store, io = { it() }, clock = { now + 120_000 })
        voice = KeyboardDictation(host, learning = EditLearning(host, io = { it() }),
            captureFactory = { frame, _, done -> ChirpImeServiceTest.FakeCapture(frame, done, mutableListOf()) },
            transportFactory = { _, _, event, failure -> ChirpImeServiceTest.FakeTransport(event, failure, mutableListOf()).also { stream = it } },
            prepare = {}, resync = { _, _ -> }, pairing = { Pairing.from("https://mac.example.test", "synthetic") }, checkHealth = false,
            history = history, started = { history.close() })
        val themed = ContextThemeWrapper(host, R.style.Theme_Chirp)
        strip = KeyboardStrip(themed); voice.attach(strip)
        val wrapper = FrameLayout(themed).apply { id = helium314.keyboard.latin.R.id.keyboard_view_wrapper }
        keys = View(themed).apply { id = helium314.keyboard.latin.R.id.keyboard_view }
        wrapper.addView(keys, FrameLayout.LayoutParams(411, 240))
        history.mount(FrameLayout(themed).apply { addView(wrapper) }, strip)
        voice.input(host.info, false); voice.shown()
    }
    @After fun teardown() { history.destroy(); voice.destroy(); controller.destroy() }

    @Test fun `history off records nothing and the panel offers one tap opt in`() {
        dictate()
        assertEquals("Synthetic.", host.editor.committed); assertFalse(file.exists())
        strip.history.performClick(); advance(0)
        assertEquals(KeyboardHistory.State.OPT_IN, history.state)
        assertEquals(View.VISIBLE, panel.visibility)
        assertEquals(View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS, keys.importantForAccessibility)
        assertEquals(View.INVISIBLE, keys.visibility)
        assertTrue(texts(panel).any { it.contains("never sent to your computer") })
        val keep = (0 until panel.list.childCount).map { panel.list.getChildAt(it) }.filterIsInstance<Button>().first { it.text == "Keep history on this phone" }
        keep.performClick(); advance(0)
        assertTrue(store.enabled); assertEquals(KeyboardHistory.State.LIST, history.state)
        assertTrue(texts(panel).any { it.startsWith("No dictations yet") })
        dictate("Second.", "second")
        assertEquals(listOf("Second."), store.entries().map { it.text })
    }

    @Test fun `off keeps old dictations available for insertion in the keyboard`() {
        store.enable()
        store.record("Retained fixture", null, null, host.info)
        store.disable()
        strip.history.performClick(); advance(0)
        assertEquals(KeyboardHistory.State.LIST, history.state)
        assertTrue(texts(panel).any { it.contains("Retained fixture") })
        assertTrue(panel.subtitle.text.contains("History off"))
        history.insertEntry(store.entries().single())
        assertEquals("Retained fixture", host.editor.committed)
        assertFalse(store.enabled)
    }

    @Test fun `inserted finals record clean-up raw and app and use raw records what was inserted`() {
        shadowOf(host.packageManager).installPackage(PackageInfo().apply {
            packageName = "com.example.chat"
            applicationInfo = ApplicationInfo().apply { packageName = "com.example.chat"; nonLocalizedLabel = "Example Chat" }
        })
        host.info.packageName = "com.example.chat"
        store.enable()
        dictate("Synthetic.", "synthetic", corrected = true)
        val entry = store.entries().single()
        assertEquals("Synthetic.", entry.text); assertEquals("synthetic", entry.raw); assertEquals("Example Chat", entry.app)
        strip.raw.performClick()
        assertEquals("synthetic", host.editor.committed)
        assertEquals("synthetic", store.entries().single().text); assertNull(store.entries().single().raw)
    }

    @Test fun `cancelled empty and incognito dictations are never recorded`() {
        store.enable()
        tap(); stream.ready(); stream.partial(); advance(16); voice.cancel("Cancelled")
        dictate("", "")
        host.info.imeOptions = EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING
        dictate()
        assertEquals("Synthetic.", host.editor.committed)
        assertFalse(file.exists()); assertTrue(store.entries().isEmpty())
    }

    @Test fun `tapping an entry reinserts at the cursor with dictation spacing and returns to keys`() {
        store.enable(); store.record("world", null, "Notes", host.info)
        host.editor.committed = "Hello"; voice.selection(0, 0, 5, 5, -1, -1)
        strip.history.performClick(); advance(0)
        assertEquals(KeyboardHistory.State.LIST, history.state)
        val row = rows().single()
        assertTrue(texts(row).contains("world")); assertTrue(texts(row).contains("2 min ago · Notes"))
        row.performClick()
        assertEquals("Hello world", host.editor.committed)
        assertEquals(KeyboardHistory.State.CLOSED, history.state); assertEquals(View.GONE, panel.visibility)
        assertEquals(View.IMPORTANT_FOR_ACCESSIBILITY_AUTO, keys.importantForAccessibility)
        assertEquals(View.VISIBLE, keys.visibility)
        assertEquals(0, panel.list.childCount)
        val entry = store.entries().single()
        host.editor.committed = "Say (" ; voice.selection(5, 5, 5, 5, -1, -1)
        history.insertEntry(entry); assertEquals("Say (world", host.editor.committed)
        host.editor.committed = ""; voice.selection(0, 0, 0, 0, -1, -1)
        history.insertEntry(entry); assertEquals("world", host.editor.committed)
    }

    @Test fun `strip button toggles the panel and dictation start closes it`() {
        store.enable()
        strip.history.performClick(); advance(0)
        assertTrue(history.open); assertTrue(strip.history.isActivated)
        assertEquals("Close dictation history", strip.history.contentDescription)
        strip.history.performClick()
        assertFalse(history.open); assertEquals("Dictation history", strip.history.contentDescription)
        panel.close.performClick(); assertFalse(history.open)
        strip.history.performClick(); advance(0); assertTrue(history.open)
        tap(); assertTrue(voice.active)
        // Timed actions use the idle-control space; the mic remains at the trailing edge.
        assertFalse(history.open); assertEquals(View.GONE, strip.history.visibility)
        voice.cancel()
        assertEquals(View.VISIBLE, strip.history.visibility)
    }

    @Test fun `long press actions copy insert raw and delete with TalkBack labels`() {
        store.enable(); store.record("Cleaned words.", "cleaned words um", "Mail", host.info)
        strip.history.performClick(); advance(0)
        val row = rows().single()
        assertTrue(row.contentDescription.contains("2 minutes ago in Mail"))
        val labels = row.createAccessibilityNodeInfo().actionList.mapNotNull { it.label?.toString() }
        assertTrue(labels.containsAll(listOf("Insert", "More options", "Copy", "Insert raw", "Delete")))
        val entry = history.entries.single()
        history.copy(entry)
        assertEquals("Cleaned words.", host.getSystemService(ClipboardManager::class.java).primaryClip!!.getItemAt(0).text)
        history.insertEntry(entry, raw = true)
        assertEquals("cleaned words um", host.editor.committed)
        strip.history.performClick(); advance(0)
        history.delete(history.entries.single())
        assertTrue(history.entries.isEmpty()); assertTrue(store.entries().isEmpty())
        assertTrue(texts(panel).any { it.startsWith("No dictations yet") })
    }

    @Test fun `hiding the keyboard closes the panel and drops loaded text`() {
        store.enable(); store.record("private note", null, null, host.info)
        strip.history.performClick(); advance(0)
        assertEquals(1, history.entries.size)
        history.close()
        assertTrue(history.entries.isEmpty()); assertEquals(0, panel.list.childCount)
    }
}
