package dev.chirp.android

import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Looper
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import helium314.keyboard.keyboard.KeyboardSwitcher
import helium314.keyboard.latin.RichInputMethodManager
import helium314.keyboard.latin.settings.Settings
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
import java.io.File

@RunWith(RobolectricTestRunner::class)
@Config(application = ChirpApplication::class, sdk = [37], qualifiers = "w411dp-h891dp-mdpi", shadows = [KeyboardInputMethods::class])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class HistoryRenderTest {
    class HistoryIme : ChirpImeService() {
        val editor = ChirpImeServiceTest.Editor()
        val info = EditorInfo().apply { inputType = android.text.InputType.TYPE_CLASS_TEXT; initialSelStart = 0; initialSelEnd = 0 }
        val now = 1_800_000_000_000L
        internal val store by lazy { DictationHistory(this, SoftwareHistoryKeys()) { now } }
        override fun getCurrentInputConnection() = editor.connection
        override fun getCurrentInputEditorInfo() = info
        override fun isInputViewShown() = true
        override fun createHistory(insert: (String) -> Boolean) = KeyboardHistory(this, insert, store, io = { it() }, clock = { now })
    }

    @Test fun `history panel replaces the keys at the same height in both themes and back returns to keys`() {
        val app = RuntimeEnvironment.getApplication()
        Settings.init(app); SubtypeSettings.init(app); RichInputMethodManager.init(app)
        val output = File(System.getProperty("chirp.screenshots")).apply { mkdirs() }
        val service = Robolectric.buildService(HistoryIme::class.java).create()
        val ime = service.get()
        try {
            for (name in listOf("light", "dark")) {
                RuntimeEnvironment.setQualifiers("w411dp-h891dp-" + (if (name == "dark") "night" else "notnight") + "-mdpi")
                ime.onConfigurationChanged(Configuration(app.resources.configuration))
                val keys = ime.onCreateInputView()
                ime.setInputView(keys)
                ime.onStartInput(ime.info, false); ime.onStartInputView(ime.info, false)
                KeyboardSwitcher.getInstance().reloadMainKeyboard()
                val root = keys.findViewById<ViewGroup>(helium314.keyboard.latin.R.id.main_keyboard_frame)
                val strip = keys.findViewWithTag<KeyboardStrip>("chirp_strip")
                fun render(file: String?): Int {
                    shadowOf(Looper.getMainLooper()).idle()
                    root.measure(View.MeasureSpec.makeMeasureSpec(411, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(900, View.MeasureSpec.AT_MOST))
                    root.layout(0, 0, 411, root.measuredHeight)
                    val bitmap = Bitmap.createBitmap(411, root.measuredHeight, Bitmap.Config.ARGB_8888)
                    root.draw(Canvas(bitmap))
                    if (file != null) File(output, "$file-$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
                    bitmap.recycle()
                    return root.measuredHeight
                }
                ime.store.disable(deleteHistory = true)
                val keyboardHeight = render(null) // keyboard-idle-*.png already shows the closed strip.
                assertEquals(View.VISIBLE, strip.history.visibility)
                strip.history.performClick()
                assertEquals("Opt-in keeps the keyboard height", keyboardHeight, render("keyboard-history-optin"))
                ime.store.enable()
                ime.store.record("Running ten minutes late, start without me.", null, "Messages", ime.info)
                ime.store.record("Can we move the design review to Thursday afternoon? The draft needs another pass.",
                    "can we move the uh design review to thursday afternoon the draft needs another pass", "Gmail", ime.info)
                ime.store.record("Pick up oat milk, lemons and coffee beans", null, "Keep Notes", ime.info)
                strip.history.performClick(); strip.history.performClick()
                assertEquals("History keeps the keyboard height", keyboardHeight, render("keyboard-history"))
                ime.store.disable()
                strip.history.performClick(); strip.history.performClick()
                assertEquals("Retained history keeps the keyboard height", keyboardHeight, render("keyboard-history-retained"))
                val panel = keys.findViewWithTag<HistoryPanel>(KeyboardHistory.TAG)
                assertEquals(View.VISIBLE, panel.visibility)
                assertEquals(root.findViewById<View>(helium314.keyboard.latin.R.id.keyboard_view_wrapper).height, panel.height)
                assertTrue(ime.onKeyDown(KeyEvent.KEYCODE_BACK, KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_BACK)))
                assertTrue(ime.onKeyUp(KeyEvent.KEYCODE_BACK, KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_BACK)))
                assertEquals(View.GONE, panel.visibility)
                ime.store.disable(deleteHistory = true)
            }
        } finally { service.destroy() }
    }
}
