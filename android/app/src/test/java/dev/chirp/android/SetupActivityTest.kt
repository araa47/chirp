package dev.chirp.android

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Looper
import dev.chirp.android.settings.SettingsPage
import dev.chirp.android.shell.ShellTab
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.android.controller.ActivityController

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class SetupActivityTest {
    class TestSetup : SetupActivity() {
        override val advancedProtection = AdvancedProtection { protectedMode }
        var protectedMode = false
        lateinit var received: (String?) -> Unit
        lateinit var cancelled: () -> Unit
        lateinit var failed: () -> Unit
        var scans = 0
        var mac: () -> Health = { Health(true, false, true, false, null, engine = "Parakeet") }
        var saved: Pair<Pairing, Health>? = null
        /** The Mac's answer waits for the test, as a real network call would. */
        var gate = kotlinx.coroutines.CompletableDeferred<Unit>()
        override suspend fun checkMac(call: okhttp3.Call): Health { gate.await(); return mac() }
        override fun savePairing(pairing: Pairing, health: Health) { saved = pairing to health } // Robolectric has no AndroidKeyStore.
        override fun scanPairingQr(received: (String?) -> Unit, cancelled: () -> Unit, failed: () -> Unit) {
            scans++; this.received = received; this.cancelled = cancelled; this.failed = failed
        }
    }
    private lateinit var controller: ActivityController<TestSetup>
    private lateinit var activity: TestSetup
    private val syntheticLink = "chirp://pair?url=https%3A%2F%2Fmac.example.test%2Fchirp&token=synthetic%2Btoken%3D"
    private fun shows(text: String) = activity.state.status.resolve(activity.resources).contains(text)
    private fun scan() = activity.scan()
    @Before fun setUp() {
        controller = Robolectric.buildActivity(TestSetup::class.java).setup()
        activity = controller.get()
    }
    @After fun tearDown() { if (!activity.isDestroyed) controller.pause().stop().destroy() }

    private fun idle() { activity.gate.complete(Unit); shadowOf(Looper.getMainLooper()).idle() }
    private fun prefs() = activity.getSharedPreferences("chirp", 0)

    @Test fun `first run opens on the welcome page`() {
        assertEquals(PAGE_WELCOME, activity.state.step); assertEquals(PAGE_WELCOME, activity.state.entryStep)
        assertFalse(activity.state.shellOpen); assertFalse(activity.state.connected)
    }
    @Test fun `a scanned code is tested and saved without another tap, and only after the Mac answers`() {
        scan(); assertEquals(1, activity.scans); assertTrue(activity.state.scanning)
        activity.received(syntheticLink)
        assertFalse(activity.state.scanning); assertEquals(syntheticLink, activity.state.link); assertEquals(PAGE_PAIR, activity.state.step)
        assertTrue(activity.state.checking); assertTrue(shows("Checking your computer")); assertNull(activity.saved)
        assertFalse(prefs().contains("token"))
        idle()
        val (pairing, health) = activity.saved!!
        assertEquals("https://mac.example.test/chirp/v1/health", pairing.endpoint("v1/health").toString())
        assertEquals("synthetic+token=", pairing.token); assertEquals("Parakeet", health.engine)
        assertFalse(activity.state.checking); assertTrue(activity.state.connected); assertEquals(true, activity.state.reachable)
        assertEquals("", activity.state.link); assertNull(activity.state.pairIssue)
    }
    @Test fun `an unreachable Mac saves nothing, keeps the link for a retry and offers one action`() {
        activity.mac = { throw java.io.IOException("synthetic") }
        scan(); activity.received(syntheticLink); idle()
        assertNull(activity.saved); assertFalse(prefs().contains("token"))
        assertEquals(PairIssue.Unreachable, activity.state.pairIssue); assertEquals(false, activity.state.reachable)
        assertFalse(activity.state.connected); assertFalse(activity.state.checking); assertEquals(syntheticLink, activity.state.link)
        activity.mac = { Health(true, false, true, false, null, engine = "Parakeet") }
        activity.gate = kotlinx.coroutines.CompletableDeferred()
        activity.testPairing(save = true); assertNull(activity.state.pairIssue); idle()
        assertNotNull(activity.saved); assertTrue(activity.state.connected)
    }
    @Test fun `a pasted link that parses is saved, anything else is not tested`() {
        activity.editLink("not a link"); assertFalse(activity.state.checking); assertEquals("not a link", activity.state.link)
        activity.editLink(syntheticLink); assertTrue(activity.state.checking); idle()
        assertNotNull(activity.saved); assertTrue(activity.state.connected)
    }
    @Test fun `scanner rejects missing malformed non pairing and insecure payloads`() {
        listOf(null, "", "https://example.test", "chirp://pair?url=http://mac.example.test&token=synthetic",
            "chirp://pair?url=https://mac.example.test&token=a&token=b").forEach { value ->
            scan(); activity.received(value)
            assertEquals("", activity.state.link); assertTrue(shows("Invalid Chirp pairing link")); assertEquals(PairIssue.InvalidLink, activity.state.pairIssue)
            assertFalse(activity.state.scanning); assertFalse(activity.state.checking)
        }
        idle(); assertNull(activity.saved)
    }
    @Test fun `cancel leaves the page as it was and scanner failure points at pasting`() {
        activity.state.link = syntheticLink
        scan(); activity.cancelled()
        assertFalse(activity.state.scanning); assertTrue(shows("Scan cancelled")); assertEquals(syntheticLink, activity.state.link); assertNull(activity.state.pairIssue)
        scan(); activity.failed()
        assertFalse(activity.state.scanning); assertTrue(shows("check Google Play services")); assertEquals(syntheticLink, activity.state.link)
        assertEquals(PairIssue.ScannerUnavailable, activity.state.pairIssue)
    }
    @Test fun `deep links share the scan path and clear the credential intent`() {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(syntheticLink))
        controller.newIntent(intent)
        assertNull(intent.data); assertEquals(syntheticLink, activity.state.link); assertEquals(PAGE_PAIR, activity.state.step)
        assertTrue(activity.state.checking); idle(); assertNotNull(activity.saved)
        val invalid = Intent(Intent.ACTION_VIEW, Uri.parse("chirp://pair?url=http://mac.example.test&token=synthetic"))
        controller.newIntent(invalid)
        assertNull(invalid.data); assertTrue(shows("Invalid Chirp pairing link"))
    }
    @Test fun `section intents open the pairing page, the settings tab or its connection page, and History`() {
        activity.state.step = PAGE_MIC
        controller.newIntent(Intent().putExtra("section", "settings"))
        assertTrue(activity.state.shellOpen); assertEquals(ShellTab.Settings, activity.state.tab); assertNull(activity.state.settingsPage)
        assertTrue("opened from outside: back returns there", activity.state.exitOnBack)
        controller.newIntent(Intent().putExtra("section", "pair"))
        assertFalse(activity.state.shellOpen); assertEquals(PAGE_PAIR, activity.state.step)
        assertEquals("back from a pair-only page leaves it", PAGE_PAIR, activity.state.entryStep); assertTrue(activity.state.pairFromShell)
        controller.newIntent(Intent().putExtra("section", "connection"))
        assertTrue(activity.state.shellOpen); assertEquals(SettingsPage.Connection, activity.state.settingsPage)
        controller.newIntent(Intent().putExtra("section", "try"))
        assertTrue(activity.state.tryIt); assertEquals(ShellTab.Notes, activity.state.tab); assertFalse(activity.state.exitOnBack)
        controller.newIntent(Intent().putExtra("section", "network"))
        assertEquals(SettingsPage.Connection, activity.state.settingsPage); assertEquals(false, activity.state.reachable)
        controller.newIntent(Intent().putExtra("section", "history"))
        assertEquals(ShellTab.History, activity.state.tab); assertTrue(activity.state.exitOnBack)
    }
    @Test fun `a pairing link closes the shell and goes to the pair page`() {
        controller.newIntent(Intent().putExtra("section", "settings"))
        controller.newIntent(Intent(Intent.ACTION_VIEW, Uri.parse(syntheticLink)))
        assertFalse(activity.state.shellOpen); assertEquals(PAGE_PAIR, activity.state.step)
    }
    @Test fun `new try entry is consumed and opening Settings survives recreation`() {
        val entry = Intent().putExtra("section", "try")
        controller.newIntent(entry)
        assertSame(entry, activity.intent)
        assertFalse(entry.hasExtra("section"))
        assertEquals(ShellTab.Notes, activity.state.tab)
        // Navigation after the entry must survive folding/rotation instead of replaying the try entry.
        activity.state.tab = ShellTab.Settings
        activity.state.settingsPage = SettingsPage.About
        activity = controller.recreate().get()
        assertTrue(activity.state.shellOpen)
        assertEquals(ShellTab.Settings, activity.state.tab)
        assertEquals(SettingsPage.About, activity.state.settingsPage)
        assertFalse(activity.intent.hasExtra("section"))
    }
    @Test fun `advancing goes to the first unmet page and finishing opens Home with the Try it card until dismissed`() {
        val state = activity.state
        state.step = PAGE_KEYBOARD; state.inputMode = InputMode.KEYBOARD; state.inputEnabled = true; state.inputSelected = true
        activity.advance(); assertEquals(PAGE_MIC, state.step); assertFalse(state.shellOpen)
        state.mic = true; activity.advance(); assertEquals(PAGE_PAIR, state.step)
        assertFalse(SettingsStore(activity).onboarded)
        state.paired = true; activity.advance()
        assertTrue(state.shellOpen); assertEquals(ShellTab.Notes, state.tab); assertNull(state.settingsPage); assertTrue(state.tryIt)
        assertTrue("the launcher opens Home from now on", SettingsStore(activity).onboarded)
        state.shellOpen = false; state.tryIt = false
        SettingsStore(activity).tryItDismissed = true
        activity.advance(); assertTrue(state.shellOpen); assertFalse(state.tryIt)
    }
    @Test fun `late scan result cannot feed a destroyed activity`() {
        scan()
        controller.pause().stop().destroy()
        activity.received(syntheticLink)
        assertEquals("", activity.state.link)
    }
    @Test fun `app does not request camera permission`() {
        val info = activity.packageManager.getPackageInfo(activity.packageName, PackageManager.GET_PERMISSIONS)
        assertFalse(info.requestedPermissions.orEmpty().contains(Manifest.permission.CAMERA))
    }
    @Test @Config(sdk = [37]) fun `Android 17 denial does not gate a Tailscale pairing connection`() {
        org.robolectric.Shadows.shadowOf(org.robolectric.RuntimeEnvironment.getApplication()).denyPermissions(LOCAL_NETWORK_PERMISSION)
        activity.state.link = syntheticLink
        activity.testPairing(save = true)
        assertTrue(shows("Checking your computer"))
        assertFalse(activity.state.wifiPermissionNeeded)
        assertFalse(activity.getSharedPreferences("chirp", 0).contains("token"))
    }

    @Test fun `mode migration persists once and explicit choice survives a keyboard switch`() {
        val store = SettingsStore(activity)
        assertNull(store.migrateInputMode(false, false, false))
        assertEquals(InputMode.OWN_KEYBOARD, store.migrateInputMode(true, false, true))
        assertEquals(InputMode.OWN_KEYBOARD, store.migrateInputMode(true, true, false))
        activity.chooseMode(InputMode.KEYBOARD)
        assertEquals(InputMode.KEYBOARD, store.inputMode)
        activity.chooseMode(InputMode.OWN_KEYBOARD)
        assertEquals(InputMode.OWN_KEYBOARD, store.inputMode)
    }
    @Test fun `completed onboarding never reopens when changing mode or losing permissions`() {
        SettingsStore(activity).apply { onboarded = true; inputMode = InputMode.OWN_KEYBOARD }
        controller.pause().stop().destroy()
        controller = Robolectric.buildActivity(TestSetup::class.java).setup(); activity = controller.get()
        assertTrue(activity.state.shellOpen)
    }
    @Test fun `Advanced Protection blocks even a direct Accessibility action`() {
        activity.protectedMode = true
        activity.openAccessibility()
        assertTrue(activity.state.advancedProtection)
        assertNull(shadowOf(activity).nextStartedActivity)
    }
    @Test fun `own keyboard mode skips the keyboard and accepts the explicit floating mic skip`() {
        activity.chooseMode(InputMode.OWN_KEYBOARD)
        activity.state.floatingMicSkipped = true
        activity.advance()
        assertEquals(PAGE_MIC, activity.state.step)
        assertFalse(activity.state.inputEnabled); assertFalse(activity.state.inputSelected)
    }
    @Test fun `returning from Accessibility while still off offers restricted settings help`() {
        activity.chooseMode(InputMode.OWN_KEYBOARD); activity.state.step = PAGE_KEYBOARD
        activity.openAccessibility()
        assertEquals(android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS, shadowOf(activity).nextStartedActivity.action)
        activity.onWindowFocusChanged(true)
        assertEquals(1, activity.state.accessibilityReturns)
        assertEquals(PAGE_KEYBOARD, activity.state.step)
    }
    @Test fun `Accessibility return auto advances once enabled without selecting Chirp Keyboard`() {
        activity.chooseMode(InputMode.OWN_KEYBOARD); activity.state.step = PAGE_KEYBOARD
        activity.openAccessibility()
        android.provider.Settings.Secure.putString(activity.contentResolver, android.provider.Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES, "dev.chirp.android/.ChirpAccessibilityService")
        activity.onWindowFocusChanged(true)
        assertTrue(activity.state.bubbleEnabled)
        assertEquals(PAGE_MIC, activity.state.step)
        assertFalse(activity.state.inputSelected)
    }

}
