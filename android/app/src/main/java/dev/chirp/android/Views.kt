package dev.chirp.android

import android.content.Context
import android.graphics.Color
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat

internal fun Context.dp(value: Int) = (value * resources.displayMetrics.density).toInt()
internal fun Context.column() = LinearLayout(this).apply {
    orientation = LinearLayout.VERTICAL
    setPadding(dp(12), dp(8), dp(12), dp(8))
    setBackgroundColor(VoicePalette.of(this@column).background)
}
internal fun Context.label(value: String, size: Float = 16f) = TextView(this).apply {
    text = value; textSize = size; setTextColor(VoicePalette.of(this@label).ink)
    setPadding(dp(4), dp(5), dp(4), dp(5))
    isSaveEnabled = false
}
internal fun LinearLayout.button(value: String, action: () -> Unit): Button = Button(context).apply {
    text = value; minHeight = context.dp(48); setOnClickListener { action() }
    this@button.addView(this)
}
internal fun TextView.retention(show: Boolean) {
    setText(R.string.debug_retention)
    setTextColor(Color.WHITE); setBackgroundColor(Color.rgb(164, 24, 24))
    visibility = if (show) View.VISIBLE else View.GONE
}
internal fun View.systemInsets() {
    val left = paddingLeft; val top = paddingTop; val right = paddingRight; val bottom = paddingBottom
    ViewCompat.setOnApplyWindowInsetsListener(this) { view, insets ->
        val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
        view.setPadding(left + bars.left, top + bars.top, right + bars.right, bottom + bars.bottom)
        insets
    }
    ViewCompat.requestApplyInsets(this)
}
internal fun correctionLabel(health: Health?): UiText = when {
    health?.correctionLeavesMachine == true -> UiText.Res(R.string.options_cleanup_host, health.correctionHost ?: UiText.Res(R.string.options_cleanup_host_unavailable))
    else -> UiText.Res(R.string.options_cleanup_local)
}

internal fun Health?.cleanupAvailable() = this?.let { it.correctionAvailable && (!it.correctionLeavesMachine || it.correctionHost != null) } == true
internal fun cleanupDescription(health: Health?): UiText = if (health?.correctionLeavesMachine == true)
    UiText.Res(R.string.cleanup_description_host, health.correctionHost ?: UiText.Res(R.string.cleanup_description_external_host))
    else UiText.Res(R.string.cleanup_description_computer)
