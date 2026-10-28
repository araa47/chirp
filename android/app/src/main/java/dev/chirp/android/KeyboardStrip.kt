package dev.chirp.android

import android.animation.ArgbEvaluator
import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.Context
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.view.animation.PathInterpolator
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.RelativeLayout
import androidx.core.graphics.ColorUtils
import androidx.core.graphics.drawable.toDrawable
import androidx.compose.ui.graphics.toArgb
import com.google.android.material.button.MaterialButton
import dev.chirp.android.ui.chirpRoles
import dev.chirp.android.ui.ripplePeriod

/** Shares HeliBoard's suggestion row: idle mic at the end, status replaces suggestions. */
@SuppressLint("ViewConstructor")
internal class KeyboardStrip(context: Context, private val now: () -> Long = SystemClock::elapsedRealtime) : LinearLayout(context) {
    private val palette = StripColors.of(context)
    private val tints = palette.tints
    /** The fixed record red (spec §C): Stop's pill colour, the same in every keyboard look. */
    private val record = chirpRoles(context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES).record.toArgb()
    val status = context.label(context.getString(R.string.status_tap_mic), 14f).apply {
        maxLines = 1; ellipsize = TextUtils.TruncateAt.END
        accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        compoundDrawablePadding = context.dp(6)
    }
    private val large = SettingsStore(context).largerMic && context.resources.configuration.smallestScreenWidthDp >= 600
    private val micWidth = context.dp(if (large) 56 else 48)
    val history = control(context.getString(R.string.history_title)).apply { setIconResource(R.drawable.ic_history) }
    /** The ⋯ beside the mic: dictation options now that press-and-hold on the mic is push-to-talk. */
    val options = control(context.getString(R.string.strip_options)).apply { setIconResource(R.drawable.ic_more_vert) }
    val mic = control(context.getString(R.string.strip_mic_idle)).apply { setIconResource(R.drawable.ic_mic) }
    val cancel = control(context.getString(R.string.strip_cancel)).apply { text = "✕" }
    val raw = control(context.getString(R.string.strip_use_raw_description)).apply { textSize = 12f; text = context.getString(R.string.strip_use_raw); visibility = GONE }
    val revert = control(context.getString(R.string.strip_undo_description)).apply { textSize = 12f; text = context.getString(R.string.strip_undo); visibility = GONE }
    /** The button for prompt actions such as turning on Tailscale; the status keeps the explanation. */
    private val rawCountdown = ActionCountdown(raw, context.getString(R.string.strip_use_raw), now)
    private val undoCountdown = ActionCountdown(revert, context.getString(R.string.strip_undo), now)
    val privateChip = context.label(context.getString(R.string.strip_private), 11f).apply {
        val lock = androidx.core.content.ContextCompat.getDrawable(context, R.drawable.ic_lock)?.mutate()?.apply {
            setBounds(0, 0, context.dp(12), context.dp(12)); setTint(palette.muted)
        }
        setCompoundDrawablesRelative(lock, null, null, null)
        compoundDrawablePadding = context.dp(3)
        setPadding(context.dp(4), 0, context.dp(4), 0)
        contentDescription = context.getString(R.string.strip_private_description)
    }
    val action = control("").apply { visibility = GONE; setPadding(context.dp(12), 0, context.dp(12), 0); minWidth = context.dp(48); minimumWidth = context.dp(48) }
    val style = context.label("", 12f).apply {
        maxLines = 1; ellipsize = TextUtils.TruncateAt.END
        setPadding(context.dp(8), 0, context.dp(8), 0)
        background = GradientDrawable().apply { setColor(palette.chip); cornerRadius = context.dp(10).toFloat() }
    }
    /** Elapsed time while listening, `0:12 · #2` once a long dictation is on its second segment; a warning chip near the time limit. */
    val timer = context.label("0:00", 13f).apply {
        maxLines = 1; gravity = Gravity.CENTER_VERTICAL; fontFeatureSettings = "tnum"
        setPadding(context.dp(8), 0, context.dp(8), 0); compoundDrawablePadding = context.dp(4)
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        background = GradientDrawable().apply { cornerRadius = context.dp(12).toFloat() }
        visibility = GONE
    }
    private val handler = Handler(Looper.getMainLooper())
    private var pulse: ValueAnimator? = null
    private var pulsingPolish = false
    private var stage = ""
    private var kind = StripKind.IDLE
    private val levels = RippleArcs(context).apply { color = palette.highlight }
    private val busy = ImageView(context).apply { importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO; visibility = GONE }
    private val busyShape = LoadingDrawable(context.dp(24), palette.highlight).also { busy.setImageDrawable(it) }
    private val micShape = LoadingDrawable(context.dp(24), palette.onAccent)
    private val rowTint = Color.TRANSPARENT.toDrawable()
    private var rowFill = Color.TRANSPARENT
    private var stopShape = 0f
    /** The mic's base fill colour while stopped: the fixed record red, or the keyboard's accent. */
    private var micFill = Color.RED
    private var micRecord = false
    private var morph: ValueAnimator? = null
    private var morphGoal = 0f to 0
    private var listenStart = -1L
    /** When Stop was tapped: while the final arrives the timer holds the time the mic was open. */
    private var listenEnd = -1L
    private var segment = 1
    private var suggestions: View? = null
    private var expanded = false
    private val tick = object : Runnable { override fun run() { if (counting) { updateTimer(); scheduleTick() } } }
    private val counting get() = listenStart >= 0 && listenEnd < 0
    init {
        gravity = Gravity.CENTER_VERTICAL
        // Transparent when idle: HeliBoard's own suggestion-row background (colour or image) shows through; states tint over it.
        background = rowTint
        cancel.backgroundTintList = ColorStateList.valueOf(Color.TRANSPARENT); cancel.setTextColor(palette.ink)
        for (button in listOf(mic, cancel, raw, revert, action, options)) {
            button.cornerRadius = context.dp(20)
            button.rippleColor = ColorStateList.valueOf(palette.ink and 0x00ffffff or 0x22000000)
        }
        // Chips look 32 dp tall; the touch target stays the full row.
        for (chip in listOf(raw, revert, action)) { chip.insetTop = context.dp(4); chip.insetBottom = context.dp(4) }
        PrivateSession.observe(this) {
            privateChip.visibility = if (PrivateSession.enabled) VISIBLE else GONE
            if (!expanded) (layoutParams as? RelativeLayout.LayoutParams)?.let { it.width = idleWidth(); layoutParams = it }
            (suggestions?.layoutParams as? RelativeLayout.LayoutParams)?.let { it.marginEnd = idleWidth(); suggestions?.layoutParams = it }
        }
        addView(privateChip, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT))
        addView(cancel, LayoutParams(context.dp(48), LayoutParams.MATCH_PARENT))
        addView(levels, LayoutParams(context.dp(72), LayoutParams.MATCH_PARENT))
        addView(busy, LayoutParams(context.dp(40), LayoutParams.MATCH_PARENT))
        addView(status, LayoutParams(0, LayoutParams.MATCH_PARENT, 1f).apply { status.gravity = Gravity.CENTER_VERTICAL })
        addView(timer, LayoutParams(LayoutParams.WRAP_CONTENT, context.dp(28)).apply { marginEnd = context.dp(4) })
        addView(style, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply { marginEnd = context.dp(4) })
        addView(revert, LayoutParams(context.dp(80), LayoutParams.MATCH_PARENT).apply { marginEnd = context.dp(4) })
        addView(raw, LayoutParams(context.dp(100), LayoutParams.MATCH_PARENT).apply { marginEnd = context.dp(4) })
        addView(action, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.MATCH_PARENT).apply { marginEnd = context.dp(4) })
        addView(history, LayoutParams(context.dp(48), LayoutParams.MATCH_PARENT))
        addView(options, LayoutParams(context.dp(OPTIONS_WIDTH), LayoutParams.MATCH_PARENT))
        addView(mic, LayoutParams(micWidth, LayoutParams.MATCH_PARENT))
        show(StatusLine.TAP_MIC, "", false, false, false, false)
        historyOpen(false)
    }
    private fun control(description: String) = MaterialButton(context).apply {
        text = ""; iconPadding = 0; iconGravity = MaterialButton.ICON_GRAVITY_TEXT_START
        minWidth = 0; minimumWidth = 0; minimumHeight = 0; minHeight = 0
        insetTop = 0; insetBottom = 0; setPadding(0, 0, 0, 0)
        contentDescription = description; isSaveEnabled = false
    }
    fun mount(parent: RelativeLayout) {
        suggestions = parent.findViewById(helium314.keyboard.latin.R.id.suggestions_strip_wrapper)
        (suggestions?.layoutParams as? RelativeLayout.LayoutParams)?.apply { marginEnd = idleWidth() }
        // Larger mic: the row grows to a 48 dp touch height on the inner screen.
        if (large) (parent.parent as? View)?.let { row -> row.layoutParams?.let { it.height = maxOf(it.height, context.dp(48)); row.layoutParams = it } }
        parent.addView(this, RelativeLayout.LayoutParams(idleWidth(), LayoutParams.MATCH_PARENT).apply { addRule(RelativeLayout.ALIGN_PARENT_END) })
    }
    /** [decorate] adds the countdown or debug timings to whichever form of the line is shown. */
    fun show(message: DictationStatus, @Suppress("UNUSED_PARAMETER") text: String, active: Boolean, finishing: Boolean, undo: Boolean, retention: Boolean,
             polishing: Boolean = false, style: String = "", notice: Boolean = false, undoable: Boolean = false, offline: Boolean = false, countdown: Boolean = false,
             phone: String? = null, actionUntil: Long? = null, decorate: (String) -> String = { it }) {
        val recovery = message.action
        val offlineRow = message == StatusLine.OFFLINE
        val error = recovery != null || offlineRow
        val full = active || undo || undoable || error || retention || notice
        if (expanded != full) {
            expanded = full
            (layoutParams as? RelativeLayout.LayoutParams)?.let { it.width = if (full) LayoutParams.MATCH_PARENT else idleWidth(); layoutParams = it }
            suggestions?.visibility = if (full) INVISIBLE else VISIBLE
            if (motionAllowed()) { alpha = .6f; animate().alpha(1f).setDuration(160).start() }
        }
        kind = when {
            polishing -> StripKind.POLISHING
            active && finishing -> StripKind.FINISHING
            active && message == StatusLine.CONNECTING -> StripKind.CONNECTING
            active -> StripKind.LISTENING
            error || notice && message.error -> StripKind.ERROR
            undo || undoable || notice && message.positive -> StripKind.SUCCESS
            full -> StripKind.NOTICE
            else -> StripKind.IDLE
        }
        val tint = tints.of(kind)
        val nextStage = when { polishing -> "polishing"; active && finishing -> "finishing"; active -> "listening"; undo -> "cleaned"; full -> "notice"; else -> "idle" }
        if (nextStage != stage) {
            status.animate().cancel()
            if (motionAllowed() && full) {
                status.alpha = .65f; status.translationY = context.dp(4).toFloat()
                status.animate().alpha(1f).translationY(0f).setDuration(180)
                    .setInterpolator(PathInterpolator(.2f, 0f, 0f, 1f)).start()
            } else { status.alpha = 1f; status.translationY = 0f }
            stage = nextStage
        }
        // The shown form drops the final's "tap mic to dictate again" hint: the chips are the actions that matter.
        // A fix that isn't a prompt replaces the line with its label unless the reason is named; the debug banner keeps the full line.
        val fix = recovery?.takeUnless { it.prompt }?.let { context.getString(it.label) }
        fun withFix(line: String) = if (fix != null) context.getString(R.string.status_with_action, line, fix) else line
        status.text = if (retention) context.getString(R.string.strip_debug_retention, withFix(decorate(message.resolve(resources))))
            else if (fix == null || message.named) withFix(decorate(message.shown(resources))) else fix
        status.visibility = if (full) VISIBLE else GONE
        val ink = if (retention) tints.solidError.text else tint?.text ?: palette.ink
        status.setTextColor(ink)
        status.background = if (retention) tints.solidError.fill.toDrawable() else null
        status.contentDescription = status.text
        lead(when {
            kind == StripKind.POLISHING -> R.drawable.ic_sparkle
            kind == StripKind.SUCCESS && !PrivateSession.enabled -> R.drawable.ic_check
            offlineRow -> R.drawable.ic_mic_off
            kind == StripKind.ERROR -> R.drawable.ic_warning
            else -> 0
        }, ink)
        // Listening, finishing and polishing are silent; the final is announced once by the dictation state.
        // The time-limit countdown is the one thing spoken while listening; its description changes only at a few marks.
        status.accessibilityLiveRegion = if (active && !countdown) View.ACCESSIBILITY_LIVE_REGION_NONE else View.ACCESSIBILITY_LIVE_REGION_POLITE
        cancel.visibility = if (full) VISIBLE else GONE
        // Full-row actions use the available width; the mic stays anchored at the trailing edge.
        history.visibility = if (full) GONE else VISIBLE
        options.visibility = if (full) GONE else VISIBLE
        cancel.isEnabled = active || undo || undoable || error
        levels.visibility = if (kind == StripKind.LISTENING) VISIBLE else GONE
        busy.visibility = if (kind == StripKind.CONNECTING) VISIBLE else GONE
        raw.visibility = if (undo) VISIBLE else GONE
        revert.visibility = if (undoable && !active) VISIBLE else GONE
        rawCountdown.show(undo, actionUntil)
        undoCountdown.show(undoable && !active, actionUntil)
        action.visibility = if (recovery?.prompt == true && !active) VISIBLE else GONE
        action.text = recovery?.let { context.getString(it.label) } ?: ""
        action.contentDescription = action.text
        // The same chip names a phone-recognised dictation; [phone] is its provider disclosure.
        this.style.text = if (phone != null) context.getString(R.string.phone_chip) else style
        this.style.contentDescription = phone ?: context.getString(R.string.strip_style_description, style)
        this.style.visibility = if (polishing || phone != null) VISIBLE else GONE
        colourChips(tint, kind == StripKind.ERROR)
        elapsed(kind, countdown, tint)
        val animateState = active && (!finishing || polishing)
        val motion = motionAllowed()
        if (pulse != null && pulsingPolish != polishing) { pulse?.cancel(); pulse = null; status.alpha = 1f; mic.alpha = 1f }
        if (animateState && motion && pulse == null) {
            pulsingPolish = polishing
            pulse = ValueAnimator.ofFloat(.55f, 1f).apply {
                duration = 1000; repeatCount = ValueAnimator.INFINITE
                repeatMode = ValueAnimator.REVERSE
                addUpdateListener {
                    val value = it.animatedValue as Float
                    if (pulsingPolish) {
                        val highlight = palette.highlight
                        val width = status.width.coerceAtLeast(1).toFloat()
                        status.paint.shader = android.graphics.LinearGradient(-width, 0f, width, 0f,
                            intArrayOf(ink, highlight, ink), floatArrayOf(0f, .5f, 1f), android.graphics.Shader.TileMode.CLAMP).apply {
                            setLocalMatrix(android.graphics.Matrix().apply { setTranslate((value - .55f) / .45f * width * 2, 0f) })
                        }
                        status.invalidate()
                    } else mic.alpha = .75f + value * .25f
                }; start()
            }
        } else if (!animateState || !motion) { pulse?.cancel(); pulse = null; status.alpha = 1f; mic.alpha = 1f }
        if (!polishing || !motion) { status.paint.shader = null; status.invalidate() }
        busyShape.running = kind == StripKind.CONNECTING && motion
        micShape.running = polishing && motion
        mic.text = ""
        when {
            polishing -> mic.icon = micShape
            active -> mic.setIconResource(R.drawable.ic_stop)
            offline -> mic.setIconResource(R.drawable.ic_mic_off)
            else -> mic.setIconResource(R.drawable.ic_mic)
        }
        mic.isEnabled = !finishing
        mic.contentDescription = if (polishing) context.getString(R.string.strip_polishing) else if (active) context.getString(R.string.strip_stop)
            else if (offline) context.getString(R.string.status_offline_description) else context.getString(R.string.strip_mic_idle)
        // Stop is a filled record pill while it stops something; polishing keeps the accent (it isn't a stop control).
        transition(if (active) 1f else 0f, tint, offline && !active, active && !polishing)
        if (!active || finishing) level(0.0)
    }
    /** Circle → record pill, the row tint and the stop fill share one 200 ms emphasised curve; instant when animations are off. */
    private fun transition(shape: Float, tint: StripTint?, muted: Boolean, recordPill: Boolean) {
        val target = tint?.fill ?: (rowFill and 0x00ffffff)
        val from = if (Color.alpha(rowFill) == 0) target and 0x00ffffff else rowFill
        val fromShape = stopShape
        if (morph != null && morphGoal == shape to target) return // render() runs on every partial; let the running morph finish.
        morph?.cancel(); morph = null; morphGoal = shape to target
        if (!motionAllowed() || (fromShape == shape && from == target && micRecord == recordPill)) {
            applyShape(shape, muted, recordPill); rowFill = target; rowTint.color = target; return
        }
        val evaluator = ArgbEvaluator()
        morph = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 200; interpolator = PathInterpolator(.3f, 0f, 0f, 1f)
            addUpdateListener {
                val f = it.animatedValue as Float
                applyShape(fromShape + (shape - fromShape) * f, muted, recordPill)
                rowFill = evaluator.evaluate(f, from, target) as Int; rowTint.color = rowFill
            }
            addListener(object : android.animation.AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: android.animation.Animator) { if (morph === animation) morph = null }
            })
            start()
        }
    }
    private fun applyShape(progress: Float, muted: Boolean, recordPill: Boolean) {
        stopShape = progress
        micRecord = recordPill
        val round = context.dp(if (large) 24 else 20); val square = context.dp(12)
        mic.cornerRadius = round + ((square - round) * progress).toInt()
        micFill = if (recordPill) record else palette.accent
        mic.backgroundTintList = ColorStateList.valueOf(ColorUtils.setAlphaComponent(micFill, (progress * 255).toInt()))
        // On the record red the glyph flips to pond ink when the red runs light (dark theme), so Stop always reads.
        val onFill = StripTints.readableOn(micFill or 0xFF000000.toInt(), palette.onAccent)
        val icon = ColorUtils.blendARGB(if (muted) palette.muted else palette.highlight, onFill, progress)
        mic.iconTint = ColorStateList.valueOf(icon); mic.setTextColor(icon)
        micShape.color = palette.onAccent
    }
    private fun lead(icon: Int, colour: Int) {
        val drawable = icon.takeIf { it != 0 }?.let { androidx.core.content.ContextCompat.getDrawable(context, it)?.mutate() }
        drawable?.setBounds(0, 0, context.dp(18), context.dp(18)); drawable?.setTint(colour)
        status.setCompoundDrawablesRelative(drawable, null, null, null)
    }
    /** Chips take a slightly stronger step of the row tint; a prompt's action is the one filled pill. */
    private fun colourChips(tint: StripTint?, prompt: Boolean) {
        val base = tint?.fill
        val text = tint?.text ?: palette.ink
        val chip = if (base != null) ColorUtils.blendARGB(base, text, .14f) else ColorUtils.blendARGB(palette.background, palette.accent, .25f)
        val chipText = StripTints.readableOn(chip, text)
        for (button in listOf(raw, revert)) { button.backgroundTintList = ColorStateList.valueOf(chip); button.setTextColor(chipText) }
        val fill = if (prompt) tints.error.accent else palette.accent
        action.backgroundTintList = ColorStateList.valueOf(fill)
        action.setTextColor(StripTints.readableOn(fill, if (prompt) Color.WHITE else palette.onAccent))
        (this.style.background as? GradientDrawable)?.setColor(chip)
        this.style.setTextColor(chipText)
    }
    private fun elapsed(kind: StripKind, countdown: Boolean, tint: StripTint?) {
        val live = kind == StripKind.LISTENING || kind == StripKind.FINISHING
        if (kind != StripKind.LISTENING && kind != StripKind.FINISHING && kind != StripKind.CONNECTING && kind != StripKind.POLISHING) {
            segment = 1
            listenStart = -1; listenEnd = -1; handler.removeCallbacks(tick)
        }
        if (live && listenStart < 0) listenStart = now()
        // Finishing holds the time; listening again (the next segment, a reconnect) carries on from the same start.
        if (kind == StripKind.FINISHING && listenStart >= 0 && listenEnd < 0) { listenEnd = now(); handler.removeCallbacks(tick) }
        if (kind == StripKind.LISTENING) listenEnd = -1
        if (counting && !handler.hasCallbacks(tick)) scheduleTick()
        timer.visibility = if (live) VISIBLE else GONE
        val warn = countdown && live
        (timer.background as GradientDrawable).setColor(if (warn) tints.warning.fill else Color.TRANSPARENT)
        timer.setTextColor(if (warn) tints.warning.text else tint?.text ?: palette.ink)
        val warning = if (warn) androidx.core.content.ContextCompat.getDrawable(context, R.drawable.ic_warning)?.mutate()?.apply {
            setBounds(0, 0, context.dp(14), context.dp(14)); setTint(tints.warning.text) } else null
        timer.setCompoundDrawablesRelative(warning, null, null, null)
        if (live) updateTimer()
        levels.color = tint?.accent ?: palette.highlight
        busyShape.color = tint?.accent ?: palette.highlight
    }
    /** A long dictation moved on to its next segment: the timer shows which one. */
    fun nextSegment() { segment++; if (listenStart >= 0) updateTimer() }
    /** HeliBoard rebuilds the strip on rotation or a fold mid-dictation; the new one keeps counting from the same start. */
    fun continueTimer(from: KeyboardStrip) { listenStart = from.listenStart; listenEnd = from.listenEnd; segment = from.segment }
    /** Ticks on the second boundary, so a long dictation never skips a second. */
    private fun scheduleTick() {
        handler.removeCallbacks(tick)
        handler.postDelayed(tick, 1000 - (now() - listenStart).mod(1000L))
    }
    private fun updateTimer() {
        val millis = (if (listenEnd >= 0) listenEnd else now()) - listenStart
        val label = elapsedLabel(millis); val spoken = elapsedSpoken(resources, millis)
        timer.text = if (segment > 1) context.getString(R.string.strip_timer_segment, label, segment) else label
        timer.contentDescription = if (segment > 1) context.getString(R.string.strip_timer_segment_spoken, spoken, segment) else spoken
    }
    private fun motionAllowed() = ValueAnimator.areAnimatorsEnabled() &&
        android.provider.Settings.Global.getFloat(context.contentResolver, android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 1f) > 0f
    /** True while any strip animation is running; with animations off this must stay false. */
    internal val animating get() = morph != null || pulse != null || busyShape.running || micShape.running
    internal val tintColor get() = rowFill
    internal val stripKind get() = kind
    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        if (counting) { updateTimer(); scheduleTick() }
    }
    override fun onDetachedFromWindow() {
        pulse?.cancel(); pulse = null; status.alpha = 1f; mic.alpha = 1f; status.paint.shader = null
        morph?.cancel(); morph = null; busyShape.running = false; micShape.running = false; handler.removeCallbacks(tick)
        super.onDetachedFromWindow()
    }
    fun level(value: Double) { levels.push(value.coerceIn(0.0, 1.0)) }
    fun historyOpen(open: Boolean) {
        history.isActivated = open
        // A tonal fill from the keyboard's own accent with a legible icon; closed it is just the icon.
        val fill = if (open) ColorUtils.blendARGB(palette.background, palette.accent, .30f) else Color.TRANSPARENT
        history.backgroundTintList = ColorStateList.valueOf(fill)
        history.iconTint = ColorStateList.valueOf(if (open) StripTints.readableOn(fill, palette.ink) else palette.highlight)
        history.contentDescription = context.getString(if (open) R.string.strip_history_close else R.string.history_title)
        options.backgroundTintList = ColorStateList.valueOf(Color.TRANSPARENT)
        options.iconTint = ColorStateList.valueOf(palette.highlight)
    }
    private fun idleWidth() = context.dp(48 + OPTIONS_WIDTH + if (PrivateSession.enabled) 76 else 0) + micWidth
    private companion object {
        const val OPTIONS_WIDTH = 36
    }
}

/**
 * The Pond Ripple as the strip's meter (spec §D): three arcs stepping off the mic, each expanding and fading,
 * staggered by a third, with the level-driven period of [ripplePeriod]. Reduces (animator scale 0) to one static
 * arc whose stroke follows the level. Only invalidates while listening: a GONE view's draw loop stops itself.
 */
private class RippleArcs(context: Context) : View(context) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { strokeCap = Paint.Cap.ROUND }
    private val oval = RectF()
    private val phases = FloatArray(3) { it / 3f }
    private var last = 0L
    private var animate = true
    var color: Int
        get() = paint.color
        set(value) { if (paint.color != value) { paint.color = value; invalidate() } }
    var level = 0f
        set(value) { field = value.coerceIn(0f, 1f); invalidate() }

    init { contentDescription = context.getString(R.string.strip_level); importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO }

    fun push(value: Double) {
        animate = android.provider.Settings.Global.getFloat(context.contentResolver,
            android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 1f) > 0f
        level = value.toFloat()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val now = SystemClock.uptimeMillis()
        val dt = if (last == 0L) 0f else (now - last) / 1000f
        last = now
        val cy = height / 2f
        val stroke = maxOf(context.dp(3).toFloat(), height * 0.10f)
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = stroke
        // Arcs radiate from the mic at the row's end: centres on the right edge, bulging left over the status.
        val centreX = width.toFloat() + stroke
        // The meter is much wider than it is tall. A width-sized radius
        // puts the left side of every steady arc outside this short viewport.
        val span = minOf(width * .45f, height * .44f)
        if (animate) {
            val period = ripplePeriod(level)
            for (index in 0..2) {
                val phase = (phases[index] + dt / period) % 1f
                phases[index] = phase
                val radius = span * (0.30f + 0.70f * phase)
                oval.set(centreX - 2 * radius, cy - radius, centreX + 2 * radius, cy + radius)
                paint.alpha = (255 * 0.55f * (1f - phase)).toInt()
                canvas.drawArc(oval, 125f, 110f, false, paint)
            }
            postInvalidateOnAnimation()
        } else {
            // Reduce Motion: one steady arc whose stroke weight answers the level instead.
            paint.strokeWidth = stroke + height * 0.16f * level
            val radius = span * 0.5f
            oval.set(centreX - 2 * radius, cy - radius, centreX + 2 * radius, cy + radius)
            paint.alpha = 200
            canvas.drawArc(oval, 125f, 110f, false, paint)
        }
    }
}
