package dev.chirp.android

import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/** Small gaps from the cross-platform sweep: Forget pairing, microphone errors and stale wording. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37])
class PolishSweepTest {
    private val context = RuntimeEnvironment.getApplication()

    @Test fun `forget pairing clears the Mac but keeps every other setting`() {
        val store = SettingsStore(context)
        store.health = Health(ready = true, debugRetention = false, correctionAvailable = true, correctionLeavesMachine = false, correctionHost = null)
        store.correction = true
        store.haptics = false; store.soundCues = true; store.onboarded = true; store.notesRecovery = false
        context.getSharedPreferences(SettingsStore.FILE, 0).edit().putString("url", "https://mac.tail1234.ts.net/chirp").putString("token", "x").commit()
        store.forgetPairingPrefs()
        val prefs = context.getSharedPreferences(SettingsStore.FILE, 0)
        listOf("url", "token", "iv", "health", "correction", "correction_explicit").forEach { assertFalse(it, prefs.contains(it)) }
        val again = SettingsStore(context)
        assertNull(again.health)
        assertFalse(again.haptics); assertTrue(again.soundCues); assertTrue(again.onboarded); assertFalse(again.notesRecovery)
    }

    @Test fun `a microphone that fails to open offers mic settings and plays the error cue`() {
        listOf("Microphone unavailable", "Microphone unavailable — check permission in Chirp settings").forEach {
            assertEquals(DictationAction.MICROPHONE, statusOf(it).action); assertTrue(statusOf(it).error)
        }
        assertTrue(statusOf("No microphone signal").error)
    }

    @Test fun `errors point to Chirp settings, the screen that exists`() {
        assertEquals(DictationAction.PAIR, statusOf("Pair your computer in Chirp settings").action)
        assertEquals(DictationAction.MICROPHONE, statusOf("Allow microphone in Chirp settings").action)
    }
}
