package dev.chirp.android

import org.json.JSONObject

sealed interface ServerEvent {
    data class Ready(val debugRetention: Boolean, val engine: String? = null) : ServerEvent
    data class Partial(val seq: Long, val text: String, val stable: String) : ServerEvent
    data class Correcting(val seq: Long, val raw: String, val profile: String) : ServerEvent
    data class Final(val text: String, val raw: String, val corrected: Boolean, val correctionError: String? = null,
                     /** Live Notes speaker labels, when `start` asked for them (`speakers.session`). */
                     val speakers: SpeakersResult? = null, val words: List<TranscriptWord>? = null, val engine: String? = null) : ServerEvent
    data class Failure(val code: String) : ServerEvent
    data object Unknown : ServerEvent
}

data class Health(val ready: Boolean, val debugRetention: Boolean, val correctionAvailable: Boolean,
                  val correctionLeavesMachine: Boolean, val correctionHost: String?, val engine: String? = null,
                  val correctionProfiles: List<CorrectionProfile> = emptyList(),
                  val notesStructure: Boolean = false, val notesReorganize: Boolean = false, val notesCorrection: Boolean = false,
                  val notesEdit: Boolean = false,
                  /** The server labels speakers (`start.speakers`), and its speaker model's state (`ready`, `not_downloaded`…). */
                  val notesSpeakers: Boolean = false, val speakersModel: String? = null, val speakersModelBytes: Long? = null,
                  val speakerVoices: Boolean = false, val speakersVoices: SpeakersVoicesHealth? = null,
                  val operationDeadlines: OperationDeadlines = OperationDeadlines(),
                  val notesRetranscribe: Boolean = false, val notesContext: Boolean = false, val speechModel: String? = null,
                  /** The name this phone was paired under (`chirp-server pair --name`); null for the shared token or an older server. */
                  val device: String? = null)

/** Effective server budgets in seconds; each absent or invalid value uses the caller's legacy timeout. */
data class OperationDeadlines(private val seconds: Map<String, Double> = emptyMap()) {
    fun timeoutMs(operation: String, fallback: Long): Long {
        return advertisedTimeoutMs(operation) ?: fallback
    }
    fun advertisedTimeoutMs(operation: String): Long? {
        val value = seconds[operation] ?: return null
        // Keep the five-second transport margin bounded, and stay within OkHttp's Int millisecond limit.
        if (!value.isFinite() || value <= 0 || value >= Int.MAX_VALUE.toDouble() / 1000 - 5) return null
        return kotlin.math.ceil((value + 5) * 1000).toLong()
    }
    fun json() = JSONObject(seconds)
    companion object {
        fun decode(json: JSONObject?) = OperationDeadlines(buildMap {
            for (operation in listOf("dictation", "notes_correction", "notes_structure", "notes_reorganize", "notes_edit")) {
                val value = json?.opt(operation) as? Number ?: continue
                val seconds = value.toDouble()
                if (seconds.isFinite() && seconds > 0) put(operation, seconds)
            }
        })
    }
}

data class SpeakersVoicesHealth(val enabled: Boolean, val count: Int, val model: String)

data class TranscriptWord(val text: String, val start: Double, val end: Double)

object Protocol {
    fun start(correction: Boolean, profile: String = "default", instructions: String = "", prompt: String? = null,
              speakers: String? = null, learned: LearnedPayload? = null, retranscribe: Boolean = false): String {
        require(CleanupStyles.validId(profile))
        require(speakers == null || SPEAKER_SESSION.matches(speakers))
        require(CleanupStyles.characterCount(instructions) <= CleanupStyles.MAX_INSTRUCTIONS)
        require(prompt == null || CleanupStyles.characterCount(prompt) <= CleanupStyles.MAX_PROMPT)
        return JSONObject().put("type", "start")
        .put("sample_rate", 16000).put("encoding", "pcm_s16le")
        .put("client", "android").put("correction", correction)
        .put("correction_profile", profile).put("correction_instructions", if (profile == "custom") instructions else "")
        .apply { if (retranscribe) { put("retranscribe", true); put("word_timings", true) } }
        .apply { if (prompt != null) put("correction_prompt", prompt) }
        .apply { if (learned != null && !learned.isEmpty) put("learned", learned.wire()) }
        .apply { if (speakers != null) put("speakers", JSONObject().put("session", speakers)) }.toString()
    }
    /** A note's random speaker-session id, as the server accepts it. */
    val SPEAKER_SESSION = Regex("[A-Za-z0-9_-]{16,64}")
    const val STOP = "{\"type\":\"stop\"}"
    const val CANCEL = "{\"type\":\"cancel\"}"
    fun stop(context: String?) = if (context == null) STOP else JSONObject().put("type", "stop").put("context", context.takeLast(500)).toString()
    fun decode(message: String): ServerEvent {
        require(message.length <= 1_000_000) { "Protocol frame too large" }
        val json = JSONObject(message)
        return when (json.getString("type")) {
            "ready" -> ServerEvent.Ready(json.getBoolean("debug_retention"), json.text("engine"))
            "partial" -> ServerEvent.Partial(json.getLong("seq"), json.getString("text"), json.optString("stable"))
            "correcting" -> ServerEvent.Correcting(json.getLong("seq"), json.getString("raw"), json.getString("profile"))
            "final" -> ServerEvent.Final(json.getString("text"), json.getString("raw"), json.getBoolean("corrected"),
                json.optString("correction_error").takeIf { it.isNotBlank() && it != "null" },
                json.optJSONObject("speakers")?.let(SpeakersResult::decode),
                json.optJSONArray("words")?.let { a -> (0 until a.length()).map { i -> a.getJSONObject(i).let {
                    TranscriptWord(it.getString("text"), it.getDouble("start"), it.getDouble("end"))
                } }.takeIf { words -> words.all { it.start.isFinite() && it.end.isFinite() && it.start >= 0 && it.end >= it.start } } },
                json.text("engine"))
            "error" -> ServerEvent.Failure(json.getString("code")) // Never display untrusted server text.
            else -> ServerEvent.Unknown
        }
    }
    fun profiles(message: String): List<CorrectionProfile> {
        require(message.length <= 512000) { "Profiles too large" }
        val array = JSONObject(message).getJSONArray("profiles")
        return buildList {
            for (i in 0 until array.length()) {
                val item = array.getJSONObject(i)
                val id = item.getString("id")
                require(CleanupStyles.validId(id)) { "Invalid profile" }
                val prompt = item.getString("prompt")
                val maximum = item.getInt("max_prompt_chars")
                require(maximum in 1..CleanupStyles.MAX_PROMPT && CleanupStyles.characterCount(prompt) <= maximum) { "Invalid prompt limit" }
                if (none { it.id == id }) add(CorrectionProfile(id, item.getString("name").take(80),
                    item.getString("description").take(300), item.getBoolean("rewrites"), prompt, maximum))
            }
        }
    }
    fun health(message: String): Health {
        val json = JSONObject(message)
        require(json.getBoolean("ok") && json.has("ready")) { "Authenticated health required" }
        return Health(json.getBoolean("ready"), json.getBoolean("debug_retention"),
            json.optString("correction") == "available", json.optBoolean("correction_leaves_machine"),
            json.optString("correction_host").takeIf { it.isNotBlank() && it != "null" },
            json.optString("engine").takeIf { it.isNotBlank() }?.take(80),
            buildList {
                val profiles = json.optJSONArray("correction_profiles")
                if (profiles != null) for (i in 0 until profiles.length()) {
                    val item = profiles.optJSONObject(i) ?: continue
                    val id = item.optString("id")
                    if (CleanupStyles.validId(id) && none { it.id == id }) add(CorrectionProfile(id,
                        item.optString("name", id).take(80), item.optString("description").take(300), item.optBoolean("rewrites")))
                }
            }, json.optBoolean("notes_structure"), json.optBoolean("notes_reorganize"), json.optBoolean("notes_correction"),
            json.optBoolean("notes_edit"), json.optBoolean("notes_speakers"),
            json.optJSONObject("speakers_model")?.optString("state")?.takeIf { it.matches(Regex("[a-z_]{1,32}")) },
            json.optJSONObject("speakers_model")?.optLong("size_bytes")?.takeIf { it > 0 },
            json.optBoolean("speaker_voices") || json.optJSONArray("capabilities")?.let { caps ->
                (0 until caps.length()).any { caps.optString(it) == "speaker_voices" }
            } == true,
            json.optJSONObject("speakers_voices")?.let { v ->
                if (v.opt("enabled") is Boolean && v.optInt("count", -1) in 0..50)
                    SpeakersVoicesHealth(v.getBoolean("enabled"), v.getInt("count"), v.optString("model").take(128)) else null
            }, OperationDeadlines.decode(json.optJSONObject("operation_deadlines")),
            json.optBoolean("notes_retranscribe") || json.optJSONArray("capabilities")?.let { a -> (0 until a.length()).any { a.optString(it) == "notes_retranscribe" } } == true,
            json.optBoolean("notes_context"), json.text("speech_model"),
            json.optString("device").take(64).takeIf { name -> name.isNotBlank() && name != "null" && name.none { it.isISOControl() } })
    }
}
