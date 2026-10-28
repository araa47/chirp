package dev.chirp.android

import android.graphics.Bitmap
import androidx.activity.ComponentActivity
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.unit.Density
import dev.chirp.android.settings.SettingsActions
import dev.chirp.android.settings.SettingsPage
import dev.chirp.android.settings.SettingsScreen
import dev.chirp.android.ui.ChirpTheme
import java.io.File
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37], qualifiers = "w411dp-h891dp-mdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class InputModeUiTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    @Test fun `choice has two radio nodes with full text and no selection until a tap`() {
        val state = SetupState().apply { step = PAGE_CHOICE; keyboardLabel = "Gboard" }
        compose.setContent { ChirpTheme { Onboarding(state, OnboardingActions(chooseMode = { state.inputMode = it })) } }
        compose.onNodeWithText("Continue").assertIsNotEnabled()
        val radios = SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.RadioButton)
        compose.onAllNodes(radios).assertCountEquals(2)
        compose.onNodeWithText("Keep Gboard").assertIsNotSelected().assert(hasText("Needs an Accessibility permission"))
        compose.onNodeWithText("Keep Gboard").performClick().assertIsSelected()
        compose.onNodeWithText("Continue").assertIsEnabled().performClick()
        compose.onNodeWithText("Turn on the floating mic").assertIsDisplayed()
        compose.onNodeWithText("Enable Chirp Keyboard").assertDoesNotExist()
    }
    @Test fun `protection replaces Accessibility with keyboard and skip actions`() {
        val state = SetupState().apply { step = PAGE_KEYBOARD; inputMode = InputMode.OWN_KEYBOARD; advancedProtection = true }
        var opened = 0; var skipped = 0
        compose.setContent { ChirpTheme { Onboarding(state, OnboardingActions(accessibility = { opened++ },
            chooseMode = { state.inputMode = it }, skipFloatingMic = { skipped++ })) } }
        compose.onNodeWithText("Open Accessibility settings").assertDoesNotExist()
        compose.onNodeWithText("Continue without it").performClick()
        assertEquals(1, skipped); assertEquals(0, opened)
        compose.onNodeWithText("Use Chirp Keyboard instead").performClick()
        compose.onNodeWithText("Turn on Chirp Keyboard").assertIsDisplayed()
    }
    @Test fun `second unsuccessful return opens help and app info action`() {
        val state = SetupState().apply { step = PAGE_KEYBOARD; inputMode = InputMode.OWN_KEYBOARD; accessibilityReturns = 2 }
        var info = 0
        compose.setContent { ChirpTheme { Onboarding(state, OnboardingActions(appSettings = { info++ })) } }
        compose.onNodeWithText("Open Chirp app info").performScrollTo().performClick()
        assertEquals(1, info)
    }
    @Test fun `settings switches modes live and owns the picker and protected off state`() {
        val state = SetupState().apply { inputMode = InputMode.KEYBOARD; inputSelected = true; inputEnabled = true }
        var picks = 0
        compose.setContent { ChirpTheme { SettingsScreen(state, SettingsActions(chooseMode = { state.inputMode = it }, picker = { picks++ }), SettingsPage.HowYouDictate) } }
        compose.onNodeWithText("Choose keyboard").performScrollTo().performClick()
        assertEquals(1, picks)
        compose.onNodeWithText("Keep my keyboard").performScrollTo().performClick()
        compose.onNodeWithText("Switch back to your keyboard").performScrollTo().performClick()
        assertEquals(2, picks)
        compose.runOnIdle { state.advancedProtection = true }
        compose.onNodeWithText("Turned off by Advanced Protection").assertExists()
        compose.onNodeWithText("Open Accessibility settings").assertDoesNotExist()
    }
    private fun renders(size: String) {
        val state = SetupState().apply { keyboardLabel = "Gboard"; step = PAGE_CHOICE }
        val dark = mutableStateOf(false)
        val font = mutableFloatStateOf(1f)
        val settings = mutableStateOf(false)
        compose.setContent {
            CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density, font.floatValue)) {
                ChirpTheme(dark.value, colour = AppColour.POND) {
                    if (settings.value) SettingsScreen(state, initialPage = SettingsPage.HowYouDictate)
                    else Onboarding(state)
                }
            }
        }
        val output = File(System.getProperty("chirp.screenshots")).apply { mkdirs() }
        fun shot(name: String) {
            val file = File(output, "keepkb-$name-$size-${if (dark.value) "dark" else "light"}${if (font.floatValue == 2f) "-font-200" else ""}.png")
            // Semantics can be ready before Robolectric's first native window buffer is drawn.
            compose.waitForIdle()
            compose.runOnIdle { compose.activity.window.decorView.invalidate() }
            compose.mainClock.advanceTimeByFrame()
            compose.waitForIdle()
            val bitmap = compose.onRoot().captureToImage().asAndroidBitmap()
            val background = bitmap.getPixel(0, 0)
            val colours = HashSet<Int>()
            var samples = 0
            var content = 0
            for (y in 0 until bitmap.height step 4) for (x in 0 until bitmap.width step 4) {
                val pixel = bitmap.getPixel(x, y)
                colours += pixel
                samples++
                if (pixel != background) content++
            }
            assertTrue("${file.name} is essentially blank: ${colours.size} colours, $content/$samples content samples",
                colours.size > 16 && content > samples / 100)
            file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
        for (night in listOf(false, true)) for (scale in listOf(1f, 2f)) {
            compose.runOnIdle { dark.value = night; font.floatValue = scale; settings.value = false; state.step = PAGE_CHOICE; state.inputMode = null; state.advancedProtection = false; state.accessibilityReturns = 0 }
            compose.onNodeWithText("Continue").assertIsDisplayed()
            shot("choice")
            compose.runOnIdle { state.step = PAGE_KEYBOARD; state.inputMode = InputMode.OWN_KEYBOARD }
            compose.onNodeWithText("Open Accessibility settings").assertIsDisplayed()
            shot("floating")
            compose.runOnIdle { state.accessibilityReturns = 2 }
            compose.onNodeWithText("Open Chirp app info").performScrollTo()
            shot("restricted")
            compose.runOnIdle { state.advancedProtection = true }
            compose.onNodeWithText("Continue without it").assertIsDisplayed()
            shot("protected")
            compose.runOnIdle { settings.value = true; state.advancedProtection = false; state.accessibilityReturns = 0 }
            shot("settings")
            compose.onNodeWithText("Add Widget").performScrollTo()
            compose.onNodeWithText("Add Dictate tile").assertExists()
            compose.onNodeWithText("Add Notes tile").assertExists()
            shot("entry-points")
        }
    }
    @Test fun `render cover in both themes at standard and large font`() = renders("cover")
    @Test @Config(qualifiers = "w840dp-h900dp-mdpi") fun `render inner in both themes at standard and large font`() = renders("inner")
}
