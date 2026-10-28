package dev.chirp.android

import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.Context
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.SystemClock
import android.text.SpannableString
import android.text.Spanned
import android.text.TextUtils
import android.text.style.ForegroundColorSpan
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.TextView
import androidx.compose.ui.graphics.toArgb
import androidx.core.graphics.ColorUtils
import com.google.android.material.button.MaterialButton
import dev.chirp.android.ui.PondDark
import dev.chirp.android.ui.PondLight
import dev.chirp.android.ui.chirpColorScheme
import dev.chirp.android.ui.chirpRoles
import dev.chirp.android.ui.ripplePeriod
import kotlin.math.max

internal data class VoicePalette(val background: Int, val surface: Int, val ink: Int, val muted: Int, val accent: Int, val onAccent: Int,
                                 val accentContainer: Int, val onAccentContainer: Int, val secondaryContainer: Int, val onSecondaryContainer: Int,
                                 val errorContainer: Int, val onErrorContainer: Int, val card: Int = background, val outline: Int = muted,
                                 val record: Int = errorContainer, val moon: Int = accent, val moonFill: Int = accentContainer,
                                 val koiDecor: Int = accent, val surfaceHigh: Int = surface) {
    companion object {
        /**
         * The panel's colours, derived from the same scheme the app uses ("App colours" →
         * [chirpColorScheme]): Pond, or the wallpaper when the user picked that. The old hand-typed
         * duplicates of the app scheme are gone; only the keyboard keeps its own HeliBoard looks.
         * `record`, `moon` and the Ripple's `koiDecor` are the fixed brand roles, even under dynamic colour.
         */
        fun of(context: Context): VoicePalette {
            val night = context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
            val scheme = runCatching { chirpColorScheme(context, night) }.getOrElse { if (night) PondDark else PondLight }
            val roles = chirpRoles(night)
            return scheme.run {
                VoicePalette(background.toArgb(), surfaceContainer.toArgb(), onSurface.toArgb(), onSurfaceVariant.toArgb(),
                    primary.toArgb(), onPrimary.toArgb(), primaryContainer.toArgb(), onPrimaryContainer.toArgb(),
                    secondaryContainer.toArgb(), onSecondaryContainer.toArgb(), errorContainer.toArgb(), onErrorContainer.toArgb(),
                    card = surface.toArgb(), outline = outlineVariant.toArgb(), record = roles.record.toArgb(), moon = roles.moon.toArgb(),
                    moonFill = roles.moonFill.toArgb(), koiDecor = roles.koiDecor.toArgb(), surfaceHigh = surfaceContainerHigh.toArgb())
            }
        }
    }
}

/** Fills or outlines a button in the palette accent instead of the theme's fixed colorPrimary, with Material's disabled alphas. */
internal fun MaterialButton.accent(palette: VoicePalette, filled: Boolean) {
    fun states(on: Int, off: Int) = ColorStateList(arrayOf(intArrayOf(-android.R.attr.state_enabled), intArrayOf()), intArrayOf(off, on))
    val content = states(if (filled) palette.onAccent else palette.accent, palette.ink and 0x00ffffff or 0x61000000)
    if (filled) backgroundTintList = states(palette.accent, palette.ink and 0x00ffffff or 0x1F000000)
    setTextColor(content); iconTint = content
}

/** Readable content on a fixed fill: whichever of white and pond ink contrasts more (pond ink on the dark theme's light record red). */
private fun readableOn(fill: Int): Int {
    val ink = 0xFF0D1526.toInt(); val white = 0xFFFFFFFF.toInt()
    return if (ColorUtils.calculateContrast(white, fill or 0xFF000000.toInt()) >= ColorUtils.calculateContrast(ink, fill or 0xFF000000.toInt())) white else ink
}

/**
 * The floating mic panel (#167), native Views so it works in a non-focusable accessibility window. Pond: a
 * 16 dp card with the one overlay shadow, Koi for the primary action, `record` for Stop, `moon` for Polished.
 * [render] draws a [PanelModel]; the service owns every transition.
 */
@SuppressLint("ViewConstructor")
internal class VoicePanel(context: Context) : LinearLayout(context) {
    private val largeText = context.resources.configuration.fontScale >= 1.5f
    private val palette = VoicePalette.of(context)
    val banner = context.label("").apply { visibility = GONE }
    private val dot = View(context)
    val headline = TextView(context).apply {
        textSize = 15f; typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD); setTextColor(palette.ink)
        accessibilityLiveRegion = ACCESSIBILITY_LIVE_REGION_POLITE; maxLines = 2; ellipsize = TextUtils.TruncateAt.END
    }
    val polished = TextView(context).apply {
        text = context.getString(R.string.panel_polished); textSize = 12f; typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        setTextColor(0xFF402D00.toInt()) // Pond's on-moon ink: the golden fill is the same in light and dark.
        setPadding(context.dp(10), context.dp(3), context.dp(10), context.dp(3))
        background = GradientDrawable().apply { setColor(palette.moonFill); cornerRadius = context.dp(12).toFloat() }
        visibility = GONE
    }
    private val spacer = View(context).apply { visibility = GONE }
    val hide = ImageButton(context).apply {
        setImageResource(R.drawable.ic_close); imageTintList = ColorStateList.valueOf(palette.muted)
        contentDescription = context.getString(R.string.panel_hide); background = null
        setPadding(context.dp(10), context.dp(10), context.dp(10), context.dp(10))
    }
    /** One tonal line with exactly one fix (#167). */
    val error = LinearLayout(context).apply {
        gravity = Gravity.CENTER_VERTICAL; visibility = GONE
        setPadding(context.dp(12), context.dp(6), context.dp(6), context.dp(6))
        background = GradientDrawable().apply { setColor(palette.errorContainer); cornerRadius = context.dp(12).toFloat() }
    }
    val errorText = TextView(context).apply { textSize = 14f; setTextColor(palette.onErrorContainer) }
    val fix = flat(palette.onErrorContainer, "")
    val transcript = TextView(context).apply {
        textSize = 17f; setTextColor(palette.ink); setLineSpacing(0f, 1.15f); maxLines = 4; ellipsize = TextUtils.TruncateAt.START
        setPadding(context.dp(14), context.dp(10), context.dp(14), context.dp(10)); minHeight = context.dp(52)
        background = GradientDrawable().apply { setColor(palette.surface); cornerRadius = context.dp(12).toFloat() }
        isSaveEnabled = false
    }
    private val ripple = RippleView(context).apply { color = palette.koiDecor }
    /** The panel's mic keeps [MicGesture]: start on down, a short release toggles, a long release stops. */
    val mic = MaterialButton(context).apply {
        text = context.getString(R.string.panel_dictate); setIconResource(R.drawable.ic_mic); iconPadding = context.dp(8)
        minHeight = context.dp(56); minWidth = context.dp(148); cornerRadius = context.dp(28)
        insetTop = 0; insetBottom = 0; textSize = 16f
        contentDescription = context.getString(R.string.panel_mic)
    }
    val cancel = flat(palette.accent, context.getString(R.string.panel_cancel)).apply { contentDescription = context.getString(R.string.panel_cancel_description) }
    private val micRow = FrameLayout(context).apply { clipChildren = false; clipToPadding = false }
    val countdown = Countdown(context, palette.accent, palette.outline)
    val raw = tonal(context.getString(R.string.strip_use_raw)).apply { contentDescription = context.getString(R.string.panel_use_raw_description) }
    val done = flat(palette.accent, context.getString(R.string.panel_done)).apply { contentDescription = context.getString(R.string.panel_done_description) }
    val scratchpad = tonal(context.getString(R.string.panel_scratchpad))
    val copy = MaterialButton(context).apply {
        text = context.getString(R.string.panel_copy); setIconResource(R.drawable.ic_copy); iconPadding = context.dp(6); insetTop = 0; insetBottom = 0
        minHeight = context.dp(44); cornerRadius = context.dp(22); accent(palette, filled = true)
    }
    private val rawCountdown = ActionCountdown(raw, context.getString(R.string.strip_use_raw))
    val privateChip = context.label(context.getString(R.string.strip_private), 12f).apply {
        val lock = androidx.core.content.ContextCompat.getDrawable(context, R.drawable.ic_lock)?.mutate()?.apply {
            setBounds(0, 0, context.dp(12), context.dp(12)); setTint(palette.muted)
        }
        setCompoundDrawables(lock, null, null, null)
        compoundDrawablePadding = context.dp(4)
        setTextColor(palette.muted)
        contentDescription = context.getString(R.string.strip_private_description)
    }
    val options = ImageButton(context).apply {
        setImageResource(R.drawable.ic_more_vert); imageTintList = ColorStateList.valueOf(palette.muted)
        contentDescription = context.getString(R.string.strip_options); background = null
        setOnClickListener { StripMenu(this).apply { show() } }
    }
    private val actions = LinearLayout(context)

    init {
        orientation = VERTICAL
        clipChildren = false
        setPadding(context.dp(16), context.dp(6), context.dp(6), context.dp(14))
        background = GradientDrawable().apply {
            setColor(palette.card); cornerRadius = context.dp(16).toFloat(); setStroke(context.dp(1), palette.outline)
        }
        elevation = context.dp(3).toFloat()
        PrivateSession.observe(this) { privateChip.visibility = if (PrivateSession.enabled) VISIBLE else GONE }
        addView(banner)
        addView(LinearLayout(context).apply {
            gravity = Gravity.CENTER_VERTICAL
            addView(dot, LayoutParams(context.dp(8), context.dp(8)).apply { marginEnd = context.dp(8) })
            // The headline takes the row unless the Polished chip follows it; then a spacer pushes ✕ to the end.
            addView(headline, LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f))
            addView(polished, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply { marginStart = context.dp(8) })
            addView(spacer, LayoutParams(0, 0, 1f))
            addView(options, LayoutParams(context.dp(44), context.dp(44)))
            addView(hide, LayoutParams(context.dp(44), context.dp(44)))
        }, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        val inner = LinearLayout(context).apply {
            orientation = VERTICAL; clipChildren = false
            setPadding(0, 0, context.dp(10), 0)
        }
        addView(inner, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        privateChip.minHeight = context.dp(24)
        inner.addView(privateChip, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply { bottomMargin = context.dp(8) })
        error.addView(errorText, LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f))
        error.addView(fix, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT))
        inner.addView(error, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply { bottomMargin = context.dp(8) })
        inner.addView(transcript, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        micRow.addView(ripple, FrameLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        if (!largeText) micRow.addView(cancel, FrameLayout.LayoutParams(LayoutParams.WRAP_CONTENT, context.dp(44), Gravity.START or Gravity.CENTER_VERTICAL))
        micRow.addView(mic, FrameLayout.LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT, Gravity.CENTER))
        inner.addView(micRow, LayoutParams(LayoutParams.MATCH_PARENT, context.dp(96)))
        if (largeText) inner.addView(cancel, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply { gravity = Gravity.CENTER_HORIZONTAL })
        inner.addView(countdown, LayoutParams(LayoutParams.MATCH_PARENT, context.dp(4)).apply { topMargin = context.dp(14) })
        inner.addView(actions, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply { topMargin = context.dp(12) })
    }

    private fun flat(color: Int, label: String) = MaterialButton(context).apply {
        text = label; setTextColor(color); minWidth = 0; minimumWidth = 0; insetTop = 0; insetBottom = 0
        backgroundTintList = ColorStateList.valueOf(android.graphics.Color.TRANSPARENT); elevation = 0f; stateListAnimator = null
        setPadding(context.dp(12), 0, context.dp(12), 0); minHeight = context.dp(44)
        rippleColor = ColorStateList.valueOf(color and 0x00ffffff or 0x22000000)
    }
    private fun tonal(label: String) = MaterialButton(context).apply {
        text = label; insetTop = 0; insetBottom = 0; minHeight = context.dp(44); cornerRadius = context.dp(22)
        minWidth = 0; minimumWidth = 0; setPadding(context.dp(16), 0, context.dp(16), 0)
        // A full-width button must not be the koi container (muddy brown in dark): tonal surfaceContainerHigh with a hairline.
        backgroundTintList = ColorStateList.valueOf(palette.surfaceHigh); setTextColor(palette.ink)
        strokeColor = ColorStateList.valueOf(palette.outline); strokeWidth = context.dp(1)
    }

    fun render(model: PanelModel, actionUntil: Long? = null) {
        val state = model.state
        banner.retention(model.retention)
        headline.text = when (state) {
            FloatingState.ERROR -> context.getString(R.string.panel_error)
            FloatingState.IDLE -> if (model.copyMode) model.headline.resolve(resources) else context.getString(R.string.panel_ready)
            FloatingState.LISTENING -> context.getString(R.string.panel_listening)
            FloatingState.INSERTED, FloatingState.POLISHED -> context.getString(R.string.panel_finished)
            else -> model.headline.resolve(resources)
        }
        val chip = state == FloatingState.POLISHED
        polished.visibility = if (chip) VISIBLE else GONE
        spacer.visibility = if (chip) VISIBLE else GONE
        headline.layoutParams = (headline.layoutParams as LayoutParams).apply { width = if (chip) LayoutParams.WRAP_CONTENT else 0; weight = if (chip) 0f else 1f }
        dot.visibility = if (state == FloatingState.LISTENING || (state == FloatingState.FINISHING && model.polishing)) VISIBLE else GONE
        dot.background = GradientDrawable().apply {
            shape = GradientDrawable.OVAL; setColor(if (state == FloatingState.LISTENING) palette.record else palette.moon)
        }
        val fix = model.fix
        error.visibility = if (state == FloatingState.ERROR) VISIBLE else GONE
        errorText.text = model.status?.resolve(resources).orEmpty()
        this.fix.visibility = if (fix != null) VISIBLE else GONE
        if (fix != null) { this.fix.text = context.getString(fix.label); this.fix.contentDescription = context.getString(fix.description) }
        // Live partials: stable words in ink, the unstable tail muted. Kept text is shown whole and selectable.
        val text = model.text
        val keeps = state == FloatingState.READY_TO_COPY || state == FloatingState.ERROR
        transcript.visibility = when {
            state == FloatingState.INSERTED || state == FloatingState.POLISHED -> GONE
            state == FloatingState.ERROR && text.isEmpty() -> GONE
            else -> VISIBLE
        }
        transcript.maxLines = if (keeps) 6 else 4
        transcript.ellipsize = if (keeps) null else TextUtils.TruncateAt.START
        transcript.setTextIsSelectable(keeps && text.isNotEmpty())
        transcript.text = when {
            text.isNotEmpty() -> SpannableString(text).apply {
                val boundary = if (!keeps && text.startsWith(model.stable)) model.stable.length else if (keeps) length else 0
                if (boundary < length) setSpan(ForegroundColorSpan(palette.muted), boundary, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
            model.copyMode && state == FloatingState.IDLE -> context.getString(R.string.panel_copy_hint)
            state == FloatingState.CONNECTING || state == FloatingState.LISTENING -> context.getString(R.string.panel_start_speaking)
            else -> ""
        }
        transcript.setTextColor(if (text.isEmpty()) palette.muted else palette.ink)
        // The mic row: Dictate (koi) → Stop (record pill) → Finishing (disabled), with the Ripple only while listening.
        val micShown = state == FloatingState.IDLE || model.active
        micRow.visibility = if (micShown) VISIBLE else GONE
        cancel.visibility = if (state == FloatingState.CONNECTING || state == FloatingState.LISTENING) VISIBLE else GONE
        val stopping = state == FloatingState.CONNECTING || state == FloatingState.LISTENING
        mic.text = context.getString(when { state == FloatingState.FINISHING -> if (model.polishing) R.string.panel_polishing else R.string.panel_finishing; stopping -> R.string.panel_stop; else -> R.string.panel_dictate })
        mic.setIconResource(if (stopping) R.drawable.ic_stop else R.drawable.ic_mic)
        mic.isEnabled = state != FloatingState.FINISHING
        mic.contentDescription = if (stopping) context.getString(R.string.strip_stop) else if (state == FloatingState.FINISHING) mic.text else context.getString(R.string.panel_mic)
        if (stopping) {
            mic.backgroundTintList = ColorStateList.valueOf(palette.record)
            val on = readableOn(palette.record); mic.setTextColor(on); mic.iconTint = ColorStateList.valueOf(on)
        } else mic.accent(palette, filled = true)
        ripple.mode = when (state) {
            FloatingState.LISTENING -> RippleView.Mode.LIVE
            FloatingState.CONNECTING, FloatingState.FINISHING -> RippleView.Mode.STATIC
            else -> RippleView.Mode.OFF
        }
        ripple.level = if (state == FloatingState.LISTENING) model.level.toFloat() else 0f
        countdown.visibility = if (state == FloatingState.POLISHED) VISIBLE else GONE
        if (state != FloatingState.POLISHED) countdown.stop()
        rawCountdown.show(state == FloatingState.POLISHED, actionUntil)
        raw.visibility = if (state == FloatingState.POLISHED) VISIBLE else GONE
        copy.contentDescription = context.getString(R.string.panel_copy_description)
        arrange(state, keeps && text.isNotEmpty())
        requestLayout()
    }
    /**
     * The action buttons per state. Ready to copy stacks full width, primary first (Copy, Open in Scratchpad,
     * Done), so the long label fits the cover screen and large fonts; kept words after an error get Done · Copy
     * in a row; Polished gets Use raw. Errors without words have no Done: ✕ already closes them.
     */
    private fun arrange(state: FloatingState, hasWords: Boolean) {
        actions.removeAllViews()
        val buttons = when {
            state == FloatingState.READY_TO_COPY -> listOfNotNull(copy.takeIf { hasWords }, scratchpad.takeIf { hasWords }, done)
            state == FloatingState.ERROR && hasWords -> listOf(done, copy)
            state == FloatingState.POLISHED -> listOf(raw)
            else -> emptyList()
        }
        val stacked = state == FloatingState.READY_TO_COPY
        actions.orientation = if (stacked) VERTICAL else HORIZONTAL
        actions.gravity = if (state == FloatingState.POLISHED) Gravity.START else Gravity.END or Gravity.CENTER_VERTICAL
        for (button in listOf(done, scratchpad, raw, copy)) button.visibility = if (button in buttons) VISIBLE else GONE
        buttons.forEachIndexed { index, button ->
            actions.addView(button, if (stacked) LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply { if (index > 0) topMargin = context.dp(8) }
                else LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply { if (index > 0) marginStart = context.dp(8) })
        }
        actions.visibility = if (buttons.isEmpty()) GONE else VISIBLE
    }
    /** The pill sits centred in [micRow]; the Ripple rings grow from its outline. */
    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        super.onLayout(changed, l, t, r, b)
        ripple.anchor(mic.left.toFloat(), mic.top.toFloat(), mic.right.toFloat(), mic.bottom.toFloat())
    }
    fun level(value: Double) { ripple.level = value.toFloat() }
}

/** The Use raw window: a thin linear bar that empties over 5 s (it stays full with animations off). */
@SuppressLint("ViewConstructor")
internal class Countdown(context: Context, private val fill: Int, private val track: Int) : View(context) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private var animator: ValueAnimator? = null
    var fraction = 1f
        set(value) { field = value.coerceIn(0f, 1f); invalidate() }
    init { importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO }
    fun run(ms: Long) {
        stop()
        animator = ValueAnimator.ofFloat(1f, 0f).apply {
            duration = ms; interpolator = android.view.animation.LinearInterpolator()
            addUpdateListener { fraction = it.animatedValue as Float }
            start()
        }
    }
    fun stop() { animator?.cancel(); animator = null; fraction = 1f }
    override fun onDetachedFromWindow() { animator?.cancel(); animator = null; super.onDetachedFromWindow() }
    override fun onDraw(canvas: Canvas) {
        val r = height / 2f
        paint.color = track; canvas.drawRoundRect(0f, 0f, width.toFloat(), height.toFloat(), r, r, paint)
        paint.color = fill; canvas.drawRoundRect(0f, 0f, width * fraction, height.toFloat(), r, r, paint)
    }
}

/**
 * The Pond Ripple for View surfaces (the floating mic's bubble and panel): three rings growing out of an anchor
 * outline (a circle for the bubble, a pill for Stop), each expanding by 0.8 of its half-height while fading
 * 0.5 → 0, staggered by a third, with [ripplePeriod]'s level-driven cycle. With animator scale 0 it draws one
 * static ring whose stroke follows the level. Only redraws while [Mode.LIVE] and attached: nothing idles.
 */
internal class RippleView(context: Context) : View(context) {
    enum class Mode { OFF, STATIC, LIVE }
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
    private val anchor = RectF()
    private val ring = RectF()
    private var phase = 0f
    private var last = 0L
    var color = 0
    var mode = Mode.OFF
        set(value) { if (field != value) { field = value; last = 0L; invalidate() } }
    var level = 0f
        set(value) { field = value.coerceIn(0f, 1f); invalidate() }

    init { importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO }

    fun anchor(left: Float, top: Float, right: Float, bottom: Float) {
        anchor.set(left, top, right, bottom); invalidate()
    }
    private fun motion() = ValueAnimator.areAnimatorsEnabled()

    override fun onDetachedFromWindow() { last = 0L; super.onDetachedFromWindow() }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        if (mode == Mode.OFF || anchor.isEmpty) return
        val half = anchor.height() / 2f
        val stroke = max(context.dp(2).toFloat(), half / 9f)
        if (mode == Mode.LIVE && motion()) {
            val now = SystemClock.uptimeMillis()
            if (last != 0L) phase = (phase + (now - last) / (ripplePeriod(level) * 1000f)) % 1f
            last = now
            repeat(3) { index ->
                val p = (phase + index / 3f) % 1f
                draw(canvas, half * 0.8f * p, stroke * (1f - 0.35f * p), (255 * 0.5f * (1f - p)).toInt())
            }
            postInvalidateOnAnimation()
        } else {
            // Static koi ring: steady while connecting or finishing; with animations off its stroke follows the level.
            val weight = stroke + if (mode == Mode.LIVE) half / 3f * level else 0f
            draw(canvas, context.dp(4).toFloat() + weight / 2f, weight, if (mode == Mode.LIVE) 220 else 110)
        }
    }
    private fun draw(canvas: Canvas, grow: Float, width: Float, alpha: Int) {
        paint.color = color; paint.alpha = alpha; paint.strokeWidth = width
        ring.set(anchor.left - grow, anchor.top - grow, anchor.right + grow, anchor.bottom + grow)
        val radius = ring.height() / 2f
        canvas.drawRoundRect(ring, radius, radius, paint)
    }
}
