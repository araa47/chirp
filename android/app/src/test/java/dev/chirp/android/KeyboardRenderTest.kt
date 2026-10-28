package dev.chirp.android

import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Looper
import android.view.ContextThemeWrapper
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodInfo
import android.view.inputmethod.InputMethodManager
import android.view.inputmethod.InputMethodSubtype
import helium314.keyboard.keyboard.KeyboardSwitcher
import helium314.keyboard.latin.RichInputMethodManager
import helium314.keyboard.latin.common.ColorType
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
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import org.robolectric.shadows.ShadowInputMethodManager
import java.io.File

@Implements(InputMethodManager::class)
class KeyboardInputMethods : ShadowInputMethodManager() {
    @Implementation override fun getInputMethodList() = listOf(InputMethodInfo("dev.chirp.android", "dev.chirp.android.ChirpImeService", "Chirp Keyboard", null))
    @Implementation override fun getCurrentInputMethodSubtype(): InputMethodSubtype = InputMethodSubtype.InputMethodSubtypeBuilder().setSubtypeLocale("en_US").setSubtypeMode("keyboard").build()
    @Implementation fun getShortcutInputMethodsAndSubtypes() = emptyMap<InputMethodInfo, List<InputMethodSubtype>>()
}

@RunWith(RobolectricTestRunner::class)
@Config(application = ChirpApplication::class, sdk = [37], qualifiers = "w411dp-h891dp-mdpi", shadows = [KeyboardInputMethods::class])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class KeyboardRenderTest {
    class RenderIme : ChirpImeService() {
        override fun createLearning() = EditLearning(this, io = { it() })
        val editor = ChirpImeServiceTest.Editor()
        val info = EditorInfo().apply { inputType = android.text.InputType.TYPE_CLASS_TEXT; initialSelStart = 0; initialSelEnd = 0 }
        override fun getCurrentInputConnection() = editor.connection
        override fun getCurrentInputEditorInfo() = info
        override fun isInputViewShown() = true
    }
    private class Fixture(val name: String, val message: String, val kind: StripKind, val show: (KeyboardStrip) -> Unit)
    private val fixtures = listOf(
        Fixture("idle", "Tap mic · hold to talk", StripKind.IDLE) { it.show(statusOf("Tap mic · hold to talk"), "", false, false, false, false) },
        Fixture("connecting", "Connecting to your computer…", StripKind.CONNECTING) { it.show(statusOf("Connecting to your computer…"), "", true, false, false, false) },
        Fixture("listening", "Listening…", StripKind.LISTENING) { it.show(statusOf("Listening…"), "Synthetic example for visual review", true, false, false, false); it.level(.45) },
        Fixture("countdown", "Listening… · 15 s left", StripKind.LISTENING) { it.show(StatusLine.LISTENING, "", true, false, false, false, countdown = true, decorate = { line -> "$line · 15 s left" }); it.level(.45) },
        Fixture("polishing", "Polishing…", StripKind.POLISHING) { it.show(statusOf("Polishing…"), "", true, true, false, false, polishing = true, style = "Email") },
        Fixture("final", "Inserted", StripKind.SUCCESS) { it.show(statusOf("Inserted · tap mic to dictate again"), "", false, false, true, false, notice = true, undoable = true) },
        Fixture("tailscale", "Tailscale is off", StripKind.ERROR) { it.show(StatusLine.TAILSCALE_OFF, "", false, false, false, false) },
        Fixture("offline", "Computer offline · Check again", StripKind.ERROR) { it.show(StatusLine.OFFLINE, "", false, false, false, false, offline = true) },
        Fixture("phone", "Listening…", StripKind.LISTENING) { it.show(statusOf("Listening…"), "", true, false, false, false, phone = "Phone speech recogniser"); it.level(.3) },
        Fixture("retention", "Debug retention on · Listening…", StripKind.LISTENING) { it.show(statusOf("Listening…"), "", true, false, false, true); it.level(.3) },
    )
    @Test fun `render every strip state in both themes, looks and cover and inner widths at an unchanged height`() {
        val app = RuntimeEnvironment.getApplication()
        Settings.init(app); SubtypeSettings.init(app); RichInputMethodManager.init(app)
        val output = File(System.getProperty("chirp.screenshots")).apply { mkdirs() }
        // Renders show each state settled, not mid-morph.
        android.provider.Settings.Global.putFloat(app.contentResolver, android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 0f)
        val service = Robolectric.buildService(RenderIme::class.java).create()
        val ime = service.get()
        try {
            for (look in listOf(KeyboardLook.GBOARD, KeyboardLook.SAMSUNG)) for ((size, qualifier, width) in listOf(Triple("cover", "w411dp-h891dp", 411), Triple("inner", "w673dp-h841dp", 673))) for (name in listOf("light", "dark")) {
                applyKeyboardLook(keyboardPrefs(app), look)
                RuntimeEnvironment.setQualifiers("$qualifier-" + (if (name == "dark") "night" else "notnight") + "-mdpi")
                ime.onConfigurationChanged(Configuration(app.resources.configuration))
                val keys = ime.onCreateInputView()
                ime.setInputView(keys)
                ime.onStartInput(ime.info, false); ime.onStartInputView(ime.info, false)
                KeyboardSwitcher.getInstance().reloadMainKeyboard()
                val root = keys.findViewById<ViewGroup>(helium314.keyboard.latin.R.id.main_keyboard_frame)
                val strip = keys.findViewWithTag<KeyboardStrip>("chirp_strip")
                // InputView applies this on its first window layout, which a detached render never gets.
                Settings.getValues().mColors.setBackground(root, ColorType.MAIN_BACKGROUND)
                val colors = StripColors.of(app)
                var idleHeight = 0
                for (state in fixtures) {
                    PrivateSession.set(state.name == "final")
                    strip.privateChip.visibility = if (state.name == "final") View.VISIBLE else View.GONE
                    state.show(strip)
                    if (state.name == "final") strip.show(statusOf("cleaned"), "", false, false, true, false, notice = true, undoable = true,
                        actionUntil = android.os.SystemClock.elapsedRealtime() + 4000)
                    assertEquals("${state.name} ${look.name} $size $name", state.kind, strip.stripKind)
                    root.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(900, View.MeasureSpec.AT_MOST))
                    root.layout(0, 0, width, root.measuredHeight)
                    assertTrue(root.measuredHeight > strip.measuredHeight)
                    if (state.name == "idle") idleHeight = root.measuredHeight
                    else assertEquals("Dictation must reuse the suggestion row height (${state.name})", idleHeight, root.measuredHeight)
                    assertFalse("Partial belongs only in the editor", strip.status.text.contains("Synthetic example"))
                    if (state.name == "countdown") assertEquals("Listening… · 15 s left", strip.status.text.toString())
                    if (state.name == "final") assertEquals("Polished", strip.status.text.toString())
                    assertNotNull(KeyboardSwitcher.getInstance().keyboard?.getKey('a'.code))
                    colors.tints.of(state.kind)?.let { tint ->
                        assertTrue("${state.name} text on tint", androidx.core.graphics.ColorUtils.calculateContrast(tint.text, tint.fill) >= StripTints.TEXT)
                        assertEquals("the row paints its tint", tint.fill, strip.tintColor)
                    }
                    val default = look == KeyboardLook.GBOARD && size == "cover"
                    val file = if (default) "keyboard-${state.name}-$name.png" else "keyboard-${look.name.lowercase()}-$size-${state.name}-$name.png"
                    val bitmap = Bitmap.createBitmap(width, root.measuredHeight, Bitmap.Config.ARGB_8888)
                    root.draw(Canvas(bitmap))
                    File(output, file).outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
                    bitmap.recycle()
                }
            }
        } finally { PrivateSession.set(false); applyKeyboardLook(keyboardPrefs(app), KeyboardLook.DEFAULT); service.destroy() }
    }
    @Test fun `render Chirp keyboard looks with the Chirp row in both themes`() {
        val app = RuntimeEnvironment.getApplication()
        Settings.init(app); SubtypeSettings.init(app); RichInputMethodManager.init(app)
        val output = File(System.getProperty("chirp.screenshots")).apply { mkdirs() }
        val service = Robolectric.buildService(RenderIme::class.java).create()
        val ime = service.get()
        try {
            for (look in listOf(KeyboardLook.GBOARD, KeyboardLook.SAMSUNG)) {
                applyKeyboardLook(keyboardPrefs(app), look)
                for (name in listOf("light", "dark")) {
                    RuntimeEnvironment.setQualifiers("w411dp-h891dp-" + (if (name == "dark") "night" else "notnight") + "-mdpi")
                    ime.onConfigurationChanged(Configuration(app.resources.configuration))
                    val keys = ime.onCreateInputView()
                    ime.setInputView(keys)
                    ime.onStartInput(ime.info, false); ime.onStartInputView(ime.info, false)
                    KeyboardSwitcher.getInstance().reloadMainKeyboard()
                    val root = keys.findViewById<ViewGroup>(helium314.keyboard.latin.R.id.main_keyboard_frame)
                    val strip = keys.findViewWithTag<KeyboardStrip>("chirp_strip")
                    assertTrue(Settings.getValues().mColors.hasKeyBorders)
                    Settings.getValues().mColors.setBackground(root, ColorType.MAIN_BACKGROUND)
                    for (state in listOf("idle", "listening")) {
                        strip.show(if (state == "listening") StatusLine.LISTENING else StatusLine.IDLE, "", state == "listening", false, false, false)
                        strip.level(if (state == "listening") .45 else 0.0)
                        root.measure(View.MeasureSpec.makeMeasureSpec(411, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(900, View.MeasureSpec.AT_MOST))
                        root.layout(0, 0, 411, root.measuredHeight)
                        val bitmap = Bitmap.createBitmap(411, root.measuredHeight, Bitmap.Config.ARGB_8888)
                        root.draw(Canvas(bitmap))
                        File(output, "keyboard-look-${look.name.lowercase()}-$state-$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
                        bitmap.recycle()
                    }
                }
            }
        } finally { PrivateSession.set(false); applyKeyboardLook(keyboardPrefs(app), KeyboardLook.DEFAULT); service.destroy() }
    }

    @Test fun `parent input view delivers real mic touches to Chirp instead of suggestion padding`() {        val app = RuntimeEnvironment.getApplication()
        shadowOf(app).grantPermissions(android.Manifest.permission.RECORD_AUDIO)
        val service = Robolectric.buildService(RenderIme::class.java).create()
        val ime = service.get()
        val window = Robolectric.buildActivity(android.app.Activity::class.java).setup()
        try {
            val keys = ime.onCreateInputView() as ViewGroup
            ime.setInputView(keys)
            ime.onStartInput(ime.info, false); ime.onStartInputView(ime.info, false)
            // A real window is required for View.isShown/global hit rectangles and IME insets.
            (keys.parent as? ViewGroup)?.removeView(keys)
            window.get().setContentView(keys)
            keys.measure(View.MeasureSpec.makeMeasureSpec(411, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(900, View.MeasureSpec.EXACTLY))
            keys.layout(0, 0, 411, 900)
            val strip = keys.findViewWithTag<KeyboardStrip>("chirp_strip")
            val bounds = android.graphics.Rect(0, 0, strip.mic.width, strip.mic.height)
            keys.offsetDescendantRectToMyCoords(strip.mic, bounds)
            assertTrue(bounds.height() > 0)
            val insets = android.inputmethodservice.InputMethodService.Insets()
            ime.onComputeInsets(insets)
            assertTrue("Android must route mic touches to the IME window", insets.touchableRegion.contains(bounds.centerX(), bounds.centerY()))
            assertTrue("Editor resize includes the Chirp strip", insets.contentTopInsets <= bounds.top)
            for ((action, time) in listOf(android.view.MotionEvent.ACTION_DOWN to 10L, android.view.MotionEvent.ACTION_UP to 50L)) {
                val touch = android.view.MotionEvent.obtain(10L, time, action, bounds.exactCenterX(), bounds.exactCenterY(), 0)
                keys.dispatchTouchEvent(touch); touch.recycle()
            }
            shadowOf(Looper.getMainLooper()).idle()
            assertEquals("Pair computer", strip.status.text.toString())
        } finally { window.pause().stop().destroy(); service.destroy() }
    }

    @Test fun `landscape split preference reaches actual keyboard layout`() {
        RuntimeEnvironment.setQualifiers("w800dp-h600dp-land-mdpi")
        val app = RuntimeEnvironment.getApplication()
        helium314.keyboard.latin.utils.DeviceProtectedUtils.getSharedPreferences(app).edit()
            .putBoolean(Settings.PREF_ENABLE_SPLIT_KEYBOARD_LANDSCAPE, true).commit()
        val controller = Robolectric.buildService(RenderIme::class.java).create()
        val ime = controller.get()
        try {
            val keys = ime.onCreateInputView()
            ime.setInputView(keys)
            ime.onStartInput(ime.info, false); ime.onStartInputView(ime.info, false)
            KeyboardSwitcher.getInstance().reloadMainKeyboard()
            assertTrue("Split must affect the built keyboard and its cache key", KeyboardSwitcher.getInstance().keyboard!!.mId.isSplitLayout)
        } finally { controller.destroy() }
    }

}
