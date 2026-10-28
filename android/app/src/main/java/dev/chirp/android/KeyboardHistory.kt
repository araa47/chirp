package dev.chirp.android

import android.annotation.SuppressLint
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.res.Resources
import android.graphics.Typeface
import android.inputmethodservice.InputMethodService
import android.os.Handler
import android.os.Looper
import android.text.TextUtils
import android.util.TypedValue
import android.view.ContextThemeWrapper
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.core.view.AccessibilityDelegateCompat
import androidx.core.view.ViewCompat
import androidx.core.view.isNotEmpty
import androidx.core.view.isVisible
import androidx.core.view.accessibility.AccessibilityNodeInfoCompat
import com.google.android.material.button.MaterialButton
import java.util.UUID
import java.util.concurrent.Executors

/** Records finals; implemented by the keyboard history so dictation stays unaware of storage. */
internal interface HistoryRecorder {
    fun record(text: String, raw: String?, info: EditorInfo?, partial: Boolean = false): String?
    fun usedRaw(id: String)
}

/** One background thread: Keystore and file work never runs on the IME's main thread. */
internal object HistoryIo {
    private val executor = Executors.newSingleThreadExecutor { Thread(it, "chirp-history").apply { isDaemon = true } }
    fun run(work: () -> Unit) { executor.execute { try { work() } catch (_: Exception) { /* History is best effort and never logged. */ } } }
}

/** How long ago, short and spoken: "5 min ago" and "5 minutes ago". */
internal fun historyAge(resources: Resources, now: Long, time: Long): Pair<String, String> {
    val minutes = (now - time).coerceAtLeast(0) / 60_000
    val hours = minutes / 60
    val days = hours / 24
    fun plural(id: Int, count: Long) = resources.getQuantityString(id, count.toInt(), count.toInt())
    return when {
        minutes < 1 -> resources.getString(R.string.age_just_now).let { it to it }
        minutes < 60 -> resources.getString(R.string.age_minutes, minutes.toInt()) to plural(R.plurals.age_minutes_spoken, minutes)
        hours < 24 -> resources.getString(R.string.age_hours, hours.toInt()) to plural(R.plurals.age_hours_spoken, hours)
        days == 1L -> resources.getString(R.string.age_yesterday).let { it to it }
        else -> plural(R.plurals.age_days, days) to plural(R.plurals.age_days_spoken, days)
    }
}

/**
 * In-keyboard history panel. It overlays HeliBoard's key area (like the clipboard panel) so the
 * keyboard keeps its height and insets; back or the keyboard button returns to the keys.
 */
internal class KeyboardHistory(
    private val host: InputMethodService,
    private val insert: (String) -> Boolean,
    private val store: DictationHistory = DictationHistory(host),
    private val io: (() -> Unit) -> Unit = HistoryIo::run,
    private val clock: () -> Long = System::currentTimeMillis,
) : HistoryRecorder {
    enum class State { CLOSED, OPT_IN, LOADING, LIST, LOCKED }
    private val handler = Handler(Looper.getMainLooper())
    var state = State.CLOSED
        private set
    var entries: List<HistoryEntry> = emptyList()
        private set
    var panel: HistoryPanel? = null
        private set
    private var strip: KeyboardStrip? = null
    private var keys: View? = null
    private var wrapper: ViewGroup? = null
    private var generation = 0
    val open get() = state != State.CLOSED

    // HeliBoard's wrapper lays out only the keyboard in one-handed mode; keep the panel over the whole key area.
    private val follow = View.OnLayoutChangeListener { _, left, top, right, bottom, _, _, _, _ ->
        val view = panel?.takeIf { it.isVisible } ?: return@OnLayoutChangeListener
        val width = right - left; val height = bottom - top
        if (view.left != 0 || view.top != 0 || view.width != width || view.height != height) {
            view.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY))
            view.layout(0, 0, width, height)
        }
    }

    fun mount(keyboard: View, strip: KeyboardStrip) {
        val reopen = open // HeliBoard recreates its views on fold/theme changes; keep the panel open across them.
        close()
        wrapper?.removeOnLayoutChangeListener(follow)
        val frame = keyboard.findViewById<ViewGroup>(helium314.keyboard.latin.R.id.keyboard_view_wrapper) ?: return
        frame.findViewWithTag<View>(TAG)?.let(frame::removeView)
        val view = HistoryPanel(ContextThemeWrapper(host, R.style.Theme_Chirp)).apply { tag = TAG; visibility = View.GONE }
        frame.addView(view, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        frame.addOnLayoutChangeListener(follow)
        view.close.setOnClickListener { close() }
        view.manage.setOnClickListener { manage() }
        strip.history.setOnClickListener { toggle() }
        wrapper = frame; panel = view; this.strip = strip
        keys = frame.findViewById(helium314.keyboard.latin.R.id.keyboard_view)
        strip.historyOpen(false)
        if (reopen) open()
    }

    fun toggle() = if (open) close() else open()

    fun open() {
        val view = panel ?: return
        state = when { !store.available -> State.LOCKED; else -> State.LOADING }
        view.visibility = View.VISIBLE
        // The accessibility framework still serves HeliBoard's virtual key nodes under
        // NO_HIDE_DESCENDANTS; an invisible view leaves the tree entirely. Layout is unchanged.
        keys?.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        keys?.visibility = View.INVISIBLE
        strip?.historyOpen(true)
        render()
        if (state == State.LOADING) load()
    }

    fun close() {
        if (state == State.CLOSED && panel?.visibility != View.VISIBLE) return
        state = State.CLOSED; ++generation
        entries = emptyList() // Plaintext lives only while the panel is open.
        panel?.apply { visibility = View.GONE; list.removeAllViews() }
        keys?.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_AUTO
        keys?.visibility = View.VISIBLE
        strip?.historyOpen(false)
    }

    fun shown() { io { store.pruneIfDue() } }

    fun destroy() { close(); wrapper?.removeOnLayoutChangeListener(follow); wrapper = null; panel = null; strip = null; keys = null }

    fun enable() {
        store.enable()
        if (open) { state = State.LOADING; render(); load() }
    }

    private fun load() {
        val id = ++generation
        io {
            val result = try { store.entries() } catch (_: Exception) { emptyList() }
            handler.post { if (id == generation && state == State.LOADING) { entries = result; state = if (!store.enabled && result.isEmpty()) State.OPT_IN else State.LIST; render() } }
        }
    }

    override fun record(text: String, raw: String?, info: EditorInfo?, partial: Boolean): String? {
        val source = info ?: return null
        if (PrivateSession.enabled || !store.enabled || !DictationHistory.allowed(source)) return null
        val editor = EditorInfo().apply { inputType = source.inputType; imeOptions = source.imeOptions; packageName = source.packageName }
        val target = source.packageName
        val id = UUID.randomUUID().toString()
        io { store.record(text, raw, label(target), editor, id, partial) }
        return id
    }

    override fun usedRaw(id: String) { io { store.usedRaw(id) } }

    private fun label(target: String?): String? = try {
        target?.let { host.packageManager.getApplicationLabel(host.packageManager.getApplicationInfo(it, 0)).toString() }
    } catch (_: Exception) { null }

    private fun manage() {
        close()
        host.requestHideSelf(0)
        host.startActivity(Intent(host, HistoryActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP))
    }

    fun insertEntry(entry: HistoryEntry, raw: Boolean = false) {
        val value = (if (raw) entry.raw else entry.text) ?: return
        if (insert(value)) close()
    }
    fun copy(entry: HistoryEntry, raw: Boolean = false) {
        val value = (if (raw) entry.raw else entry.text) ?: return
        host.getSystemService(ClipboardManager::class.java)?.setPrimaryClip(ClipData.newPlainText("Chirp dictation", value))
    }
    fun delete(entry: HistoryEntry) {
        entries = entries.filterNot { it.id == entry.id }
        io { store.delete(entry.id) }
        render()
    }

    private fun render() {
        val view = panel ?: return
        view.list.removeAllViews()
        val kept = store.retention.label(host.resources)
        view.subtitle.text = host.getString(if (store.enabled) R.string.keyboard_history_subtitle_on else R.string.keyboard_history_subtitle_off, kept)
        view.manage.visibility = if (state == State.LOCKED) View.GONE else View.VISIBLE
        when (state) {
            State.CLOSED -> Unit
            State.LOCKED -> view.message(host.getString(R.string.keyboard_history_locked))
            State.OPT_IN -> {
                view.subtitle.text = host.getString(R.string.keyboard_history_subtitle_never)
                view.message(host.getString(R.string.keyboard_history_offer, kept))
                view.action(host.getString(R.string.keyboard_history_keep), primary = true) { enable() }
                view.action(host.getString(R.string.keyboard_history_not_now), primary = false) { close() }
            }
            State.LOADING -> view.message(host.getString(R.string.keyboard_history_loading))
            State.LIST -> if (entries.isEmpty()) view.message(host.getString(R.string.keyboard_history_empty, kept))
                else { val now = clock(); entries.forEach { entry -> view.row(entry, now, this) } }
        }
    }

    companion object { const val TAG = "chirp_history" }
}

@SuppressLint("ViewConstructor")
internal class HistoryPanel(context: Context) : LinearLayout(context) {
    private val colors = VoicePalette.of(context)
    val title = context.label(context.getString(R.string.history_title), 15f).apply { setTypeface(typeface, Typeface.BOLD) }
    val subtitle = context.label("", 12f).apply { setTextColor(colors.muted); setPadding(context.dp(4), 0, context.dp(4), 0) }
    val manage = MaterialButton(context, null, android.R.attr.borderlessButtonStyle).apply {
        text = context.getString(R.string.keyboard_history_manage); contentDescription = context.getString(R.string.keyboard_history_manage_description); isSaveEnabled = false
        isAllCaps = false; setTextColor(colors.accent)
    }
    val close = MaterialButton(context, null, android.R.attr.borderlessButtonStyle).apply {
        text = ""; setIconResource(R.drawable.ic_keyboard); iconPadding = 0; iconGravity = MaterialButton.ICON_GRAVITY_TEXT_START
        iconTint = android.content.res.ColorStateList.valueOf(colors.accent)
        minWidth = 0; minimumWidth = 0; setPadding(0, 0, 0, 0); insetTop = 0; insetBottom = 0
        contentDescription = context.getString(R.string.keyboard_history_back); isSaveEnabled = false
    }
    val list = LinearLayout(context).apply { orientation = VERTICAL }
    private val scroll = ScrollView(context).apply { addView(list); isFillViewport = true }
    init {
        orientation = VERTICAL
        setBackgroundColor(colors.background)
        isClickable = true // Touches on empty panel space must never reach the keys underneath.
        accessibilityPaneTitle = context.getString(R.string.history_title)
        val header = LinearLayout(context).apply {
            gravity = Gravity.CENTER_VERTICAL
            setPadding(context.dp(12), context.dp(6), context.dp(4), context.dp(2))
            addView(LinearLayout(context).apply {
                orientation = VERTICAL
                addView(title.apply { setPadding(context.dp(4), 0, context.dp(4), 0) }); addView(subtitle)
            }, LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f))
            addView(manage, LayoutParams(LayoutParams.WRAP_CONTENT, context.dp(48)))
            addView(close, LayoutParams(context.dp(48), context.dp(48)))
        }
        addView(header, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        addView(divider(), LayoutParams(LayoutParams.MATCH_PARENT, 1))
        addView(scroll, LayoutParams(LayoutParams.MATCH_PARENT, 0, 1f))
    }
    private fun divider() = View(context).apply { setBackgroundColor(colors.muted and 0x00ffffff or 0x33000000) }
    fun message(text: String) {
        list.addView(context.label(text, 14f).apply {
            setTextColor(colors.ink); setPadding(context.dp(16), context.dp(12), context.dp(16), context.dp(8))
        })
    }
    fun action(text: String, primary: Boolean, click: () -> Unit) {
        val button = if (primary) MaterialButton(context) else MaterialButton(context, null, android.R.attr.borderlessButtonStyle)
        if (!primary) button.setTextColor(colors.accent)
        list.addView(button.apply { this.text = text; isAllCaps = false; isSaveEnabled = false; setOnClickListener { click() } },
            LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply {
                marginStart = context.dp(16); marginEnd = context.dp(16)
            })
    }
    fun row(entry: HistoryEntry, now: Long, owner: KeyboardHistory) {
        val (age, spokenAge) = historyAge(resources, now, entry.time)
        val polished = context.getString(R.string.keyboard_history_polished).takeIf { entry.raw != null }
        val meta = listOfNotNull(age, entry.app, polished, context.getString(R.string.keyboard_history_partial).takeIf { entry.partial }).joinToString(" · ")
        val ripple = TypedValue().also { context.theme.resolveAttribute(android.R.attr.selectableItemBackground, it, true) }
        val row = LinearLayout(context).apply {
            orientation = VERTICAL; minimumHeight = context.dp(56)
            setPadding(context.dp(16), context.dp(8), context.dp(16), context.dp(8))
            if (ripple.resourceId != 0) setBackgroundResource(ripple.resourceId)
            addView(context.label(entry.text, 15f).apply {
                maxLines = 2; ellipsize = TextUtils.TruncateAt.END; setPadding(0, 0, 0, 0)
            })
            addView(context.label(meta, 12f).apply { setTextColor(colors.muted); setPadding(0, context.dp(2), 0, 0) })
            val where = entry.app?.let { context.getString(R.string.keyboard_history_age_in_app, spokenAge, it) } ?: spokenAge
            contentDescription = listOfNotNull(entry.text, where, polished, context.getString(R.string.keyboard_history_partial_spoken).takeIf { entry.partial })
                .joinToString(". ")
            setOnClickListener { owner.insertEntry(entry) }
            setOnLongClickListener { menu(this, entry, owner); true }
        }
        ViewCompat.setAccessibilityDelegate(row, object : AccessibilityDelegateCompat() {
            override fun onInitializeAccessibilityNodeInfo(host: View, info: AccessibilityNodeInfoCompat) {
                super.onInitializeAccessibilityNodeInfo(host, info)
                info.addAction(AccessibilityNodeInfoCompat.AccessibilityActionCompat(AccessibilityNodeInfoCompat.ACTION_CLICK, context.getString(R.string.keyboard_history_insert)))
                info.addAction(AccessibilityNodeInfoCompat.AccessibilityActionCompat(AccessibilityNodeInfoCompat.ACTION_LONG_CLICK, context.getString(R.string.keyboard_history_more)))
            }
        })
        ViewCompat.addAccessibilityAction(row, context.getString(R.string.keyboard_history_copy)) { _, _ -> owner.copy(entry); true }
        if (entry.raw != null) ViewCompat.addAccessibilityAction(row, context.getString(R.string.keyboard_history_insert_raw)) { _, _ -> owner.insertEntry(entry, raw = true); true }
        ViewCompat.addAccessibilityAction(row, context.getString(R.string.keyboard_history_delete)) { _, _ -> owner.delete(entry); true }
        if (list.isNotEmpty()) list.addView(divider(), LayoutParams(LayoutParams.MATCH_PARENT, 1).apply { marginStart = context.dp(16) })
        list.addView(row, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
    }
    private fun menu(anchor: View, entry: HistoryEntry, owner: KeyboardHistory) {
        StripMenu(anchor).apply {
            item(R.drawable.ic_copy, context.getString(R.string.keyboard_history_copy)) { owner.copy(entry) }
            if (entry.raw != null) item(R.drawable.ic_undo, context.getString(R.string.keyboard_history_insert_raw)) { owner.insertEntry(entry, raw = true) }
            item(R.drawable.ic_delete, context.getString(R.string.keyboard_history_delete)) { owner.delete(entry) }
            show()
        }
    }
}
