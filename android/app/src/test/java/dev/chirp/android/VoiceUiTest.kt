package dev.chirp.android

import dev.chirp.android.AppColour

import android.content.res.Configuration
import android.graphics.Bitmap
import androidx.activity.ComponentActivity
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.unit.Density
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import java.io.File
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37], qualifiers = "w411dp-h891dp-mdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class VoiceUiTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val syntheticLink = "chirp://pair?url=https%3A%2F%2Fmac.example.test%2Fchirp&token=synthetic%2Btoken%3D"
    private class Calls { val seen = mutableListOf<String>()
        fun actions(state: SetupState? = null) = OnboardingActions(grantMic = { seen += "mic" }, keyboardSettings = { seen += "enable" }, picker = { seen += "select" },
            appSettings = { seen += "permissions" }, scan = { seen += "scan" }, pasteLink = { state?.link = it; seen += "paste" }, retry = { seen += "retry" }, finish = { seen += "finish" }, chooseMode = { state?.inputMode = it }) }

    private fun fontScaled(scale: Float, content: @Composable () -> Unit) = fontScaled(mutableFloatStateOf(scale), content)
    private fun fontScaled(scale: State<Float>, content: @Composable () -> Unit) =
        compose.setContent { CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density, scale.value)) { content() } }

    @Test fun `onboarding is five pages and each primary button follows the next unmet requirement`() {
        val state = SetupState(); val calls = Calls()
        compose.setContent { ChirpTheme { Onboarding(state, calls.actions(state)) } }
        compose.onNodeWithContentDescription("Step 1 of 5").assertIsDisplayed()
        compose.onNodeWithText("Welcome to Chirp").assertIsDisplayed()
        compose.onNodeWithText("Get started").performClick()
        compose.onNodeWithText("How you’ll dictate").assertIsDisplayed()
        compose.onNodeWithText("Continue").assertIsNotEnabled()
        compose.runOnIdle { state.inputMode = InputMode.KEYBOARD }
        compose.onNodeWithText("Continue").performClick()
        compose.onNodeWithText("Turn on Chirp Keyboard").assertIsDisplayed()
        compose.onNodeWithContentDescription("Step 3 of 5").assertExists()
        compose.onNodeWithText("Enable Chirp Keyboard").performClick()
        compose.runOnIdle { state.inputEnabled = true }
        compose.onNodeWithText("Select Chirp Keyboard").performClick()
        compose.onNodeWithText("Continue").assertDoesNotExist()
        compose.runOnIdle { state.inputSelected = true }
        compose.onNodeWithText("Continue").performClick()
        compose.onNodeWithText("Allow the microphone").assertIsDisplayed()
        compose.onNodeWithText("Allow microphone").performClick()
        compose.runOnIdle { state.mic = true }
        compose.onNodeWithText("Continue").performClick()
        compose.onNodeWithText("Pair your computer").assertIsDisplayed()
        compose.onNodeWithText("Pair a Phone, or run", substring = true).assertIsDisplayed()
        compose.onNodeWithText("chirp\u2011server\u00A0pair", substring = true).assertIsDisplayed()
        compose.onNodeWithText("on your server.", substring = true).assertIsDisplayed()
        compose.onNodeWithText("About pairing").assertIsDisplayed()
        compose.onNodeWithText("Skip for now").assertIsDisplayed()
        compose.onNodeWithText("Scan code").performClick()
        assertEquals(listOf("enable", "select", "mic", "scan"), calls.seen)
    }
    @Test fun `done requirements are icon rows not check mark characters`() {
        val state = SetupState().apply { step = PAGE_KEYBOARD; inputEnabled = true }
        compose.setContent { ChirpTheme { Onboarding(state) } }
        compose.onNodeWithText("Enabled").assertIsDisplayed().assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Done"))
        compose.onNodeWithText("Selected as default").assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Not done yet"))
        compose.onAllNodesWithText("✓", substring = true).assertCountEquals(0)
        compose.runOnIdle { state.inputSelected = true }
        compose.onNodeWithText("Continue").assertIsDisplayed()
        compose.onAllNodesWithText("✓", substring = true).assertCountEquals(0)
    }
    @Test fun `denied microphone offers app permissions and the pair page shows its issue with one action`() {
        val state = SetupState().apply { step = PAGE_MIC }; val calls = Calls()
        compose.setContent { ChirpTheme { Onboarding(state, calls.actions(state)) } }
        compose.onNodeWithText("Open app permissions").assertDoesNotExist()
        compose.runOnIdle { state.micDenied = true }
        compose.onNodeWithText("Open app permissions").performClick()
        compose.runOnIdle { state.step = PAGE_PAIR; state.pairIssue = PairIssue.Unreachable }
        compose.onNodeWithText("Couldn’t reach your computer").assertIsDisplayed()
        compose.onNodeWithText("Try again").performClick()
        compose.runOnIdle { state.pairIssue = PairIssue.ScannerUnavailable }
        compose.onNodeWithText("Paste link instead").assertIsDisplayed()
        compose.runOnIdle { state.pairIssue = PairIssue.InvalidLink }
        compose.onNodeWithText("Scan again").performClick()
        assertEquals(listOf("permissions", "retry", "scan"), calls.seen)
    }
    @Test fun `pasting a pairing link reports it and shows a field error for text that is not one`() {
        val state = SetupState().apply { step = PAGE_PAIR }; val calls = Calls()
        compose.setContent { ChirpTheme { Onboarding(state, calls.actions(state)) } }
        compose.onNodeWithText("Paste link instead").performClick()
        compose.onNodeWithContentDescription("Private Chirp pairing link").performTextInput("not a link")
        compose.onNodeWithText("That isn’t a Chirp pairing link").assertIsDisplayed()
        compose.onNodeWithContentDescription("Private Chirp pairing link").performTextClearance()
        compose.onNodeWithContentDescription("Private Chirp pairing link").performTextInput(syntheticLink)
        compose.runOnIdle { assertEquals(syntheticLink, state.link); assertEquals(listOf("paste", "paste", "paste"), calls.seen) }
    }
    @Test fun `a saved pairing shows the connected host and engine and Finish`() {
        val state = connectedState(); val calls = Calls()
        compose.setContent { ChirpTheme { Onboarding(state, calls.actions()) } }
        compose.onNodeWithText("Connected · mac.example.test").assertIsDisplayed()
        compose.onNodeWithText("Parakeet · clean-up on your computer", substring = true).assertIsDisplayed()
        compose.onNodeWithText("Scan code").assertDoesNotExist()
        compose.onNodeWithText("Finish").performClick()
        assertEquals(listOf("finish"), calls.seen)
    }
    @Test fun `back returns one page at a time and stops at the page onboarding opened on`() {
        val state = SetupState().apply { step = PAGE_MIC; entryStep = PAGE_KEYBOARD }
        compose.setContent { ChirpTheme { Onboarding(state) } }
        compose.runOnUiThread { compose.activity.onBackPressedDispatcher.onBackPressed() }
        compose.runOnIdle { assertEquals(PAGE_KEYBOARD, state.step) }
        compose.onNodeWithText("Turn on Chirp Keyboard").assertIsDisplayed()
        assertFalse(compose.activity.onBackPressedDispatcher.hasEnabledCallbacks())
    }
    @Test fun `onboarding points history at Privacy and history and learning at Dictation`() {
        val state = SetupState()
        compose.setContent { ChirpTheme { Onboarding(state) } }
        compose.onNodeWithText("Turn history off in Settings → Privacy & history, and learning off in Settings → Dictation.", substring = true).assertExists()
        compose.onNodeWithText("Turn them off in Settings → Dictation").assertDoesNotExist()
        compose.runOnIdle { state.step = PAGE_MIC }
        compose.onNodeWithText("What Chirp keeps").performClick()
        compose.onNodeWithText("turn history off in Settings → Privacy & history, and learning off in Settings → Dictation.", substring = true).assertExists()
    }

    @Test fun `pages still change with animations turned off`() {
        android.provider.Settings.Global.putFloat(compose.activity.contentResolver, android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 0f)
        val state = SetupState()
        compose.setContent { ChirpTheme { Onboarding(state) } }
        compose.onNodeWithText("Get started").performClick()
        compose.onNodeWithText("How you’ll dictate").assertIsDisplayed()
    }
    @Test fun `at 200 percent font the primary button is visible without scrolling on every page`() {
        val state = SetupState()
        fontScaled(2f) { ChirpTheme { Onboarding(state) } }
        val labels = listOf(PAGE_WELCOME to "Get started", PAGE_KEYBOARD to "Enable Chirp Keyboard", PAGE_MIC to "Allow microphone", PAGE_PAIR to "Scan code")
        for ((page, label) in labels) {
            compose.runOnIdle { state.step = page }
            compose.onNodeWithText(label).assertIsDisplayed()
        }
        compose.runOnIdle { state.step = PAGE_PAIR; state.pairIssue = PairIssue.Unreachable; state.wifiPermissionNeeded = true }
        compose.onNodeWithText("Scan code").assertIsDisplayed()
        compose.runOnIdle { state.connected = true; state.paired = true; state.host = "mac.example.test" }
        compose.onNodeWithText("Finish").assertIsDisplayed()
    }
    private fun connectedState() = SetupState().apply {
        step = PAGE_PAIR; paired = true; connected = true; reachable = true; host = "mac.example.test"
        health = Health(true, false, true, false, null, engine = "Parakeet")
    }
    @Test fun `render onboarding pages in light and dark and guard against blank frames`() {
        val output = File(System.getProperty("chirp.screenshots")).apply { mkdirs() }
        val state = SetupState()
        val dark = mutableStateOf(false)
        val font = mutableFloatStateOf(1f)
        fontScaled(font) { dev.chirp.android.ui.ChirpTheme(dark.value, colour = AppColour.POND) { Onboarding(state) } }
        fun shot(name: String) {
            compose.waitForIdle()
            // Compose semantics may settle before Robolectric draws the native window buffer.
            // Schedule a real draw before capture, as in the keep-keyboard render suite.
            compose.runOnIdle { compose.activity.window.decorView.invalidate() }
            compose.mainClock.advanceTimeByFrame()
            compose.waitForIdle()
            val bitmap = compose.onRoot().captureToImage().asAndroidBitmap()
            val colours = HashSet<Int>()
            for (y in 0 until bitmap.height step 5) for (x in 0 until bitmap.width step 5) colours += bitmap.getPixel(x, y)
            assertTrue("$name is blank: ${colours.size} colour", colours.size > 4)
            File(output, "onboarding-$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
        for (night in listOf(false, true)) {
            val theme = if (night) "dark" else "light"
            for ((page, name) in listOf(PAGE_WELCOME to "welcome", PAGE_KEYBOARD to "keyboard", PAGE_MIC to "microphone", PAGE_PAIR to "pair")) {
                compose.runOnIdle { dark.value = night; state.step = page }
                shot("$name-$theme")
            }
            compose.runOnIdle { state.step = PAGE_KEYBOARD; state.inputEnabled = true; state.inputSelected = true }
            shot("keyboard-done-$theme")
            compose.runOnIdle { state.inputEnabled = false; state.inputSelected = false; state.step = PAGE_PAIR; state.pairIssue = PairIssue.Unreachable }
            shot("pair-failed-$theme")
            compose.runOnIdle { state.pairIssue = null; state.checking = true }
            shot("pair-checking-$theme")
            compose.runOnIdle { state.checking = false; state.paired = true; state.connected = true; state.reachable = true; state.host = "mac.example.test"
                state.health = Health(true, false, true, false, null, engine = "Parakeet") }
            shot("pair-connected-$theme")
            compose.runOnIdle { state.paired = false; state.connected = false; state.health = null }
        }
        compose.runOnIdle { dark.value = false; font.floatValue = 2f }
        for ((page, name) in listOf(PAGE_WELCOME to "welcome", PAGE_KEYBOARD to "keyboard", PAGE_MIC to "microphone", PAGE_PAIR to "pair")) {
            compose.runOnIdle { state.step = page }
            shot("font-200-$name")
        }
    }
}
