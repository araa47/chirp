package dev.chirp.android

import dev.chirp.android.settings.connectionSummary
import dev.chirp.android.shell.HomeFix
import dev.chirp.android.shell.SetupNeed
import dev.chirp.android.ui.StatusKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/** Enum and model labels hold resource ids (#339); the English they resolve to is what users and e2e scripts read. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37])
class LabelsTest {
    private val resources get() = RuntimeEnvironment.getApplication().resources
    private fun text(id: Int) = resources.getString(id)

    @Test fun `enum labels resolve to their English`() {
        assertEquals(listOf("Off", "Always", "In chat apps only"), AutoEnterMode.entries.map { text(it.label) })
        assertEquals(listOf("Never", "1 year", "90 days", "30 days"), NotesRetention.entries.map { text(it.label) })
        assertEquals(listOf("Learning", "In use", "Off"), LearnedState.entries.map { text(it.title) })
        assertEquals(listOf("Gboard-like", "Samsung-like", "HeliBoard classic", "HeliBoard rounded", "HeliBoard Holo"), KeyboardLook.entries.map { text(it.label) })
        assertEquals("HeliBoard's Holo style", text(KeyboardLook.HELIBOARD_HOLO.description))
        assertEquals(listOf("Pair computer", "Allow", "Turn on", "Check again"), HomeFix.entries.map { text(it.label) })
        assertEquals(listOf("pair your computer", "allow the microphone", "turn on Chirp Keyboard", "turn on the floating mic"), SetupNeed.entries.map { text(it.next) })
        assertEquals(listOf("Pair computer", "Allow", "Set up", "Set up"), SetupNeed.entries.map { text(it.action) })
    }
    @Test fun `stored values do not follow the labels`() {
        assertEquals(listOf("off", "always", "chat"), AutoEnterMode.entries.map { it.key })
        assertEquals(listOf(0, 365, 90, 30), NotesRetention.entries.map { it.days })
        assertEquals(listOf("LEARNING", "ACTIVE", "OFF"), LearnedState.entries.map { it.name })
    }
    @Test fun `clean-up and private session help keep their wording`() {
        assertEquals("Polishes punctuation and filler words on your computer; text never leaves it", cleanupDescription(null).resolve(resources))
        val away = Health(true, false, true, true, "api.example.test")
        assertEquals("When enabled, sends text to api.example.test for clean-up", cleanupDescription(away).resolve(resources))
        assertEquals("When enabled, sends text to the external host for clean-up", cleanupDescription(away.copy(correctionHost = null)).resolve(resources))
        assertEquals("Exclude dictations from history until the screen locks or 1 hour passes. Clean-up and the connection to your computer work as usual.",
            text(PrivateSession.HELP))
    }
    @Test fun `the connection row says what it always said`() {
        fun row(paired: Boolean, reachable: Boolean?, checking: Boolean, health: Health?) = connectionSummary(paired, "mac.test", reachable, checking, health).let {
            listOf(it.title, it.summary, it.hint).map { part -> part?.resolve(resources) }
        }
        val local = Health(true, false, true, false, null, engine = "Parakeet")
        assertEquals(listOf("Not paired", "Pair your computer to dictate", null), row(false, null, false, null))
        assertEquals(listOf("Checking · mac.test", "Engine not reported · clean-up off", null), row(true, null, true, null))
        assertEquals(listOf("Computer unreachable · mac.test", "Parakeet · clean-up on your computer",
            "Check Tailscale is connected on both devices. Wake the computer and start Chirp, then check again."), row(true, false, false, local))
        assertEquals(listOf("Paired · mac.test", "Computer is loading its speech model", null), row(true, true, false, local.copy(ready = false)))
        assertEquals(listOf("Connected · mac.test", "Parakeet · clean-up via api.example.test", null), row(true, true, false, local.copy(correctionLeavesMachine = true, correctionHost = "api.example.test")))
        assertEquals(StatusKind.Success, connectionSummary(true, "mac.test", true, false, local).kind)
        assertNull(connectionSummary(true, "mac.test", null, false, local).hint)
    }
}
