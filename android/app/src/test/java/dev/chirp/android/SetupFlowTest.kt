package dev.chirp.android

import org.junit.Assert.*
import org.junit.Test

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
    @Test fun `onboarding titles match the iOS wizard`() {
        assertEquals("Welcome to Chirp", WELCOME_TITLE)
        assertEquals("Pair your computer", PAIR_PAGE_TITLE)
        assertEquals("About pairing", ABOUT_PAIRING)
        assertEquals("Allow the microphone", MICROPHONE_TITLE)
        assertEquals("What Chirp keeps", ABOUT_MICROPHONE)
        assertEquals("Turn on Chirp Keyboard", KEYBOARD_TITLE)
        assertEquals("About the keyboard", ABOUT_KEYBOARD)
        assertEquals(
            "On your computer, open Chirp → Settings → Devices → Pair a Phone, or run chirp-server pair on your server.",
            PAIRING_STEPS)
        assertFalse(PAIRING_STEPS.contains("Mac"))
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
