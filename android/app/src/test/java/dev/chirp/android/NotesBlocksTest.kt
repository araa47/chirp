package dev.chirp.android

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextDecoration
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

class NotesBlocksTest {
    private val notes = """
        # Launch sync
        ## Plan
        - Beta goes to **ten** design partners
          - then the *waitlist*
        1. Draft copy
        2) Review
        - [ ] Draft the invite email
        - [x] Book the room
        - **Decision:** Ship on Friday
        Question: Do we need a waitlist?

        First line
        second line
        > quoted
        ---
        _Not structured — see transcript_
    """.trimIndent()

    @Test fun `headings, lists, tasks and callouts parse with their source lines`() {
        val blocks = NotesBlocks.parse(notes)
        assertEquals(listOf("Heading", "Heading", "Item", "Item", "Item", "Item", "Task", "Task", "Callout", "Callout", "Paragraph", "Quote", "Rule", "Note"),
            blocks.map { it::class.simpleName })
        assertEquals(NotesBlock.Heading(1, "Launch sync", 0, 13), blocks[0])
        assertEquals(2, (blocks[1] as NotesBlock.Heading).level)
        val nested = blocks[3] as NotesBlock.Item
        assertEquals(1, nested.depth); assertNull(nested.number)
        assertEquals(listOf("1.", "2."), blocks.subList(4, 6).map { (it as NotesBlock.Item).number })
        val (open, done) = blocks[6] as NotesBlock.Task to blocks[7] as NotesBlock.Task
        assertFalse(open.checked); assertTrue(done.checked)
        assertEquals("Draft the invite email", open.text)
        assertEquals(' ', notes[open.mark]); assertEquals('x', notes[done.mark])
        assertEquals("- [ ] Draft the invite email", notes.substring(open.start, open.end))
        assertEquals(NotesBlock.Callout.Kind.DECISION to "Ship on Friday", (blocks[8] as NotesBlock.Callout).let { it.kind to it.text })
        assertEquals(NotesBlock.Callout.Kind.QUESTION to "Do we need a waitlist?", (blocks[9] as NotesBlock.Callout).let { it.kind to it.text })
        assertEquals("First line\nsecond line", (blocks[10] as NotesBlock.Paragraph).text)
        assertEquals("Not structured — see transcript", (blocks[13] as NotesBlock.Note).text)
    }

    @Test fun `callouts are recognised bold, plain or as list items, and other bold labels are not`() {
        for (line in listOf("- **Decision:** Go", "**Decision**: Go", "Decision: Go", "* decisions: Go")) {
            assertEquals(line, NotesBlock.Callout.Kind.DECISION, (NotesBlocks.parse(line).single() as? NotesBlock.Callout)?.kind)
        }
        assertTrue(NotesBlocks.parse("- **Owner:** Sam").single() is NotesBlock.Item)
        assertTrue(NotesBlocks.parse("Decisive moment").single() is NotesBlock.Paragraph)
    }

    @Test fun `a code fence keeps its lines and nothing inside is Markdown`() {
        val block = NotesBlocks.parse("```\n# not a heading\n- nor a list\n```\nafter").first() as NotesBlock.Code
        assertEquals("# not a heading\n- nor a list", block.text)
    }

    @Test fun `ticking a task writes x into the Markdown and nothing else`() {
        val task = NotesBlocks.parse(notes).filterIsInstance<NotesBlock.Task>()
        val ticked = NotesBlocks.toggle(notes, task[0])
        assertTrue(ticked.contains("- [x] Draft the invite email"))
        assertEquals(notes.length, ticked.length)
        assertEquals(notes, NotesBlocks.toggle(ticked, NotesBlocks.parse(ticked).filterIsInstance<NotesBlock.Task>()[0]))
        assertTrue(NotesBlocks.toggle(notes, task[1]).contains("- [ ] Book the room"))
        // A stale block (the text moved under it) changes nothing.
        assertEquals("abc", NotesBlocks.toggle("abc", task[0]))
    }

    @Test fun `inline bold, italic, code, strike and links render without their markers`() {
        val text = notesInline("**Ship** it _now_, run `make` ~~today~~ [see doc](https://example.test) and snake_case_name")
        assertEquals("Ship it now, run make today see doc and snake_case_name", text.text)
        fun styleAt(word: String) = text.spanStyles.filter { text.text.indexOf(word) in it.start until it.end }.map { it.item }
        assertTrue(styleAt("Ship").any { it.fontWeight == FontWeight.SemiBold })
        assertTrue(styleAt("now").any { it.fontStyle == FontStyle.Italic })
        assertTrue(styleAt("today").any { it.textDecoration == TextDecoration.LineThrough })
        assertTrue(styleAt("see doc").any { it.textDecoration == TextDecoration.Underline })
        assertTrue(styleAt("snake").isEmpty())
        assertEquals("2 * 3 and *literal", notesInline("2 * 3 and \\*literal", SpanStyle(), SpanStyle()).text)
    }

    @Test fun `block keys follow content, not position`() {
        val before = NotesBlocks.parse("- a\n- b")
        val after = NotesBlocks.parse("# New\n- a\n- b")
        assertEquals(NotesBlocks.keys("- a\n- b", before), NotesBlocks.keys("# New\n- a\n- b", after).drop(1))
        val twice = NotesBlocks.keys("- a\n- a", NotesBlocks.parse("- a\n- a"))
        assertEquals(2, twice.toSet().size)
    }

    @Test fun `the formatting bar toggles a line kind and keeps the caret in the words`() {
        val bullet = NotesFormat.toggle(TextFieldValue("one\ntwo", TextRange(5)), NotesLineKind.BULLET)
        assertEquals("one\n- two", bullet.text); assertEquals(TextRange(7), bullet.selection)
        val off = NotesFormat.toggle(bullet, NotesLineKind.BULLET)
        assertEquals("one\ntwo", off.text); assertEquals(TextRange(5), off.selection)
        val task = NotesFormat.toggle(bullet, NotesLineKind.TASK)
        assertEquals("one\n- [ ] two", task.text); assertEquals(TextRange(11), task.selection)
        val heading = NotesFormat.toggle(TextFieldValue("  - item", TextRange(8)), NotesLineKind.HEADING)
        assertEquals("## item", heading.text); assertEquals(TextRange(7), heading.selection)
        val both = NotesFormat.toggle(TextFieldValue("a\nb\nc", TextRange(0, 3)), NotesLineKind.TASK)
        assertEquals("- [ ] a\n- [ ] b\nc", both.text)
        val empty = NotesFormat.toggle(TextFieldValue("", TextRange(0)), NotesLineKind.TASK)
        assertEquals("- [ ] ", empty.text); assertEquals(TextRange(6), empty.selection)
    }

    @Test fun `undo steps back through the user's typing and drops when anything else changed the notes`() {
        var now = 0L
        val undo = NotesTextUndo { now }
        undo.record(TextFieldValue(""), "a"); now += 200
        undo.record(TextFieldValue("a"), "ab"); now += 5000
        undo.record(TextFieldValue("ab"), "ab!")
        assertTrue(undo.canUndo("ab!"))
        assertEquals("ab", undo.undo("ab!")?.text)
        assertEquals("", undo.undo("ab")?.text)
        assertNull(undo.undo(""))
        undo.record(TextFieldValue("x"), "xy")
        // A structuring answer landed: undo would take it away too, so there is none.
        assertFalse(undo.canUndo("xy\n\n- From the Mac"))
        assertNull(undo.undo("xy\n\n- From the Mac"))
    }

    @Test fun `previews read as words and the title comes from the name, a first heading or the time`() {
        assertEquals("Plan · Beta goes to ten design partners · ☐ Draft the invite email", NotesBlocks.preview(
            "# Launch sync\n## Plan\n- Beta goes to **ten** design partners\n- [ ] Draft the invite email", "Launch sync"))
        assertTrue(NotesBlocks.preview("word ".repeat(100), max = 40).let { it.length == 40 && it.endsWith("…") })
        val document = NotesDocument(text = "\n# Launch sync\n- a")
        assertEquals("Launch sync", document.displayTitle())
        document.name = "Board prep"; assertEquals("Board prep", document.displayTitle())
        assertEquals("Plan", NotesDocument(text = "## Plan").displayTitle())
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37], qualifiers = "w411dp-h891dp-mdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class NotesPageTest {
    @org.junit.Before fun noMotion() {
        android.provider.Settings.Global.putFloat(RuntimeEnvironment.getApplication().contentResolver, android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 0f)
    }

    @get:Rule val compose = createComposeRule()

    private fun screen(text: String): NotesModelRig {
        val rig = NotesModelRig(RuntimeEnvironment.getApplication())
        rig.model.edit(TextFieldValue(text))
        compose.setContent { ChirpTheme(false) { NotesScreen(rig.model, rig.model::toggle, {}, {}, {}, {}) } }
        return rig
    }

    @Test fun `the notes render as a document, not as Markdown source`() {
        screen("## Plan\n- Beta goes to **ten** partners\n- [ ] Draft the invite\n- **Decision:** Ship Friday")
        compose.onNode(hasText("Plan") and isHeading() and hasTestTag("notes-block")).assertIsDisplayed()
        compose.onNodeWithText("Beta goes to ten partners").assertIsDisplayed()
        compose.onNodeWithText("## Plan", substring = true).assertDoesNotExist()
        compose.onNodeWithText("Decision").assertIsDisplayed()
        compose.onNodeWithText("Ship Friday").assertIsDisplayed()
        compose.onNode(hasSetTextAction()).assertDoesNotExist()
        compose.onNodeWithContentDescription("Continue recording").assertIsDisplayed()
    }

    @Test fun `ticking a to-do writes it back to the Markdown as the user's edit`() {
        val rig = screen("- [ ] Draft the invite\n- [ ] Book the room")
        fun task() = compose.onNode(hasText("Draft the invite") and isToggleable())
        // TalkBack: one checkbox named by its words.
        task().assertIsOff().performSemanticsAction(SemanticsActions.OnClick)
        compose.runOnIdle { assertEquals("- [x] Draft the invite\n- [ ] Book the room", rig.model.document.text) }
        // Touch: the box ticks, the words edit.
        task().assertIsOn().performTouchInput { click(centerLeft + Offset(16f, 0f)) }
        compose.runOnIdle { assertEquals("- [ ] Draft the invite\n- [ ] Book the room", rig.model.document.text) }
        compose.onNode(hasSetTextAction()).assertDoesNotExist()
        task().performTouchInput { click(center) }
        compose.onNode(hasSetTextAction()).assertIsDisplayed()
    }

    @Test fun `tapping a block edits there, the toolbar formats, and Done returns to the page`() {
        val rig = screen("## Plan\n- Beta\nLoose line")
        compose.onNodeWithText("Loose line").performClick()
        compose.onNode(hasSetTextAction()).assertIsDisplayed().assertIsFocused()
        assertEquals(TextRange("## Plan\n- Beta\nLoose line".length), rig.model.field.selection)
        compose.onNodeWithContentDescription("Checklist").performClick()
        compose.runOnIdle { assertEquals("## Plan\n- Beta\n- [ ] Loose line", rig.model.document.text) }
        compose.onNodeWithContentDescription("Undo").performClick()
        compose.runOnIdle { assertEquals("## Plan\n- Beta\nLoose line", rig.model.document.text) }
        compose.onNodeWithContentDescription("Undo").assertIsNotEnabled()
        compose.onNodeWithText("Done").performClick()
        compose.onNode(hasSetTextAction()).assertDoesNotExist()
        compose.onNodeWithText("Loose line").assertIsDisplayed()
    }

    @Test fun `Organize is one tap away and supporting actions live in the overflow menu`() {
        screen("- a")
        compose.onNodeWithText("Share").assertDoesNotExist()
        compose.onNodeWithContentDescription("Organize").assertIsDisplayed().assertIsEnabled()
        compose.onNodeWithContentDescription("More options").performClick()
        compose.onNodeWithText("Organize").assertIsDisplayed()
        compose.onNodeWithText("Share").assertIsDisplayed()
        compose.onNodeWithText("Export Markdown").assertIsDisplayed()
        compose.onNodeWithText("Notes settings").assertIsDisplayed()
        compose.onNodeWithText("Delete").assertIsDisplayed().assertIsEnabled()
    }

    @Test fun `toolbar Organize runs the model and is disabled on an empty note`() {
        val rig = screen("")
        compose.onNodeWithContentDescription("Organize").assertIsDisplayed().assertIsNotEnabled()
        compose.runOnIdle { rig.model.edit(TextFieldValue("A synthetic planning note. ".repeat(60))) }
        compose.onNodeWithContentDescription("Organize").assertIsEnabled().performClick()
        compose.runOnIdle { rig.idle(); assertEquals(1, rig.api.reorganizations.size) }
    }

    @Test fun `the transcript is a second view on the cover screen`() {
        val rig = screen("")
        compose.runOnIdle { rig.record().final("synthetic words"); rig.idle() }
        compose.onNodeWithText("Transcript").performClick()
        compose.onAllNodesWithText("synthetic words").onLast().assertIsDisplayed()
        compose.onNodeWithText("0:00", substring = true).assertIsDisplayed()
        // Older notes never saved their model; the engine line waits until one is known, as on iOS.
        compose.onNodeWithText("Transcribed with unknown").assertDoesNotExist()
    }

    @Test fun `the meta line under the title gives the date and open to-dos, as on iOS`() {
        screen("- [ ] Draft the invitation\n- [ ] Check pricing")
        compose.onNodeWithTag("notes-meta").assertTextContains("☐ 2 open", substring = true)
        compose.onNodeWithText("Tap Record to take notes").assertDoesNotExist()
    }
}
