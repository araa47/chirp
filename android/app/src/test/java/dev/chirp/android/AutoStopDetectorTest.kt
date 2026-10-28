package dev.chirp.android

import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/** The Mac's `AutoStopDetectorTests` vectors, fed in 50 ms frames. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class AutoStopDetectorTest {
    private fun feed(d: AutoStopDetector, rms: Float, from: Double, to: Double): Double? {
        var t = from
        while (t < to) { if (d.feed(rms, t)) return t; t += 0.05 }
        return null
    }
    @Test fun `stops after the pause that follows speech`() {
        val d = AutoStopDetector(2.0)
        assertNull(feed(d, 0.002f, 0.0, 0.5))   // room noise
        assertNull(feed(d, 0.08f, 0.5, 3.0))    // talking
        val fired = feed(d, 0.002f, 3.0, 8.0)
        assertTrue(fired != null && Math.abs(fired - 5.0) < 0.11)
        assertFalse(d.feed(0f, 9.0))             // once
    }
    @Test fun `short pauses between words do not stop`() {
        val d = AutoStopDetector(1.5)
        var t = 0.0
        repeat(10) {
            assertNull(feed(d, 0.06f, t, t + 0.8))
            assertNull(feed(d, 0.003f, t + 0.8, t + 1.6))
            t += 1.6
        }
    }
    @Test fun `steady noise is not speech and never speaking times out`() {
        val d = AutoStopDetector(1.0)
        val fired = feed(d, 0.006f, 0.0, 20.0)
        assertTrue(fired != null && Math.abs(fired - AutoStopDetector.NO_SPEECH_TIMEOUT) < 0.11)
    }
    @Test fun `never stops before speech even with a long leading silence under the timeout`() {
        val d = AutoStopDetector(1.0)
        assertNull(feed(d, 0.001f, 0.0, 9.9))
    }
    @Test fun `pause choices snap and settings keep the mode and pause`() {
        assertEquals(1.5, AutoStopDetector.nearest(1.4), 0.0)
        assertEquals(AutoStopDetector.DEFAULT_SILENCE, AutoStopDetector.nearest(Double.NaN), 0.0)
        val resources = RuntimeEnvironment.getApplication().resources
        assertEquals("1.5 s", AutoStopDetector.label(1.5).resolve(resources)); assertEquals("2 s", AutoStopDetector.label(2.0).resolve(resources))
        val store = SettingsStore(RuntimeEnvironment.getApplication())
        assertFalse(store.stopOnPause); assertNull(store.autoStopSeconds); assertEquals(2.0, store.pauseSeconds, 0.0)
        store.stopOnPause = true; store.pauseSeconds = 3.0
        val again = SettingsStore(RuntimeEnvironment.getApplication())
        assertTrue(again.stopOnPause); assertEquals(3.0, again.autoStopSeconds!!, 0.0)
        again.pauseSeconds = Double.POSITIVE_INFINITY; assertEquals(2.0, again.pauseSeconds, 0.0)
    }
}
