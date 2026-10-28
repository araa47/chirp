package dev.chirp.android

import kotlin.math.abs
import kotlin.math.max

/** The server accepts 120 s of audio per utterance; capture stops 1 s before its limit and counts down over the last 15 s. */
internal object CaptureLimit {
    const val CAP_SECONDS = 120
    const val COUNTDOWN_SECONDS = 15
    /** A keyboard dictation rolls into new utterances at pauses, up to this long in all. */
    const val ROLLING_SECONDS = 600
}

/**
 * Port of the Mac's `AutoStopDetector`: fires once when the speaker has been quiet for `silence` seconds after speaking,
 * or has not spoken within [NO_SPEECH_TIMEOUT]. Speech is judged against the room's own noise floor, which follows the
 * quietest frames at once and rises only slowly, so steady background noise never counts as talking.
 */
internal class AutoStopDetector(private val silence: Double = DEFAULT_SILENCE) {
    private var floor: Float? = null
    private var startedAt: Double? = null
    private var lastSpeech: Double? = null
    private var fired = false

    fun feed(rms: Float, time: Double): Boolean {
        if (fired) return false
        val start = startedAt ?: time
        startedAt = start
        val current = floor ?: rms
        floor = if (rms < current) rms else current + (rms - current) * 0.002f
        if (rms >= max(MINIMUM_SPEECH, current * SPEECH_RATIO)) lastSpeech = time
        val spoke = lastSpeech
        if (spoke != null) { if (time - spoke >= silence) fired = true }
        else if (time - start >= NO_SPEECH_TIMEOUT) fired = true
        return fired
    }

    companion object {
        const val DEFAULT_SILENCE = 2.0
        /** The pauses offered in settings, in seconds. */
        val CHOICES = listOf(1.0, 1.5, 2.0, 3.0, 5.0)
        const val NO_SPEECH_TIMEOUT = 10.0
        /** Below this RMS (about −40 dBFS) nothing is speech, however quiet the room. */
        const val MINIMUM_SPEECH = 0.01f
        /** Speech is this many times the noise floor. */
        const val SPEECH_RATIO = 3f
        fun nearest(seconds: Double) = if (seconds.isFinite()) CHOICES.minByOrNull { abs(it - seconds) }!! else DEFAULT_SILENCE
        fun label(seconds: Double) = UiText.Res(R.string.stop_pause_seconds, if (seconds % 1.0 == 0.0) seconds.toInt().toString() else seconds.toString())
    }
}
