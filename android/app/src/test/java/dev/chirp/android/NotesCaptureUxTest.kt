package dev.chirp.android

import android.graphics.Bitmap
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import java.io.File
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RuntimeEnvironment
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37], qualifiers = "w360dp-h740dp-mdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class NotesCaptureUxTest {
    @get:Rule val compose = createComposeRule()

    @org.junit.Before fun noMotion() {
        android.provider.Settings.Global.putFloat(RuntimeEnvironment.getApplication().contentResolver, android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 0f)
    }

    @Test fun `speaker capsules retain separate 48dp touch targets and named actions`() {
        var selected = ""
        compose.setContent { ChirpTheme {
            Column {
                SpeakerChip("Sam", 0, { selected = "Sam" })
                SpeakerChip("Jo", 1, { selected = "Jo" })
            }
        } }
        val sam = compose.onNodeWithContentDescription("Sam. Rename, merge or reassign this speaker")
        val jo = compose.onNodeWithContentDescription("Jo. Rename, merge or reassign this speaker")
        val first = sam.fetchSemanticsNode().boundsInRoot
        val second = jo.fetchSemanticsNode().boundsInRoot
        assertTrue(first.width >= 48f && first.height >= 48f)
        assertTrue(second.width >= 48f && second.height >= 48f)
        assertTrue("targets do not overlap", first.bottom <= second.top)
        sam.performClick(); assertEquals("Sam", selected)
        jo.performClick(); assertEquals("Jo", selected)
    }

    @Test fun `connection recovery and speaker preparation coexist and the connection action works`() {
        RuntimeEnvironment.setFontScale(2f)
        val app = RuntimeEnvironment.getApplication()
        val keys = SoftwareHistoryKeys()
        val document = NotesDocument().apply { name = "Recovered conversation"; userEdit(0, 0, "Synthetic recovery fixture") }
        NotesJournal(app, keys, io = { it() }).update({ document.toJson().put("elapsed", 45.0) }, now = true)
        val rig = NotesModelRig(app, notesMac.copy(notesSpeakers = true, speakersModel = "downloading"), keys = keys)
        rig.idle()
        assertNotNull(rig.model.recovered)
        rig.model.message = "Tailscale is off"
        var action: DictationAction? = null
        val dark = mutableStateOf(false)
        compose.setContent { ChirpTheme(dark.value) {
            NotesStatusStack(rig.model, { action = it }, Modifier.fillMaxWidth().padding(16.dp))
        } }
        compose.onNodeWithText("Tailscale is off").assertIsDisplayed()
        compose.onNodeWithText("Recovered note").assertIsDisplayed()
        compose.onNodeWithText("Getting the speaker model ready…").assertIsDisplayed()
        compose.onNodeWithText("Who was speaking?").assertDoesNotExist()
        compose.onNodeWithText("Turn on").performClick()
        assertEquals(DictationAction.TAILSCALE_ON, action)
        for (night in listOf(false, true)) {
            compose.runOnIdle { dark.value = night }
            compose.mainClock.advanceTimeBy(2000); compose.waitForIdle()
            val bitmap = notesScreenshot(compose.onRoot())
            File(System.getProperty("chirp.screenshots"), "notes-status-stack-font-200-${if (night) "dark" else "light"}.png")
                .outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
    }

    @Test fun `recording dock focus includes title state and elapsed without a live timer`() {
        val rig = NotesModelRig(RuntimeEnvironment.getApplication())
        compose.setContent { ChirpTheme { NotesScreen(rig.model, rig.model::toggle, {}, {}, {}, {}) } }
        compose.runOnIdle { rig.record().final("Synthetic conversation"); rig.model.rename("Garden plans"); rig.idle() }
        val info = compose.onNode(hasStateDescription("Recording"))
        val node = info.fetchSemanticsNode()
        val spoken = node.config[SemanticsProperties.ContentDescription].joinToString()
        assertTrue(spoken, "Garden plans" in spoken && rig.model.elapsedText in spoken)
        assertFalse(SemanticsProperties.LiveRegion in node.config)
        assertTrue(node.children.isEmpty())
        compose.onNodeWithContentDescription("Pause recording notes").performClick()
        compose.onNode(hasStateDescription("Paused")).assertExists()
        compose.onNodeWithContentDescription("Resume recording notes").performClick()
        assertTrue(rig.model.recording)
        compose.onNodeWithContentDescription("Stop recording notes").performClick()
        assertEquals(NotesRecorder.State.STOPPING, rig.model.state)
    }
}
