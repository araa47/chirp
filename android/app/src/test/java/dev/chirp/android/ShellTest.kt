package dev.chirp.android

import dev.chirp.android.AppColour

import android.content.Intent
import android.os.Looper
import android.text.InputType
import android.view.inputmethod.EditorInfo
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.requiredWidth
import dev.chirp.android.shell.*
import dev.chirp.android.ui.ChirpTheme
import dev.chirp.android.ui.StatusKind
import org.junit.After
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.android.controller.ActivityController
import java.time.ZoneOffset

class NotesConnectionStatusTest {
    @Test fun `connection chip distinguishes Mac offline and phone fallback`() {
        assertEquals("Computer", notesConnectionStatus(true, true, false, false).label)
        assertTrue(notesConnectionStatus(true, true, false, false).connected)
        assertEquals("Offline", notesConnectionStatus(true, false, false, true).label)
        assertEquals("Offline", notesConnectionStatus(true, true, true, false).label)
        assertEquals("Offline", notesConnectionStatus(false, null, false, false).label)
        assertEquals("Phone", notesConnectionStatus(false, null, false, true).label)
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37])
class LauncherRoutingTest {
    class Launch : SetupActivity() {
        val fake = TailscalePromptTest.FakeTailscale()
        override val tailscale: TailscaleControl get() = fake
        var recentsScreenshots: Boolean? = null
        override fun setRecentsScreenshotEnabled(enabled: Boolean) { recentsScreenshots = enabled; super.setRecentsScreenshotEnabled(enabled) }
        override suspend fun checkMac(call: okhttp3.Call): Health = kotlinx.coroutines.awaitCancellation()
    }
    private val app get() = RuntimeEnvironment.getApplication()
    private var controller: ActivityController<Launch>? = null
    private fun launch(intent: Intent? = null): Launch = Robolectric.buildActivity(Launch::class.java, intent).also { controller = it }.setup().get()
    @After fun tearDown() { controller?.let { if (!it.get().isDestroyed) it.pause().stop().destroy() } }
    /** Runs the next frames too, so a state change has recomposed (and registered its back handlers). */
    private fun idle() = shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(100))

    @Test fun `the launcher opens onboarding until setup is complete, then Notes`() {
        SettingsStore(app).onboarded = false
        val first = launch()
        assertFalse(first.state.shellOpen); assertEquals(PAGE_WELCOME, first.state.step)
        assertEquals("the whole app stays out of the Recents thumbnail", false, first.recentsScreenshots)
        controller!!.pause().stop().destroy()
        SettingsStore(app).onboarded = true
        val later = launch()
        assertTrue(later.state.shellOpen); assertEquals(ShellTab.Notes, later.state.tab); assertFalse(later.state.exitOnBack)
        assertTrue("first run: Try it on Notes", later.state.tryIt)
        assertEquals(false, later.recentsScreenshots)
    }

    @Test fun `Notes’ fixes act on the card's state`() {
        SettingsStore(app).onboarded = true
        val activity = launch()
        activity.fix(HomeFix.TailscaleOn)
        assertEquals(1, activity.fake.connects); assertEquals("Connecting Tailscale…", activity.state.status)
        activity.fix(HomeFix.Pair)
        assertFalse(activity.state.shellOpen); assertEquals(PAGE_PAIR, activity.state.step); assertTrue(activity.state.pairFromShell)
        activity.state.micDenied = true
        activity.fix(HomeFix.Microphone)
        assertEquals(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS, shadowOf(activity).nextStartedActivity.action)
    }

    @Test fun `the keyboard's history link is a thin deep link into the History tab`() {
        val history = Robolectric.buildActivity(HistoryActivity::class.java).setup().get()
        assertTrue(history.isFinishing)
        val forwarded = shadowOf(history).nextStartedActivity
        assertEquals(SetupActivity::class.java.name, forwarded.component?.className); assertEquals("history", forwarded.getStringExtra("section"))
        SettingsStore(app).onboarded = true
        val shell = launch(forwarded)
        assertEquals(ShellTab.History, shell.state.tab)
        idle(); shell.onBackPressedDispatcher.onBackPressed()
        assertTrue("opened from the keyboard: back returns there", shell.isFinishing)
    }
}

/** The real activity under a compose rule, so its back handlers are composed. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37], qualifiers = "w411dp-h891dp-mdpi")
class ShellBackTest {
    @get:Rule val compose = createAndroidComposeRule<SetupActivity>()

    @Test fun `back from the pair page opened from Home returns to the shell, and Notes’ tiles switch tabs`() {
        val activity = compose.activity
        compose.runOnIdle { activity.state.apply { inputMode = InputMode.KEYBOARD; inputEnabled = true; inputSelected = true; mic = true; paired = true }; activity.advance() }
        compose.onNodeWithContentDescription("Record new note").assertExists()
        compose.runOnIdle { activity.fix(HomeFix.Pair) }
        compose.waitForIdle()
        compose.runOnIdle { activity.onBackPressedDispatcher.onBackPressed() }
        assertTrue("back from the pair page returns to the shell", activity.state.shellOpen); assertFalse(activity.isFinishing)
        compose.onNode(hasText("History") and isSelectable()).performClick()
        // History reads its entries off the main thread, so the empty state appears a beat after the tab opens.
        compose.waitUntil(5000) { compose.onAllNodesWithText("No dictations yet").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("No dictations yet").assertExists()
        compose.runOnIdle { activity.onBackPressedDispatcher.onBackPressed() }
        assertEquals(ShellTab.Notes, activity.state.tab); assertFalse(activity.isFinishing)
        compose.onNode(hasText("Notes") and isSelectable()).performClick()
        assertEquals(ShellTab.Notes, activity.state.tab)
        compose.onNodeWithContentDescription("Record new note").assertExists()
        assertSame("the tab and NotesActivity share one session", NotesSessionHolder.current, NotesSessionHolder.model(activity) { error("already created") })
        assertEquals(ShellTab.Notes, activity.state.tab)
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37], qualifiers = "w411dp-h891dp-mdpi")
class AppShellTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val tab = mutableStateOf(ShellTab.Notes)
    private val exit = mutableStateOf(false)
    private val page = mutableStateOf(false)

    private fun show(font: Float = 1f, dark: Boolean = false) = compose.setContent {
        androidx.compose.runtime.CompositionLocalProvider(
            androidx.compose.ui.platform.LocalDensity provides androidx.compose.ui.unit.Density(androidx.compose.ui.platform.LocalDensity.current.density, font)) {
            ChirpTheme(dark, colour = AppColour.POND) {
                AppShell(tab.value, { tab.value = it; exit.value = false }, exit.value) { shown ->
                    if (shown == ShellTab.Settings) BackHandler(enabled = page.value) { page.value = false }
                    Text("${shown.label} content" + if (page.value) " page" else "")
                }
            }
        }
    }
    private fun item(label: String) = compose.onNode(hasText(label) and isSelectable())
    private fun back() = compose.runOnIdle { compose.activity.onBackPressedDispatcher.onBackPressed() }

    @Test fun `the bar is labelled and Back pops within the tab, then goes to Notes, then leaves`() {
        show()
        ShellTab.entries.forEach { item(it.label).assertExists() }
        item("Notes").assertIsSelected()
        val root = compose.onRoot().fetchSemanticsNode().boundsInRoot
        assertTrue("a bottom bar on the cover screen", item("Notes").fetchSemanticsNode().boundsInRoot.top > root.height * .8f)
        item("Settings").performClick()
        compose.runOnIdle { page.value = true }
        compose.onNodeWithText("Settings content page").assertExists()
        back(); compose.onNodeWithText("Settings content").assertExists(); assertEquals(ShellTab.Settings, tab.value)
        back(); assertEquals(ShellTab.Notes, tab.value); compose.onNodeWithText("Notes content").assertExists()
        assertFalse(compose.activity.isFinishing)
        back(); assertTrue(compose.activity.isFinishing)
    }

    @Test fun `tabs keep their place while hidden`() {
        show()
        item("Notes").performClick(); compose.onNodeWithText("Notes content").assertExists()
        item("History").performClick(); item("History").assertIsSelected(); compose.onNodeWithText("Notes content").assertDoesNotExist()
    }

    @Test fun `opened from outside, Back from the tab leaves at once`() {
        tab.value = ShellTab.History; exit.value = true
        show()
        back(); assertTrue(compose.activity.isFinishing)
    }

    /** Folding or unfolding swaps the bar and the rail: the open screen must keep its state (the fold e2e lost its recording screen). */
    @Test fun `the screen keeps its state when the bar becomes a rail`() {
        val width = mutableStateOf(411.dp)
        var created = 0
        compose.setContent {
            ChirpTheme(colour = AppColour.POND) {
                androidx.compose.foundation.layout.Box(androidx.compose.ui.Modifier.requiredWidth(width.value)) {
                    AppShell(tab.value, { tab.value = it }) { _ -> remember { created++; Any() }; Text("Notes content") }
                }
            }
        }
        compose.onNodeWithText("Notes content").assertExists()
        assertEquals(1, created)
        compose.runOnIdle { width.value = 840.dp }
        compose.onNodeWithText("Notes content").assertExists()
        compose.runOnIdle { width.value = 411.dp }
        compose.onNodeWithText("Notes content").assertExists()
        assertEquals("the open screen was rebuilt when the layout changed", 1, created)
    }

    @Config(qualifiers = "w840dp-h900dp-mdpi") @Test fun `the inner screen has a rail`() {
        show()
        val home = item("Notes").fetchSemanticsNode().boundsInRoot
        val settings = item("Settings").fetchSemanticsNode().boundsInRoot
        assertTrue("a rail down the start edge", home.right < 120f && settings.top > home.bottom)
        assertTrue("content beside the rail", compose.onNodeWithText("Notes content").fetchSemanticsNode().boundsInRoot.left >= home.right)
    }
}

/** #182 needs real text metrics, so it renders natively rather than with the legacy stub measurements. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37], qualifiers = "w840dp-h900dp-mdpi")
@org.robolectric.annotation.GraphicsMode(org.robolectric.annotation.GraphicsMode.Mode.NATIVE)
class ShellLargeFontTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val tab = mutableStateOf(ShellTab.Notes)

    private fun show(font: Float = 1f, dark: Boolean = false) = compose.setContent {
        androidx.compose.runtime.CompositionLocalProvider(
            androidx.compose.ui.platform.LocalDensity provides androidx.compose.ui.unit.Density(androidx.compose.ui.platform.LocalDensity.current.density, font)) {
            ChirpTheme(dark, colour = AppColour.POND) { AppShell(tab.value, { tab.value = it }) { shown -> Text("${shown.label} content") } }
        }
    }
    private fun item(label: String) = compose.onNode(hasText(label) and isSelectable())

    /** #182: at 200% font every destination's label stays on one line, whole, inside its own target, and the content keeps clear of the rail. */
    private fun assertLabelsReadable(font: Float, dark: Boolean) {
        show(font, dark)
        val items = ShellTab.entries.map { item(it.label).fetchSemanticsNode().boundsInRoot }
        ShellTab.entries.forEach { tabEntry ->
            val label = compose.onNode(hasText(tabEntry.label) and !isSelectable(), useUnmergedTree = true).fetchSemanticsNode()
            val results = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
            label.config[androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult].action?.invoke(results)
            assertEquals("${tabEntry.label} stays on one line", 1, results.single().lineCount)
            // The label's box is at least as wide as its text (the layout's own overflow flag is always set for softWrap = false).
            assertTrue("${tabEntry.label} is not clipped", label.boundsInRoot.width >= results.single().getLineRight(0) - 1f && !results.single().didOverflowHeight)
            val target = items[tabEntry.ordinal]
            assertTrue("${tabEntry.label} is inside its target", label.boundsInRoot.left >= target.left - 1f && label.boundsInRoot.right <= target.right + 1f)
            compose.onNode(hasText(tabEntry.label) and isSelectable()).assertHasClickAction()
        }
        assertTrue("separate, non-overlapping targets", items.zipWithNext().all { (a, b) -> a.bottom <= b.top + 1f })
        val rail = items.maxOf { it.right }
        assertTrue("content beside the rail", compose.onNodeWithText("Notes content").fetchSemanticsNode().boundsInRoot.left >= rail - 1f)
    }

    @Test fun `the rail's labels are whole at 200 percent font in light`() = assertLabelsReadable(2f, false)
    @Test fun `the rail's labels are whole at 200 percent font in dark`() = assertLabelsReadable(2f, true)
    @Test fun `the rail stays compact at the default font`() {
        show()
        assertTrue(item("Settings").fetchSemanticsNode().boundsInRoot.right < 120f)
    }
}
