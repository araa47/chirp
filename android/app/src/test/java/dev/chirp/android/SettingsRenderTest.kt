package dev.chirp.android

import dev.chirp.android.AppColour

import android.graphics.Bitmap
import androidx.activity.ComponentActivity
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.unit.Density
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

/** Renders the settings tree to docs/screenshots/android/settings-*.png: cover width, Fold inner width (two panes), light, dark and 200% font. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37], qualifiers = "w411dp-h891dp-mdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class SettingsRenderTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val output = File(System.getProperty("chirp.screenshots")).apply { mkdirs() }

    private fun save(name: String, cropAt: String? = null) {
        compose.waitForIdle()
        // Flush the native buffer after semantics settle, including the first frame.
        compose.runOnIdle { compose.activity.window.decorView.invalidate() }
        compose.mainClock.advanceTimeByFrame()
        compose.waitForIdle()
        var bitmap = compose.onRoot().captureToImage().asAndroidBitmap()
        val first = bitmap.getPixel(0, 0)
        assertTrue("$name is blank", (0 until bitmap.height step 7).any { y -> (0 until bitmap.width step 7).any { x -> bitmap.getPixel(x, y) != first } })
        if (cropAt != null) {
            val bottom = compose.onAllNodesWithText(cropAt).fetchSemanticsNodes().lastOrNull()?.boundsInRoot?.bottom?.toInt()?.plus(64) ?: bitmap.height
            bitmap = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, minOf(bottom, bitmap.height))
        }
        File(output, "settings-$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    private val page = mutableStateOf<SettingsPage?>(null)
    private val dark = mutableStateOf(false)
    private val fontScale = mutableFloatStateOf(1f)

    private fun start() {
        val (state, history, updates) = settingsFixture()
        state.host = "computer.example.test"
        compose.setContent {
            CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density, fontScale.floatValue)) {
                ChirpTheme(dark.value, colour = AppColour.POND) { key(page.value) { SettingsScreen(state, initialPage = page.value, history = history, updates = updates) } }
            }
        }
    }

    private fun shot(prefix: String, shown: SettingsPage?, night: Boolean, font: Float = 1f, cropAt: String? = null) {
        compose.runOnIdle { page.value = shown; dark.value = night; fontScale.floatValue = font }
        compose.mainClock.advanceTimeBy(2000); compose.waitForIdle()
        save("$prefix-${if (night) "dark" else "light"}", cropAt)
    }

    @Config(qualifiers = "w411dp-h2400dp-mdpi") @Test fun `top level in light and dark`() {
        start()
        for (night in listOf(false, true)) shot("top", null, night, cropAt = "About")
    }

    @Config(qualifiers = "w411dp-h5000dp-mdpi") @Test fun `top level at 200 percent font`() {
        start()
        shot("top-font-200", null, false, 2f, cropAt = "About")
    }

    @Test fun `every detail page in light and dark`() {
        start()
        for (shown in SettingsPage.entries) for (night in listOf(false, true)) shot(shown.name.lowercase(), shown, night)
    }

    @Test fun `forget pairing confirmation in light and dark`() {
        start()
        for (night in listOf(false, true)) {
            shot("connection", SettingsPage.Connection, night)
            compose.onNodeWithText("Forget pairing").performClick()
            compose.onNodeWithText("Forget this computer?").assertIsDisplayed()
            compose.mainClock.advanceTimeBy(2000); compose.waitForIdle()
            val target = compose.onNode(isRoot() and hasAnyDescendant(hasText("Forget this computer?")))
            val bitmap = notesScreenshot(target)
            File(output, "settings-connection-forget-${if (night) "dark" else "light"}.png").outputStream().use {
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
            }
            compose.onNodeWithText("Cancel").performClick()
        }
    }

    @Test fun `history stop and delete confirmations in light and dark`() {
        start()
        fun dialog(title: String, name: String) {
            compose.onNodeWithText(title).assertIsDisplayed()
            compose.mainClock.advanceTimeBy(2000); compose.waitForIdle()
            val target = compose.onNode(isRoot() and hasAnyDescendant(hasText(title)))
            val bitmap = notesScreenshot(target)
            File(output, "settings-$name.png").outputStream().use {
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
            }
        }
        for (night in listOf(false, true)) {
            shot("history-dialog-context", SettingsPage.History, night)
            compose.onNodeWithText("Keep dictation history on this phone").performClick()
            compose.onNodeWithText("Keep dictation history on this phone").performClick()
            val theme = if (night) "dark" else "light"
            dialog("Turn off dictation history?", "history-turn-off-$theme")
            compose.onNodeWithText("Turn off, keep history").performClick()
            compose.onNodeWithText("Keep dictation history on this phone").assertIsOff()
            compose.onNodeWithText("Delete history").performScrollTo().performClick()
            dialog("Delete dictation history?", "history-delete-$theme")
            compose.onNodeWithText("Cancel").performClick()
        }
    }

    @Config(qualifiers = "w840dp-h900dp-mdpi") @Test fun `Fold inner screen shows the list and the detail side by side`() {
        start()
        for (night in listOf(false, true)) shot("two-pane", null, night)
        compose.onAllNodesWithContentDescription("Back").assertCountEquals(0)
        assertTrue(compose.onAllNodesWithText("Connection").fetchSemanticsNodes().isNotEmpty())   // the list row; the detail title says it too
        compose.onNodeWithText("About").performClick()
        compose.onNodeWithText("Check for updates").assertExists()
        compose.onNodeWithText("Diagnostics").assertExists()
        shot("two-pane-about", SettingsPage.About, false)
    }
    @Config(qualifiers = "w840dp-h1200dp-mdpi") @Test fun `two panes at 200 percent font`() {
        start()
        for (night in listOf(false, true)) shot("two-pane-font-200", null, night, 2f)
        compose.onAllNodesWithText("Privacy & history").assertCountEquals(1)
    }

}
