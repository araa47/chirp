package dev.chirp.android

import dev.chirp.android.AppColour

import android.graphics.Bitmap
import android.text.InputType
import android.view.inputmethod.EditorInfo
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import dev.chirp.android.shell.*
import dev.chirp.android.ui.ChirpTheme
import java.io.File
import java.time.ZoneOffset
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Renders the app shell to docs/screenshots/android/history-*.png: cover (bar) and Fold inner (rail) widths, light and dark. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class ShellRenderTest {
    @get:Rule val compose = createComposeRule()
    private val context = RuntimeEnvironment.getApplication()
    private val output = File(System.getProperty("chirp.screenshots")).apply { mkdirs() }
    /** 2027-01-15 14:00 UTC: "Good afternoon". */
    private val now = 1_800_000_000_000L + 6 * 3_600_000L
    private var clock = now
    private val history = DictationHistory(context, SoftwareHistoryKeys()) { clock }
    private val dark = mutableStateOf(false)
    private val tab = mutableStateOf(ShellTab.Notes)

    private fun seed() {
        history.enable()
        val info = EditorInfo().apply { inputType = InputType.TYPE_CLASS_TEXT }
        listOf(
            Triple("Running ten minutes late, start without me.", null, "Messages") to 50L,
            Triple("Can we move the design review to Thursday afternoon?", "can we move the uh design review to thursday afternoon", "Gmail") to 22L,
            Triple("Pick up oat milk, lemons and coffee beans.", null, "Keep Notes") to 0L,
        ).forEach { (entry, hoursAgo) -> clock = now - hoursAgo * 3_600_000L - 120_000L; history.record(entry.first, entry.second, entry.third, info) }
        clock = now
    }

    private fun start(state: SetupState) {
        compose.setContent {
            ChirpTheme(dark.value, colour = AppColour.POND) {
                AppShell(tab.value, { tab.value = it }) { shown ->
                    when (shown) {
                        ShellTab.History -> HistoryScreen(history, { now }, ZoneOffset.UTC)
                        else -> androidx.compose.material3.Text("Notes")
                    }
                }
            }
        }
    }

    private fun save(name: String) {
        compose.waitForIdle()
        val bitmap = compose.onRoot().captureToImage().asAndroidBitmap()
        val first = bitmap.getPixel(0, 0)
        assertTrue("$name is blank", (0 until bitmap.height step 7).any { y -> (0 until bitmap.width step 7).any { x -> bitmap.getPixel(x, y) != first } })
        File(output, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    private fun shots(name: String, width: String) {
        for (night in listOf(false, true)) {
            compose.runOnIdle { dark.value = night }
            save("$name-$width-${if (night) "dark" else "light"}")
        }
    }

    private fun render(width: String) {
        val (state) = settingsFixture()
        state.mic = true
        seed()
        start(state)
        compose.runOnIdle { tab.value = ShellTab.History }
        compose.waitUntil(5000) { compose.onAllNodesWithText("Yesterday").fetchSemanticsNodes().isNotEmpty() }
        if (width == "inner") compose.onNodeWithText("Can we move the design review to Thursday afternoon?").performClick()
        shots("history-list", width)
        compose.runOnIdle { history.clear(); tab.value = ShellTab.Notes }
        compose.runOnIdle { tab.value = ShellTab.History }
        compose.waitUntil(5000) { compose.onAllNodesWithText("Nothing yet").fetchSemanticsNodes().isNotEmpty() }
        shots("history-empty", width)
        compose.runOnIdle { history.disable(); tab.value = ShellTab.Notes }
        compose.runOnIdle { tab.value = ShellTab.History }
        compose.waitUntil(5000) { compose.onAllNodesWithText("History is off").fetchSemanticsNodes().isNotEmpty() }
        shots("history-off", width)
    }

    @Test @Config(qualifiers = "w411dp-h891dp-mdpi") fun `render History on the cover screen with a bar`() = render("cover")
    @Test @Config(qualifiers = "w840dp-h900dp-mdpi") fun `render History on the inner screen with a rail and two panes`() = render("inner")
}
