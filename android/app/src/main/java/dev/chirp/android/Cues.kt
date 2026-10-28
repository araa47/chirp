package dev.chirp.android

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import kotlin.math.PI
import kotlin.math.sin

internal enum class Cue(val tones: List<Pair<Int, Int>>) {
    START(listOf(880 to 70)), STOP(listOf(660 to 70)),
    INSERTED(listOf(660 to 60, 990 to 90)), ERROR(listOf(330 to 160));
}

/** Short generated tones (no bundled audio); silent unless the ringer is in normal mode. */
internal open class Cues(private val context: Context, private val sink: (ShortArray) -> Unit = ::playPcm) {
    open fun play(cue: Cue) {
        val audio = context.getSystemService(AudioManager::class.java)
        if (audio?.ringerMode != AudioManager.RINGER_MODE_NORMAL) return
        try { sink(samples(cue)) } catch (_: Exception) {}
    }
    companion object {
        const val RATE = 22050
        fun samples(cue: Cue): ShortArray = cue.tones.flatMap { (hz, ms) ->
            val count = RATE * ms / 1000; val fade = count / 5
            List(count) { i ->
                val envelope = minOf(1.0, i / fade.toDouble(), (count - 1 - i) / fade.toDouble())
                (sin(2 * PI * hz * i / RATE) * envelope * 0.35 * Short.MAX_VALUE).toInt().toShort()
            }
        }.toShortArray()
        private fun playPcm(pcm: ShortArray) {
            val track = AudioTrack.Builder()
                .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
                .setAudioFormat(AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT).setSampleRate(RATE)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
                .setTransferMode(AudioTrack.MODE_STATIC).setBufferSizeInBytes(pcm.size * 2).build()
            track.write(pcm, 0, pcm.size)
            track.setNotificationMarkerPosition(pcm.size - 1)
            track.setPlaybackPositionUpdateListener(object : AudioTrack.OnPlaybackPositionUpdateListener {
                override fun onMarkerReached(t: AudioTrack) { t.release() }
                override fun onPeriodicNotification(t: AudioTrack) {}
            })
            track.play()
        }
    }
}
