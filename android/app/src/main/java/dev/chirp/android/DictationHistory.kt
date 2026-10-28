package dev.chirp.android

import android.content.Context
import android.os.UserManager
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.text.InputType
import android.util.AtomicFile
import android.view.inputmethod.EditorInfo
import androidx.core.content.edit
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Deliberately not a data class: toString must never expose dictated text. */
internal class HistoryEntry(val id: String, val time: Long, val text: String, val raw: String?, val app: String?,
                            /** Kept from partials after a failure, never finalised by the Mac. */ val partial: Boolean = false, val packageName: String? = null) {
    fun copy(text: String = this.text, raw: String? = this.raw) = HistoryEntry(id, time, text, raw, app, partial, packageName)
    override fun toString() = "HistoryEntry(<redacted>)"
}

internal enum class HistoryRetention(val days: Int, val label: String) {
    DAY(1, "1 day"), WEEK(7, "7 days"), MONTH(30, "30 days");
    val millis get() = days * 86_400_000L
    fun label(resources: android.content.res.Resources): String = resources.getQuantityString(R.plurals.retention_days, days, days)
    companion object { fun of(days: Int) = entries.firstOrNull { it.days == days } ?: WEEK }
}

/**
 * On-by-default dictation history that never leaves this phone. Entries live only in credential-encrypted
 * app storage (unavailable before first unlock), are sealed with an Android Keystore AES-GCM key,
 * and are excluded from backup/transfer. Nothing here is logged or added to diagnostics.
 * Turning history off stops new entries. Explicit deletion removes the file and its key.
 */
internal class DictationHistory(
    context: Context,
    private val keys: HistoryKeys = KeystoreHistoryKeys,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private val settings = SettingsStore(context)
    private val deviceProtected = context.isDeviceProtectedStorage
    private val app = context.applicationContext ?: context
    private val prefs = app.getSharedPreferences("chirp_history", Context.MODE_PRIVATE)
    private val file = File(app.filesDir, FILE_NAME)

    val enabled get() = prefs.getBoolean("enabled", true)
    var retention: HistoryRetention
        get() = HistoryRetention.of(prefs.getInt("retention_days", HistoryRetention.WEEK.days))
        set(value) { prefs.edit { putInt("retention_days", value.days) }; if (available) synchronized(LOCK) { save(load()) } }

    /** False before first unlock or for a device-protected context, where history must never be written. */
    val available: Boolean get() = !deviceProtected && !app.isDeviceProtectedStorage &&
        app.getSystemService(UserManager::class.java)?.isUserUnlocked != false

    fun enable() { prefs.edit { putBoolean("enabled", true) } }
    /** Fence new writers, optionally deleting retained entries and the key under the same lock. */
    fun disable(deleteHistory: Boolean = false) = synchronized(LOCK) {
        prefs.edit { putBoolean("enabled", false) }
        if (deleteHistory) clear()
    }

    fun clear() = synchronized(LOCK) {
        AtomicFile(file).delete()
        prefs.edit { remove("oldest") }
        try { keys.delete() } catch (_: Exception) { /* A missing key already makes old ciphertext unreadable. */ }
    }

    /** Newest first, already pruned to the retention window and entry limit. */
    fun entries(): List<HistoryEntry> = if (!available) emptyList() else synchronized(LOCK) {
        val stored = read()
        val kept = prune(stored)
        if (kept.size != stored.size) save(kept)
        kept.asReversed()
    }

    /** Returns the stored entry, or null when history is off, unavailable or the editor is excluded. */
    fun record(text: String, raw: String?, appLabel: String?, info: EditorInfo?, id: String = UUID.randomUUID().toString(),
               partial: Boolean = false): HistoryEntry? {
        if (!enabled || !available || settings.privateSession || !allowed(info)) return null
        val inserted = text.trim()
        if (inserted.isEmpty() || inserted.length > MAX_CHARS) return null
        val original = raw?.trim()?.takeIf { it.isNotEmpty() && it != inserted && it.length <= MAX_CHARS }
        val entry = HistoryEntry(id, clock(), inserted, original, appLabel?.trim()?.take(80)?.takeIf { it.isNotEmpty() }, partial, info?.packageName)
        synchronized(LOCK) {
            if (!enabled || settings.privateSession) return null // Re-check while holding the write lock.
            save(load() + entry)
        }
        return entry
    }

    /** "Use raw" replaced the insertion: history keeps what is actually in the field. */
    fun usedRaw(id: String) = update(id) { entry ->
        entry.raw?.let { raw -> entry.copy(text = raw, raw = null) } ?: entry
    }

    fun delete(id: String) = update(id) { null }

    /** Undo of [delete]: puts the entry back where it was, unless it has since expired. */
    fun restore(entry: HistoryEntry) {
        if (!available) return
        synchronized(LOCK) { save(prune((load().filter { it.id != entry.id } + entry).sortedBy { it.time })) }
    }

    /** Cheap check on keyboard show: decrypts only when the oldest entry may have expired. */
    fun pruneIfDue() {
        if (!available) return
        val oldest = prefs.getLong("oldest", Long.MAX_VALUE)
        if (oldest != Long.MAX_VALUE && clock() - oldest > retention.millis) synchronized(LOCK) { save(load()) }
    }

    private fun update(id: String, change: (HistoryEntry) -> HistoryEntry?) {
        if (!available) return
        synchronized(LOCK) {
            val current = load()
            val next = current.mapNotNull { if (it.id == id) change(it) else it }
            if (next.size != current.size || next.zip(current).any { (a, b) -> a.text != b.text }) save(next)
        }
    }

    private fun load() = prune(read())
    private fun prune(entries: List<HistoryEntry>): List<HistoryEntry> {
        val cutoff = clock() - retention.millis
        return entries.filter { it.time >= cutoff }.takeLast(MAX_ENTRIES)
    }

    private fun read(): List<HistoryEntry> {
        val atomic = AtomicFile(file)
        if (!file.exists()) return emptyList()
        return try {
            val bytes = atomic.readFully()
            require(bytes.size > HEADER.size + IV_BYTES && bytes.copyOfRange(0, HEADER.size).contentEquals(HEADER))
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, keys.get(create = false) ?: error("missing key"),
                GCMParameterSpec(128, bytes, HEADER.size, IV_BYTES))
            cipher.updateAAD(HEADER)
            val plain = cipher.doFinal(bytes, HEADER.size + IV_BYTES, bytes.size - HEADER.size - IV_BYTES)
            val json = JSONArray(String(plain, Charsets.UTF_8))
            (0 until json.length()).map { index ->
                val item = json.getJSONObject(index)
                HistoryEntry(item.getString("id"), item.getLong("time"), item.getString("text"),
                    item.optString("raw").takeIf { item.has("raw") }, item.optString("app").takeIf { item.has("app") }, item.optBoolean("partial"), item.optString("package").takeIf { item.has("package") })
            }.sortedBy { it.time }
        } catch (_: Exception) {
            // Lost key (reinstall/restore) or damaged file: unreadable history is discarded, never repaired.
            atomic.delete(); prefs.edit { remove("oldest") }
            emptyList()
        }
    }

    private fun save(entries: List<HistoryEntry>) {
        val atomic = AtomicFile(file)
        if (entries.isEmpty()) { atomic.delete(); prefs.edit { remove("oldest") }; return }
        val json = JSONArray()
        entries.forEach { entry ->
            json.put(JSONObject().put("id", entry.id).put("time", entry.time).put("text", entry.text).apply {
                entry.packageName?.let { put("package", it) }; entry.raw?.let { put("raw", it) }; entry.app?.let { put("app", it) }; if (entry.partial) put("partial", true)
            })
        }
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, keys.get(create = true)) // Fresh random IV for every write.
        cipher.updateAAD(HEADER)
        val sealed = cipher.doFinal(json.toString().toByteArray(Charsets.UTF_8))
        check(cipher.iv.size == IV_BYTES)
        val stream = atomic.startWrite()
        try {
            stream.write(HEADER); stream.write(cipher.iv); stream.write(sealed)
            atomic.finishWrite(stream)
        } catch (error: Exception) { atomic.failWrite(stream); throw error }
        prefs.edit { putLong("oldest", entries.minOf { it.time }) }
    }

    companion object {
        const val MAX_ENTRIES = 200
        const val MAX_CHARS = 20_000
        const val FILE_NAME = "dictation_history.bin"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val IV_BYTES = 12
        private val HEADER = byteArrayOf('C'.code.toByte(), 'H'.code.toByte(), 1)
        private val LOCK = Any()

        /** Password fields and incognito editors (IME_FLAG_NO_PERSONALIZED_LEARNING) are never recorded. */
        fun allowed(info: EditorInfo?): Boolean {
            if (info == null) return false
            if (info.imeOptions and EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING != 0) return false
            val type = info.inputType and InputType.TYPE_MASK_CLASS
            val variation = info.inputType and InputType.TYPE_MASK_VARIATION
            return !((type == InputType.TYPE_CLASS_TEXT && variation in setOf(InputType.TYPE_TEXT_VARIATION_PASSWORD,
                    InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD, InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD)) ||
                (type == InputType.TYPE_CLASS_NUMBER && variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD))
        }
    }
}

internal interface HistoryKeys {
    fun get(create: Boolean): SecretKey?
    fun delete()
}

/** One Keystore key per store, apart from pairing: clearing a store crypto-shreds it without touching the pairing token. */
internal open class KeystoreKeys(private val alias: String) : HistoryKeys {
    private fun store() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    override fun get(create: Boolean): SecretKey? {
        (store().getKey(alias, null) as? SecretKey)?.let { return it }
        if (!create) return null
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).build())
        }.generateKey()
    }
    override fun delete() { store().deleteEntry(alias) }
}

internal object KeystoreHistoryKeys : KeystoreKeys("chirp_history_v1")
