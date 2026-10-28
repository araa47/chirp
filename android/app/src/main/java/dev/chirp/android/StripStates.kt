package dev.chirp.android

import android.graphics.Color
import androidx.core.graphics.ColorUtils

/** A row fill with the text colour that reads on it (≥ 4.5:1) and the accent that draws on it (≥ 3:1). */
internal data class StripTint(val fill: Int, val text: Int, val accent: Int)

/** What the strip row is showing; drives tint, leading icon and which controls appear. */
internal enum class StripKind { IDLE, CONNECTING, LISTENING, FINISHING, POLISHING, SUCCESS, NOTICE, ERROR }

/**
 * The state colour model: every tint is derived from the keyboard's own background, ink and accent,
 * so it follows the Gboard-like, Samsung-like and HeliBoard looks. Idle has no tint (HeliBoard's row shows through).
 */
internal data class StripTints(val listening: StripTint, val success: StripTint, val error: StripTint, val warning: StripTint, val solidError: StripTint) {
    fun of(kind: StripKind): StripTint? = when (kind) {
        StripKind.CONNECTING, StripKind.LISTENING, StripKind.FINISHING, StripKind.POLISHING -> listening
        StripKind.SUCCESS -> success
        StripKind.ERROR -> error
        StripKind.IDLE, StripKind.NOTICE -> null
    }

    companion object {
        const val TEXT = 4.5
        const val GRAPHIC = 3.0
        private val LIGHT_ERROR = 0xFFB3261E.toInt()
        private val DARK_ERROR = 0xFFF2B8B5.toInt()
        private val LIGHT_WARNING = 0xFF8A5100.toInt()
        private val DARK_WARNING = 0xFFFFB95C.toInt()

        fun derive(background: Int, ink: Int, accent: Int): StripTints {
            val base = background or 0xFF000000.toInt()
            val dark = ColorUtils.calculateLuminance(base) < .5
            val inkColor = ink or 0xFF000000.toInt()
            val listening = tint(base, accent, .20f, inkColor, accent)
            val success = tint(base, inkColor, .10f, inkColor, accent)
            val error = tint(base, if (dark) DARK_ERROR else LIGHT_ERROR, if (dark) .22f else .16f, inkColor, if (dark) DARK_ERROR else LIGHT_ERROR)
            val warning = tint(base, if (dark) DARK_WARNING else LIGHT_WARNING, if (dark) .22f else .16f, inkColor, if (dark) DARK_WARNING else LIGHT_WARNING)
            // Debug retention: a strong banner that keeps the one palette error colour, text picked for contrast.
            val solid = if (dark) 0xFF8C1D18.toInt() else LIGHT_ERROR
            return StripTints(listening, success, error, warning, StripTint(solid, readableOn(solid, inkColor), solid))
        }

        private fun tint(base: Int, hue: Int, amount: Float, ink: Int, graphic: Int): StripTint {
            val fill = ColorUtils.blendARGB(base, hue or 0xFF000000.toInt(), amount)
            return StripTint(fill, readableOn(fill, ink), readableOn(fill, graphic, GRAPHIC))
        }

        /** [preferred] if it reads on [fill], else the nearest of black or white that does. */
        fun readableOn(fill: Int, preferred: Int, ratio: Double = TEXT): Int {
            val opaque = preferred or 0xFF000000.toInt()
            if (ColorUtils.calculateContrast(opaque, fill) >= ratio) return opaque
            val target = if (ColorUtils.calculateLuminance(fill) > .5) Color.BLACK else Color.WHITE
            var result = opaque
            for (step in 1..10) {
                result = ColorUtils.blendARGB(opaque, target, step / 10f)
                if (ColorUtils.calculateContrast(result, fill) >= ratio) break
            }
            return result
        }
    }
}

/** m:ss, hours folded into minutes (a dictation never runs that long). */
internal fun elapsedLabel(millis: Long): String {
    val seconds = (millis / 1000).coerceAtLeast(0)
    return "${seconds / 60}:${(seconds % 60).toString().padStart(2, '0')}"
}

/** Spoken form of the timer, e.g. "1 minute 5 seconds". */
internal fun elapsedSpoken(resources: android.content.res.Resources, millis: Long): String {
    val seconds = (millis / 1000).coerceAtLeast(0)
    fun unit(count: Long, plural: Int) = resources.getQuantityString(plural, count.toInt(), count.toInt())
    return when {
        seconds < 60 -> unit(seconds, R.plurals.elapsed_seconds)
        seconds % 60 == 0L -> unit(seconds / 60, R.plurals.elapsed_minutes)
        else -> resources.getString(R.string.elapsed_minutes_seconds, unit(seconds / 60, R.plurals.elapsed_minutes), unit(seconds % 60, R.plurals.elapsed_seconds))
    }
}

internal fun actionSeconds(deadline: Long, now: Long): Int = ((deadline - now + 999) / 1000).toInt().coerceAtLeast(0)

/** Text ticks silently; the stable accessible name announces the offer once. */
internal class ActionCountdown(private val button: android.widget.TextView, private val label: String,
                               private val now: () -> Long = android.os.SystemClock::elapsedRealtime) {
    private var until: Long? = null
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())
    private val tick = object : Runnable {
        override fun run() {
            val left = until?.let { actionSeconds(it, now()) } ?: return
            button.text = button.resources.getString(R.string.action_countdown, label, left)
            if (left > 0) handler.postDelayed(this, 200)
        }
    }
    init {
        button.fontFeatureSettings = "tnum"
        button.accessibilityLiveRegion = android.view.View.ACCESSIBILITY_LIVE_REGION_NONE
        button.addOnAttachStateChangeListener(object : android.view.View.OnAttachStateChangeListener {
            override fun onViewAttachedToWindow(v: android.view.View) { handler.removeCallbacks(tick); if (until != null) tick.run() }
            override fun onViewDetachedFromWindow(v: android.view.View) { handler.removeCallbacks(tick) }
        })
    }
    fun show(available: Boolean, deadline: Long? = null) {
        if (!available) {
            until = null; handler.removeCallbacks(tick); button.text = label; button.contentDescription = label
            return
        }
        val next = deadline ?: until ?: (now() + 5000)
        if (next == until) return
        until = next
        val seconds = actionSeconds(next, now())
        button.contentDescription = button.resources.getQuantityString(R.plurals.action_available, seconds, label, seconds)
        if (button.isAttachedToWindow) button.announceForAccessibility(button.contentDescription)
        handler.removeCallbacks(tick); tick.run()
    }
}
