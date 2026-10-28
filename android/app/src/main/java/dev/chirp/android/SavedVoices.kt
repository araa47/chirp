package dev.chirp.android

import java.io.IOException
import org.json.JSONObject

/** Metadata only. Voiceprints are never returned to, or stored on, this client. */
internal data class SavedVoice(val id: String, val name: String, val seconds: Double,
                               val created: String, val updated: String, val compatible: Boolean)
internal data class SavedVoices(val enabled: Boolean, val model: String, val voices: List<SavedVoice>, val voice: SavedVoice? = null) {
    companion object {
        fun decode(text: String): SavedVoices {
            val json = JSONObject(text)
            fun voice(item: JSONObject): SavedVoice {
                val id = item.getString("id").also { require(VOICE_ID.matches(it)) }
                val name = item.getString("name").also { require(validVoiceName(it)) }
                val seconds = item.getDouble("seconds").also { require(it.isFinite() && it >= 0) }
                return SavedVoice(id, name, seconds, item.getString("created").take(32), item.getString("updated").take(32), item.getBoolean("compatible"))
            }
            val array = json.getJSONArray("voices").also { require(it.length() <= 50) }
            val voices = (0 until array.length()).map { voice(array.getJSONObject(it)) }
            require(voices.map { it.id }.distinct().size == voices.size)
            return SavedVoices(json.getBoolean("enabled"), json.getString("model").take(128), voices, json.optJSONObject("voice")?.let(::voice))
        }
    }
}
internal val VOICE_ID = Regex("[0-9a-f]{16}")
internal fun validVoiceName(name: String) = name.length in 1..60 && name.any(Char::isLetter) &&
    name.none { it == ':' || it.isISOControl() || Character.getType(it) == Character.FORMAT.toInt() }
internal fun cleanVoiceName(name: String) = name.trim().replace(Regex("\\s+"), " ").take(60)

/** The server's ephemeral centroid reference. Never serialized into a note or preferences. */
internal data class SpeakerVoiceSource(val session: String, val generation: String, val speaker: Int) {
    fun json() = JSONObject().put("session", session).put("generation", generation).put("speaker", speaker)
}
internal sealed interface VoiceAction {
    fun json(): JSONObject
    data class Remember(val name: String, val source: SpeakerVoiceSource, val voice: String? = null) : VoiceAction {
        override fun json() = JSONObject().put("action", "remember").put("name", name).put("from", source.json()).apply { voice?.let { put("voice", it) } }
    }
    data class Rename(val voice: String, val name: String) : VoiceAction {
        override fun json() = JSONObject().put("action", "rename").put("voice", voice).put("name", name)
    }
    data class Forget(val voice: String) : VoiceAction { override fun json() = JSONObject().put("action", "forget").put("voice", voice) }
    data object ForgetAll : VoiceAction { override fun json() = JSONObject().put("action", "forget_all") }
    data object Enable : VoiceAction { override fun json() = JSONObject().put("action", "enable") }
    data class Disable(val forget: Boolean) : VoiceAction { override fun json() = JSONObject().put("action", "disable").put("forget", forget) }
}
/** Fixed codes and copy only; no server message, name, URL or response body in exceptions. */
internal class VoiceLibraryError(val code: String) : IOException("Saved voices: $code") {
    companion object {
        fun text(code: String) = UiText.Res(when (code) {
            "gone" -> R.string.notes_status_voice_gone
            "too_short" -> R.string.notes_status_voice_too_short
            "disabled" -> R.string.notes_status_voice_disabled
            "full" -> R.string.notes_status_voice_full
            "no_voice" -> R.string.notes_status_voice_no_voice
            "unsupported" -> R.string.notes_status_voice_unsupported
            "bad_speakers" -> R.string.notes_status_voice_bad_speakers
            "auth" -> R.string.notes_status_voice_auth
            else -> R.string.notes_status_voice_failed
        })
    }
}
