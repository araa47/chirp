package dev.chirp.android

import android.app.Activity
import android.content.Context
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.GradientDrawable
import android.view.ContextThemeWrapper
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.TextView
import java.io.File
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * The floating mic (#167) as it sits over another app: a synthetic chat field, the bubble at the edge and the
 * panel above the field, for every state on the cover and inner screens in light and dark. Synthetic text only.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37], qualifiers = "w411dp-h891dp-xhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class FloatingMicRenderTest {
    private val heard = "Synthetic example for visual review"
    private data class Shot(val name: String, val model: PanelModel?, val copy: Boolean = false, val hold: Boolean = false)
    private val shots = listOf(
        Shot("idle", null), Shot("idle-copy", null, copy = true), Shot("hold", null, hold = true),
        Shot("connecting", PanelModel(FloatingState.CONNECTING)),
        Shot("listening", PanelModel(FloatingState.LISTENING, text = heard, stable = "Synthetic example for", level = .5)),
        Shot("finishing", PanelModel(FloatingState.FINISHING, text = heard, stable = heard, polishing = true)),
        Shot("polished", PanelModel(FloatingState.POLISHED)),
        Shot("ready", PanelModel(FloatingState.READY_TO_COPY, text = "$heard. It waits here until you copy it.")),
        Shot("ready-copy-mode", PanelModel(FloatingState.READY_TO_COPY, text = "$heard.", copyMode = true)),
        Shot("error", PanelModel(FloatingState.ERROR, status = ConnectionFailure.Kind.DOWN.status)),
        Shot("error-tailscale", PanelModel(FloatingState.ERROR, status = DictationAction.TAILSCALE_OFF)),
    )

    private fun Context.field(night: Boolean) = TextView(this).apply {
        text = "Synthetic reply draft"; textSize = 16f; gravity = Gravity.CENTER_VERTICAL
        setTextColor(if (night) 0xFFE3E3E3.toInt() else 0xFF1F1F1F.toInt()); setPadding(dp(20), 0, dp(20), 0)
        background = GradientDrawable().apply { setColor(if (night) 0xFF2B2B2B.toInt() else 0xFFFFFFFF.toInt()); cornerRadius = dp(28).toFloat() }
    }

    /** Lays out one scene with the real placement rules and draws it. */
    private fun scene(context: Context, widthDp: Int, night: Boolean, shot: Shot): Bitmap {
        val width = context.dp(widthDp)
        val root = FrameLayout(context).apply { setBackgroundColor(if (night) 0xFF121212.toInt() else 0xFFF1F3F4.toInt()) }
        var panel: VoicePanel? = null
        var panelHeight = 0
        if (shot.model != null) {
            PrivateSession.set(shot.name == "polished")
            panel = VoicePanel(context).apply { render(shot.model, android.os.SystemClock.elapsedRealtime() + 4000) }
            if (shot.model.state == FloatingState.POLISHED) panel.countdown.fraction = .6f
            val panelWidth = minOf(context.dp(360), width - context.dp(32))
            panel.measure(View.MeasureSpec.makeMeasureSpec(panelWidth, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
            panelHeight = panel.measuredHeight
        }
        val height = (if (panel != null) panelHeight + context.dp(24) else context.dp(140)) + context.dp(88)
        val fieldArea = Area(context.dp(16), height - context.dp(72), width - context.dp(16), height - context.dp(16))
        val m = BubbleMetrics(width, height, 0, height, context.dp(56), context.dp(8), context.dp(16))
        root.addView(context.field(night), FrameLayout.LayoutParams(fieldArea.width, fieldArea.height).apply {
            leftMargin = fieldArea.left; topMargin = fieldArea.top })
        if (panel != null) {
            val area = BubblePlacement.panel(m, fieldArea, BubbleEdge.RIGHT, 0, context.dp(360), panelHeight)
            root.addView(panel, FrameLayout.LayoutParams(area.width, area.height).apply { leftMargin = area.left; topMargin = area.top })
        } else {
            val at = BubblePlacement.bubble(m, fieldArea, null)
            val bubble = BubbleView(context, VoicePalette.of(context)).apply { copyMode = shot.copy; holding = shot.hold; edge = at.edge }
            if (shot.hold) {
                val ripple = RippleView(context).apply { color = VoicePalette.of(context).koiDecor; mode = RippleView.Mode.LIVE; level = .6f }
                root.addView(ripple, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
                val inset = context.dp(4).toFloat()
                ripple.anchor(at.x + inset, at.y + inset, at.x + m.size - inset, at.y + m.size - inset)
                val palette = VoicePalette.of(context)
                root.addView(TextView(context).apply {
                    text = "Synthetic words so far"; textSize = 15f; setTextColor(palette.ink); gravity = Gravity.CENTER_VERTICAL
                    setPadding(context.dp(14), 0, context.dp(14), 0)
                    background = GradientDrawable().apply { setColor(palette.card); cornerRadius = context.dp(20).toFloat(); setStroke(context.dp(1), palette.outline) }
                }, FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, context.dp(40)).apply {
                    gravity = Gravity.END or Gravity.TOP; topMargin = at.y + (m.size - context.dp(40)) / 2; rightMargin = m.size + context.dp(20) })
            }
            root.addView(bubble, FrameLayout.LayoutParams(m.size, m.size).apply { leftMargin = at.x; topMargin = at.y })
        }
        root.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY))
        root.layout(0, 0, width, height)
        if (panel != null && context.resources.configuration.fontScale >= 1.5f) {
            val controls = listOf(panel.cancel, panel.mic, panel.fix, panel.privateChip, panel.raw, panel.copy, panel.scratchpad, panel.done)
            for (view in controls.filter { it.visibility == View.VISIBLE && (it.parent as View).visibility == View.VISIBLE }) {
                val layout = view.layout ?: continue
                assertTrue("${view.text} fits vertically in ${shot.name}", layout.height <= view.height - view.compoundPaddingTop - view.compoundPaddingBottom)
                assertTrue("${view.text} is not ellipsized", (0 until layout.lineCount).none { layout.getEllipsisCount(it) > 0 })
            }
            if (panel.cancel.visibility == View.VISIBLE && panel.mic.visibility == View.VISIBLE) {
                fun bounds(view: View) = android.graphics.Rect(0, 0, view.width, view.height).also { root.offsetDescendantRectToMyCoords(view, it) }
                assertFalse("Cancel and mic do not overlap", android.graphics.Rect.intersects(bounds(panel.cancel), bounds(panel.mic)))
            }
        }
        return Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).also { root.draw(Canvas(it)) }
    }

    @Test fun `render floating mic states on cover and inner in light and dark`() = render()
    @Test fun `render floating panel at twice the font size`() = render(2f)

    private fun render(fontScale: Float = 1f) {
        val output = File(System.getProperty("chirp.screenshots")).apply { mkdirs() }
        val controller = Robolectric.buildActivity(Activity::class.java).setup()
        val activity = controller.get()
        try {
            for ((theme, night) in listOf("light" to false, "dark" to true)) {
                val config = Configuration(activity.resources.configuration).apply {
                    this.fontScale = fontScale
                    uiMode = Configuration.UI_MODE_TYPE_NORMAL or if (night) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO
                }
                val themed = ContextThemeWrapper(activity.createConfigurationContext(config), R.style.Theme_Chirp)
                for ((screen, widthDp) in listOf("cover" to 360, "inner" to 720)) for (shot in shots) {
                    val bitmap = scene(themed, widthDp, night, shot)
                    val colours = HashSet<Int>()
                    for (y in 0 until bitmap.height step 4) for (x in 0 until bitmap.width step 4) colours += bitmap.getPixel(x, y)
                    assertTrue("${shot.name} is blank", colours.size > 8)
                    File(output, "floating-${shot.name}-$screen-${if (fontScale == 2f) "font-200-" else ""}$theme.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
                    bitmap.recycle()
                }
            }
            val files = output.listFiles()!!.filter { it.name.startsWith("floating-") && it.extension == "png" }
            assertTrue(files.all { it.length() < 2_000_000 })
        } finally { PrivateSession.set(false); controller.pause().stop().destroy() }
    }

    @Test fun `the panel is never full width on the inner screen and keeps 16 dp from the edges`() {
        val m = BubbleMetrics(2208, 1840, 80, 1760, 147, 21, 42)
        val area = BubblePlacement.panel(m, Area(100, 1400, 2100, 1500), BubbleEdge.LEFT, 1300, 945, 600)
        assertEquals(945, area.width); assertEquals(42, area.left)
        assertTrue(area.bottom <= 1400)
    }

    @Test fun `large panel buttons are tonal surfaces with a hairline in dark, never the koi container (174)`() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        for (night in listOf(true, false)) {
            val config = Configuration(activity.resources.configuration).apply {
                uiMode = Configuration.UI_MODE_TYPE_NORMAL or if (night) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO
            }
            val context = ContextThemeWrapper(activity.createConfigurationContext(config), R.style.Theme_Chirp)
            val palette = VoicePalette.of(context)
            val panel = VoicePanel(context)
            for (button in listOf(panel.scratchpad, panel.raw)) {
                assertEquals("${button.text} fill, night=$night", palette.surfaceHigh, button.backgroundTintList!!.defaultColor)
                assertNotEquals("${button.text} uses the koi container, night=$night", palette.accentContainer, button.backgroundTintList!!.defaultColor)
                assertEquals(palette.ink, button.textColors.defaultColor)
                assertTrue(button.strokeWidth > 0)
            }
            if (night) assertEquals(0xFF5C2207.toInt(), palette.accentContainer) // the colour the buttons used to be
        }
    }

    @Test fun `ready to copy shows Done Scratchpad and Copy and an error exactly one fix`() {
        val context = ContextThemeWrapper(Robolectric.buildActivity(Activity::class.java).setup().get(), R.style.Theme_Chirp)
        val panel = VoicePanel(context)
        fun shown() = listOf(panel.copy, panel.scratchpad, panel.done, panel.raw, panel.mic, panel.cancel, panel.fix)
            .filter { it.visibility == View.VISIBLE && (it.parent as View).visibility == View.VISIBLE }.map { it.text.toString() }
        panel.render(PanelModel(FloatingState.READY_TO_COPY, text = "Synthetic."))
        assertEquals(listOf("Copy", "Open in Scratchpad", "Done"), shown())
        assertTrue(panel.transcript.isTextSelectable)
        panel.render(PanelModel(FloatingState.ERROR, status = BubbleFix.NO_MICROPHONE))
        assertEquals(listOf("Allow"), listOf(panel.fix).filter { it.visibility == View.VISIBLE }.map { it.text.toString() })
        assertEquals(View.VISIBLE, panel.error.visibility); assertEquals(View.GONE, panel.done.visibility)
        panel.render(PanelModel(FloatingState.LISTENING, text = "synthetic"))
        assertEquals("Stop", panel.mic.text.toString()); assertEquals(View.VISIBLE, panel.cancel.visibility)
        panel.render(PanelModel(FloatingState.POLISHED))
        assertEquals(View.VISIBLE, panel.raw.visibility); assertEquals(View.VISIBLE, panel.polished.visibility)
        assertEquals(View.VISIBLE, panel.countdown.visibility)
    }
}
