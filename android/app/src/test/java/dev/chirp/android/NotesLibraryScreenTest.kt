package dev.chirp.android

import android.graphics.Bitmap
import androidx.activity.ComponentActivity
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.text.input.TextFieldValue
import dev.chirp.android.shell.AppShell
import dev.chirp.android.shell.ShellTab
import java.io.File
import java.time.Instant
import java.time.ZoneOffset
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37])
class NotesGroupsTest {
    @Test fun `groups use calendar days and include older months and years`() {
        val now = Instant.parse("2026-10-24T00:10:00Z").toEpochMilli()
        fun group(date: String) = notesGroup(now, Instant.parse(date).toEpochMilli(), ZoneOffset.UTC).resolve(RuntimeEnvironment.getApplication().resources)
        assertEquals("Today", group("2026-10-24T00:01:00Z"))
        assertEquals("Yesterday", group("2026-10-23T23:59:00Z"))
        assertEquals("Previous 7 days", group("2026-10-17T12:00:00Z"))
        assertEquals("Previous 30 days", group("2026-09-24T12:00:00Z"))
        assertEquals("September", group("2026-09-01T12:00:00Z"))
        assertEquals("October 2025", group("2025-10-24T12:00:00Z"))
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37], qualifiers = "w411dp-h891dp-mdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class NotesLibraryScreenTest {

    @org.junit.Before fun noMotion() {
        android.provider.Settings.Global.putFloat(RuntimeEnvironment.getApplication().contentResolver, android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 0f)
    }

    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val context get() = RuntimeEnvironment.getApplication()
    private val now = Instant.parse("2026-10-24T14:00:00Z").toEpochMilli()
    private var time = now
    private val keys = SoftwareHistoryKeys()
    private val library by lazy { NotesSessions(context, keys, { time }) }
    private val live by lazy { NotesModelRig(context, sessions = library) }
    private val reader by lazy { NotesModelRig(context, sessions = library) }
    private val shortcuts = AppShortcuts()
    private val dark = mutableStateOf(false)
    private val tab = mutableStateOf(ShellTab.Notes)
    private val setup = SetupState().apply { mic = true; paired = true; reachable = true; inputEnabled = true; inputSelected = true }
    private var connections = 0
    private var dictations = 0

    private fun note(title: String, text: String, hoursAgo: Int = 0, transcript: String = "", audio: Boolean = false, duration: Double = 732.0): String {
        time = now - hoursAgo * 3_600_000L
        val doc = NotesDocument().apply {
            name = title; userEdit(0, 0, text)
            if (transcript.isNotBlank()) append(NotesSegment(0, 0.0, transcript))
        }
        library.put(doc.uid, doc.toJson().put("elapsed", duration))
        if (audio) library.storeClip(doc.uid, 0, 0.0, 32000, byteArrayOf(1, 2, 3))
        return doc.uid
    }

    private fun show() {
        library.refresh()
        compose.setContent { CompositionLocalProvider(LocalAppShortcuts provides shortcuts) { ChirpTheme(dark.value) {
            AppShell(tab.value, { tab.value = it }) {
                if (it == ShellTab.Notes) NotesLibraryScreen(live.model, reader.model,
                    record = { id -> if (id == null) { live.model.keepSession(); live.model.clear(); live.model.start() } else live.model.continueRecording(id, stopCurrent = true) },
                    copy = {}, share = {}, save = {}, act = {}, state = setup, connection = { connections++ }, dictate = { dictations++ }, now = { now })
                else androidx.compose.material3.Text("Other tab")
            }
        } } }
    }
    private fun search(text: String) = compose.onNode(hasSetTextAction()).performTextReplacement(text)
    private fun back() = compose.runOnIdle { compose.activity.onBackPressedDispatcher.onBackPressed() }
    private fun open(title: String) = compose.onNode(hasText(title) and hasClickAction()).performClick()
    private fun trash() { compose.onNodeWithContentDescription("Library options").performClick(); compose.onNodeWithText("Recently Deleted").performClick() }
    private fun loaded(title: String) { compose.waitUntil(5000) { compose.onAllNodesWithContentDescription("Rename notes: $title").fetchSemanticsNodes().isNotEmpty() } }
    private fun displayed(text: String) {
        // IO completion and the snackbar's first visible frame are independent of Compose idleness.
        compose.waitUntil(5000) { compose.onNodeWithText(text).isDisplayed() }
    }

    private fun newTypedNote(width: String) {
        setup.paired = false; setup.mic = false
        show()
        compose.onNodeWithContentDescription("New note").performClick()
        compose.onNodeWithContentDescription("Notes (Markdown)").assertIsFocused()
        for (night in listOf(false, true)) {
            compose.runOnIdle { dark.value = night }; compose.mainClock.advanceTimeBy(2000); compose.waitForIdle()
            val bitmap = notesScreenshot(compose.onRoot())
            File(System.getProperty("chirp.screenshots"), "notes-library-$width-new-note-${if (night) "dark" else "light"}.png")
                .outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
        compose.onNodeWithContentDescription("Notes (Markdown)").performTextInput("Typed locally")
        val first = reader.model.document.uid
        compose.runOnIdle { live.record().final("A synthetic recording"); live.idle() }
        val recording = live.model.document.uid
        compose.runOnIdle {
            assertTrue(shortcuts.dispatch(android.view.KeyEvent(0, 0, android.view.KeyEvent.ACTION_DOWN,
                android.view.KeyEvent.KEYCODE_N, 0, android.view.KeyEvent.META_CTRL_ON)))
        }
        compose.onNodeWithContentDescription("Notes (Markdown)").assertIsFocused()
        assertEquals("", reader.model.field.text)
        assertNotEquals(first, reader.model.document.uid)
        assertEquals(recording, live.model.document.uid)
        assertTrue(live.model.state.active)
        assertEquals("Typed locally", NotesDocument.fromJson(library.open(first)!!.document).text)
    }

    @Test fun `New note opens a blank focused editor and Ctrl N keeps a recording separate`() = newTypedNote("cover")
    @Test @Config(qualifiers = "w840dp-h900dp-mdpi") fun `New note works on inner with a separate recording`() = newTypedNote("inner")

    @Test fun `Ctrl F closes a cover detail and focuses library search`() {
        note("Garden plans", "A synthetic page")
        show(); open("Garden plans"); loaded("Garden plans")
        compose.runOnIdle {
            assertTrue(shortcuts.dispatch(android.view.KeyEvent(0, 0, android.view.KeyEvent.ACTION_DOWN,
                android.view.KeyEvent.KEYCODE_F, 0, android.view.KeyEvent.META_CTRL_ON)))
        }
        compose.waitForIdle()
        compose.onNode(hasSetTextAction()).assertIsFocused()
        compose.onNodeWithContentDescription("Edit notes").assertDoesNotExist()
    }

    @Test fun `full transcript search highlights results and Back preserves the query and list position`() {
        val id = note("Garden plans", "- Buy seeds", transcript = "A quiet pond beside the terrace")
        repeat(14) { note("Earlier note $it", "- A synthetic example", 25 + it) }
        show()
        search("pond")
        compose.waitUntil(5000) { compose.onAllNodesWithText("A quiet pond beside the terrace").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("A quiet pond beside the terrace").assertIsDisplayed()
        open("Garden plans"); loaded("Garden plans")
        compose.onNodeWithText("Continue recording").assertIsDisplayed()
        back()
        compose.onNode(hasSetTextAction()).assertTextEquals("pond")
        compose.onNodeWithText("Garden plans").assertIsDisplayed()
        assertEquals(id, reader.model.document.uid)
        search("no such phrase")
        compose.waitUntil(5000) { compose.onAllNodesWithText("No results for “no such phrase”").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("No results for “no such phrase”").assertExists()
        compose.onNodeWithText("Your notes will live here").assertDoesNotExist()
    }

    @Test fun `the note menu deletes with Undo`() {
        val id = note("Garden plans", "- Buy seeds")
        show(); open("Garden plans"); loaded("Garden plans")
        compose.onNodeWithContentDescription("More options").performClick()
        compose.onNodeWithText("Delete").performClick()
        displayed("Note deleted")
        compose.runOnIdle { assertTrue(library.open(id)!!.entry.deleted) }
        compose.onNodeWithText("Undo").performClick()
        displayed("Garden plans")
        compose.runOnIdle { assertFalse(library.open(id)!!.entry.deleted) }
    }

    @Test fun `Delete audio asks first, shows megabytes, and keeps the text`() {
        val id = note("Garden plans", "- Buy seeds", audio = true)
        show(); open("Garden plans"); loaded("Garden plans")
        compose.onNodeWithContentDescription("More options").performClick()
        compose.onNodeWithText("<0.1 MB on this phone").assertIsDisplayed()
        compose.onNodeWithText("Delete audio").performClick()
        compose.onNodeWithText("Delete audio?").assertIsDisplayed()
        compose.onNodeWithText("This deletes this note’s audio (<0.1 MB). The text and transcript stay.").assertIsDisplayed()
        compose.onNodeWithText("Cancel").performClick()
        compose.runOnIdle { assertTrue(library.open(id)!!.document.getJSONArray("audio").length() > 0) }
        compose.onNodeWithContentDescription("More options").performClick()
        compose.onNodeWithText("Delete audio", substring = false).performClick()
        compose.onNodeWithText("Delete audio", substring = false).performClick()
        compose.waitUntil(5000) { library.open(id)!!.document.getJSONArray("audio").length() == 0 }
        assertEquals("- Buy seeds", NotesDocument.fromJson(library.open(id)!!.document).text)
        compose.onNodeWithContentDescription("More options").performClick()
        compose.onNodeWithText("Delete audio").assertDoesNotExist()
    }

    @Test fun `swipe deletes with Undo and recently deleted can restore`() {
        val id = note("Garden plans", "- Buy seeds")
        show()
        compose.onNode(hasText("Garden plans") and hasClickAction()).performTouchInput { swipeLeft() }
        displayed("Note deleted")
        // TalkBack and UiAutomator reach Undo as a button with a click action, not by position.
        compose.onNode(hasText("Undo") and hasClickAction()).assertHasClickAction()
        compose.onNodeWithText("Undo").performClick()
        displayed("Garden plans")
        compose.runOnIdle { assertFalse(library.open(id)!!.entry.deleted) }
        compose.onNode(hasText("Garden plans") and hasClickAction()).performTouchInput { swipeLeft() }
        displayed("Note deleted")
        trash()
        compose.onNodeWithText("Restore").performClick()
        displayed("Nothing recently deleted")
        compose.runOnIdle { assertFalse(library.open(id)!!.entry.deleted) }
    }

    @Test fun `long press selects notes and bulk delete leaves a recording alone`() {
        val id = note("Garden plans", "- Buy seeds")
        note("A second thought", "- Make time to think")
        show()
        compose.runOnIdle { live.record().final("A synthetic recording"); live.idle() }
        compose.onNode(hasText("Garden plans") and hasClickAction()).performTouchInput { longClick() }
        compose.onNodeWithText("1 selected").assertExists()
        open("A second thought")
        compose.onNodeWithText("2 selected").assertExists()
        compose.onNodeWithContentDescription("Delete selected notes").performClick()
        // Deletion runs on IO; Compose idleness alone does not await the storage operation.
        compose.waitUntil(5000) { compose.onAllNodesWithText("2 notes deleted").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("2 notes deleted").assertExists()
        assertTrue(live.model.state.active)
        compose.runOnIdle { assertTrue(library.open(id)!!.entry.deleted) }
    }

    @Test fun `while a note records the primary action opens it and a new recording stays deliberate`() {
        note("Garden plans", "- Buy seeds")
        show()
        compose.runOnIdle { live.model.rename("Product conversation"); live.record().final("We can keep the first release small."); live.idle() }
        val recordingId = live.model.document.uid
        // The pinned card is the same note the primary action opens; neither stops nor replaces it.
        compose.onNodeWithContentDescription("Open the current recording").performClick()
        loaded("Product conversation")
        assertEquals(recordingId, live.model.document.uid)
        assertEquals(NotesRecorder.State.RECORDING, live.model.state)
        compose.onNodeWithText("Start a new recording?").assertDoesNotExist()
        back()
        compose.onNodeWithText("Start a new recording?").assertDoesNotExist()
        // A deliberate new recording stays behind a named action and its confirmation.
        compose.onNodeWithContentDescription("Library options").performClick()
        compose.onNodeWithText("Record new note").performClick()
        compose.onNodeWithText("Start a new recording?").assertIsDisplayed()
        compose.onNodeWithText("Cancel").performClick()
        assertEquals(NotesRecorder.State.RECORDING, live.model.state)
    }

    @Test fun `while a note is paused the primary action opens the same paused note`() {
        show()
        compose.runOnIdle { live.model.rename("Product conversation"); live.record().final("We can keep the first release small."); live.idle() }
        compose.runOnIdle { live.model.pause(); live.idle() }
        val recordingId = live.model.document.uid
        compose.onNodeWithContentDescription("Open the paused recording").performClick()
        loaded("Product conversation")
        assertEquals(recordingId, live.model.document.uid)
        assertEquals(NotesRecorder.State.PAUSED, live.model.state)
        compose.onNodeWithText("Start a new recording?").assertDoesNotExist()
    }

    @Test fun `the pinned recording card is one button with truthful state and a named open action`() {
        show()
        compose.runOnIdle { live.model.rename("Product conversation"); live.record().final("We can keep the first release small."); live.idle() }
        val card = compose.onNode(hasStateDescription("Recording"))
        card.assertExists()
        val node = card.fetchSemanticsNode()
        assertEquals("Open the recording", node.config[androidx.compose.ui.semantics.SemanticsActions.OnClick].label)
        // One merged node: the title and the frozen preview are announced by the card itself.
        assertTrue(node.config[androidx.compose.ui.semantics.SemanticsProperties.Text].any { "Product conversation" in it.text })
        assertTrue("elapsed is available when focusing the card", node.config[androidx.compose.ui.semantics.SemanticsProperties.Text].any { live.model.elapsedText.notesEnglish() in it.text })
        assertTrue("one focus target", node.children.isEmpty())
        fun quiet(n: androidx.compose.ui.semantics.SemanticsNode) {
            if (androidx.compose.ui.semantics.SemanticsProperties.LiveRegion in n.config)
                fail("no live region inside the recording card")
            n.children.forEach(::quiet)
        }
        node.children.forEach(::quiet)
        assertFalse(androidx.compose.ui.semantics.SemanticsProperties.LiveRegion in node.config)
        card.performClick()
        loaded("Product conversation")
        assertTrue(live.model.state.active)
    }

    @Test fun `the pinned card tells paused from recording`() {
        show()
        compose.runOnIdle { live.model.rename("Product conversation"); live.record().final("We can keep the first release small."); live.idle() }
        compose.runOnIdle { live.model.pause(); live.idle() }
        compose.onNode(hasStateDescription("Paused")).assertExists()
        compose.onNode(hasStateDescription("Recording")).assertDoesNotExist()
    }

    @Test fun `a failed open can be retried or left without stranding the library`() {
        val id = note("Garden plans", "- Buy seeds")
        show()
        // The row is already displayed when its file becomes unavailable.
        val file = File(context.filesDir, "${NotesSessions.DIR}/$id.bin")
        val bytes = file.readBytes()
        file.delete()
        open("Garden plans")
        compose.onNodeWithText("Couldn’t open this note").assertExists()
        compose.onNodeWithText("Try again").performClick()
        compose.onNodeWithText("Back to notes").assertExists()
        file.writeBytes(bytes)
        compose.onNodeWithText("Try again").performClick()
        loaded("Garden plans")
        back()
        // A second missing note can be left using its visible recovery action.
        val other = note("An earlier draft", "Synthetic draft")
        File(context.filesDir, "${NotesSessions.DIR}/$other.bin").delete()
        open("An earlier draft")
        compose.onNodeWithText("Back to notes").performClick()
        compose.onNodeWithText("Search notes").assertExists()
    }

    @Test fun `browsing and renaming another note preserves the live recording`() {
        val id = note("Garden plans", "- Buy seeds")
        show()
        compose.runOnIdle { live.record().final("A synthetic recording"); live.idle() }
        val recordingId = live.model.document.uid
        open("Garden plans"); loaded("Garden plans")
        compose.onNodeWithContentDescription("Rename notes: Garden plans").performClick()
        compose.onNodeWithContentDescription("Note title").performTextReplacement("Garden journal")
        compose.onNodeWithContentDescription("Save title").performClick()
        assertEquals("Garden journal", reader.model.displayTitle)
        assertEquals(recordingId, live.model.document.uid)
        assertTrue(live.model.recording)
        compose.runOnIdle { assertEquals("Garden journal", library.open(id)!!.entry.title) }
        compose.onNodeWithText("Continue recording").performClick()
        compose.onNodeWithText("Stop current and continue here").assertExists()
    }

    @Test fun `connection and Dictate actions and the dismissible setup card are reachable`() {
        setup.mic = false
        show()
        compose.onNodeWithContentDescription("Connection: Computer. Open connection settings").performClick()
        assertEquals(1, connections)
        compose.onNodeWithContentDescription("Dictate").performClick()
        assertEquals(1, dictations)
        compose.onNodeWithText("Finish setting up").assertIsDisplayed()
        compose.onNodeWithText("Next: allow the microphone").assertExists()
        compose.onNodeWithContentDescription("Dismiss setup").performClick()
        compose.onNodeWithText("Next: allow the microphone").assertDoesNotExist()
        assertTrue(SettingsStore(context).tryItDismissed)
    }

    @Test fun `Back restores the scrolled list and switching tabs restores the search`() {
        repeat(24) { note("Notebook $it", "A synthetic page", it + 1) }
        show()
        compose.onNodeWithTag("notes-library-list").performScrollToNode(hasText("Notebook 20"))
        val before = compose.onNode(hasText("Notebook 20") and hasClickAction()).fetchSemanticsNode().boundsInRoot.top
        open("Notebook 20"); loaded("Notebook 20"); back()
        val after = compose.onNode(hasText("Notebook 20") and hasClickAction()).fetchSemanticsNode().boundsInRoot.top
        assertEquals(before, after, 1f)
        search("Notebook 2")
        compose.onNode(hasText("History") and isSelectable()).performClick()
        compose.onNode(hasText("Notes") and isSelectable()).performClick()
        compose.onNode(hasSetTextAction()).assertTextEquals("Notebook 2")
    }

    @Test @Config(qualifiers = "w1280dp-h800dp-land-mdpi") fun `wide landscape has a third transcript pane`() {
        note("Launch sync", "## A smaller beta\n- [ ] Draft the invitation", transcript = "Synthetic speech for this review.", audio = true)
        show(); open("Launch sync"); loaded("Launch sync")
        compose.onNodeWithText("Show raw").assertExists()
        compose.onNodeWithContentDescription("Close transcript").assertDoesNotExist()
        compose.onNodeWithContentDescription("Play segment 1").assertExists()
        for (night in listOf(false, true)) {
            compose.runOnIdle { dark.value = night }
            compose.mainClock.advanceTimeBy(2000); compose.waitForIdle()
            val bitmap = compose.onRoot().captureToImage().asAndroidBitmap()
            File(System.getProperty("chirp.screenshots"), "notes-library-wide-landscape-${if (night) "dark" else "light"}.png")
                .outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
    }

    private fun render(width: String, fontScale: Float = 1f) {
        RuntimeEnvironment.setFontScale(fontScale)
        setup.mic = false
        show()
        val output = File(System.getProperty("chirp.screenshots")).apply { mkdirs() }
        fun shot(state: String) {
            for (night in listOf(false, true)) {
                compose.runOnIdle { dark.value = night }
                compose.mainClock.advanceTimeBy(2000); compose.waitForIdle()
                // A modal sheet has its own window/root. Capture that window when present.
                val target = when (state) {
                    "transcript-sheet" -> compose.onNode(isRoot() and hasAnyDescendant(hasText("Show raw")))
                    "empty-trash" -> compose.onNode(isRoot() and hasAnyDescendant(hasText("Empty Recently Deleted?")))
                    else -> compose.onRoot()
                }
                val bitmap = notesScreenshot(target)
                File(output, "notes-library-$width-$state-${if (night) "dark" else "light"}.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            }
        }
        shot("empty")
        val first = note("Launch sync", "## A smaller, better beta\nThe first release goes to ten design partners.\n- [ ] Draft the invitation\n- [ ] Check pricing with finance", transcript = "The beta goes to ten design partners. We agreed to ship on Friday.", audio = true)
        note("A walk by the water", "A quiet morning, a notebook, and a little room to think.", 5, duration = 0.0)
        note("Ideas for the studio", "- A long table by the window\n- [ ] Find a reading lamp", 25)
        val deleted = note("An earlier draft", "A few thoughts worth returning to.", 50)
        library.trash(deleted); time = now
        compose.onNodeWithText("0 open tasks").assertDoesNotExist()
        compose.onNodeWithText("0 sec").assertDoesNotExist()
        val listBottom = compose.onNodeWithTag("notes-library-list").fetchSemanticsNode().boundsInRoot.bottom
        val fabTop = compose.onNodeWithContentDescription("Record new note").fetchSemanticsNode().boundsInRoot.top
        assertTrue("list viewport stays above the capture controls", listBottom <= fabTop)
        shot("populated")
        compose.runOnIdle { live.model.rename("Product conversation"); live.record().final("We can keep the first release small."); live.idle() }
        // The card that leads back to the live note is on screen, not inserted above the list's scroll anchor.
        compose.onNode(hasStateDescription("Recording")).assertIsDisplayed()
        shot("recording")
        compose.runOnIdle { live.model.pause(); live.idle() }
        compose.onNode(hasStateDescription("Paused")).assertIsDisplayed()
        shot("recording-paused")
        val primary = compose.onNodeWithContentDescription("Open the paused recording").fetchSemanticsNode().boundsInRoot
        val dictate = compose.onNodeWithContentDescription("Dictate").fetchSemanticsNode().boundsInRoot
        val viewport = compose.onRoot().fetchSemanticsNode().boundsInRoot
        assertTrue("paused primary stays inside screen", primary.left >= 0 && primary.right <= viewport.right)
        assertTrue("primary and Dictate do not overlap", primary.left >= dictate.right || primary.top >= dictate.bottom || dictate.top >= primary.bottom)
        assertTrue("measured list clears paused controls", compose.onNodeWithTag("notes-library-list").fetchSemanticsNode().boundsInRoot.bottom <= minOf(primary.top, dictate.top))
        compose.runOnIdle { live.model.togglePause(); live.idle() }
        search("design")
        // At 200% font the sticky recording card and the first rows share one viewport: the row is past the fold
        // until the list is scrolled (lazy lists compose only what intersects the viewport).
        // A new search first returns to the top; scroll once the results have settled there.
        compose.waitUntil(5000) {
            runCatching { compose.onNodeWithTag("notes-library-list").performScrollToNode(hasText("Launch sync")) }.isSuccess &&
                compose.onAllNodesWithText("Launch sync").fetchSemanticsNodes().isNotEmpty()
        }
        shot("search")
        search("summer holiday")
        // A new search starts at the top, where the way back to the recording is (Connecting again after Resume).
        compose.onNode(hasText("Product conversation") and hasClickAction()).assertIsDisplayed()
        // At 200% on the cover the explanation sits below the card, past the fold.
        compose.waitUntil(5000) {
            runCatching { compose.onNodeWithTag("notes-library-list").performScrollToNode(hasText("No results for “summer holiday”")) }.isSuccess
        }
        compose.onNodeWithText("No results for “summer holiday”").assertIsDisplayed()
        shot("no-results")
        if (fontScale != 1f) return
        search("")
        compose.onNode(hasText("Launch sync") and hasClickAction()).performTouchInput { longClick() }
        open("A walk by the water")
        shot("multi-select")
        back()
        trash(); compose.onNodeWithText("Search Recently Deleted").assertIsDisplayed(); shot("recently-deleted")
        compose.onNodeWithContentDescription("Library options").performClick()
        compose.onNodeWithText("Empty Recently Deleted").performClick()
        compose.onNodeWithText("Delete permanently").assertIsDisplayed()
        shot("empty-trash")
        compose.onNodeWithText("Cancel").performClick(); back()
        open("Launch sync"); loaded("Launch sync")
        shot("detail")
        compose.onNodeWithText("Transcript").performClick()
        compose.onNodeWithContentDescription("Play segment 1").assertExists()
        shot("transcript-sheet")
        // The note being read is independent of the recording in every viewport.
        assertEquals(first, reader.model.document.uid)
        assertTrue(live.model.recording)
    }

    @Test fun `render library on cover in light and dark`() = render("cover")
    @Test @Config(qualifiers = "w840dp-h900dp-mdpi") fun `render library on inner in light and dark`() = render("inner")
    @Test @Config(qualifiers = "w360dp-h740dp-mdpi") fun `render library at twice the font size on a narrow cover`() = render("narrow-font-200", fontScale = 2f)
    @Test @Config(qualifiers = "w840dp-h900dp-mdpi") fun `render library at twice the font size unfolded`() = render("inner-font-200", fontScale = 2f)
}
