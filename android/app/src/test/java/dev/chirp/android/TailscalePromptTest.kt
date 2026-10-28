package dev.chirp.android

import android.Manifest
import android.content.ComponentName
import android.content.Intent
import android.content.IntentFilter
import android.inputmethodservice.InputMethodService
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Looper
import android.view.ContextThemeWrapper
import android.view.MotionEvent
import android.view.View
import android.view.inputmethod.EditorInfo
import okhttp3.HttpUrl.Companion.toHttpUrl
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
import org.robolectric.shadows.ShadowNetworkCapabilities
import java.time.Duration

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class TailscalePromptTest {
    class Host : InputMethodService() {
        val editor = ChirpImeServiceTest.Editor()
        val info = EditorInfo().apply { inputType = android.text.InputType.TYPE_CLASS_TEXT; initialSelStart = 0; initialSelEnd = 0 }
        override fun getCurrentInputConnection() = editor.connection
        override fun getCurrentInputEditorInfo() = info
    }
    class FakeTailscale(var installed: Boolean = true, var connected: Boolean = false) : TailscaleControl {
        var connects = 0
        var opens = 0
        var watcher: (() -> Unit)? = null
        override fun installed() = installed
        override fun connected() = connected
        override fun watch(changed: () -> Unit): AutoCloseable { watcher = changed; return AutoCloseable { watcher = null } }
        override fun connect() = installed.also { if (it) connects++ }
        override fun open() = installed.also { if (it) opens++ }
        fun set(value: Boolean) { connected = value; watcher?.invoke() }
    }
    private val controller = Robolectric.buildService(Host::class.java)
    private lateinit var host: Host
    private lateinit var voice: KeyboardDictation
    private lateinit var strip: KeyboardStrip
    private lateinit var stream: ChirpImeServiceTest.FakeTransport
    private var transports = 0
    private val tailscale = FakeTailscale()
    private fun advance(ms: Long) = shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(ms))
    private fun keyboard(url: String = "https://mac.example.ts.net/chirp") {
        voice = KeyboardDictation(host, learning = EditLearning(host, io = { it() }),
            captureFactory = { frame, _, done -> ChirpImeServiceTest.FakeCapture(frame, done, mutableListOf()) },
            transportFactory = { _, _, event, failure -> transports++; ChirpImeServiceTest.FakeTransport(event, failure, mutableListOf()).also { stream = it } },
            prepare = {}, resync = { _, _ -> }, pairing = { Pairing.from(url, "synthetic") }, checkHealth = false, tailscale = tailscale,
            policy = PrewarmPolicy().apply { dictated(null) })
        strip = KeyboardStrip(ContextThemeWrapper(host, R.style.Theme_Chirp)); voice.attach(strip)
        voice.input(host.info, false); voice.shown()
    }
    private fun prompted(status: String, button: String) {
        assertEquals(View.VISIBLE, strip.status.visibility)
        assertEquals(status, strip.status.text.toString())
        assertEquals(View.VISIBLE, strip.action.visibility)
        assertEquals(button, strip.action.text.toString())
        assertTrue(strip.cancel.isEnabled)
    }
    private fun collapsed() {
        assertEquals(View.GONE, strip.status.visibility); assertEquals(View.GONE, strip.action.visibility)
    }
    @Before fun setup() {
        controller.create(); host = controller.get()
        shadowOf(RuntimeEnvironment.getApplication()).grantPermissions(Manifest.permission.RECORD_AUDIO)
    }
    @After fun teardown() { if (::voice.isInitialized) voice.destroy(); controller.destroy() }

    @Test fun `opening the keyboard with Tailscale off offers Turn on and recovers when the VPN comes up`() {
        keyboard()
        prompted("Tailscale is off", "Turn on")
        assertEquals("Tailscale is off. Turn on", strip.status.contentDescription.toString())
        strip.action.performClick()
        assertEquals(1, tailscale.connects)
        assertEquals("Connecting Tailscale…", strip.status.text.toString())
        assertEquals(View.GONE, strip.action.visibility)
        val before = transports
        tailscale.set(true)
        assertEquals("Tailscale connected", strip.status.text.toString())
        assertEquals("Reconnecting must prewarm a fresh transport", before + 1, transports)
        advance(5000); collapsed()
        // A late timeout from the connect attempt must not replace the recovered row.
        advance(10000); collapsed()
    }
    @Test fun `a connect that Tailscale cannot finish falls back to opening Tailscale`() {
        keyboard()
        strip.status.performClick()
        assertEquals(1, tailscale.connects)
        advance(10000)
        prompted("Tailscale didn't connect", "Open Tailscale")
        strip.action.performClick()
        assertEquals(1, tailscale.opens)
    }
    @Test fun `missing Tailscale opens Chirp network setup`() {
        tailscale.installed = false
        keyboard()
        prompted("Tailscale isn't installed", "Set up")
        strip.action.performClick()
        val intent = shadowOf(host).nextStartedActivity
        assertEquals(SetupActivity::class.java.name, intent.component?.className)
        assertEquals("network", intent.getStringExtra("section"))
        assertEquals(0, tailscale.connects)
    }
    @Test fun `connected Tailscale and non-tailnet pairings never prompt`() {
        tailscale.connected = true
        keyboard(); collapsed()
        voice.destroy()
        tailscale.connected = false
        keyboard("https://mac.example.test"); collapsed()
        assertNull("Non-tailnet pairings must not watch VPN state", tailscale.watcher)
    }
    @Test fun `dismissing or typing past the prompt keeps it away until a dictation attempt or reconnect`() {
        keyboard()
        strip.cancel.performClick(); collapsed()
        voice.hidden(); assertNull(tailscale.watcher)
        voice.shown(); collapsed()
        // Trying to dictate while off brings the reason back instead of a generic network error.
        voice.touch(MotionEvent.ACTION_DOWN); advance(40); voice.touch(MotionEvent.ACTION_UP)
        stream.failure()
        assertFalse(voice.active)
        prompted("Tailscale is off", "Turn on")
        voice.beforeEdit(); collapsed()
        voice.hidden(); voice.shown(); collapsed()
        tailscale.set(true); collapsed()
        tailscale.set(false)
        prompted("Tailscale is off", "Turn on")
    }
    @Test fun `tailnet hosts are recognised without DNS`() {
        for (url in listOf("https://mac.example.ts.net/chirp", "https://MAC.Example.TS.NET", "https://100.64.0.1", "https://100.127.255.254",
            "https://[fd7a:115c:a1e0::1]")) assertTrue(url, TailscaleControl.routes(url.toHttpUrl()))
        for (url in listOf("https://mac.example.test", "https://ts.net.example.test", "https://100.63.255.255", "https://100.128.0.1",
            "https://192.168.1.2", "https://[fd7a:115c:a1e1::1]", "https://[fe80::1]")) assertFalse(url, TailscaleControl.routes(url.toHttpUrl()))
    }
    @Test fun `Android control sends an explicit connect broadcast only when Tailscale is installed`() {
        val app = RuntimeEnvironment.getApplication()
        val control = AndroidTailscale(app)
        assertFalse(control.installed()); assertFalse(control.connect()); assertFalse(control.open())
        assertTrue(shadowOf(app).broadcastIntents.isEmpty())
        val main = ComponentName(TailscaleControl.PACKAGE, "com.tailscale.ipn.MainActivity")
        shadowOf(app.packageManager).apply {
            addActivityIfNotPresent(main)
            addIntentFilterForActivity(main, IntentFilter(Intent.ACTION_MAIN).apply { addCategory(Intent.CATEGORY_LAUNCHER) })
        }
        assertTrue(control.installed()); assertTrue(control.connect())
        val sent = shadowOf(app).broadcastIntents.single()
        assertEquals(TailscaleControl.CONNECT, sent.action)
        assertEquals(ComponentName(TailscaleControl.PACKAGE, TailscaleControl.RECEIVER), sent.component)
        assertTrue(control.open())
        assertEquals(TailscaleControl.PACKAGE, shadowOf(app).nextStartedActivity.component?.packageName)
    }
    @Test fun `Android control reports VPN networks and stops watching on close`() {
        val app = RuntimeEnvironment.getApplication()
        val connectivity = app.getSystemService(ConnectivityManager::class.java)
        val control = AndroidTailscale(app)
        assertFalse(control.connected())
        val watch = control.watch {}
        assertEquals(1, shadowOf(connectivity).networkCallbacks.size)
        watch.close()
        assertTrue(shadowOf(connectivity).networkCallbacks.isEmpty())
        val vpn = ShadowNetworkCapabilities.newInstance().also { shadowOf(it).addTransportType(NetworkCapabilities.TRANSPORT_VPN) }
        shadowOf(connectivity).setNetworkCapabilities(connectivity.activeNetwork, vpn)
        assertTrue(control.connected())
    }
}
