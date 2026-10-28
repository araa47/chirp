package dev.chirp.android

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.text.TextUtils
import android.view.ContextThemeWrapper
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.WindowManager
import android.view.accessibility.AccessibilityNodeInfo
import android.view.animation.PathInterpolator
import android.widget.FrameLayout
import androidx.appcompat.widget.AppCompatImageView
import android.widget.TextView
import androidx.core.content.ContextCompat
import kotlin.math.roundToInt

/**
 * The floating mic's windows (#167): the edge-docked bubble, the hold-to-talk pill beside it, the panel and the
 * drag's "Hide here" target. Each is a [WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY]; nothing here
 * reads the screen or holds text beyond what the service hands it to draw.
 */
@SuppressLint("ClickableViewAccessibility")
internal class FloatingMicOverlay(context: Context, private val manager: WindowManager, private val store: SettingsStore,
                                  private val host: Host) {
    interface Host {
        fun tap()
        fun holdStart()
        fun holdEnd()
        fun holdCancel()
        fun hideHere()
    }
    private val context: Context = ContextThemeWrapper(context, R.style.Theme_Chirp)
    private val handler = Handler(Looper.getMainLooper())
    private val palette = VoicePalette.of(this.context)
    private val gesture = BubbleGesture(this.context.dp(BubbleGesture.SLOP_DP).toFloat())
    private val standard = PathInterpolator(.2f, 0f, 0f, 1f)
    private var field: Area? = null
    private var at: BubbleAt? = null
    private var grab = 0f to 0f
    private var bubbleRoot: FrameLayout? = null
    private var panelRoot: FrameLayout? = null
    private var targetRoot: FrameLayout? = null
    private var snap: ValueAnimator? = null
    private var leaving: ValueAnimator? = null
    /** The IME's top from the overlay's own insets, when Android hands them over (the #167 spike); else null. */
    private var rootImeTop: Int? = null
    val bubble = BubbleView(this.context, palette)
    private val ripple = RippleView(this.context).apply { color = palette.koiDecor }
    private val pill = TextView(this.context).apply {
        textSize = 15f; setTextColor(palette.ink); maxLines = 1; ellipsize = TextUtils.TruncateAt.START
        setPadding(this@FloatingMicOverlay.context.dp(14), 0, this@FloatingMicOverlay.context.dp(14), 0)
        gravity = Gravity.CENTER_VERTICAL; accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        background = GradientDrawable().apply {
            setColor(palette.card); cornerRadius = this@FloatingMicOverlay.context.dp(20).toFloat()
            setStroke(this@FloatingMicOverlay.context.dp(1), palette.outline)
        }
        elevation = this@FloatingMicOverlay.context.dp(3).toFloat()
    }
    var panel: VoicePanel? = null
        private set
    val bubbleShown get() = bubbleRoot != null && leaving == null
    val holding get() = ripple.parent != null
    val edge get() = at?.edge ?: BubbleEdge.RIGHT

    init {
        bubble.setOnTouchListener { _, event -> touch(event); true }
        bubble.setOnClickListener { host.tap() } // TalkBack's double tap; touch input goes through [touch].
        bubble.actions = { id ->
            when (id) {
                R.id.bubble_move_side -> { moveToOtherSide(); true }
                R.id.bubble_hide_here -> { host.hideHere(); true }
                else -> false
            }
        }
    }

    // ---- Geometry -------------------------------------------------------------------------------------------

    private fun metrics(): BubbleMetrics {
        val window = manager.currentWindowMetrics
        val bounds = window.bounds
        val insets = window.windowInsets
        val bars = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
        val ime = insets.getInsets(WindowInsets.Type.ime()).bottom.takeIf { it > 0 && insets.isVisible(WindowInsets.Type.ime()) }
        return BubbleMetrics(bounds.width(), bounds.height(), bars.top, bounds.height() - bars.bottom,
            size = context.dp(56), gap = context.dp(8), margin = context.dp(16),
            imeTop = ime?.let { bounds.height() - it } ?: rootImeTop)
    }
    private fun posture(m: BubbleMetrics) = BubblePlacement.posture(m.width, m.height, context.resources.displayMetrics.density)

    private fun params(width: Int, height: Int, x: Int, y: Int, touchable: Boolean = true) = WindowManager.LayoutParams(
        width, height, WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or (if (touchable) 0 else WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE),
        PixelFormat.TRANSLUCENT,
    ).apply {
        gravity = Gravity.TOP or Gravity.START
        this.x = x; this.y = y
        layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
        title = context.getString(R.string.bubble_window_title)
    }

    /** The overlay windows' ids, so the service ignores accessibility events from its own surfaces. */
    fun owns(windowId: Int): Boolean = listOfNotNull(bubbleRoot, panelRoot, targetRoot).any {
        it.isAttachedToWindow && it.createAccessibilityNodeInfo().windowId == windowId && windowId != -1
    }

    // ---- Bubble ----------------------------------------------------------------------------------------------

    /** Shows (fading in) or moves the bubble for the focused field; [copyMode] adds the clipboard badge. */
    fun showBubble(field: Area?, copyMode: Boolean) {
        this.field = field
        bubble.copyMode = copyMode
        if (gesture.dragging || holding) return
        val m = metrics()
        val spot = store.bubbleSpot(posture(m))
        val placed = BubblePlacement.bubble(m, field, spot)
        at = placed
        bubble.edge = placed.edge
        leaving?.cancel(); leaving = null
        val root = bubbleRoot
        if (root == null) {
            (bubble.parent as? ViewGroup)?.removeView(bubble)
            val created = FrameLayout(context).apply {
                clipChildren = false
                addView(bubble, FrameLayout.LayoutParams(m.size, m.size, Gravity.TOP or Gravity.START))
                setOnApplyWindowInsetsListener { _, insets ->
                    // The #167 IME spike: an accessibility overlay rarely gets IME insets; when it does, keep clear of them.
                    val ime = insets.getInsets(WindowInsets.Type.ime()).bottom
                    val top = if (ime > 0) metrics().height - ime else null
                    if (top != rootImeTop) { rootImeTop = top; handler.post { if (!gesture.dragging && !holding) showBubble(this@FloatingMicOverlay.field, bubble.copyMode) } }
                    insets
                }
            }
            bubbleRoot = created
            manager.addView(created, params(m.size, m.size, placed.x, placed.y))
            appear(bubble)
        } else {
            bubble.alpha = 1f; bubble.scaleX = 1f; bubble.scaleY = 1f
            manager.updateViewLayout(root, params(m.size, m.size, placed.x, placed.y))
        }
        bubble.describe()
    }

    /** Fades the bubble out (90 ms) or, for privacy exits and with animations off, removes it at once. */
    fun hideBubble(animated: Boolean) {
        val root = bubbleRoot ?: return
        gesture.cancel(); snap?.cancel(); snap = null
        removeTarget()
        if (holding) leaveHold()
        if (!animated || !ValueAnimator.areAnimatorsEnabled()) { leaving?.cancel(); leaving = null; remove(root); root.removeView(bubble); bubbleRoot = null; return }
        if (leaving != null) return
        leaving = ValueAnimator.ofFloat(1f, 0f).apply {
            duration = 90
            addUpdateListener { bubble.alpha = it.animatedValue as Float }
            addListener(object : AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: Animator) {
                    if (leaving !== animation) return
                    leaving = null; remove(root); root.removeView(bubble); if (bubbleRoot === root) bubbleRoot = null
                }
            })
            start()
        }
    }

    private fun appear(view: View) {
        if (!ValueAnimator.areAnimatorsEnabled()) { view.alpha = 1f; view.scaleX = 1f; view.scaleY = 1f; return }
        view.alpha = 0f; view.scaleX = .8f; view.scaleY = .8f
        view.animate().alpha(1f).scaleX(1f).scaleY(1f).setDuration(120).setInterpolator(standard).start()
    }

    private fun remove(view: View) {
        if (view.isAttachedToWindow || view.parent != null) runCatching { manager.removeViewImmediate(view) }
    }

    private fun touch(event: MotionEvent) {
        val now = SystemClock.uptimeMillis()
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                snap?.cancel(); snap = null
                gesture.down(now, event.rawX, event.rawY)
                val place = at ?: return
                grab = event.rawX - place.x to event.rawY - place.y
                handler.postDelayed(holdCheck, BubbleGesture.HOLD_MS)
            }
            MotionEvent.ACTION_MOVE -> when (gesture.move(now, event.rawX, event.rawY)) {
                BubbleGesture.Action.DRAG_START -> { handler.removeCallbacks(holdCheck); showTarget(); drag(event) }
                BubbleGesture.Action.DRAG -> drag(event)
                BubbleGesture.Action.HOLD_START -> { handler.removeCallbacks(holdCheck); host.holdStart() }
                else -> Unit
            }
            MotionEvent.ACTION_UP -> {
                handler.removeCallbacks(holdCheck)
                when (gesture.up(now, event.rawX, event.rawY)) {
                    BubbleGesture.Action.TAP -> host.tap()
                    BubbleGesture.Action.DROP -> drop()
                    BubbleGesture.Action.HOLD_END -> host.holdEnd()
                    else -> Unit
                }
            }
            MotionEvent.ACTION_CANCEL -> {
                handler.removeCallbacks(holdCheck)
                when (gesture.cancel()) {
                    BubbleGesture.Action.CANCEL -> host.holdCancel()
                    BubbleGesture.Action.DROP -> drop(cancelled = true)
                    else -> Unit
                }
            }
        }
    }
    private val holdCheck = Runnable {
        if (gesture.held(SystemClock.uptimeMillis()) == BubbleGesture.Action.HOLD_START) host.holdStart()
    }

    /** A drag moves only the window: no mic, no service, no indicator (#167). */
    private fun drag(event: MotionEvent) {
        val root = bubbleRoot ?: return
        val m = metrics()
        val moved = BubblePlacement.dragged(m, (event.rawX - grab.first).roundToInt(), (event.rawY - grab.second).roundToInt())
        at = moved
        manager.updateViewLayout(root, params(m.size, m.size, moved.x, moved.y))
        val target = targetRoot ?: return
        val over = BubblePlacement.overTarget(moved.x + m.size / 2, moved.y + m.size / 2, BubblePlacement.hideTarget(m, context.dp(64)))
        (target.getChildAt(0) as? TargetView)?.active = over
    }

    private fun drop(cancelled: Boolean = false) {
        val m = metrics()
        val place = at ?: return
        val overTarget = !cancelled && BubblePlacement.overTarget(place.x + m.size / 2, place.y + m.size / 2,
            BubblePlacement.hideTarget(m, context.dp(64)))
        removeTarget()
        if (overTarget) { host.hideHere(); return }
        val edge = BubblePlacement.nearestEdge(place.x + m.size / 2, m.width)
        val spot = BubbleSpot(edge, BubblePlacement.fraction(place.y, m))
        if (!cancelled) store.saveBubbleSpot(posture(m), spot) // Written only on drop.
        val home = BubblePlacement.bubble(m, field, spot)
        bubble.edge = home.edge
        animateTo(home)
    }

    private fun animateTo(home: BubbleAt) {
        val root = bubbleRoot ?: return
        val from = at ?: home
        at = home
        val size = context.dp(56)
        if (!ValueAnimator.areAnimatorsEnabled()) { manager.updateViewLayout(root, params(size, size, home.x, home.y)); bubble.describe(); return }
        snap?.cancel()
        snap = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 250; interpolator = standard
            addUpdateListener {
                val f = it.animatedValue as Float
                if (root.isAttachedToWindow) manager.updateViewLayout(root, params(size, size,
                    (from.x + (home.x - from.x) * f).roundToInt(), (from.y + (home.y - from.y) * f).roundToInt()))
            }
            start()
        }
        bubble.describe()
    }

    /** TalkBack's "Move to other side". */
    fun moveToOtherSide() {
        val m = metrics()
        val place = at ?: return
        val edge = if (place.edge == BubbleEdge.LEFT) BubbleEdge.RIGHT else BubbleEdge.LEFT
        val spot = BubbleSpot(edge, BubblePlacement.fraction(place.y, m))
        store.saveBubbleSpot(posture(m), spot)
        bubble.edge = edge
        animateTo(BubblePlacement.bubble(m, field, spot))
    }

    private fun showTarget() {
        if (targetRoot != null) return
        val m = metrics()
        val size = context.dp(64)
        val area = BubblePlacement.hideTarget(m, size)
        val root = FrameLayout(context).apply { addView(TargetView(context, palette), FrameLayout.LayoutParams(size, size)) }
        targetRoot = root
        manager.addView(root, params(size, size, area.left, area.top, touchable = false))
        appear(root.getChildAt(0))
    }
    private fun removeTarget() { targetRoot?.let(::remove); targetRoot = null }

    // ---- Hold to talk ----------------------------------------------------------------------------------------

    /** Hold to talk: the Ripple around the bubble and a one-line partials pill beside it, instead of the panel. */
    fun enterHold() {
        val root = bubbleRoot ?: return
        val place = at ?: return
        val m = metrics()
        val height = context.dp(96)
        val width = minOf(context.dp(360), m.width - context.dp(16))
        val left = if (place.edge == BubbleEdge.LEFT) 0 else m.width - width
        val top = (place.y - (height - m.size) / 2).coerceIn(0, m.height - height)
        val inner = if (place.edge == BubbleEdge.LEFT) Gravity.START else Gravity.END
        bubble.layoutParams = FrameLayout.LayoutParams(m.size, m.size, inner or Gravity.TOP).apply { topMargin = place.y - top }
        root.addView(ripple, 0, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        root.addView(pill, FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, context.dp(40), inner or Gravity.TOP).apply {
            topMargin = place.y - top + (m.size - context.dp(40)) / 2
            marginStart = if (place.edge == BubbleEdge.LEFT) m.size + context.dp(20) else context.dp(8)
            marginEnd = if (place.edge == BubbleEdge.RIGHT) m.size + context.dp(20) else context.dp(8)
        })
        bubble.holding = true
        manager.updateViewLayout(root, params(width, height, left, top))
        root.post { anchorRipple() }
    }
    private fun anchorRipple() {
        val inset = context.dp(4).toFloat()
        ripple.anchor(bubble.left + inset, bubble.top + inset, bubble.right - inset, bubble.bottom - inset)
    }
    /** Updates the hold pill; [ring] is the Ripple's mode, [touchable] false once the finger is up. */
    fun hold(text: String, ring: RippleView.Mode, level: Double, touchable: Boolean = true) {
        if (!holding) return
        pill.text = text
        ripple.mode = ring; ripple.level = level.toFloat(); anchorRipple()
        val root = bubbleRoot ?: return
        val params = root.layoutParams as? WindowManager.LayoutParams ?: return
        val flag = WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
        val wanted = if (touchable) params.flags and flag.inv() else params.flags or flag
        if (wanted != params.flags) { params.flags = wanted; manager.updateViewLayout(root, params) }
    }
    fun level(value: Double) { if (holding) ripple.level = value.toFloat() }
    fun leaveHold() {
        val root = bubbleRoot
        if (!holding) return
        root?.removeView(ripple); root?.removeView(pill)
        ripple.mode = RippleView.Mode.OFF
        bubble.holding = false
        val size = context.dp(56)
        bubble.layoutParams = FrameLayout.LayoutParams(size, size, Gravity.TOP or Gravity.START)
        val place = at
        if (root != null && place != null) manager.updateViewLayout(root, params(size, size, place.x, place.y))
    }

    // ---- Panel -----------------------------------------------------------------------------------------------

    /** Expands into the panel: a fresh [VoicePanel] the service wires, with the bubble hidden behind it. */
    fun openPanel(): VoicePanel {
        panelRoot?.let(::remove)
        if (holding) leaveHold()
        val view = VoicePanel(context)
        val root = FrameLayout(context).apply {
            clipChildren = false; clipToPadding = false
            setPadding(context.dp(6), context.dp(6), context.dp(6), context.dp(6))
            addView(view)
        }
        panel = view; panelRoot = root
        bubbleRoot?.let { gesture.cancel(); remove(it); it.removeView(bubble) }; bubbleRoot = null; leaving?.cancel(); leaving = null
        val m = metrics()
        manager.addView(root, params(context.dp(360), WindowManager.LayoutParams.WRAP_CONTENT, 0, m.safeTop, touchable = true))
        placePanel()
        appear(view)
        return view
    }

    /** Re-measures the panel and places it above the field when there is room, otherwise below (#167). */
    fun placePanel(field: Area? = this.field) {
        this.field = field
        val root = panelRoot ?: return
        val m = metrics()
        val pad = context.dp(6)
        val width = minOf(context.dp(360), m.width - 2 * m.margin) + 2 * pad
        root.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(m.height, View.MeasureSpec.AT_MOST))
        val area = BubblePlacement.panel(m.copy(margin = m.margin - pad), field, edge, at?.y ?: m.height / 2,
            context.dp(360) + 2 * pad, root.measuredHeight)
        manager.updateViewLayout(root, params(area.width, WindowManager.LayoutParams.WRAP_CONTENT, area.left, area.top))
    }

    fun closePanel() { panelRoot?.let(::remove); panelRoot = null; panel = null }

    fun removeAll() {
        handler.removeCallbacksAndMessages(null)
        snap?.cancel(); snap = null; leaving?.cancel(); leaving = null
        gesture.cancel()
        if (holding) { bubbleRoot?.removeView(ripple); bubbleRoot?.removeView(pill); bubble.holding = false }
        listOfNotNull(bubbleRoot, panelRoot, targetRoot).forEach(::remove)
        bubbleRoot = null; panelRoot = null; targetRoot = null; panel = null
        (bubble.parent as? ViewGroup)?.removeView(bubble)
    }
}

/**
 * The 48 dp Pond disc on a 56 dp touch target: `surfaceRaised` with a 1.5 dp koi ring and the Material Symbols
 * Rounded mic in koi, plus the one overlay shadow (it floats over other apps). Copy mode adds a clipboard badge.
 */
@SuppressLint("ViewConstructor")
internal class BubbleView(context: Context, private val palette: VoicePalette) : View(context) {
    private val disc = Paint(Paint.ANTI_ALIAS_FLAG)
    private val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = context.dp(3) / 2f }
    private val badgeFill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val badgeEdge = Paint(Paint.ANTI_ALIAS_FLAG)
    private val mic: Drawable = ContextCompat.getDrawable(context, R.drawable.ic_mic)!!.mutate()
    private val clip: Drawable = ContextCompat.getDrawable(context, R.drawable.ic_copy)!!.mutate()
    var actions: (Int) -> Boolean = { false }
    var edge = BubbleEdge.RIGHT
        set(value) { field = value; invalidate() }
    var copyMode = false
        set(value) { if (field != value) { field = value; invalidate(); describe() } }
    /** Hold to talk: the disc fills koi while the Ripple runs around it. */
    var holding = false
        set(value) { field = value; invalidate() }

    init {
        isClickable = true; isFocusable = true
        describe()
    }
    fun describe() {
        contentDescription = context.getString(if (copyMode) R.string.bubble_description_copy else R.string.bubble_description)
    }
    override fun onInitializeAccessibilityNodeInfo(info: AccessibilityNodeInfo) {
        super.onInitializeAccessibilityNodeInfo(info)
        info.className = android.widget.Button::class.java.name
        info.addAction(AccessibilityNodeInfo.AccessibilityAction(R.id.bubble_move_side, context.getString(R.string.bubble_action_move_side)))
        info.addAction(AccessibilityNodeInfo.AccessibilityAction(R.id.bubble_hide_here, context.getString(R.string.bubble_action_hide)))
    }
    override fun performAccessibilityAction(action: Int, arguments: Bundle?): Boolean =
        actions(action) || super.performAccessibilityAction(action, arguments)

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val cx = width / 2f; val cy = height / 2f
        val radius = context.dp(24).toFloat()
        disc.color = if (holding) palette.accent else palette.surface
        disc.setShadowLayer(context.dp(3).toFloat(), 0f, context.dp(1).toFloat(), 0x40000000)
        canvas.drawCircle(cx, cy, radius, disc)
        ring.color = palette.accent
        canvas.drawCircle(cx, cy, radius - ring.strokeWidth / 2f, ring)
        val icon = context.dp(24) / 2
        mic.setTint(if (holding) palette.onAccent else palette.accent)
        mic.setBounds((cx - icon).toInt(), (cy - icon).toInt(), (cx + icon).toInt(), (cy + icon).toInt())
        mic.draw(canvas)
        if (copyMode) {
            // The badge sits on the inner side, away from the screen edge.
            val badge = context.dp(9).toFloat()
            val bx = if (edge == BubbleEdge.RIGHT) cx - radius * .62f else cx + radius * .62f
            val by = cy + radius * .62f
            badgeFill.color = palette.accent
            badgeEdge.color = palette.surface
            canvas.drawCircle(bx, by, badge + context.dp(1), badgeEdge)
            canvas.drawCircle(bx, by, badge, badgeFill)
            val half = context.dp(6)
            clip.setTint(palette.onAccent)
            clip.setBounds((bx - half).toInt(), (by - half).toInt(), (bx + half).toInt(), (by + half).toInt())
            clip.draw(canvas)
        }
    }
}

/** The drag's "Hide here" target: a koi-outlined ✕ that fills when the bubble is over it. */
@SuppressLint("ViewConstructor")
private class TargetView(context: Context, private val palette: VoicePalette) : AppCompatImageView(context) {
    var active = false
        set(value) { if (field != value) { field = value; paint() } }
    init {
        setImageResource(R.drawable.ic_close); scaleType = ScaleType.CENTER
        contentDescription = context.getString(R.string.bubble_hide_here)
        paint()
    }
    private fun paint() {
        background = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(if (active) palette.accent else palette.card)
            setStroke(context.dp(2), palette.accent)
        }
        imageTintList = android.content.res.ColorStateList.valueOf(if (active) palette.onAccent else palette.accent)
    }
}

