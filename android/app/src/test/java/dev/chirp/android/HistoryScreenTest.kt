package dev.chirp.android

import dev.chirp.android.AppColour

import android.content.ClipboardManager
import android.text.InputType
import android.view.inputmethod.EditorInfo
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import dev.chirp.android.shell.HistoryDay
import dev.chirp.android.shell.HistoryScreen
import dev.chirp.android.shell.historyDay
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLog
import java.io.File
import java.time.ZoneOffset

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37], qualifiers = "w411dp-h891dp-mdpi")
class HistoryScreenTest {
    @get:Rule val compose = createComposeRule()
    private val context = RuntimeEnvironment.getApplication()
    /** 2027-01-15 08:00 UTC. */
    private val now = 1_800_000_000_000L
    private var clock = now
    private val store = DictationHistory(context, SoftwareHistoryKeys()) { clock }
    private val text = EditorInfo().apply { inputType = InputType.TYPE_CLASS_TEXT }
    private val hour = 3_600_000L

    private fun record(value: String, raw: String? = null, app: String = "Messages", at: Long = now) { clock = at; store.record(value, raw, app, text); clock = now }
    private fun show() = compose.setContent { dev.chirp.android.ui.ChirpTheme(colour = AppColour.POND) { HistoryScreen(store, { now }, ZoneOffset.UTC) } }
    /** The list is lazy: scroll entries into composition before asserting on them. */
    private fun reveal(text: String) = compose.waitUntil(5000) {
        try { compose.onNode(hasScrollAction()).performScrollToNode(hasText(text)); true } catch (_: AssertionError) { false }
    }
    private fun clip() = context.getSystemService(ClipboardManager::class.java).primaryClip!!

    /** Nothing dictated reaches preferences or the log. */
    private fun assertPrivate(vararg secrets: String) {
        val prefs = File(context.applicationInfo.dataDir, "shared_prefs").listFiles().orEmpty().joinToString("\n") { it.readText() }
        val log = ShadowLog.getLogs().joinToString("\n") { "${it.tag} ${it.msg} ${it.throwable}" }
        secrets.forEach { secret -> assertFalse("in prefs", prefs.contains(secret)); assertFalse("in the log", log.contains(secret)) }
    }

    @Test fun `days are calendar days in the zone`() {
        val zone = ZoneOffset.UTC
        assertEquals(HistoryDay.Today, historyDay(now, now - 8 * hour + 60_000, zone))
        assertEquals(HistoryDay.Yesterday, historyDay(now, now - 8 * hour - 60_000, zone))
        assertEquals(HistoryDay.Yesterday, historyDay(now, now - 32 * hour + 60_000, zone))
        assertEquals(HistoryDay.Earlier, historyDay(now, now - 32 * hour - 60_000, zone))
    }

    @Test fun `entries are grouped by day and search filters them`() {
        store.enable()
        record("Meet at the pier at noon")
        record("Draft the quarterly summary", "draft the uh quarterly summary", "Gmail", at = now - 20 * hour)
        record("Running ten minutes late", at = now - 72 * hour)
        show()
        reveal("Running ten minutes late")
        val tops = listOf("Today", "Meet at the pier at noon", "Yesterday", "Draft the quarterly summary", "Earlier", "Running ten minutes late").map {
            compose.onNodeWithText(it).fetchSemanticsNode().boundsInRoot.top
        }
        assertEquals("headers in order, each above its entries", tops.sorted(), tops)
        compose.onNodeWithText("Gmail · 20 h ago · Polished").assertExists()
        compose.onNodeWithText("Search history").performTextInput("pier")
        compose.waitUntil(5000) { compose.onAllNodesWithText("Draft the quarterly summary").fetchSemanticsNodes().isEmpty() }
        compose.onNodeWithText("Meet at the pier at noon").assertExists()
        compose.onNodeWithText("Yesterday").assertDoesNotExist()
        compose.onNodeWithContentDescription("Clear search").performClick()
        reveal("Draft the quarterly summary")
        compose.onNodeWithText("Search history").performTextInput("zebra")
        compose.onNodeWithText("No matches").assertExists()
    }

    @Test fun `the detail sheet copies the text or the raw words and keeps them off the clipboard preview`() {
        store.enable()
        record("Draft the quarterly summary", "draft the uh quarterly summary", "Gmail")
        show()
        reveal("Draft the quarterly summary")
        compose.onNodeWithText("Draft the quarterly summary").performClick()
        compose.onNodeWithText("Before clean-up").assertExists()
        compose.onNodeWithText("draft the uh quarterly summary").assertExists()
        compose.onNodeWithText("Share").assertExists()
        compose.onNodeWithText("Copy").performClick()
        assertEquals("Draft the quarterly summary", clip().getItemAt(0).text.toString())
        assertTrue(clip().description.extras!!.getBoolean("android.content.extra.IS_SENSITIVE"))
        compose.onNodeWithText("Copy raw").performClick()
        assertEquals("draft the uh quarterly summary", clip().getItemAt(0).text.toString())
        assertPrivate("quarterly summary", "draft the uh")
    }

    @Test fun `swipe deletes at once and Undo restores the entry`() {
        store.enable()
        record("Meet at the pier at noon", at = now - hour)
        record("Pick up oat milk")
        show()
        reveal("Meet at the pier at noon")
        compose.onNodeWithText("Meet at the pier at noon").performTouchInput { swipeLeft() }
        compose.waitUntil(5000) { store.entries().none { it.text == "Meet at the pier at noon" } }
        compose.onNodeWithText("Dictation deleted").assertExists()
        compose.onNodeWithText("Meet at the pier at noon").assertDoesNotExist()
        compose.onNodeWithText("Undo").performClick()
        compose.waitUntil(5000) { store.entries().any { it.text == "Meet at the pier at noon" } }
        assertEquals(listOf("Pick up oat milk", "Meet at the pier at noon"), store.entries().map { it.text })
        reveal("Meet at the pier at noon")
        compose.waitForIdle()
        assertEquals("the restored row stays", 2, store.entries().size)
        assertPrivate("pier", "oat milk")
    }

    @Test fun `Delete in the detail sheet and the TalkBack action both delete`() {
        store.enable()
        record("Meet at the pier at noon")
        record("Pick up oat milk")
        show()
        reveal("Pick up oat milk")
        compose.onNodeWithText("Pick up oat milk").performClick()
        compose.onNodeWithText("Delete").performClick()
        compose.waitUntil(5000) { store.entries().size == 1 }
        val row = compose.onNode(hasText("Meet at the pier at noon") and hasClickAction()).fetchSemanticsNode()
        compose.runOnIdle { row.config[androidx.compose.ui.semantics.SemanticsActions.CustomActions].first { it.label == "Delete" }.action() }
        compose.waitUntil(5000) { store.entries().isEmpty() }
        compose.onNodeWithText("No dictations yet").assertExists()
    }

    @Test fun `history off shows the opt-in, and settings sit behind the menu where turning off confirms then deletes`() {
        store.disable()
        show()
        compose.onNodeWithText("Dictation history is off").assertExists()
        compose.onNodeWithText("Search history").assertDoesNotExist()
        compose.onNodeWithText("Turn on").performClick()
        compose.onNodeWithText("Keep dictation history on this phone").assertIsOff().performClick()
        assertTrue(store.enabled)
        compose.onNodeWithText("Delete history").assertExists()
        compose.onNodeWithText("7 days").performScrollTo().assertIsSelected()
        record("Meet at the pier at noon")
        compose.onNodeWithText("Keep dictation history on this phone").performScrollTo().performClick()
        compose.onNodeWithText("Turn off and delete").performClick()
        compose.waitUntil(5000) { !store.enabled && !File(context.filesDir, DictationHistory.FILE_NAME).exists() }
    }

    @Test fun `history kept while off remains searchable and can be deleted`() {
        record("Retained fixture")
        store.disable()
        show()
        reveal("Retained fixture")
        compose.onNodeWithText("Search history").assertExists()
        compose.onNodeWithContentDescription("More options").performClick()
        compose.onNodeWithText("History settings").performClick()
        compose.onNodeWithText("Keep dictation history on this phone").assertIsOff()
        compose.onNodeWithText("Delete history").performScrollTo().performClick()
        compose.onNodeWithText("Delete dictation history?").assertExists()
        val deleteButtons = compose.onAllNodesWithText("Delete history")
        deleteButtons[deleteButtons.fetchSemanticsNodes().lastIndex].performClick()
        compose.waitUntil(5000) { store.entries().isEmpty() }
        assertFalse(store.enabled)
    }

    @Test fun `long press offers add to note which creates then appends through the library`() {
        store.enable()
        val notes = NotesSessions(context, SoftwareHistoryKeys())
        record("Meet at the pier at noon")
        record("Pick up oat milk, lemons and coffee beans", at = now - hour)
        compose.setContent { dev.chirp.android.ui.ChirpTheme(colour = AppColour.POND) { HistoryScreen(store, { now }, ZoneOffset.UTC, notes = notes) } }
        reveal("Pick up oat milk, lemons and coffee beans")
        compose.onNodeWithText("Meet at the pier at noon").performTouchInput { longClick() }
        compose.onNodeWithText("Save as new note").performClick()
        compose.waitUntil(5000) { notes.entries().size == 1 }
        assertEquals("Meet at the pier at noon", notes.entries().single().title)
        compose.onNodeWithText("Saved as a new note").assertExists()
        compose.onNodeWithText("Pick up oat milk, lemons and coffee beans").performTouchInput { longClick() }
        compose.onNodeWithText("Add to latest note (“Meet at the pier at noon”)").assertIsDisplayed().performClick()
        compose.waitUntil(5000) { notes.entries().single().snippet.contains("oat milk") }
        assertEquals("Pick up oat milk, lemons and coffee beans", notes.entries().single().snippet)
        assertEquals("One note, appended", 1, notes.entries().size)
        val body = NotesDocument.fromJson(notes.open(notes.entries().single().id)!!.document).text
        assertEquals("Meet at the pier at noon\n\nPick up oat milk, lemons and coffee beans", body)
        compose.onNodeWithText("Added to your latest note").assertExists()
    }

    @Test fun `save as new is available alongside the named latest note`() {
        store.enable()
        val notes = NotesSessions(context, SoftwareHistoryKeys())
        val original = NotesDocument().apply { userEdit(0, 0, "Meeting body"); name = "Team meeting" }
        assertTrue(notes.put(original.uid, original.toJson()))
        record("A separate thought")
        compose.setContent { dev.chirp.android.ui.ChirpTheme(colour = AppColour.POND) { HistoryScreen(store, { now }, ZoneOffset.UTC, notes = notes) } }
        reveal("A separate thought")
        compose.onNodeWithText("A separate thought").performTouchInput { longClick() }
        compose.onNodeWithText("Add to latest note (“Team meeting”)").assertIsDisplayed()
        compose.onNodeWithText("Save as new note").assertIsDisplayed().performClick()
        compose.waitUntil(5000) { notes.entries().size == 2 }
        assertEquals("Meeting body", NotesDocument.fromJson(notes.open(original.uid)!!.document).text)
        assertEquals("A separate thought", notes.entries().first { it.id != original.uid }.title)
    }

    @Test fun `save as new through the accessibility action when the library is off says so`() {
        store.enable()
        val notes = NotesSessions(context, SoftwareHistoryKeys()).also { it.disable() }
        record("Meet at the pier at noon")
        compose.setContent { dev.chirp.android.ui.ChirpTheme(colour = AppColour.POND) { HistoryScreen(store, { now }, ZoneOffset.UTC, notes = notes) } }
        reveal("Meet at the pier at noon")
        val row = compose.onNode(hasText("Meet at the pier at noon") and hasClickAction()).fetchSemanticsNode()
        compose.runOnIdle { row.config[androidx.compose.ui.semantics.SemanticsActions.CustomActions].first { it.label == "Save as new note" }.action() }
        compose.waitUntil(5000) { compose.onAllNodes(hasText("Notes are off", substring = true)).fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("Notes are off — turn on Keep notes on this phone in Settings → Notes").assertExists()
        assertTrue(notes.entries().isEmpty())
        assertPrivate("pier")
        assertTrue(notes.entries().isEmpty())
        assertPrivate("pier")
    }

    @Test fun `the menu opens history settings with retention`() {
        store.enable()
        show()
        compose.onNodeWithText("No dictations yet").assertExists()
        compose.onNodeWithContentDescription("More options").performClick()
        compose.onNodeWithText("History settings").performClick()
        compose.onNodeWithText("1 day").performScrollTo().performClick()
        compose.waitUntil(5000) { store.retention == HistoryRetention.DAY }
    }
}
