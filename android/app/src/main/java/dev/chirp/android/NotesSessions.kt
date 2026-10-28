package dev.chirp.android

import androidx.annotation.StringRes
import android.content.Context
import android.os.UserManager
import androidx.core.content.edit
import java.io.File
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONArray
import org.json.JSONObject

/** "Delete notes older than": its own setting, apart from dictation history. Never is the default. */
internal enum class NotesRetention(val days: Int, @StringRes val label: Int) {
    NEVER(0, R.string.retention_never), YEAR(365, R.string.retention_year), DAYS_90(90, R.string.retention_days_90), DAYS_30(30, R.string.retention_days_30);
    val millis get() = days * 86_400_000L
    companion object { fun of(days: Int) = entries.firstOrNull { it.days == days } ?: NEVER }
}

/**
 * One row of the library list, enough to draw it without opening the note. Deliberately redacted: toString never exposes
 * notes text. [deletedAt] is set while the note sits in Recently Deleted.
 */
internal data class NotesIndexEntry(
    val id: String,
    val title: String,
    val snippet: String,
    val openTodos: Int,
    val createdAt: Long,
    val updatedAt: Long,
    val deletedAt: Long?,
    /** Seconds of audio recorded into the note. */
    val duration: Double,
    /** Sealed size of the kept audio, bytes. */
    val audioBytes: Long,
    /** Restored from a crash by the recovery copy, until the user has seen it. */
    val recovered: Boolean = false,
) {
    val deleted get() = deletedAt != null
    override fun toString() = "NotesIndexEntry(<redacted>)"

    fun toJson(): JSONObject = JSONObject().put("id", id).put("title", title).put("snippet", snippet).put("openTodos", openTodos)
        .put("createdAt", createdAt).put("updatedAt", updatedAt).put("duration", duration).put("audioBytes", audioBytes)
        .put("recovered", recovered).apply { deletedAt?.let { put("deletedAt", it) } }

    companion object {
        fun fromJson(json: JSONObject) = NotesIndexEntry(json.getString("id"), json.getString("title"), json.getString("snippet"),
            json.getInt("openTodos"), json.getLong("createdAt"), json.getLong("updatedAt"), json.optLong("deletedAt").takeIf { json.has("deletedAt") },
            json.getDouble("duration"), json.getLong("audioBytes"), json.optBoolean("recovered"))
    }
}

/** A whole note: its row, the document as [NotesDocument.toJson] wrote it (with `elapsed`) and its kept audio. */
internal class NotesRecord(val entry: NotesIndexEntry, val document: JSONObject, val revision: String = "") {
    val id get() = entry.id
    val clips: List<NotesAudioClip> get() = document.optJSONArray("audio")?.let { a -> (0 until a.length()).map { NotesAudioClip.fromJson(a.getJSONObject(it)) } }.orEmpty()
    override fun toString() = "NotesRecord(<redacted>)"
}

/** A search result: the note's row, and the matching line with the match's range for highlighting. */
internal class NotesSearchHit(val entry: NotesIndexEntry, val snippet: String, val matchStart: Int, val matchEnd: Int) {
    override fun toString() = "NotesSearchHit(<redacted>)"
}

/**
 * The notes library: every note is its own file (`notes/<id>.bin`) and a small `index.bin` lists them, so the list loads
 * without opening every note. All of it is sealed with one Android Keystore key in credential-encrypted app storage (never
 * before first unlock), is excluded from backup and transfer, and is never logged.
 *
 * On by default; an earlier explicit opt-out stays off until [enable]. Turning it off keeps what is there; only
 * [deleteAll] deletes. There is no cap. Retention ([retention], default Never) moves old notes to Recently Deleted, which
 * keeps them [TRASH_DAYS] days. A file that cannot be opened is moved to `notes/quarantine`, never deleted, and never
 * takes the rest of the collection with it. The old single-blob store is migrated on first read.
 *
 * Everything here blocks: call it off the main thread.
 */
internal class NotesSessions(
    context: Context,
    private val keys: HistoryKeys = KeystoreKeys(ALIAS),
    private val clock: () -> Long = System::currentTimeMillis,
    private val encoder: AudioEncoder? = null,
) {
    private val app = context.applicationContext ?: context
    private val prefs = app.getSharedPreferences("chirp_notes_sessions", Context.MODE_PRIVATE)
    private val root = File(app.filesDir, DIR)
    private val indexFile = SealedFile(File(root, INDEX_FILE), keys, INDEX_HEADER)
    private val legacy = SealedFile(File(app.filesDir, FILE_NAME), keys, LEGACY_HEADER)
    private val audioEncoder: AudioEncoder by lazy { encoder ?: MediaCodecAacEncoder(File(app.noBackupFilesDir, "notes_scratch")) }
    private val rows = MutableStateFlow<List<NotesIndexEntry>>(emptyList())

    /** The library's rows (Recently Deleted included), newest edit first; updated by every change and by [refresh]. */
    val index: StateFlow<List<NotesIndexEntry>> get() = rows

    /** An absent preference counts as on: new installs and upgrades keep notes. */
    val enabled get() = prefs.getBoolean("enabled", true)
    /** The user turned it off before this version: still off, with an "Enable notes library" path. */
    val optedOut get() = prefs.contains("enabled") && !prefs.getBoolean("enabled", true)
    val available: Boolean get() = !app.isDeviceProtectedStorage && app.getSystemService(UserManager::class.java)?.isUserUnlocked != false

    var retention: NotesRetention
        get() = NotesRetention.of(prefs.getInt("notes_retention_days", NotesRetention.NEVER.days))
        set(value) { prefs.edit { putInt("notes_retention_days", value.days) }; if (available) sweep() }

    /** "Keep audio with notes": off until the user opts in. */
    var keepAudio: Boolean
        get() = prefs.getBoolean("keep_audio", false)
        set(value) { prefs.edit { putBoolean("keep_audio", value) } }

    fun enable() { prefs.edit { putBoolean("enabled", true) } }
    /** Off stops keeping notes. It never deletes them: that is [deleteAll]. */
    fun disable() { prefs.edit { putBoolean("enabled", false) } }

    /** Every note, kept audio and quarantined file, and the key: crypto-shredded. */
    fun deleteAll() = synchronized(LOCK) {
        root.deleteRecursively(); legacy.remove()
        try { keys.delete() } catch (_: Exception) { }
        rows.value = emptyList()
    }

    // Reading

    /** The list: live notes newest edit first, then Recently Deleted (newest deletion first) when [includeDeleted]. */
    fun entries(includeDeleted: Boolean = false): List<NotesIndexEntry> {
        if (!available) return emptyList()
        return synchronized(LOCK) { snapshot().let { all -> sorted(if (includeDeleted) all else all.filter { !it.deleted }) } }
    }

    fun trashed(): List<NotesIndexEntry> = entries(includeDeleted = true).filter { it.deleted }.sortedByDescending { it.deletedAt }

    /** Reloads [index] from disk (also runs the retention sweep). */
    fun refresh() { entries(includeDeleted = true) }

    /** Opens a note; null when there is none, or its file could not be opened (then it is quarantined). */
    fun open(id: String): NotesRecord? {
        if (!available || !safe(id)) return null
        return synchronized(LOCK) {
            val list = snapshot()
            val record = readRecord(id)
            if (record == null && list.any { it.id == id }) { writeIndex(list.filter { it.id != id }) }
            record
        }
    }

    /** Local search over title, notes and transcript of live notes, best (newest) first. Blank finds nothing. */
    fun search(query: String): List<NotesSearchHit> {
        val needle = query.trim()
        if (needle.isEmpty() || !available) return emptyList()
        return synchronized(LOCK) {
            sorted(snapshot().filter { !it.deleted }).mapNotNull { entry ->
                val record = readRecord(entry.id) ?: return@mapNotNull null
                val doc = record.document
                val lines = listOf(entry.title) + doc.optString("text").lines() +
                    (0 until (doc.optJSONArray("segments")?.length() ?: 0)).map { doc.getJSONArray("segments").getJSONObject(it).optString("text") }
                lines.firstNotNullOfOrNull { line ->
                    line.indexOf(needle, ignoreCase = true).takeIf { it >= 0 }?.let { at -> window(line.trim().let { t -> t to line.indexOf(t) }, at, needle.length) }
                }?.let { (text, start) -> NotesSearchHit(entry, text, start, start + needle.length) }
            }
        }
    }

    /**
     * Names people were given in recent live notes, newest note first, without repeats: what "Name speakers" suggests as
     * you type. Looks at the [notes] most recent notes other than [excluding]. Names stay on this phone and are never logged.
     */
    fun speakerNames(excluding: String? = null, notes: Int = 30, limit: Int = 30): List<String> {
        if (!available) return emptyList()
        return synchronized(LOCK) {
            val names = LinkedHashMap<String, String>()
            for (entry in sorted(snapshot().filter { !it.deleted && it.id != excluding }).take(notes)) {
                val people = readRecord(entry.id)?.document?.optJSONArray("people") ?: continue
                for (i in 0 until people.length()) {
                    val person = people.optJSONObject(i) ?: continue
                    val name = person.optString("name").trim()
                    if (!person.has("merged") && name.isNotEmpty()) names.putIfAbsent(name.lowercase(), name)
                }
            }
            names.values.take(limit)
        }
    }

    // Writing

    /**
     * Keeps [document] (as [NotesDocument.toJson] wrote it) under [id], replacing its earlier copy; the title, snippet and
     * counts are worked out here. An untouched blank note is not kept (and an earlier copy of it goes). False when nothing
     * was written (off, locked, or blank). With [expectedRevision], also false if the record changed or was deleted
     * since it was opened. Every record write changes that token, including writes made within the same millisecond.
     */
    fun put(id: String, document: JSONObject, recovered: Boolean = false, expectedRevision: String? = null): Boolean {
        if (!enabled || !available || !safe(id)) return false
        val parsed = try { NotesDocument.fromJson(document) } catch (_: Exception) { return false }
        return synchronized(LOCK) {
            val list = snapshot()
            val old = list.firstOrNull { it.id == id }
            val existing = old?.let { readRecord(id) }
            // Check and write under the same lock, across all NotesSessions instances. A stale History edit must
            // neither replace a newer autosave nor recreate a note that was deleted while the edit was prepared.
            if (expectedRevision != null && (existing?.revision != expectedRevision || old?.deleted != false)) return@synchronized false
            if (parsed.untouched) { purgeLocked(id); return@synchronized false }
            val now = clock()
            // Clips made since this snapshot was taken (they are written on their own thread) are not lost.
            val merged = (existing?.clips.orEmpty().associateBy { it.segment } + parsed.audio.associateBy { it.segment }).values
                .filter { clipFile(id, it.segment).exists() }.sortedBy { it.segment }
            document.put("audio", JSONArray().apply { merged.forEach { put(it.toJson()) } }).put("uid", id) // One id, whatever the document carried.
            val entry = NotesIndexEntry(id, parsed.libraryTitle(), parsed.snippet, parsed.openTodos, old?.createdAt ?: parsed.startedAt, now,
                old?.deletedAt, document.optDouble("elapsed", 0.0), merged.sumOf { it.bytes }, recovered || old?.recovered == true)
            writeRecord(NotesRecord(entry, document))
            writeIndex(list.filter { it.id != id } + entry)
            true
        }
    }

    /** A user rename (blank goes back to the derived title). The note's document carries the name. */
    fun rename(id: String, title: String): Boolean = edit(id) { doc -> if (title.isBlank()) doc.remove("name") else doc.put("name", title.trim().take(MAX_TITLE)) }

    /** The "Recovered" mark has been seen. */
    fun clearRecovered(id: String): Boolean = update(id) { it.copy(recovered = false) }

    /** Delete: into Recently Deleted for [TRASH_DAYS] days. */
    fun trash(id: String): Boolean = update(id) { it.copy(deletedAt = it.deletedAt ?: clock()) }
    fun restore(id: String): Boolean = update(id) { it.copy(deletedAt = null, updatedAt = clock()) } // Fresh, so retention does not take it straight back.

    /** Gone for good, with its audio (the key stays: other notes use it). */
    fun purge(id: String) { if (safe(id)) synchronized(LOCK) { purgeLocked(id) } }
    fun emptyTrash() = synchronized(LOCK) { snapshot().filter { it.deleted }.forEach { purgeLocked(it.id) } }

    /** Recently Deleted past [TRASH_DAYS] days goes; notes past [retention] move to Recently Deleted. */
    fun sweep() { if (available) synchronized(LOCK) { snapshot() } }

    // Kept audio

    /** Encodes [pcm] (16-bit mono) as AAC-LC. Slow and lock-free: run it off the main thread, on [NotesAudioIo]. Null on failure. */
    fun encodeClip(pcm: ByteArray, sampleRate: Int = SAMPLE_RATE): ByteArray? =
        if (pcm.size < 2) null else try { audioEncoder.encode(pcm, sampleRate) } catch (_: Exception) { null }

    /**
     * Seals [encoded] under `notes/<id>/audio/<segment>.m4a` (wiped afterwards) and records the clip with the note, which
     * must already be kept. The clip, or null when the note is gone or the write failed.
     */
    fun storeClip(id: String, segment: Int, offset: Double, pcmBytes: Int, encoded: ByteArray, sampleRate: Int = SAMPLE_RATE): NotesAudioClip? {
        if (!available || !safe(id)) return null
        val clip = NotesAudioClip(segment, offset, pcmBytes / 2.0 / sampleRate, sampleRate, encoded.size.toLong())
        return synchronized(LOCK) {
            try {
                if (readRecord(id) == null) return@synchronized null
                clipSealed(id, segment).write(encoded)
                edit(id) { doc ->
                    val clips = NotesRecord(NotesIndexEntry(id, "", "", 0, 0, 0, null, 0.0, 0), doc).clips.filter { it.segment != segment } + clip
                    doc.put("audio", JSONArray().apply { clips.sortedBy { it.segment }.forEach { put(it.toJson()) } })
                }
                clip
            } catch (_: Exception) { null } finally { encoded.fill(0) }
        }
    }

    /** [encodeClip] then [storeClip], for callers that are already off the main thread and know the note is kept. */
    fun saveClip(id: String, segment: Int, offset: Double, pcm: ByteArray, sampleRate: Int = SAMPLE_RATE): NotesAudioClip? =
        encodeClip(pcm, sampleRate)?.let { storeClip(id, segment, offset, pcm.size, it, sampleRate) }

    /** The decrypted `.m4a` of a segment for playback, or null. Zero it when done. */
    fun clipBytes(id: String, segment: Int): ByteArray? {
        if (!available || !safe(id)) return null
        return synchronized(LOCK) {
            when (val loaded = clipSealed(id, segment).load()) {
                is SealedFile.Loaded.Ok -> loaded.plain
                SealedFile.Loaded.Missing -> null
                SealedFile.Loaded.Corrupt -> { clipSealed(id, segment).quarantine(File(root, "$QUARANTINE/$id-$segment.m4a.${clock()}")); null }
            }
        }
    }

    /** "Delete audio": the note's clips go, its text stays. */
    fun deleteAudio(id: String): Boolean {
        if (!safe(id)) return false
        return synchronized(LOCK) {
            File(root, id).deleteRecursively()
            edit(id) { it.put("audio", JSONArray()) }
        }
    }

    /** "Delete kept audio (N MB)": every note's clips. */
    fun deleteAllAudio() = synchronized(LOCK) { snapshot().forEach { deleteAudio(it.id) } }

    /** Sealed size of all kept audio, bytes (Recently Deleted included, as it still occupies the phone). */
    fun totalAudioBytes(): Long = if (!available) 0L else synchronized(LOCK) { snapshot().sumOf { it.audioBytes } }

    // Storage

    /** Live notes by last edit, then Recently Deleted by deletion, newest first. */
    private fun sorted(list: List<NotesIndexEntry>) = list.sortedWith(compareBy<NotesIndexEntry> { it.deleted }.thenByDescending { it.deletedAt ?: it.updatedAt })

    private fun safe(id: String) = id.isNotEmpty() && id.length <= 64 && id.all { it.isLetterOrDigit() || it == '-' }

    private fun noteSealed(id: String) = SealedFile(File(root, "$id.bin"), keys, NOTE_HEADER)
    private fun clipFile(id: String, segment: Int) = File(root, "$id/audio/$segment.m4a")
    private fun clipSealed(id: String, segment: Int) = SealedFile(clipFile(id, segment), keys, AUDIO_HEADER)

    /** The index after migration, quarantine of what cannot be opened and the sweeps; the live rows are published. */
    private fun snapshot(): List<NotesIndexEntry> {
        migrate()
        var list = readIndex()
        val now = clock()
        val cutoff = retention.takeIf { it != NotesRetention.NEVER }?.let { now - it.millis }
        val expired = list.filter { it.deletedAt?.let { at -> now - at >= TRASH_DAYS * 86_400_000L } == true }
        if (expired.isNotEmpty()) { expired.forEach { purgeFiles(it.id) }; list = list.filter { e -> expired.none { it.id == e.id } } }
        if (cutoff != null) {
            val old = list.filter { !it.deleted && it.updatedAt < cutoff }.map { it.id }.toSet()
            if (old.isNotEmpty()) list = list.map { if (it.id in old) it.copy(deletedAt = now) else it }
        }
        if (expired.isNotEmpty() || cutoff != null && list.any { it.deletedAt == now }) writeIndex(list) else rows.value = sorted(list)
        return list
    }

    private fun readIndex(): List<NotesIndexEntry> = when (val loaded = indexFile.load()) {
        is SealedFile.Loaded.Ok -> try {
            val array = JSONObject(String(loaded.plain, Charsets.UTF_8)).getJSONArray("notes")
            (0 until array.length()).map { NotesIndexEntry.fromJson(array.getJSONObject(it)) }
        } catch (_: Exception) { quarantineIndex(); rebuild() } finally { loaded.plain.fill(0) }
        SealedFile.Loaded.Missing -> if (noteFiles().isEmpty()) emptyList() else rebuild()
        SealedFile.Loaded.Corrupt -> { quarantineIndex(); rebuild() }
    }

    private fun quarantineIndex() { indexFile.quarantine(File(root, "$QUARANTINE/index.bin.${clock()}")) }

    private fun noteFiles() = root.listFiles { f -> f.isFile && f.name.endsWith(".bin") && f.name != INDEX_FILE }.orEmpty()

    /** The index from the notes themselves, when it is missing or unreadable. Notes that cannot be opened are quarantined. */
    private fun rebuild(): List<NotesIndexEntry> =
        noteFiles().mapNotNull { readRecord(it.name.removeSuffix(".bin"))?.entry }.also { writeIndex(it) }

    /** A note's record; one that cannot be opened is moved aside (never deleted), and null is returned. */
    private fun readRecord(id: String): NotesRecord? {
        val sealed = noteSealed(id)
        return when (val loaded = sealed.load()) {
            SealedFile.Loaded.Missing -> null
            SealedFile.Loaded.Corrupt -> { sealed.quarantine(File(root, "$QUARANTINE/$id.bin.${clock()}")); null }
            is SealedFile.Loaded.Ok -> try {
                val json = JSONObject(String(loaded.plain, Charsets.UTF_8))
                if (json.optInt("v") > VERSION) null // A note from a newer Chirp stays for that version.
                else NotesRecord(NotesIndexEntry.fromJson(json.getJSONObject("entry")), json.getJSONObject("doc"), json.optString("revision"))
            } catch (_: Exception) { sealed.quarantine(File(root, "$QUARANTINE/$id.bin.${clock()}")); null } finally { loaded.plain.fill(0) }
        }
    }

    private fun writeRecord(record: NotesRecord) {
        root.mkdirs()
        val plain = JSONObject().put("v", VERSION).put("revision", java.util.UUID.randomUUID().toString())
            .put("entry", record.entry.toJson()).put("doc", record.document).toString().toByteArray(Charsets.UTF_8)
        try { noteSealed(record.id).write(plain) } finally { plain.fill(0) }
    }

    private fun writeIndex(list: List<NotesIndexEntry>) {
        root.mkdirs()
        val plain = JSONObject().put("v", VERSION).put("notes", JSONArray().apply { list.forEach { put(it.toJson()) } }).toString().toByteArray(Charsets.UTF_8)
        try { indexFile.write(plain) } finally { plain.fill(0) }
        rows.value = sorted(list)
    }

    private fun purgeFiles(id: String) { noteSealed(id).remove(); File(root, id).deleteRecursively() }
    private fun purgeLocked(id: String) {
        val list = readIndex()
        purgeFiles(id)
        if (list.any { it.id == id }) writeIndex(list.filter { it.id != id })
    }

    /** Changes one row (and the record's own copy of it). */
    private fun update(id: String, change: (NotesIndexEntry) -> NotesIndexEntry): Boolean {
        if (!available || !safe(id)) return false
        return synchronized(LOCK) {
            val list = snapshot()
            val old = list.firstOrNull { it.id == id } ?: return@synchronized false
            val record = readRecord(id) ?: run { writeIndex(list.filter { it.id != id }); return@synchronized false }
            val entry = change(old)
            writeRecord(NotesRecord(entry, record.document)); writeIndex(list.map { if (it.id == id) entry else it })
            true
        }
    }

    /** Changes one note's document, then its title, snippet and counts follow. */
    private fun edit(id: String, change: (JSONObject) -> Unit): Boolean {
        if (!available || !safe(id)) return false
        return synchronized(LOCK) {
            val list = snapshot()
            val old = list.firstOrNull { it.id == id } ?: return@synchronized false
            val record = readRecord(id) ?: run { writeIndex(list.filter { it.id != id }); return@synchronized false }
            change(record.document)
            val parsed = try { NotesDocument.fromJson(record.document) } catch (_: Exception) { return@synchronized false }
            val bytes = record.clips.sumOf { it.bytes }
            val entry = old.copy(title = parsed.libraryTitle(), snippet = parsed.snippet, openTodos = parsed.openTodos, audioBytes = bytes)
            writeRecord(NotesRecord(entry, record.document)); writeIndex(list.map { if (it.id == id) entry else it })
            true
        }
    }

    /** The old single sealed blob becomes one note each, once; one that cannot be opened is set aside, not deleted. */
    private fun migrate() {
        if (!legacy.exists) return
        when (val loaded = legacy.load()) {
            SealedFile.Loaded.Missing -> Unit
            SealedFile.Loaded.Corrupt -> legacy.quarantine(File(root, "$QUARANTINE/$FILE_NAME.${clock()}"))
            is SealedFile.Loaded.Ok -> try {
                val array = JSONArray(String(loaded.plain, Charsets.UTF_8))
                val list = readIndexOrEmpty().toMutableList()
                for (i in 0 until array.length()) {
                    val item = array.getJSONObject(i)
                    val id = item.getString("id").takeIf(::safe) ?: continue
                    if (list.any { it.id == id }) continue
                    val document = item.getJSONObject("doc")
                    val parsed = NotesDocument.fromJson(document)
                    if (parsed.untouched) continue
                    val time = item.getLong("time")
                    val entry = NotesIndexEntry(id, parsed.libraryTitle(), parsed.snippet, parsed.openTodos, parsed.startedAt.coerceAtMost(time), time,
                        null, document.optDouble("elapsed", 0.0), 0)
                    writeRecord(NotesRecord(entry, document)); list += entry
                }
                writeIndex(list)
                legacy.remove() // The file only: the key is the library's now.
            } catch (_: Exception) { legacy.quarantine(File(root, "$QUARANTINE/$FILE_NAME.${clock()}")) } finally { loaded.plain.fill(0) }
        }
    }

    private fun readIndexOrEmpty(): List<NotesIndexEntry> = if (indexFile.exists || noteFiles().isNotEmpty()) readIndex() else emptyList()

    /** Elsewhere in one place: a window of [line] around a match, with the match's start inside it. */
    private fun window(line: Pair<String, Int>, at: Int, length: Int): Pair<String, Int> {
        val (text, shift) = line
        val from = (at - shift - 40).coerceAtLeast(0)
        val to = (at - shift + length + 80).coerceAtMost(text.length)
        val slice = text.substring(from, to)
        val prefix = if (from > 0) "…" else ""
        return (prefix + slice + if (to < text.length) "…" else "") to (at - shift - from + prefix.length)
    }

    companion object {
        /** The old single blob, `files/notes_sessions.bin`. */
        const val FILE_NAME = "notes_sessions.bin"
        const val DIR = "notes"
        const val INDEX_FILE = "index.bin"
        const val QUARANTINE = "quarantine"
        const val MAX_TITLE = 120
        /** Recently Deleted keeps a note this long. */
        const val TRASH_DAYS = 30
        const val SAMPLE_RATE = 16000
        private const val VERSION = 1
        private const val ALIAS = "chirp_notes_sessions_v1"
        private val LEGACY_HEADER = byteArrayOf('C'.code.toByte(), 'S'.code.toByte(), 1)
        private val NOTE_HEADER = byteArrayOf('C'.code.toByte(), 'N'.code.toByte(), 'L'.code.toByte(), 1)
        private val INDEX_HEADER = byteArrayOf('C'.code.toByte(), 'N'.code.toByte(), 'X'.code.toByte(), 1)
        private val AUDIO_HEADER = byteArrayOf('C'.code.toByte(), 'A'.code.toByte(), 'U'.code.toByte(), 1)
        private val LOCK = Any()
    }
}
