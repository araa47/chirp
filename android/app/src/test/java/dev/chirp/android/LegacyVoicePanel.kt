package dev.chirp.android

import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.drawable.GradientDrawable
import android.text.SpannableString
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.LinearLayout
import com.google.android.material.button.MaterialButton
import kotlin.math.max

/** The pre-#167 voice panel, kept only for the legacy voice IME test harness. */
@SuppressLint("SetTextI18n")
internal class LegacyVoicePanel(context: Context) : LinearLayout(context) {
    private val colors = VoicePalette.of(context)
    val banner = context.label("").apply { visibility = GONE }
    /** No breadcrumb (spec §D): the panel shows a status line only when it names a problem to fix. */
    val status = context.label("", 14f).apply { visibility = GONE }
    val transcript = context.label("Tap to dictate · hold to talk", 19f)
    val mic = MaterialButton(context).apply {
        text = "Tap to dictate"; setIconResource(R.drawable.ic_mic); minHeight = context.dp(72)
        contentDescription = "Microphone: tap to toggle, hold to talk"
        accent(colors, filled = true)
    }
    val raw = MaterialButton(context).apply { text = "Use raw"; visibility = GONE; accent(colors, filled = true) }
    val controls = LinearLayout(context).apply { gravity = Gravity.CENTER }
    val extras = LinearLayout(context).apply { orientation = VERTICAL }
    private val ring = LegacyLevelRing(context)
    init {
        orientation = VERTICAL
        setPadding(context.dp(16), context.dp(8), context.dp(16), context.dp(8))
        background = GradientDrawable().apply { setColor(this@LegacyVoicePanel.colors.background); cornerRadius = context.dp(28).toFloat() }
        addView(banner)
        status.setTextColor(colors.onErrorContainer)
        status.accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        status.setPadding(context.dp(12), context.dp(6), context.dp(12), context.dp(6))
        addView(status, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        transcript.apply {
            minHeight = context.dp(56); maxLines = 3
            setPadding(context.dp(12), context.dp(8), context.dp(12), context.dp(8))
            background = GradientDrawable().apply { setColor(this@LegacyVoicePanel.colors.surface); cornerRadius = context.dp(16).toFloat() }
        }
        addView(transcript, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        addView(FrameLayout(context).apply {
            addView(ring, FrameLayout.LayoutParams(LayoutParams.MATCH_PARENT, context.dp(88)))
            addView(mic, FrameLayout.LayoutParams(context.dp(232), context.dp(72), Gravity.CENTER))
        })
        addView(controls, LayoutParams(LayoutParams.MATCH_PARENT, context.dp(48)))
        addView(raw)
        addView(extras)
    }
    fun control(text: String, description: String, action: () -> Unit): MaterialButton = MaterialButton(context,
        null, com.google.android.material.R.attr.materialButtonOutlinedStyle).apply {
        this.text = text; contentDescription = description; minWidth = 0; minimumWidth = 0
        setPadding(0, 0, 0, 0); insetLeft = 0; insetRight = 0; accent(colors, filled = false)
        controls.addView(this, LayoutParams(0, context.dp(48), 1f))
        setOnClickListener { action() }
    }
    fun show(statusText: String, text: String, stable: String = "", active: Boolean = false, finalizing: Boolean = false) {
        // Only a problem gets the line; idle and success states are the mic's and transcript's to say.
        val problem = (StatusLine.entries + ConnectionFailure.Kind.entries).firstOrNull { it.resolve(resources) == statusText }?.let { it.error || it.action != null } == true
        status.text = statusText
        status.visibility = if (problem) VISIBLE else GONE
        status.setTextColor(if (problem) colors.onErrorContainer else colors.muted)
        status.background = if (problem) GradientDrawable().apply { setColor(this@LegacyVoicePanel.colors.errorContainer); cornerRadius = context.dp(12).toFloat() } else null
        val content = text.ifEmpty { "Tap to dictate · hold to talk" }
        transcript.text = SpannableString(content).apply {
            if (text.isNotEmpty()) {
                val boundary = if (text.startsWith(stable)) stable.length else 0
                if (boundary < length) setSpan(ForegroundColorSpan(colors.muted), boundary, length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }
        }
        mic.text = when { finalizing -> "Finishing…"; active -> "Stop"; else -> "Tap to dictate" }
        mic.setIconResource(if (active) R.drawable.ic_stop else R.drawable.ic_mic)
        mic.isEnabled = !finalizing
        mic.contentDescription = if (active) "Microphone: stop dictation" else "Microphone: tap to toggle, hold to talk"
        ring.listening = active && !finalizing
        if (!active) ring.level = 0.0
    }
    fun level(value: Double) { ring.level = value }
}

/** Only invalidates when a new audio level arrives; no animation or timer while idle. */
private class LegacyLevelRing(context: Context) : View(context) {
    private val accent = VoicePalette.of(context).accent
    private var animator: ValueAnimator? = null
    var listening = false
        set(value) {
            field = value
            if (!value) { animator?.cancel(); animator = null; level = 0.0 }
        }
    var level = 0.0
        set(value) {
            animator?.cancel()
            val target = value.coerceIn(0.0, 1.0)
            if (!listening || !isAttachedToWindow) { field = target; invalidate(); return }
            animator = ValueAnimator.ofFloat(field.toFloat(), target.toFloat()).apply {
                duration = 160
                addUpdateListener { field = (it.animatedValue as Float).toDouble(); invalidate() }
                start()
            }
        }
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = context.dp(3).toFloat() }
    override fun onDetachedFromWindow() { animator?.cancel(); animator = null; super.onDetachedFromWindow() }
    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        paint.color = accent; paint.alpha = if (listening) 210 else 60
        val inset = context.dp(8).toFloat() - (max(0.0, level) * context.dp(5)).toFloat()
        canvas.drawRoundRect(width / 2f - context.dp(122) - level.toFloat() * context.dp(8), inset,
            width / 2f + context.dp(122) + level.toFloat() * context.dp(8), height - inset,
            context.dp(44).toFloat(), context.dp(44).toFloat(), paint)
    }
}
