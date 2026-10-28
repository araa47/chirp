package dev.chirp.android

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.inputmethod.ExtractedTextRequest
import android.view.inputmethod.InputConnection
import android.widget.Toast

/** A bounded watch of one verified insertion. Field content never leaves memory except extracted corrections. */
internal class EditWatcher(private val permitted: () -> Boolean, private val onEdit: (String, String) -> Unit,
                           private val handler: Handler = Handler(Looper.getMainLooper())) {
    private var read: (() -> String?)? = null
    private var before = ""
    private var latest = ""
    private var inserted = ""
    private var start = -1
    private var until = 0L
    private val tick = object : Runnable {
        override fun run() {
            sample()
            if (read == null) return
            if (SystemClock.elapsedRealtime() >= until) finish() else handler.postDelayed(this, 400)
        }
    }
    var onClosed: () -> Unit = {}
    val watching get() = read != null
    fun watch(value: String, offset: Int, reader: () -> String?) {
        finish()
        if (!permitted() || value.isBlank() || offset < 0) return
        val snapshot = reader() ?: return
        if (snapshot.length > MAX_FIELD || offset > snapshot.length - value.length || snapshot.substring(offset, offset + value.length) != value) return
        before = snapshot; latest = snapshot; inserted = value; start = offset; read = reader
        until = SystemClock.elapsedRealtime() + 60_000
        handler.postDelayed(tick, 400)
    }
    fun sample() {
        if (read != null && SystemClock.elapsedRealtime() >= until) { finish(sample = false); return }
        if (!permitted()) { cancel(); return }
        val value = read?.invoke()
        if (value == null || value.length > MAX_FIELD) { finish(sample = false); return }
        latest = value
    }
    fun finish(sample: Boolean = true) {
        if (read == null) return
        if (sample && SystemClock.elapsedRealtime() < until && permitted()) read?.invoke()?.takeIf { it.length <= MAX_FIELD }?.let { latest = it }
        val edited = if (permitted()) EditRegion.edited(before, latest, start, inserted.length) else null
        val original = inserted
        try { if (edited != null && edited != original) onEdit(original, edited) } finally { cancel() }
    }
    fun cancel() { handler.removeCallbacks(tick); read = null; before = ""; latest = ""; inserted = ""; start = -1; onClosed() }
    companion object { const val MAX_FIELD = 100_000 }
}

/** Serialized with history IO: finish the old edit before reading the next session's payload. */
internal class EditLearning(private val context: Context, private val store: LearnedStore = LearnedStore(context),
                            private val io: (() -> Unit) -> Unit = HistoryIo::run) {
    private val main = Handler(Looper.getMainLooper())
    private var raw = ""
    private var target: String? = null
    var eligible: () -> Boolean = { true }
    val watcher = EditWatcher({ store.allowed && eligible() }, onEdit = { inserted, edited ->
        val said = raw; val app = target
        io {
            val activated = store.observe(inserted, edited, said, app)
            if (activated.isNotEmpty()) main.post {
                if (store.allowed) Toast.makeText(context, context.getString(R.string.learned_toast, activated.first().correction.title.resolve(context.resources)), Toast.LENGTH_SHORT).show()
            }
        }
    }).apply { onClosed = { raw = ""; target = null } }
    fun watch(text: String, offset: Int, said: String, app: String?, read: () -> String?) {
        watcher.finish()
        raw = said.codePoints().limit(300).toArray().let { String(it, 0, it.size) }; target = app
        watcher.watch(text, offset, read)
        if (!watcher.watching) { raw = ""; target = null }
    }
    fun prepare(app: String?, allowed: Boolean = true, ready: (LearnedPayload) -> Unit) {
        watcher.finish()
        io {
            val payload = runCatching { if (allowed) store.payload(app) else LearnedPayload() }.getOrDefault(LearnedPayload())
            val deliver = { ready(if (store.allowed && allowed) payload else LearnedPayload()) }
            if (Looper.myLooper() == Looper.getMainLooper()) deliver() else main.post { deliver() }
        }
    }
}

/** Only a full, bounded extraction can prove that the inserted span still belongs to this field. */
internal fun InputConnection.learningText(): String? = try {
    getExtractedText(ExtractedTextRequest().apply { hintMaxChars = EditWatcher.MAX_FIELD + 1; hintMaxLines = 10000 }, 0)?.let {
        if (it.startOffset != 0 || it.partialStartOffset >= 0 || it.text == null || it.text.length > EditWatcher.MAX_FIELD) null else it.text.toString()
    }
} catch (_: RuntimeException) { null }
