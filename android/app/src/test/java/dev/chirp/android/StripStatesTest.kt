package dev.chirp.android

import android.graphics.Color
import android.view.ContextThemeWrapper
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.core.graphics.ColorUtils
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37])
class StripStatesTest {
    private val app get() = RuntimeEnvironment.getApplication()
    private fun strip(clock: () -> Long = { 0L }) = KeyboardStrip(ContextThemeWrapper(app, R.style.Theme_Chirp), clock)
    private fun noMotion() = android.provider.Settings.Global.putFloat(app.contentResolver, android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 0f)
    private fun descendants(root: View): List<View> = listOf(root) + if (root is ViewGroup) (0 until root.childCount).flatMap { descendants(root.getChildAt(it)) } else emptyList()

    // Backgrounds, inks and accents of the shipped looks in light and dark, plus pale and saturated extremes.
    private val looks = listOf(
        "gboard light" to Triple(0xFFF6FAF6.toInt(), 0xFF182D25.toInt(), 0xFF386A58.toInt()), "gboard dark" to Triple(0xFF121715.toInt(), 0xFFE3EBE5.toInt(), 0xFF9FD3B9.toInt()),
        "samsung light" to Triple(0xFFF1F1F4.toInt(), 0xFF1B1B1F.toInt(), 0xFF2F7CF6.toInt()), "samsung dark" to Triple(0xFF111113.toInt(), 0xFFF0F0F3.toInt(), 0xFF3E91FF.toInt()),
        "heliboard light" to Triple(0xFFECEFF1.toInt(), 0xFF000000.toInt(), 0xFF80CBC4.toInt()), "heliboard dark" to Triple(0xFF263238.toInt(), 0xFFFFFFFF.toInt(), 0xFF80CBC4.toInt()),
        "holo" to Triple(0xFF282828.toInt(), 0xFFFFFFFF.toInt(), 0xFFFFFFFF.toInt()),
        "pale accent on light" to Triple(0xFFFFFFFF.toInt(), 0xFF202020.toInt(), 0xFFFFF59D.toInt()), "dark accent on dark" to Triple(0xFF000000.toInt(), 0xFFEEEEEE.toInt(), 0xFF1A237E.toInt()),
    )

    @Test fun `status text reads on every state tint and the stop icon on its fill for every look and theme`() {
        for ((name, parts) in looks) {
            val (background, ink, accent) = parts
            val colors = StripColors.derive(background, ink, ink, accent)
            for (kind in StripKind.entries) {
                val tint = colors.tints.of(kind) ?: continue
                assertTrue("$name $kind text", ColorUtils.calculateContrast(tint.text, tint.fill) >= StripTints.TEXT)
                assertTrue("$name $kind accent graphics", ColorUtils.calculateContrast(tint.accent, tint.fill) >= StripTints.GRAPHIC)
            }
            for (tint in listOf(colors.tints.warning, colors.tints.solidError)) assertTrue("$name text on ${tint.fill}", ColorUtils.calculateContrast(tint.text, tint.fill) >= StripTints.TEXT)
            assertTrue("$name stop icon on its fill", ColorUtils.calculateContrast(colors.onAccent, colors.accent) >= StripTints.GRAPHIC)
            assertTrue("$name waveform on the row", ColorUtils.calculateContrast(colors.highlight, background or Color.BLACK) >= 3.0)
        }
    }

    @Test fun `palette containers follow the app colours and keep text readable`() {
        val colors = VoicePalette.of(app)
        for ((fill, text) in listOf(colors.accentContainer to colors.onAccentContainer, colors.secondaryContainer to colors.onSecondaryContainer, colors.errorContainer to colors.onErrorContainer)) {
            assertNotEquals(Color.TRANSPARENT, fill)
            assertTrue(ColorUtils.calculateContrast(text, fill) >= 4.5)
        }
    }

    @Test fun `the row tints while listening and returns to transparent, with the same height contract`() {
        noMotion()
        val strip = strip()
        assertEquals(0, Color.alpha(strip.tintColor))
        strip.show(statusOf("Listening…"), "", true, false, false, false)
        assertEquals(StripKind.LISTENING, strip.stripKind); assertNotEquals(0, Color.alpha(strip.tintColor))
        strip.show(statusOf("Inserted · tap mic to dictate again"), "", false, false, true, false, notice = true, undoable = true)
        assertEquals(StripKind.SUCCESS, strip.stripKind); assertEquals("Finished", strip.status.text.toString())
        strip.show(statusOf("Tap mic · hold to talk"), "", false, false, false, false)
        assertEquals(StripKind.IDLE, strip.stripKind); assertEquals(0, Color.alpha(strip.tintColor))
        strip.show(statusOf("Tailscale is off"), "", false, false, false, false)
        assertEquals(StripKind.ERROR, strip.stripKind); assertEquals(View.VISIBLE, strip.action.visibility)
    }

    @Test fun `with animator scale zero no strip animator runs in any state`() {
        noMotion()
        val strip = strip()
        for (state in listOf("Connecting to your computer…" to false, "Listening…" to false, "Polishing…" to true)) {
            strip.show(statusOf(state.first), "", true, state.second, false, false, polishing = state.second, style = "Email")
            assertFalse("${state.first} animating", strip.animating)
        }
        strip.show(statusOf("Listening…"), "", true, false, false, false)
        assertEquals("shape is applied instantly", app.dp(12), strip.mic.cornerRadius)
    }

    @Test fun `with animations on the morph runs once and settles on the tint`() {
        val strip = strip()
        strip.show(statusOf("Listening…"), "", true, false, false, false)
        assertTrue(strip.animating)
        strip.show(statusOf("Listening…"), "", true, false, false, false) // a partial re-render must not restart it
        shadowOf(android.os.Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(400))
        assertEquals(strip.stripKind, StripKind.LISTENING)
        assertEquals(app.dp(12), strip.mic.cornerRadius)
        val tint = StripColors.of(app).tints.listening.fill
        assertEquals(tint, strip.tintColor)
    }

    @Test fun `elapsed timer counts while listening and shows the segment`() {
        noMotion()
        var now = 0L
        val strip = strip { now }
        assertEquals(View.GONE, strip.timer.visibility)
        strip.show(statusOf("Connecting to your computer…"), "", true, false, false, false)
        assertEquals("no timer while connecting", View.GONE, strip.timer.visibility)
        strip.show(statusOf("Listening…"), "", true, false, false, false)
        assertEquals(View.VISIBLE, strip.timer.visibility); assertEquals("0:00", strip.timer.text.toString())
        now = 12_400
        shadowOf(android.os.Looper.getMainLooper()).idleFor(java.time.Duration.ofSeconds(1))
        assertEquals("0:12", strip.timer.text.toString()); assertEquals("12 seconds", strip.timer.contentDescription.toString())
        strip.nextSegment(); assertEquals("0:12 · #2", strip.timer.text.toString()); assertTrue(strip.timer.contentDescription.endsWith("part 2"))
        assertEquals(View.IMPORTANT_FOR_ACCESSIBILITY_NO, strip.timer.importantForAccessibility)
        strip.show(statusOf("Tap mic · hold to talk"), "", false, false, false, false)
        assertEquals(View.GONE, strip.timer.visibility)
        now = 99_000; strip.show(statusOf("Listening…"), "", true, false, false, false); assertEquals("0:00", strip.timer.text.toString())
    }

    @Test fun `spoken times come from plural resources`() {
        val res = app.resources
        assertEquals("1 second", elapsedSpoken(res, 1_400))
        assertEquals("2 minutes", elapsedSpoken(res, 120_000))
        assertEquals("1 minute 5 seconds", elapsedSpoken(res, 65_000))
        assertEquals("2 minutes 1 second", elapsedSpoken(res, 121_000))
        assertEquals("5 min ago" to "5 minutes ago", historyAge(res, 300_000, 0))
        assertEquals("1 h ago" to "1 hour ago", historyAge(res, 3_600_000, 0))
        assertEquals("Yesterday" to "Yesterday", historyAge(res, 86_400_000, 0))
        assertEquals("3 days ago" to "3 days ago", historyAge(res, 3 * 86_400_000L, 0))
        assertEquals("1 day", HistoryRetention.DAY.label(res))
        assertEquals("7 days", HistoryRetention.WEEK.label(res))
    }

    @Test fun `after Stop the timer holds the time the mic was open`() {
        noMotion()
        var now = 0L
        val strip = strip { now }
        strip.show(statusOf("Listening…"), "", true, false, false, false)
        now = 5_300; shadowOf(android.os.Looper.getMainLooper()).idleFor(java.time.Duration.ofSeconds(1))
        strip.show(statusOf("Finishing…"), "", true, true, false, false)
        assertEquals("0:05", strip.timer.text.toString())
        now = 9_000; shadowOf(android.os.Looper.getMainLooper()).idleFor(java.time.Duration.ofSeconds(3))
        strip.show(statusOf("Finishing…"), "", true, true, false, false)
        assertEquals("finishing must not keep counting", "0:05", strip.timer.text.toString())
        strip.show(statusOf("Listening…"), "", true, false, false, false) // the next segment of a long dictation
        assertEquals("0:09", strip.timer.text.toString())
    }

    @Test fun `a strip rebuilt mid-dictation keeps the time and segment`() {
        noMotion()
        var now = 0L
        val before = strip { now }
        before.show(statusOf("Listening…"), "", true, false, false, false)
        before.nextSegment()
        now = 42_700
        // Rotation or a fold: HeliBoard replaces the input view and Chirp mounts a new strip.
        val after = strip { now }.apply { continueTimer(before) }
        after.show(statusOf("Listening…"), "", true, false, false, false)
        assertEquals("0:42 · #2", after.timer.text.toString())
        // The next tick lands on the second boundary (300 ms away), not a whole second after the rebuild.
        now = 43_000; shadowOf(android.os.Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(300))
        assertEquals("0:43 · #2", after.timer.text.toString())
    }

    @Test fun `the timer resumes ticking when the strip is attached again`() {
        noMotion()
        var now = 0L
        val activity = org.robolectric.Robolectric.buildActivity(android.app.Activity::class.java).setup().get()
        val strip = KeyboardStrip(ContextThemeWrapper(activity, R.style.Theme_Chirp)) { now }
        val host = android.widget.FrameLayout(activity).also(activity::setContentView)
        host.addView(strip)
        strip.show(statusOf("Listening…"), "", true, false, false, false)
        host.removeView(strip); host.addView(strip)
        now = 3_000; shadowOf(android.os.Looper.getMainLooper()).idleFor(java.time.Duration.ofSeconds(1))
        assertEquals("0:03", strip.timer.text.toString())
    }

    @Test fun `near the limit the timer is a warning chip but the one live region is unchanged`() {
        noMotion()
        val strip = strip()
        strip.show(StatusLine.LISTENING, "", true, false, false, false, countdown = true, decorate = { "$it · 15 s left" })
        assertNotNull(strip.timer.compoundDrawablesRelative[0])
        assertEquals(1, descendants(strip).count { it.accessibilityLiveRegion != View.ACCESSIBILITY_LIVE_REGION_NONE })
        strip.show(statusOf("Listening…"), "", true, false, false, false)
        assertEquals(0, descendants(strip).count { it.accessibilityLiveRegion != View.ACCESSIBILITY_LIVE_REGION_NONE })
        assertEquals("Listening…", strip.status.text.toString())
    }

    @Test fun `the final shows Undo then Use raw chips and no truncated hint`() {
        noMotion()
        val strip = strip()
        strip.show(statusOf("cleaned"), "", false, false, true, false, notice = true, undoable = true)
        assertEquals(View.VISIBLE, strip.raw.visibility); assertEquals(View.VISIBLE, strip.revert.visibility)
        assertTrue(strip.indexOfChild(strip.revert) < strip.indexOfChild(strip.raw))
        assertEquals("Polished", strip.status.text.toString())
        assertEquals(StripKind.SUCCESS, strip.stripKind)
    }

    @Test fun `debug retention uses the palette error colours not a fixed red`() {
        noMotion()
        val strip = strip()
        strip.show(statusOf("Listening…"), "", true, false, false, true)
        val fill = (strip.status.background as android.graphics.drawable.ColorDrawable).color
        val error = StripColors.of(app).tints.solidError
        assertEquals(error.fill, fill); assertEquals(error.text, strip.status.currentTextColor)
        assertTrue(ColorUtils.calculateContrast(error.text, error.fill) >= 4.5)
    }

    @Test fun `the history toggle shows a tonal fill with a readable icon when open`() {
        val strip = strip()
        strip.historyOpen(true)
        val fill = strip.history.backgroundTintList!!.defaultColor
        assertNotEquals(Color.TRANSPARENT, fill)
        assertTrue(ColorUtils.calculateContrast(strip.history.iconTint.defaultColor, fill) >= 4.5)
        strip.historyOpen(false)
        assertEquals(Color.TRANSPARENT, strip.history.backgroundTintList!!.defaultColor)
    }

    @Test fun `the options menu exposes switch and radio roles with checked state and closes on a choice`() {
        val anchor = View(ContextThemeWrapper(app, R.style.Theme_Chirp))
        var cleanup = true; var picked = ""; var opened = false
        val menu = StripMenu(anchor).apply {
            toggle("Clean-up", "On your computer", cleanup) { cleanup = it }
            section("Style")
            radio("Default", null, true) { picked = "default" }
            radio("Notes", "rewrites", false) { picked = "notes" }
            section("Chirp")
            item(R.drawable.ic_settings, "Chirp settings") { opened = true }
        }
        val all = descendants(menu.content).filter { it.isClickable }
        assertEquals(5, all.size)
        assertTrue(all.first().contentDescription.toString().startsWith("Private session"))
        val rows = all.drop(1)
        fun info(view: View) = android.view.accessibility.AccessibilityNodeInfo.obtain().also { view.onInitializeAccessibilityNodeInfo(it) }
        assertEquals("android.widget.Switch", info(rows[0]).className.toString()); assertTrue(info(rows[0]).isChecked)
        assertEquals("android.widget.RadioButton", info(rows[1]).className.toString()); assertTrue(info(rows[1]).isChecked)
        assertFalse(info(rows[2]).isChecked); assertEquals("Notes, rewrites", rows[2].contentDescription.toString())
        rows[0].performClick(); assertFalse(cleanup)
        assertFalse(info(rows[0]).isChecked)
        rows[2].performClick(); assertEquals("notes", picked)
        rows[3].performClick(); assertTrue(opened)
        assertTrue(descendants(menu.content).filterIsInstance<TextView>().any { it.text == "Style" && androidx.core.view.ViewCompat.isAccessibilityHeading(it) })
    }
    @Test fun `action digits tick but TalkBack description stays fixed and offers never restart`() {
        val app = org.robolectric.RuntimeEnvironment.getApplication()
        val button = android.widget.TextView(app)
        var now = 0L
        val countdown = ActionCountdown(button, "Use raw") { now }
        countdown.show(true, 5000)
        assertEquals("Use raw (5s)", button.text.toString())
        val spoken = button.contentDescription
        now = 1000
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(200))
        assertEquals("Use raw (4s)", button.text.toString())
        assertEquals(spoken, button.contentDescription)
        countdown.show(true, 5000)
        assertEquals("Use raw (4s)", button.text.toString())
        countdown.show(false)
        now = 4000
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idleFor(java.time.Duration.ofSeconds(1))
        assertEquals("Use raw", button.text.toString())
    }

}
