package dev.chirp.android

import android.content.Context
import android.util.AtomicFile
import androidx.annotation.StringRes
import androidx.core.content.edit
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec

internal enum class LearnedState(@StringRes val title: Int) { LEARNING(R.string.learned_state_learning), ACTIVE(R.string.learned_state_active), OFF(R.string.learned_state_off) }
internal class LearnedItem(val id: String, val correction: LearnedCorrection, val app: String?, val state: LearnedState,
                           val count: Int, val time: Long, val inserted: String, val edited: String, val said: String) {
    override fun toString() = "LearnedItem(<redacted>)"
}

/** Credential-encrypted app files, AES-GCM with a separate Keystore key; backup excludes all app files. IO thread only. */
internal class LearnedStore(context: Context, private val keys: HistoryKeys = KeystoreLearnedKeys,
                            private val clock: () -> Long = System::currentTimeMillis) {
    private val app = context.applicationContext ?: context
    private val deviceProtected = context.isDeviceProtectedStorage
    private val history = DictationHistory(context)
    private val prefs = app.getSharedPreferences("chirp_learning", Context.MODE_PRIVATE)
    private val atomic = AtomicFile(File(app.filesDir, FILE_NAME))
    var enabled: Boolean
        get() = prefs.getBoolean("enabled", true)
        set(value) { prefs.edit { putBoolean("enabled", value) } }
    val available get() = !deviceProtected && history.available
    val allowed get() = enabled && history.enabled && available && !PrivateSession.enabled

    fun all(): List<LearnedItem> = synchronized(LOCK) { if (available) read() else emptyList() }
    private fun read(): List<LearnedItem> {
        if (!atomic.baseFile.exists()) return emptyList()
        // A locked/denied Keystore is not proof of corruption; preserve the ciphertext.
        val key = keys.get(false)
        if (key == null) { atomic.delete(); return emptyList() }
        return try {
            val bytes = atomic.readFully()
            require(bytes.size in (HEADER.size + 12 + 16)..2_000_000 && bytes.copyOfRange(0, HEADER.size).contentEquals(HEADER))
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, bytes, HEADER.size, 12)); cipher.updateAAD(HEADER)
            val array = JSONArray(String(cipher.doFinal(bytes, HEADER.size + 12, bytes.size - HEADER.size - 12), Charsets.UTF_8))
            require(array.length() <= MAX_ITEMS)
            (0 until array.length()).map { i ->
                val o = array.getJSONObject(i)
                LearnedItem(o.getString("id"), LearnedCorrection(o.getString("heard"), o.getString("term"),
                    o.optString("style").takeIf { it.isNotEmpty() }?.let { LearnedStyle.valueOf(it) }),
                    o.optString("app").takeIf { o.has("app") }, LearnedState.valueOf(o.getString("state")), o.getInt("count"),
                    o.getLong("time"), o.getString("inserted"), o.getString("edited"), o.getString("said"))
            }
        } catch (_: Exception) { atomic.delete(); emptyList() }
    }
    private fun save(items: List<LearnedItem>) {
        if (items.isEmpty()) { atomic.delete(); return }
        val array = JSONArray()
        items.forEach { item -> array.put(JSONObject().put("id", item.id).put("heard", item.correction.heard).put("term", item.correction.term)
            .put("style", item.correction.style?.name ?: "").put("app", item.app).put("state", item.state.name).put("count", item.count)
            .put("time", item.time).put("inserted", item.inserted).put("edited", item.edited).put("said", item.said)) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, keys.get(true)); cipher.updateAAD(HEADER)
        val sealed = cipher.doFinal(array.toString().toByteArray(Charsets.UTF_8))
        val stream = atomic.startWrite()
        try { stream.write(HEADER); stream.write(cipher.iv); stream.write(sealed); atomic.finishWrite(stream) }
        catch (e: Exception) { atomic.failWrite(stream); throw e }
    }
    /** Count at most once per completed dictation window, never once per keystroke. */
    fun observe(inserted: String, edited: String, said: String, target: String?, explicit: Boolean = false): List<LearnedItem> = synchronized(LOCK) {
        if (!allowed) return emptyList()
        val corrections = EditCorrections.extract(inserted, edited)
        if (corrections.isEmpty()) return emptyList()
        val items = read().toMutableList()
        val activated = mutableListOf<LearnedItem>()
        fun bounded(s: String) = s.codePoints().limit(300).toArray().let { String(it, 0, it.size) }
        for (c in corrections) {
            // Style requires an actual target package, terms apply everywhere.
            if (c.style != null && target == null) continue
            val index = items.indexOfFirst { it.correction.same(c) && (c.style == null || it.app == target) }
            val old = items.getOrNull(index)
            val count = ((old?.count ?: 0) + 1).coerceAtMost(1_000_000)
            val state = when {
                old?.state == LearnedState.OFF -> LearnedState.OFF
                explicit || count >= 2 -> LearnedState.ACTIVE
                else -> LearnedState.LEARNING
            }
            val item = LearnedItem(old?.id ?: UUID.randomUUID().toString(), c, old?.app ?: target, state, count,
                clock(), bounded(inserted), bounded(edited), bounded(said))
            if (index < 0) items += item else items[index] = item
            if (state == LearnedState.ACTIVE && old?.state != LearnedState.ACTIVE) activated += item
        }
        val trimmed = items.sortedWith(compareBy<LearnedItem> { when (it.state) {
            LearnedState.ACTIVE -> 2; LearnedState.OFF -> 1; LearnedState.LEARNING -> 0
        } }.thenBy { it.time }).takeLast(MAX_ITEMS)
        if (allowed) save(trimmed)
        activated.filter { a -> trimmed.any { it.id == a.id } }
    }
    fun set(id: String, state: LearnedState) = mutate { items -> items.map {
        if (it.id == id) LearnedItem(it.id, it.correction, it.app, state, it.count, it.time, it.inserted, it.edited, it.said) else it
    } }
    fun delete(id: String) = mutate { it.filterNot { item -> item.id == id } }
    fun reset(target: String?) = mutate { it.filterNot { item -> item.app == target } }
    fun clear() = synchronized(LOCK) { if (available) { atomic.delete(); keys.delete() } }
    private fun mutate(change: (List<LearnedItem>) -> List<LearnedItem>) = synchronized(LOCK) { if (available) save(change(read())) }
    fun payload(target: String?): LearnedPayload = if (allowed) payload(all(), target) else LearnedPayload()
    companion object {
        const val FILE_NAME = "learned.bin"
        const val MAX_ITEMS = 200
        private val HEADER = "chirp.learned.v1".toByteArray(Charsets.US_ASCII)
        private val LOCK = Any()
        fun payload(items: List<LearnedItem>, target: String?): LearnedPayload {
            val active = items.asReversed().filter { it.state == LearnedState.ACTIVE }.sortedByDescending { it.time }
            val terms = active.filter { it.correction.style == null }.groupBy { it.correction.term }.entries.take(100).map { (term, list) ->
                LearnedPayload.Term(term, list.map { it.correction.heard }.distinct().take(4))
            }
            val local = active.filter { target != null && it.app == target && it.correction.style != null }.sortedByDescending { it.time }
            val examples = local.filter { it.said.isNotBlank() && it.edited.isNotBlank() }.distinctBy { it.said }.take(3)
                .map { LearnedPayload.Example(it.said, it.edited) }
            return LearnedPayload(terms, local.mapNotNull { it.correction.style }.distinct(), examples)
        }
    }
}
internal object KeystoreLearnedKeys : KeystoreKeys("chirp_learned_v1")
