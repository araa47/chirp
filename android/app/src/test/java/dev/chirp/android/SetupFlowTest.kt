package dev.chirp.android

import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37])
class OnboardingCopyTest {
    private val resources get() = RuntimeEnvironment.getApplication().resources
    @Test fun `onboarding titles match the iOS wizard`() {
        fun text(id: Int) = resources.getString(id)
        assertEquals("Welcome to Chirp", text(R.string.onboarding_title_welcome))
        assertEquals("Pair your computer", text(R.string.onboarding_title_pair))
        assertEquals("About pairing", text(R.string.onboarding_about_pairing))
        assertEquals("Allow the microphone", text(R.string.onboarding_title_microphone))
        assertEquals("What Chirp keeps", text(R.string.onboarding_about_microphone))
        assertEquals("Turn on Chirp Keyboard", text(R.string.onboarding_title_keyboard))
        assertEquals("About the keyboard", text(R.string.onboarding_about_keyboard))
        val steps = pairingSteps(resources)
        assertEquals("On your computer, open Chirp → Settings → Devices → Pair a Phone, or run chirp-server pair on your server.", steps)
        assertFalse(steps.contains("Mac"))
    }
}

class SetupFlowTest {
    @Test fun `every requirement combination respects the chosen mode and skip`() {
        for (mode in InputMode.entries) for (enabled in listOf(false, true)) for (selected in listOf(false, true))
            for (mic in listOf(false, true)) for (paired in listOf(false, true)) for (bubble in listOf(false, true))
                for (skipped in listOf(false, true)) {
                    val ready = if (mode == InputMode.KEYBOARD) enabled && selected else bubble || skipped
                    val expected = when { !ready -> PAGE_KEYBOARD; !mic -> PAGE_MIC; !paired -> PAGE_PAIR; else -> ONBOARDING_DONE }
                    assertEquals(expected, setupStep(enabled, selected, mic, paired, mode = mode, bubbleEnabled = bubble, floatingMicSkipped = skipped))
                }
    }
    @Test fun `fresh installs start at welcome then require a choice`() {
        assertEquals(PAGE_WELCOME, setupStep(false, false, false, false, welcomed = false, mode = null))
        assertEquals(PAGE_CHOICE, setupStep(false, false, false, false, mode = null))
        assertEquals(PAGE_CHOICE, setupStep(false, false, true, true, mode = null))
    }
    @Test fun `every legacy keyboard and bubble combination migrates without changing its behaviour`() {
        for (enabled in listOf(false, true)) for (selected in listOf(false, true)) for (bubble in listOf(false, true)) {
            val expected = when { selected || (enabled && !bubble) -> InputMode.KEYBOARD; bubble -> InputMode.OWN_KEYBOARD; else -> null }
            assertEquals(expected, migratedInputMode(enabled, selected, bubble))
        }
    }
    @Test fun `each recoverable dictation error has a specific action`() {
        assertEquals(DictationAction.PAIR, statusOf("Pair your computer in Chirp settings").action)
        assertEquals(DictationAction.PAIR, statusOf("Pairing refused — pair again in Chirp settings").action)
        assertEquals(DictationAction.MICROPHONE, statusOf("Allow microphone in Chirp settings").action)
        assertEquals(DictationAction.NETWORK, statusOf("Computer unreachable — is Tailscale on?").action)
        assertNull(statusOf("Listening…").action)
        assertNull(statusOf("Inserted · tap mic to dictate again").action)
    }
}
