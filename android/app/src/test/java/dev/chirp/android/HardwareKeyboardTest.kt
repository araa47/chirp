package dev.chirp.android

import android.Manifest
import android.content.res.Configuration
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import helium314.keyboard.latin.settings.Settings
import helium314.keyboard.latin.RichInputMethodManager
import helium314.keyboard.latin.utils.SubtypeSettings
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** The real IME service: key events reach dictation, and the larger mic grows the row on the inner screen. */
@RunWith(RobolectricTestRunner::class)
@Config(application = ChirpApplication::class, sdk = [37], qualifiers = "w800dp-h1200dp-mdpi", shadows = [KeyboardInputMethods::class])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class HardwareKeyboardTest {
    private val chord = KeyEvent.META_CTRL_ON or KeyEvent.META_ALT_ON
    private fun down(code: Int, meta: Int = 0) = KeyEvent(0, 0, KeyEvent.ACTION_DOWN, code, 0, meta)
    private fun up(code: Int, meta: Int = 0) = KeyEvent(0, 0, KeyEvent.ACTION_UP, code, 0, meta)
    private fun <T> withIme(block: (KeyboardRenderTest.RenderIme, View, KeyboardStrip) -> T): T {
        val app = RuntimeEnvironment.getApplication()
        Settings.init(app); SubtypeSettings.init(app); RichInputMethodManager.init(app)
        shadowOf(app).grantPermissions(Manifest.permission.RECORD_AUDIO)
        val service = Robolectric.buildService(KeyboardRenderTest.RenderIme::class.java).create()
        val ime = service.get()
        try {
            val keys = ime.onCreateInputView()
            ime.setInputView(keys)
            ime.onStartInput(ime.info, false); ime.onStartInputView(ime.info, false)
            return block(ime, keys, keys.findViewWithTag("chirp_strip"))
        } finally { service.destroy() }
    }

    @Test fun `Ctrl Alt Space and its key up are consumed`() = withIme { ime, _, strip ->
        // No pairing in this environment, so the chord reaches dictation and asks to pair.
        assertTrue(ime.onKeyDown(KeyEvent.KEYCODE_SPACE, down(KeyEvent.KEYCODE_SPACE, chord)))
        assertEquals(english.getString(DictationAction.PAIR.label), strip.status.text.toString())
        assertTrue(ime.onKeyUp(KeyEvent.KEYCODE_SPACE, up(KeyEvent.KEYCODE_SPACE, chord)))
    }
    @Test fun `disabled setting leaves the chord to HeliBoard`() = withIme { ime, _, strip ->
        SettingsStore(RuntimeEnvironment.getApplication()).hardwareShortcut = false
        ime.onKeyDown(KeyEvent.KEYCODE_SPACE, down(KeyEvent.KEYCODE_SPACE, chord))
        assertNotEquals(english.getString(DictationAction.PAIR.label), strip.status.text.toString())
    }
    @Test fun `password field ignores the chord and Esc is not consumed while idle`() = withIme { ime, _, strip ->
        ime.info.inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD
        ime.onKeyDown(KeyEvent.KEYCODE_SPACE, down(KeyEvent.KEYCODE_SPACE, chord))
        assertNotEquals(english.getString(DictationAction.PAIR.label), strip.status.text.toString())
        assertNotEquals("Dictation unavailable in password fields", strip.status.text.toString())
        ime.info.inputType = android.text.InputType.TYPE_CLASS_TEXT
        assertFalse(ime.onKeyDown(KeyEvent.KEYCODE_ESCAPE, down(KeyEvent.KEYCODE_ESCAPE)) && ime.onKeyUp(KeyEvent.KEYCODE_ESCAPE, up(KeyEvent.KEYCODE_ESCAPE)))
    }
    @Test fun `larger mic is off by default and grows the inner screen row to 48 dp when on`() {
        val app = RuntimeEnvironment.getApplication()
        withIme { _, keys, strip ->
            assertEquals(app.dp(48), strip.mic.layoutParams.width)
            assertTrue((strip.parent.parent as View).layoutParams.height < app.dp(48) + 1)
        }
        SettingsStore(app).largerMic = true
        withIme { _, _, strip ->
            assertEquals(app.dp(56), strip.mic.layoutParams.width)
            assertTrue((strip.parent.parent as View).layoutParams.height >= app.dp(48))
            assertEquals(ViewGroup.LayoutParams.MATCH_PARENT, strip.mic.layoutParams.height)
        }
    }
}
