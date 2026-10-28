package dev.chirp.android

import android.graphics.Bitmap
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.Density
import java.io.File
import org.junit.After
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37], qualifiers = "w411dp-h891dp-mdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class NotesRetranscribeRenderTest {
    @get:Rule val compose = createComposeRule()
    @After fun reset() { RuntimeEnvironment.setFontScale(1f); RetranscribeGate.progress = null; RetranscribeGate.owner = null }

    @Test fun `consent progress completion and old server in light dark and large text`() {
        val rig = NotesModelRig(RuntimeEnvironment.getApplication(), notesMac.copy(notesRetranscribe = true, speechModel = "Parakeet v3"), server = "computer.example.test")
        val model = rig.model
        model.rename("Weekly sync")
        model.document.append(NotesSegment(0, 0.0, "A synthetic meeting example", engine = "Parakeet v2"))
        model.document.addClip(NotesAudioClip(0, 0.0, 32.0, 16000, 128000))
        val dark = mutableStateOf(false); val font = mutableStateOf(1f)
        compose.setContent { CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density, font.value)) {
            ChirpTheme(dark.value) { Surface { NotesScreen(model, model::toggle, {}, {}, {}, {}) } }
        } }
        fun shot(name: String, text: String? = null) {
            compose.mainClock.advanceTimeBy(2000); compose.waitForIdle()
            val root = if (text == null) compose.onRoot() else compose.onNode(isRoot() and hasAnyDescendant(hasText(text)))
            val bitmap = notesScreenshot(root)
            File(File(System.getProperty("chirp.screenshots")).apply { mkdirs() }, "notes-retranscribe-$name-${if (dark.value) "dark" else "light"}.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
        for (night in listOf(false, true)) {
            compose.runOnIdle { dark.value = night; model.askRetranscribe() }
            compose.onNodeWithText("Re-transcribe “Weekly sync”?").assertIsDisplayed()
            compose.onNodeWithText("Re-transcribe", substring = false).assertIsDisplayed()
            shot("consent", "Re-transcribe “Weekly sync”?")
            compose.runOnIdle { font.value = 1f; model.retranscribeSheet = false; RetranscribeGate.progress = RetranscribeProgress(model.document.uid, 12, 40, 92.0, 490.0) }
            compose.onNodeWithText("Re-transcribing · 12 of 40 · 1:32 of 8:10").assertIsDisplayed()
            shot("progress")
            compose.runOnIdle { RetranscribeGate.progress = null; model.document.applyRetranscription(mapOf(0 to RetranscribedSegment(model.document.audio.single(), ServerEvent.Final("Updated synthetic words", "Updated synthetic words", false), "new"))); model.retranscribeNotice = RetranscribeNotice.Updated }
            compose.onNodeWithText("Undo").assertIsDisplayed(); shot("updated")
            compose.runOnIdle { model.retranscribeNotice = null }
        }
    }

    @Test fun `the banner offers Undo by the kind of notice, not by its words`() {
        val rig = NotesModelRig(RuntimeEnvironment.getApplication())
        val model = rig.model
        model.document.append(NotesSegment(0, 0.0, "A synthetic meeting example", engine = "Parakeet v2"))
        model.document.addClip(NotesAudioClip(0, 0.0, 32.0, 16000, 128000))
        model.document.applyRetranscription(mapOf(0 to RetranscribedSegment(model.document.audio.single(), ServerEvent.Final("Updated synthetic words", "Updated synthetic words", false), "new")))
        compose.setContent { ChirpTheme(false) { RetranscribeBanner(model) } }
        for (notice in listOf(RetranscribeNotice.Updated, RetranscribeNotice.Partial(1, 2), RetranscribeNotice.RebuildFailed)) {
            compose.runOnIdle { model.retranscribeNotice = notice }
            compose.onNodeWithText(notice.ui.notesEnglish()).assertIsDisplayed()
            compose.onNodeWithText("Undo").assertIsDisplayed()
        }
        // "No segments updated" says updated, but nothing was: no Undo for the transcript an earlier run replaced.
        for (notice in listOf(RetranscribeNotice.NoneUpdated, RetranscribeNotice.Restored, RetranscribeNotice.Cancelled, RetranscribeNotice.Interrupted)) {
            compose.runOnIdle { model.retranscribeNotice = notice }
            compose.onNodeWithText(notice.ui.notesEnglish()).assertIsDisplayed()
            compose.onNodeWithText("Undo").assertDoesNotExist()
        }
        // "Notes rebuilt" offers Undo only while the rebuild can be undone.
        compose.runOnIdle { model.retranscribeNotice = RetranscribeNotice.Rebuilt }
        compose.onNodeWithText("Notes rebuilt").assertIsDisplayed()
        compose.onNodeWithText("Undo").assertDoesNotExist()
        compose.runOnIdle { model.retranscribeNotice = null; model.retranscribeFailure = RetranscribeFailure.TRANSCRIPT_CHANGED }
        compose.onNodeWithText("This transcript changed. Re-transcribe again.").assertIsDisplayed()
    }

    @Test fun `sheet scrolls at real 200 percent font without horizontal overflow`() {
        RuntimeEnvironment.setFontScale(2f)
        val rig = NotesModelRig(RuntimeEnvironment.getApplication(), notesMac.copy(notesRetranscribe = true, speechModel = "Parakeet v3"), server = "computer.example.test")
        rig.model.rename("Weekly sync")
        rig.model.document.addClip(NotesAudioClip(0, 0.0, 32.0, 16000, 128000))
        rig.model.askRetranscribe()
        val dark = mutableStateOf(false)
        compose.setContent { ChirpTheme(dark.value) { RetranscribeSheet(rig.model) } }
        for (night in listOf(false, true)) {
            compose.runOnIdle { dark.value = night }
            compose.mainClock.advanceTimeBy(2000); compose.waitForIdle()
            val target = compose.onNode(isRoot() and hasAnyDescendant(hasText("Re-transcribe “Weekly sync”?")))
            val bitmap = notesScreenshot(target)
            File(File(System.getProperty("chirp.screenshots")).apply { mkdirs() }, "notes-retranscribe-font-200-${if (night) "dark" else "light"}.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
        val button = compose.onNodeWithText("Re-transcribe", substring = false)
        button.performScrollTo().assertIsDisplayed()
        val bounds = button.fetchSemanticsNode().boundsInRoot
        val root = compose.onNode(isRoot() and hasAnyDescendant(hasText("Re-transcribe", substring = false))).fetchSemanticsNode().boundsInRoot
        org.junit.Assert.assertTrue(bounds.left >= root.left && bounds.right <= root.right)
    }

    @Test fun `debug retention and external cleanup are disclosed every time`() {
        val rig = NotesModelRig(RuntimeEnvironment.getApplication(), notesMac.copy(notesRetranscribe = true, debugRetention = true,
            correctionLeavesMachine = true, correctionHost = "cleanup.example.test"), server = "computer.example.test")
        SettingsStore(RuntimeEnvironment.getApplication()).correction = true
        rig.model.rename("Weekly sync")
        rig.model.document.addClip(NotesAudioClip(0, 0.0, 32.0, 16000, 128000))
        rig.model.askRetranscribe()
        val dark = mutableStateOf(false)
        compose.setContent { ChirpTheme(dark.value) { RetranscribeSheet(rig.model) } }
        for (night in listOf(false, true)) {
            compose.runOnIdle { dark.value = night }; compose.mainClock.advanceTimeBy(2000); compose.waitForIdle()
            compose.onNodeWithText("Re-transcribe anyway").performScrollTo().assertIsDisplayed()
            compose.onNodeWithText("Your server is keeping debug recordings. This audio will be saved there for up to 3 days.").assertExists()
            compose.onNodeWithText("Clean-up sends text to cleanup.example.test. Audio stays on your computer.").assertExists()
            val bitmap = notesScreenshot(compose.onNode(isRoot() and hasAnyDescendant(hasText("Re-transcribe anyway"))))
            File(File(System.getProperty("chirp.screenshots")).apply { mkdirs() }, "notes-retranscribe-warning-${if (night) "dark" else "light"}.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
    }

    @Test fun `older server has no send button`() {
        val rig = NotesModelRig(RuntimeEnvironment.getApplication())
        rig.model.document.addClip(NotesAudioClip(0, 0.0, 32.0, 16000, 128000))
        rig.model.askRetranscribe()
        compose.setContent { ChirpTheme(false) { RetranscribeSheet(rig.model) } }
        compose.onNodeWithText("Update Chirp on your computer to re-transcribe").assertIsDisplayed()
        compose.onNodeWithText("Re-transcribe", substring = false).assertDoesNotExist()
    }
}
