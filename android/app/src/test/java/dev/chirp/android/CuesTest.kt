package dev.chirp.android

import android.content.Context
import android.media.AudioManager
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class CuesTest {
    private val context: Context = RuntimeEnvironment.getApplication()
    private fun ringer(mode: Int) = context.getSystemService(AudioManager::class.java).setRingerMode(mode)

    @Test fun `tones are short, bounded and fade in and out`() {
        for (cue in Cue.entries) {
            val pcm = Cues.samples(cue)
            val ms = pcm.size * 1000 / Cues.RATE
            assertTrue("$cue $ms ms", ms in 50..250)
            assertTrue(pcm.maxOf { Math.abs(it.toInt()) } < Short.MAX_VALUE / 2)
            assertEquals(0, pcm.first().toInt()); assertTrue(Math.abs(pcm.last().toInt()) < 400)
        }
        assertNotEquals(Cues.samples(Cue.START).toList(), Cues.samples(Cue.STOP).toList())
    }
    @Test fun `plays only when the ringer is normal`() {
        val played = mutableListOf<Int>()
        val cues = Cues(context) { played += it.size }
        ringer(AudioManager.RINGER_MODE_NORMAL); cues.play(Cue.START); assertEquals(1, played.size)
        ringer(AudioManager.RINGER_MODE_VIBRATE); cues.play(Cue.STOP)
        ringer(AudioManager.RINGER_MODE_SILENT); cues.play(Cue.ERROR)
        assertEquals(1, played.size)
    }
    @Test fun `a failing audio sink never reaches dictation`() {
        ringer(AudioManager.RINGER_MODE_NORMAL)
        Cues(context) { throw IllegalStateException("synthetic audio failure") }.play(Cue.INSERTED)
    }
    @Test fun `error statuses are recognised and normal ones are not`() {
        for (status in listOf("Didn't catch that", "Speech engine hiccup", "Chirp server is busy — try again", "Allow microphone in Chirp settings",
            "Dictation unavailable in password fields", "Chirp server took too long — try again", "Text field unavailable — try again",
            ConnectionFailure.Kind.DNS.english(), ConnectionFailure.Kind.DOWN.english(), ConnectionFailure.Kind.TLS.english()))
            assertTrue(status, statusOf(status).error)
        for (status in listOf("Listening…", "Finishing…", "Polishing…", "Cancelled", "Inserted · tap mic to dictate again", "Tailscale connected"))
            assertFalse(status, statusOf(status).error)
    }
}
