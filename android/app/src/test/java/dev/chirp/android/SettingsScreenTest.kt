package dev.chirp.android

import dev.chirp.android.AppColour

import androidx.activity.ComponentActivity
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import dev.chirp.android.settings.*
import dev.chirp.android.ui.ChirpTheme
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import okhttp3.OkHttpClient
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** A paired, reachable Mac with clean-up on, with no network, keystore or clock behind it. */
internal fun settingsFixture(): Triple<SetupState, DictationHistory, UpdateController> {
    val context = RuntimeEnvironment.getApplication()
    val health = Health(true, false, true, false, null, engine = "Parakeet")
    SettingsStore(context).apply { this.health = health } // Robolectric has no AndroidKeyStore, so no saved pairing.
    val state = SetupState().apply { paired = true; host = "mac.example.test"; this.health = health; reachable = true }
    val updates = UpdateController(context, CoroutineScope(Dispatchers.Unconfined), OkHttpClient(), pairing = { null }, installed = { 1 })
    return Triple(state, DictationHistory(context, SoftwareHistoryKeys()).also { it.disable() }, updates)
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37], qualifiers = "w411dp-h891dp-mdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class SettingsScreenTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val context = RuntimeEnvironment.getApplication()

    private fun show(state: SetupState, history: DictationHistory, updates: UpdateController, actions: SettingsActions = SettingsActions(),
                     initialPage: SettingsPage? = null, onExit: (() -> Unit)? = null) =
        compose.setContent { ChirpTheme(colour = AppColour.POND) { SettingsScreen(state, actions, initialPage, history, updates, onExit) } }

    private fun assertOnce(label: String) = compose.onAllNodesWithText(label).assertCountEquals(1)

    private fun open(page: SettingsPage) = compose.onNodeWithText(context.getString(page.title)).performScrollTo().performClick()

    /** Every control reachable by the label it has, one page per category; each must exist somewhere in that page's tree. */
    private val tree = linkedMapOf<SettingsPage?, List<String>>(
        null to listOf("Connection", "How you dictate", "Dictation", "Keyboard", "Feedback & look", "Notes", "Privacy & history", "About"),
        SettingsPage.Connection to listOf("Check connection", "Change pairing", "Forget pairing", "Use this phone's recogniser"),
        SettingsPage.Dictation to listOf("Clean-up", "Styles", "Stop dictation", "Spoken commands",
            "Press Send after dictating", "Learn from my edits", "Learned"),
        SettingsPage.HowYouDictate to listOf("Use Chirp Keyboard", "Keep my keyboard", "Other ways to dictate"),
        SettingsPage.Keyboard to listOf("Keyboard look", "Swipe typing", "Hardware keyboard shortcut", "Larger mic on the inner screen",
            "Layouts, languages & typing"),
        SettingsPage.Feedback to listOf("App colours", "Haptic cues", "Sound cues"),
        SettingsPage.Notes to listOf("Save battery while the screen is off", "Keep a recovery copy until notes are saved", "Keep notes on this phone"),
        SettingsPage.History to listOf("Keep dictation history on this phone", "What Chirp keeps"),
        SettingsPage.About to listOf("Check for updates", "Debug overlay (timings only)", "Copy diagnostics", "Clear timings"),
    )

    @Test fun `every setting is reachable from its category page exactly once, and back returns to the list`() {
        val (state, history, updates) = settingsFixture()
        show(state, history, updates)
        tree.getValue(null).forEach(::assertOnce)
        for (page in SettingsPage.entries) {
            open(page)
            assertTrue(compose.onAllNodes(hasText(context.getString(page.title)).and(SemanticsMatcher.keyIsDefined(SemanticsProperties.Heading))).fetchSemanticsNodes().isNotEmpty())
            for (label in tree.getValue(page)) {
                assertTrue("$label missing on ${context.getString(page.title)}", compose.onAllNodesWithText(label).fetchSemanticsNodes().isNotEmpty() ||
                    run { compose.onNodeWithText(context.getString(page.title)).performScrollTo(); compose.onAllNodesWithText(label).fetchSemanticsNodes().isNotEmpty() })
            }
            compose.onNodeWithContentDescription("Back").performClick()
            assertTrue("back from ${context.getString(page.title)} shows the list", compose.onAllNodesWithText("Settings").fetchSemanticsNodes().isNotEmpty())
            assertOnce("About")
        }
    }

    @Test fun `each category row carries a live one-line summary`() {
        val (state, history, updates) = settingsFixture()
        show(state, history, updates)
        compose.onNodeWithText("Connected · mac.example.test").assertExists()                       // Connection
        compose.onNodeWithText("Clean-up on · stops on tap").assertExists()  // Dictation
        compose.onNodeWithText("Battery saver · recovery copy · keeps notes").assertExists()      // Notes (defaults)
        compose.onNodeWithText("Dictation history off").assertExists()                            // Privacy & history
        compose.onNodeWithText("Chirp ${BuildConfig.VERSION_NAME}").assertExists()                // About
    }

    @Config(qualifiers = "w840dp-h900dp-mdpi")
    @Test fun `two pane summaries update while their detail page stays open`() {
        val (state, history, updates) = settingsFixture()
        show(state, history, updates)
        open(SettingsPage.Dictation)
        compose.onNode(hasText("Clean-up") and isToggleable()).performClick()
        compose.onNodeWithText("Clean-up off · stops on tap").assertExists()
        open(SettingsPage.Feedback)
        compose.onNodeWithText("Haptic cues").performScrollTo().performClick()
        compose.onNodeWithText("Pond · haptic cues off").assertExists()
        open(SettingsPage.History)
        compose.onNodeWithText("Keep dictation history on this phone").performClick()
        compose.onNodeWithText("History on · keeps 7 days").assertExists()
    }

    @Test fun `the Dictation page has no History group`() {
        val (state, history, updates) = settingsFixture()
        show(state, history, updates, initialPage = SettingsPage.Dictation)
        compose.onNodeWithText("Keep dictation history on this phone").assertDoesNotExist()
        compose.onNodeWithText("Clear history").assertDoesNotExist()
        compose.onNodeWithText("Learn from my edits").assertExists()
    }

    @Test fun `switch summaries follow the switch`() {
        val (state, history, updates) = settingsFixture()
        show(state, history, updates, initialPage = SettingsPage.History)
        compose.onNode(hasText("Keep dictation history on this phone") and hasText("Off")).assertIsOff()
        compose.onNodeWithText("Keep dictation history on this phone").performClick()
        compose.onNode(hasText("Keep dictation history on this phone") and hasText("On · encrypted on this phone only")).assertIsOn()
        compose.onNodeWithText("Keep dictation history on this phone").performClick()
        compose.onNodeWithText("Turn off and delete").performClick()
        compose.waitUntil(5000) { compose.onAllNodes(hasText("Keep dictation history on this phone") and hasText("Off")).fetchSemanticsNodes().isNotEmpty() }
        compose.onNode(hasText("Keep dictation history on this phone") and hasText("On · encrypted on this phone only")).assertDoesNotExist()

        compose.onNodeWithContentDescription("Back").performClick()
        open(SettingsPage.Notes)
        compose.onNode(hasText("Save battery while the screen is off") and hasText("On")).assertIsOn()
        compose.onNode(hasText("Keep a recovery copy until notes are saved") and hasText("On")).assertIsOn()
        compose.onNode(hasText("Keep notes on this phone") and hasText("On · encrypted on this phone only")).assertIsOn()
        compose.onNodeWithText("On by default").assertDoesNotExist()
        compose.onNodeWithText("Save battery while the screen is off").performClick()
        compose.onNode(hasText("Save battery while the screen is off") and hasText("Off")).assertIsOff()
        compose.onNodeWithText("Keep a recovery copy until notes are saved").performScrollTo().performClick()
        compose.onNode(hasText("Keep a recovery copy until notes are saved") and hasText("Off")).assertIsOff()
        compose.onNodeWithText("Keep notes on this phone").performScrollTo().performClick()
        // Turning it off is an explicit opt-out: the switch leaves and Enable notes library takes its place.
        compose.onNodeWithText("Keep notes on this phone").assertDoesNotExist()
        compose.onNodeWithText("Enable notes library").performScrollTo().assertExists()
    }

    @Test fun `audio sizes use megabytes in the phone locale`() {
        val previous = java.util.Locale.getDefault()
        try {
            java.util.Locale.setDefault(java.util.Locale.GERMANY)
            assertEquals("<0.1 MB", megabytes(50_000))
            assertEquals("1,5 MB", megabytes(1_500_000))
            java.util.Locale.setDefault(java.util.Locale.US)
            assertEquals("1.5 MB", megabytes(1_500_000))
        } finally { java.util.Locale.setDefault(previous) }
    }

    @Test fun `paragraph help sits behind an info sheet, not on the row`() {
        val (state, history, updates) = settingsFixture()
        show(state, history, updates)
        open(SettingsPage.Dictation)
        compose.onNodeWithText("Off by default").assertExists()
        compose.onNodeWithText("Ending a dictation with \"new line\" or \"new paragraph\" types a line break instead of the words.").assertDoesNotExist()
        compose.onNodeWithContentDescription("About Spoken commands").performClick()
        compose.onNodeWithText("Ending a dictation with \"new line\" or \"new paragraph\" types a line break instead of the words.").assertExists()
        compose.onNodeWithText("Close").performClick()
        compose.onNodeWithText("Ending a dictation with \"new line\" or \"new paragraph\" types a line break instead of the words.").assertDoesNotExist()
    }

    @Test fun `notes retention and audio live under Notes, history retention under Privacy and history`() {
        val (state, history, updates) = settingsFixture()
        show(state, history, updates)
        open(SettingsPage.Notes)
        compose.onNodeWithText("Delete notes older than").performScrollTo().assertExists()
        compose.onNodeWithText("Keep audio with notes").performScrollTo().assertExists()
        compose.onNodeWithContentDescription("Back").performClick()
        open(SettingsPage.History)
        compose.onNodeWithText("Keep for").assertExists()   // retention also applies to history kept while off
        compose.onNodeWithText("Keep dictation history on this phone").performClick()
        compose.onNodeWithText("Keep for").assertExists()
        compose.onNodeWithText("Keep audio with notes").assertDoesNotExist()
    }

    @Test fun `an unreachable Mac offers Open Tailscale only when it is installed`() {
        val (state, history, updates) = settingsFixture()
        state.reachable = false
        var opened = 0
        show(state, history, updates, SettingsActions(openTailscale = { opened++ }), SettingsPage.Connection)
        compose.onNodeWithText("Open Tailscale").performClick()
        assertEquals(1, opened)
        compose.runOnIdle { state.reachable = true }
        compose.onNodeWithText("Open Tailscale").assertDoesNotExist()
    }

    @Test fun `without Tailscale installed the unreachable banner has no button`() {
        val (state, history, updates) = settingsFixture()
        state.reachable = false
        show(state, history, updates, SettingsActions(), SettingsPage.Connection)
        compose.onNodeWithText("Open Tailscale").assertDoesNotExist()
    }

    @Test fun `forgetting a pairing asks first - dismiss keeps it and confirm forgets it`() {
        val (state, history, updates) = settingsFixture()
        var forgotten = 0
        show(state, history, updates, SettingsActions(forgetPairing = { forgotten++ }), SettingsPage.Connection)
        compose.onNodeWithText("Forget pairing").performClick()
        compose.onNodeWithText("Forget this computer?").assertExists()
        compose.onNodeWithText("You’ll need to scan a new code to dictate. This also ends the session.").assertExists()
        compose.onNodeWithText("Cancel").performClick()
        compose.onNodeWithText("Forget this computer?").assertDoesNotExist()
        assertEquals(0, forgotten)
        compose.onNodeWithText("Forget pairing").performClick()
        compose.onNodeWithText("Forget", substring = false).performClick()
        compose.runOnIdle { assertEquals(1, forgotten) }
        compose.onNodeWithText("Forget this computer?").assertDoesNotExist()
    }

    @Test fun `back leaves a detail page for the list, then the list leaves the screen`() {
        val (state, history, updates) = settingsFixture()
        var exits = 0
        show(state, history, updates, onExit = { exits++ })
        val dispatcher = compose.activity.onBackPressedDispatcher
        open(SettingsPage.About)
        compose.onNodeWithText("Copy diagnostics").assertExists()
        compose.runOnIdle { dispatcher.onBackPressed() }
        compose.onNodeWithText("Copy diagnostics").assertDoesNotExist()
        assertEquals(0, exits)
        compose.runOnIdle { dispatcher.onBackPressed() }
        assertEquals(1, exits)
    }

    @Test fun `without an exit handler the list leaves back to the system`() {
        val (state, history, updates) = settingsFixture()
        show(state, history, updates)
        open(SettingsPage.Dictation)
        compose.runOnIdle { assertTrue(compose.activity.onBackPressedDispatcher.hasEnabledCallbacks()) }
        compose.onNodeWithContentDescription("Back").performClick()
        compose.runOnIdle { assertFalse(compose.activity.onBackPressedDispatcher.hasEnabledCallbacks()) }
    }

    @Test fun `the clean-up switch records an explicit choice only when toggled`() {
        val (state, history, updates) = settingsFixture()
        show(state, history, updates)
        open(SettingsPage.Dictation)
        compose.onNode(hasText("Clean-up") and isToggleable()).assertIsDisplayed().assertIsOn()
        compose.onNodeWithText("Polishes punctuation and filler words on your computer").assertIsDisplayed()
        compose.runOnIdle { assertFalse(context.getSharedPreferences("chirp", 0).contains("correction_explicit")) }
        compose.onNode(hasText("Clean-up") and isToggleable()).performClick()
        compose.runOnIdle { assertFalse(SettingsStore(context).correction); assertTrue(context.getSharedPreferences("chirp", 0).getBoolean("correction_explicit", false)) }
    }

    @Test fun `a Mac with clean-up off says so instead of hiding the feature`() {
        val (state, history, updates) = settingsFixture()
        state.health = Health(true, false, false, false, null)
        show(state, history, updates)
        open(SettingsPage.Dictation)
        compose.onNodeWithText("Clean-up is off on your computer").assertIsDisplayed()
        compose.onNode(hasText("Clean-up") and isToggleable()).assertDoesNotExist()
    }

    @Test fun `stop dictation no longer promises 119 seconds`() {
        val (state, history, updates) = settingsFixture()
        show(state, history, updates)
        open(SettingsPage.Dictation)
        compose.onNodeWithText("Stop dictation").performScrollTo()
        compose.onNodeWithText("Learn more").performScrollTo().performClick()
        compose.onNodeWithText("Tap the stop button to finish. Either way, a countdown starts 15 seconds before the limit and dictation ends at 10 minutes.").assertExists()
    }

    @Test fun `connection summary reflects pairing and reachability`() {
        assertEquals("Not paired", connectionSummary(false, "", null, false, null).title)
        val health = Health(true, false, true, false, null, engine = "Parakeet")
        assertEquals("Connected · mac.example.test", connectionSummary(true, "mac.example.test", true, false, health).title)
        assertEquals("Parakeet · clean-up on your computer", connectionSummary(true, "mac.example.test", true, false, health).summary)
        assertEquals("Paired · mac.example.test", connectionSummary(true, "mac.example.test", null, false, health).title)
        assertEquals("Checking · mac.example.test", connectionSummary(true, "mac.example.test", true, true, health).title)
        val down = connectionSummary(true, "mac.example.test", false, false, health)
        assertEquals("Computer unreachable · mac.example.test", down.title); assertNotNull(down.hint)
        assertEquals("Computer is loading its speech model", connectionSummary(true, "m", null, false, health.copy(ready = false)).summary)
    }

    /** #181: dispatches a 48 dp status bar and a 40 dp gesture area over the window, as an edge-to-edge activity receives them. */
    private fun withSystemBars(): Pair<Float, Float> {
        val density = context.resources.displayMetrics.density
        val (top, bottom) = 48 * density to 40 * density
        compose.runOnUiThread {
            androidx.core.view.WindowCompat.setDecorFitsSystemWindows(compose.activity.window, false)
            androidx.core.view.ViewCompat.dispatchApplyWindowInsets(compose.activity.window.decorView,
                androidx.core.view.WindowInsetsCompat.Builder().setInsets(androidx.core.view.WindowInsetsCompat.Type.systemBars(),
                    androidx.core.graphics.Insets.of(0, top.toInt(), 0, bottom.toInt())).build())
        }
        compose.waitForIdle()
        return top to bottom
    }

    private fun assertClearOfSystemBars(first: String, last: String) {
        val (top, bottom) = withSystemBars()
        val height = compose.onRoot().fetchSemanticsNode().boundsInRoot.height
        assertTrue("$first starts below the status bar", compose.onNodeWithText(first).fetchSemanticsNode().boundsInRoot.top >= top)
        compose.onNodeWithText(last).performScrollTo()
        assertTrue("$last ends above the gesture area", compose.onNodeWithText(last).fetchSemanticsNode().boundsInRoot.bottom <= height - bottom)
        compose.onNodeWithText(last).assertIsDisplayed().assertHasClickAction()
    }

    @Config(qualifiers = "w840dp-h900dp-mdpi")
    @Test fun `the inner screen's category column keeps clear of the system bars`() {
        val (state, history, updates) = settingsFixture()
        show(state, history, updates)
        assertClearOfSystemBars("Settings", "About")
        open(SettingsPage.About) // Still tappable after scrolling to the last row.
        compose.onNodeWithText("Check for updates").assertExists()
    }

    @Test fun `the cover screen's list keeps clear of the system bars`() {
        val (state, history, updates) = settingsFixture()
        show(state, history, updates)
        val (top, bottom) = withSystemBars()
        val height = compose.onRoot().fetchSemanticsNode().boundsInRoot.height
        assertTrue(compose.onAllNodes(hasText("Settings").and(SemanticsMatcher.keyIsDefined(SemanticsProperties.Heading))).fetchSemanticsNodes().single().boundsInRoot.top >= top - 1f)
        compose.onNodeWithText("About").performScrollTo()
        assertTrue(compose.onNodeWithText("About").fetchSemanticsNode().boundsInRoot.bottom <= height - bottom)
    }
}
