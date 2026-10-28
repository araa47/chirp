package dev.chirp.android

import android.Manifest
import android.inputmethodservice.InputMethodService
import android.os.Looper
import android.view.ContextThemeWrapper
import android.view.MotionEvent
import android.view.View
import android.view.inputmethod.EditorInfo
import java.net.UnknownHostException
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
class OfflineStateTest {
    class Host : InputMethodService() {
        val editor = ChirpImeServiceTest.Editor()
        val info = EditorInfo().apply { inputType = android.text.InputType.TYPE_CLASS_TEXT; initialSelStart = 0; initialSelEnd = 0 }
        override fun getCurrentInputConnection() = editor.connection
        override fun getCurrentInputEditorInfo() = info
    }
    private val controller = Robolectric.buildService(Host::class.java)
    private lateinit var host: Host
    private lateinit var voice: KeyboardDictation
    private lateinit var strip: KeyboardStrip
    private lateinit var stream: ChirpImeServiceTest.FakeTransport
    private var transports = 0
    private val tailscale = TailscalePromptTest.FakeTailscale(connected = true)
    private var health: () -> Health = { Health(true, false, true, false, null) }
    private fun advance(ms: Long) = shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(ms))
    private fun await(condition: () -> Boolean) {
        repeat(300) { shadowOf(Looper.getMainLooper()).idle(); if (condition()) return; Thread.sleep(10) }
        fail("timed out")
    }
    private fun keyboard(url: String = "https://mac.example.test/chirp", checkHealth: Boolean = false) {
        voice = KeyboardDictation(host, learning = EditLearning(host, io = { it() }),
            captureFactory = { frame, _, done -> ChirpImeServiceTest.FakeCapture(frame, done, mutableListOf()) },
            transportFactory = { _, _, event, failure -> transports++; ChirpImeServiceTest.FakeTransport(event, failure, mutableListOf()).also { stream = it } },
            prepare = {}, resync = { _, _ -> }, pairing = { Pairing.from(url, "synthetic") }, checkHealth = checkHealth,
            tailscale = tailscale, healthCheck = { health() }, policy = PrewarmPolicy().apply { dictated(null) })
        strip = KeyboardStrip(ContextThemeWrapper(host, R.style.Theme_Chirp)); voice.attach(strip)
        voice.input(host.info, false); voice.shown()
    }
    private fun fails(kind: ConnectionFailure.Kind) { stream.failureKind = kind; stream.failure() }
    private fun tap() { voice.touch(MotionEvent.ACTION_DOWN); advance(40); voice.touch(MotionEvent.ACTION_UP) }
    private fun assertOfflineRow() {
        assertEquals(View.VISIBLE, strip.status.visibility)
        assertEquals("Computer offline · Check again", strip.status.text.toString())
        assertEquals("Computer offline, double-tap to retry", strip.status.contentDescription.toString())
        assertTrue(strip.status.isClickable); assertTrue(strip.cancel.isEnabled)
        assertEquals(View.GONE, strip.action.visibility)
        assertBadge(true)
    }
    private fun assertBadge(offline: Boolean) {
        assertEquals(if (offline) "Computer offline, double-tap to retry" else "Microphone: tap to dictate, hold to talk", strip.mic.contentDescription.toString())
    }
    private fun assertNotOffline() = assertNotEquals("Computer offline, double-tap to retry", strip.mic.contentDescription.toString())
    private fun assertQuiet() { assertEquals(View.GONE, strip.status.visibility); assertEquals(View.GONE, strip.action.visibility) }
    @Before fun setup() {
        controller.create(); host = controller.get()
        shadowOf(RuntimeEnvironment.getApplication()).grantPermissions(Manifest.permission.RECORD_AUDIO)
    }
    @After fun teardown() { if (::voice.isInitialized) voice.destroy(); controller.destroy() }

    @Test fun `a failed prewarm marks the Mac offline with a badge, a status row and TalkBack actions`() {
        keyboard(); assertQuiet(); assertBadge(false)
        fails(ConnectionFailure.Kind.DNS)
        assertOfflineRow()
        // The row is drawable at keyboard width without exceptions.
        strip.measure(View.MeasureSpec.makeMeasureSpec(1080, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(168, View.MeasureSpec.EXACTLY))
        strip.layout(0, 0, 1080, 168)
        strip.draw(android.graphics.Canvas(android.graphics.Bitmap.createBitmap(1080, 168, android.graphics.Bitmap.Config.ARGB_8888)))
    }
    @Test fun `the mark survives hiding and showing within 30 seconds and then expires`() {
        keyboard(); fails(ConnectionFailure.Kind.DOWN); assertOfflineRow()
        voice.hidden(); advance(10000); voice.shown(); assertOfflineRow()
        advance(19000); assertOfflineRow()
        advance(2000); assertQuiet(); assertBadge(false)
        voice.hidden(); voice.shown(); assertQuiet()
    }
    @Test fun `TLS and unclassified failures are not offline`() {
        keyboard(); fails(ConnectionFailure.Kind.TLS); assertQuiet(); assertBadge(false)
        keyboard(); fails(ConnectionFailure.Kind.OTHER); assertQuiet(); assertBadge(false)
    }
    @Test fun `dismissing or typing past the row keeps the badge until the Mac answers`() {
        keyboard(); fails(ConnectionFailure.Kind.DNS)
        strip.cancel.performClick(); assertQuiet(); assertBadge(true)
        voice.hidden(); voice.shown(); assertQuiet(); assertBadge(true)
        voice.destroy(); keyboard(); fails(ConnectionFailure.Kind.DNS); assertOfflineRow()
        voice.beforeEdit(); assertQuiet(); assertBadge(true)
    }
    @Test fun `tapping the mic while offline dictates at once without a health check, and Ready clears the mark`() {
        keyboard(); fails(ConnectionFailure.Kind.DNS)
        val before = transports
        tap()
        assertTrue(voice.active); assertEquals("a fresh transport, the failed one is gone", before + 1, transports)
        stream.ready(); assertNotOffline()
    }
    @Test fun `tapping the status row retries like the mic`() {
        keyboard(); fails(ConnectionFailure.Kind.DNS)
        strip.status.performClick()
        assertTrue(voice.active)
    }
    @Test fun `a retry re-checks health, then dictates when the Mac is back`() {
        health = { throw UnknownHostException("synthetic") }
        keyboard(checkHealth = true)
        await { strip.status.text.toString() == "Computer offline · Check again" }
        assertOfflineRow()
        val gate = java.util.concurrent.CountDownLatch(1)
        health = { gate.await(); Health(true, false, true, false, null) }
        tap()
        assertFalse("must not start before the check returns", voice.active)
        assertEquals("Checking your computer…", strip.status.text.toString())
        gate.countDown()
        await { voice.active }
        assertNotOffline()
    }
    @Test fun `a retry that still fails names the reason and offers Check Tailscale`() {
        health = { throw UnknownHostException("synthetic") }
        keyboard(checkHealth = true)
        await { strip.status.text.toString() == "Computer offline · Check again" }
        tap()
        await { strip.status.text.toString().startsWith("Can't find your computer") }
        assertFalse(voice.active)
        assertEquals(english.getString(DictationAction.NETWORK.label), strip.status.contentDescription.toString().substringAfterLast(". "))
        assertBadge(true)
        advance(5000); assertBadge(true)
    }
    @Test fun `a second tap during the check never waits for it`() {
        health = { throw UnknownHostException("synthetic") }
        keyboard(checkHealth = true)
        await { strip.status.text.toString() == "Computer offline · Check again" }
        health = { Thread.sleep(2000); Health(true, false, true, false, null) }
        tap(); assertFalse(voice.active)
        advance(100); tap()
        assertTrue(voice.active)
    }
    @Test fun `a health answer that is not about reachability never marks offline`() {
        health = { throw java.io.IOException("Health unavailable") }
        keyboard(checkHealth = true)
        advance(500); Thread.sleep(100); advance(500)
        assertQuiet(); assertBadge(false)
        tap(); assertTrue(voice.active)
    }
    @Test fun `a failed dictation marks offline and the specific reason shows first`() {
        keyboard(); tap(); assertTrue(voice.active)
        fails(ConnectionFailure.Kind.DNS)
        assertFalse(voice.active)
        assertEquals("${ConnectionFailure.Kind.DNS.english()} · ${english.getString(DictationAction.NETWORK.label)}", strip.status.text.toString())
        assertEquals(english.getString(DictationAction.NETWORK.label), strip.status.contentDescription.toString().substringAfterLast(". "))
        assertBadge(true)
        advance(5000); assertBadge(true)
    }
    @Test fun `a TLS failure during dictation names it and offers no Tailscale action`() {
        keyboard(); tap(); fails(ConnectionFailure.Kind.TLS)
        assertEquals(ConnectionFailure.Kind.TLS.english(), strip.status.text.toString())
        assertEquals(View.GONE, strip.action.visibility); assertBadge(false)
    }
    @Test fun `Tailscale being off takes priority over the offline row`() {
        tailscale.connected = false
        keyboard("https://mac.example.ts.net/chirp")
        assertEquals("Tailscale is off", strip.status.text.toString())
        fails(ConnectionFailure.Kind.DNS)
        assertEquals("Tailscale is off", strip.status.text.toString())
        assertEquals("Turn on", strip.action.text.toString())
        tailscale.connected = true
    }
}
