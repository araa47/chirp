package dev.chirp.android

import androidx.annotation.StringRes

/**
 * The one line under the Notes title, and the fix it offers (#339). Notes decides the [action] from what went wrong,
 * not from the words, so the text can be translated.
 */
internal data class NotesStatus(val text: UiText, val action: DictationAction? = null) {
    constructor(@StringRes id: Int, action: DictationAction? = null) : this(UiText.Res(id), action)

    companion object {
        val IDLE = NotesStatus(R.string.notes_status_idle)
        val PAIR = NotesStatus(R.string.notes_status_pair, DictationAction.PAIR)
        val PAIR_AGAIN = NotesStatus(R.string.notes_status_pair_again, DictationAction.PAIR)
        val PAIRING_CHANGED = NotesStatus(R.string.notes_status_pairing_changed)
        val FINISH_RETRANSCRIBE = NotesStatus(R.string.notes_status_finish_retranscribe)
        val FINISH_EDIT = NotesStatus(R.string.notes_status_finish_edit)
        val ALLOW_MICROPHONE = NotesStatus(R.string.notes_status_allow_mic, DictationAction.MICROPHONE)
        val MICROPHONE_PERMISSION = NotesStatus(R.string.notes_status_mic_permission, DictationAction.MICROPHONE)
        val SAVE_FAILED = NotesStatus(R.string.notes_status_save_failed)
        val SAVED = NotesStatus(R.string.notes_status_saved)
        val OPEN_FAILED = NotesStatus(R.string.notes_status_open_failed)
        val COPIED = NotesStatus(R.string.notes_status_copied)
        val NO_SAVE_APP = NotesStatus(R.string.notes_status_no_save_app)
        val CONNECTING_TAILSCALE = NotesStatus(R.string.notes_status_connecting_tailscale)
        val TAILSCALE_OFF = NotesStatus(R.string.notes_status_tailscale_off, DictationAction.TAILSCALE_ON)
        val TAILSCALE_MISSING = NotesStatus(R.string.notes_status_tailscale_missing, DictationAction.TAILSCALE_SETUP)
        /** "Record a little more with them": also the saved voices error for a voice that has gone. */
        val VOICE_GONE = NotesStatus(R.string.notes_status_voice_gone)
    }
}

/**
 * Why a recording, a resume or one segment failed. The recorder keeps the type; Notes resolves [ui] where it is shown and
 * decides the [action] from the type. [english] is the one English form that is stored or logged, never shown through
 * the resources: the gap line saved in the note and exported to Markdown, and the numbers-only Diagnostics.
 */
internal sealed interface RecordingFailure {
    val english: String
    val ui: UiText
    val action: DictationAction? get() = null

    /** The server's answer code, as the user is told it. */
    enum class Server(override val english: String, @StringRes private val id: Int, override val action: DictationAction? = null) : RecordingFailure {
        AUTH("Pairing refused — pair again in Chirp settings", R.string.notes_status_fail_auth, DictationAction.PAIR),
        BUSY("Chirp server is busy", R.string.notes_status_fail_busy),
        TOO_LONG("Segment too long", R.string.notes_status_fail_too_long),
        BAD_AUDIO("audio not understood", R.string.notes_status_fail_bad_audio),
        ENGINE("speech engine hiccup", R.string.notes_status_fail_engine),
        UNAVAILABLE("speech engine unavailable", R.string.notes_status_fail_unavailable);

        override val ui get() = UiText.Res(id)

        companion object {
            fun of(code: String) = when (code) {
                "auth" -> AUTH; "busy" -> BUSY; "too_long" -> TOO_LONG; "bad_audio" -> BAD_AUDIO; "engine" -> ENGINE
                else -> UNAVAILABLE
            }
        }
    }

    data object TimedOut : RecordingFailure {
        override val english = "timed out"
        override val ui = UiText.Res(R.string.notes_status_fail_timed_out)
    }

    data object ConnectionClosed : RecordingFailure {
        override val english = "connection closed"
        override val ui = UiText.Res(R.string.notes_status_fail_closed)
    }

    data object ConnectionLost : RecordingFailure {
        override val english = "connection lost"
        override val ui = UiText.Res(R.string.notes_status_fail_lost)
    }

    /** The Mac could not be reached. [kind] is from the exception classes; [timedOut] is a deadline passing before Ready. */
    data class Connection(val kind: ConnectionFailure.Kind?, val timedOut: Boolean = false) : RecordingFailure {
        /** What the user is told: a connect timeout when the transport recorded no better reason. */
        val shown get() = if (kind == null || kind == ConnectionFailure.Kind.OTHER) (if (timedOut) ConnectionFailure.Kind.DOWN else ConnectionFailure.Kind.OTHER) else kind
        /** Probably Tailscale being off: Notes says that instead when the Mac is on the tailnet. */
        val maybeTailscale get() = shown == ConnectionFailure.Kind.OTHER
        override val english get() = when (shown) {
            ConnectionFailure.Kind.DNS -> "Can't find your computer on the tailnet — is it online?"
            ConnectionFailure.Kind.DOWN -> "Computer may be asleep, or Chirp isn't running"
            ConnectionFailure.Kind.TLS -> "Couldn't make a secure connection to your computer"
            ConnectionFailure.Kind.OTHER -> "Computer unreachable — is Tailscale on?"
        }
        override val ui: UiText get() = shown
        // TLS has no Tailscale fix; the status text alone explains it.
        override val action get() = DictationAction.NETWORK.takeIf { shown != ConnectionFailure.Kind.TLS }
    }

    /** The microphone ended the recording; [status] is the capture's own reason, or null when it gave none. */
    data class Capture(val status: DictationStatus?) : RecordingFailure {
        override val english get() = when (status) {
            null -> "The microphone stopped"
            StatusLine.MICROPHONE_BLOCKED -> "Microphone unavailable — check permission in Chirp settings"
            else -> "Microphone unavailable"
        }
        override val ui: UiText get() = status ?: UiText.Res(R.string.notes_status_fail_microphone)
        override val action get() = DictationAction.MICROPHONE.takeIf { status != null }
    }

    /** Segments kept failing, so the recording ended: "Notes stopped: …". */
    data class Stopped(val cause: RecordingFailure) : RecordingFailure {
        override val english get() = "Notes stopped: " + cause.english
        override val ui get() = UiText.Res(R.string.notes_status_fail_stopped, cause.ui)
    }
}

/** What a note was transcribed with. */
internal sealed interface TranscriptEngine {
    /** Saved with the previous transcript: the engine's name, or `unknown` or `mixed`. */
    val wire: String
    val ui: UiText

    data class Named(val name: String) : TranscriptEngine {
        override val wire get() = name
        override val ui get() = UiText.Raw(name)
    }

    data object Unknown : TranscriptEngine {
        override val wire = "unknown"
        override val ui = UiText.Res(R.string.notes_retranscribe_model_unknown)
    }

    data object Mixed : TranscriptEngine {
        override val wire = "mixed"
        override val ui = UiText.Res(R.string.notes_status_engine_mixed)
    }
}
