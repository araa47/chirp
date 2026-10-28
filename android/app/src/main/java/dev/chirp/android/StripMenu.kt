package dev.chirp.android

import android.annotation.SuppressLint
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.text.TextUtils
import android.view.ContextThemeWrapper
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.ViewOutlineProvider
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.PopupWindow
import android.widget.ScrollView
import android.widget.TextView
import androidx.core.graphics.ColorUtils
import androidx.core.graphics.drawable.toDrawable
import androidx.core.view.AccessibilityDelegateCompat
import androidx.core.view.ViewCompat
import androidx.core.view.accessibility.AccessibilityNodeInfoCompat
import com.google.android.material.materialswitch.MaterialSwitch

/**
 * The strip's options menu: a Material-styled panel in a [PopupWindow] (an IME can't host Compose popups cheaply) with
 * section headings, a switch row, radio rows and icon rows. Colours come from the keyboard's own theme so it matches
 * every look. Rows expose switch / radio role and checked state to TalkBack; a radio choice closes the menu, a switch stays open.
 */
@SuppressLint("ViewConstructor")
internal class StripMenu(private val anchor: View) {
    private val context: Context = ContextThemeWrapper(anchor.context, R.style.Theme_Chirp)
    private val colors = StripColors.of(context)
    private val surface = ColorUtils.blendARGB(colors.background, colors.ink, .08f)
    private val list = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL; setPadding(0, context.dp(8), 0, context.dp(8)) }
    private var popup: PopupWindow? = null
    private var first = true

    /** The menu body; tests and [show] share it. */
    val content: View = ScrollView(context).apply {
        addView(list); isFillViewport = false; accessibilityPaneTitle = context.getString(R.string.strip_options)
        background = GradientDrawable().apply { setColor(surface); cornerRadius = context.dp(16).toFloat() }
        clipToOutline = true; outlineProvider = ViewOutlineProvider.BACKGROUND; elevation = context.dp(8).toFloat()
    }

    init {
        toggle(context.getString(R.string.options_private), context.getString(R.string.options_private_detail), PrivateSession.enabled) { PrivateSession.set(it) }
    }

    private fun text(value: String, size: Float, color: Int) = TextView(context).apply {
        text = value; textSize = size; setTextColor(color); isSaveEnabled = false
    }
    private fun row(minHeight: Int = 48) = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
        minimumHeight = context.dp(minHeight); setPadding(context.dp(16), context.dp(4), context.dp(16), context.dp(4))
        val ripple = android.util.TypedValue().also { context.theme.resolveAttribute(android.R.attr.selectableItemBackground, it, true) }
        if (ripple.resourceId != 0) setBackgroundResource(ripple.resourceId)
        isClickable = true; isFocusable = true
    }
    private fun add(view: View, params: LinearLayout.LayoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)) { list.addView(view, params); first = false }
    private fun labels(label: String, detail: String?) = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        addView(text(label, 15f, colors.ink).apply { maxLines = 2; ellipsize = TextUtils.TruncateAt.END })
        if (detail != null) addView(text(detail, 12f, colors.muted).apply { maxLines = 2; ellipsize = TextUtils.TruncateAt.END })
    }
    private fun role(view: View, className: String, checked: Boolean?, label: String) {
        view.contentDescription = label
        ViewCompat.setAccessibilityDelegate(view, object : AccessibilityDelegateCompat() {
            override fun onInitializeAccessibilityNodeInfo(host: View, info: AccessibilityNodeInfoCompat) {
                super.onInitializeAccessibilityNodeInfo(host, info)
                info.className = className
                if (checked != null) { info.isCheckable = true; info.isChecked = checked }
            }
        })
    }

    fun section(title: String) {
        if (!first) add(View(context).apply { setBackgroundColor(colors.muted and 0x00ffffff or 0x33000000) },
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 1).apply { topMargin = context.dp(4); bottomMargin = context.dp(4) })
        add(text(title, 12f, colors.muted).apply {
            setTypeface(typeface, Typeface.BOLD); letterSpacing = .04f; isAllCaps = false
            setPadding(context.dp(16), context.dp(8), context.dp(16), context.dp(4))
        }.also { ViewCompat.setAccessibilityHeading(it, true) })
    }
    fun note(value: String) = add(text(value, 14f, colors.muted).apply { setPadding(context.dp(16), context.dp(12), context.dp(16), context.dp(12)) })

    fun toggle(label: String, detail: String?, checked: Boolean, onChange: (Boolean) -> Unit) {
        var value = checked
        val control = MaterialSwitch(context).apply {
            isChecked = checked; isClickable = false; isFocusable = false; importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            val states = arrayOf(intArrayOf(android.R.attr.state_checked), intArrayOf())
            thumbTintList = ColorStateList(states, intArrayOf(colors.onAccent, colors.muted))
            trackTintList = ColorStateList(states, intArrayOf(colors.accent, ColorUtils.blendARGB(surface, colors.ink, .12f)))
            trackDecorationTintList = ColorStateList(states, intArrayOf(Color.TRANSPARENT, colors.muted))
        }
        val line = row(56).apply {
            addView(labels(label, detail), LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            addView(control)
        }
        role(line, "android.widget.Switch", value, label + (detail?.let { ", $it" } ?: ""))
        line.setOnClickListener {
            value = !value; control.isChecked = value; role(line, "android.widget.Switch", value, label + (detail?.let { ", $it" } ?: ""))
            line.sendAccessibilityEvent(android.view.accessibility.AccessibilityEvent.TYPE_VIEW_CLICKED); onChange(value)
        }
        add(line)
    }

    fun radio(label: String, note: String?, selected: Boolean, onSelect: () -> Unit) {
        val line = row().apply {
            addView(Dot(context, selected, colors.accent, colors.muted), LinearLayout.LayoutParams(context.dp(20), context.dp(20)).apply { marginEnd = context.dp(16) })
            addView(text(label, 15f, colors.ink).apply { maxLines = 1; ellipsize = TextUtils.TruncateAt.END }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            if (note != null) addView(text(note, 12f, colors.muted).apply { setPadding(context.dp(8), 0, 0, 0) })
        }
        role(line, "android.widget.RadioButton", selected, label + (note?.let { ", $it" } ?: ""))
        line.setOnClickListener { popup?.dismiss(); onSelect() }
        add(line)
    }

    fun item(icon: Int, label: String, onClick: () -> Unit) {
        val line = row().apply {
            addView(ImageView(context).apply { setImageResource(icon); imageTintList = ColorStateList.valueOf(colors.muted); importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO },
                LinearLayout.LayoutParams(context.dp(20), context.dp(20)).apply { marginEnd = context.dp(16) })
            addView(text(label, 15f, colors.ink), LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        }
        role(line, "android.widget.Button", null, label)
        line.setOnClickListener { popup?.dismiss(); onClick() }
        add(line)
    }

    /** Opens above the anchor, end-aligned (below it when there is no room above); a tall menu scrolls instead of leaving the screen. */
    fun show() {
        val width = minOf(context.dp(288), context.resources.displayMetrics.widthPixels - context.dp(16))
        content.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
        val top = IntArray(2).also(anchor::getLocationOnScreen)[1]
        val above = top - context.dp(8)
        val below = context.resources.displayMetrics.heightPixels - top - anchor.height
        val up = above >= content.measuredHeight || above > below
        val height = minOf(content.measuredHeight, if (up) above else below)
        popup = PopupWindow(content, width, height, true).apply {
            setBackgroundDrawable(Color.TRANSPARENT.toDrawable()); isOutsideTouchable = true; elevation = context.dp(8).toFloat()
        }
        try { popup?.showAsDropDown(anchor, anchor.width - width, if (up) -(anchor.height + height) else 0) } catch (_: RuntimeException) { popup = null }
    }
    fun dismiss() { popup?.dismiss() }
}

/** A radio indicator: ring, with a filled dot when selected. */
@SuppressLint("ViewConstructor")
private class Dot(context: Context, private val selected: Boolean, private val accent: Int, private val idle: Int) : View(context) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    init { importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO }
    override fun onDraw(canvas: Canvas) {
        val c = width / 2f; val ring = context.dp(2).toFloat()
        paint.style = Paint.Style.STROKE; paint.strokeWidth = ring; paint.color = if (selected) accent else idle
        canvas.drawCircle(c, height / 2f, c - ring / 2, paint)
        if (selected) { paint.style = Paint.Style.FILL; canvas.drawCircle(c, height / 2f, c * .5f, paint) }
    }
}
