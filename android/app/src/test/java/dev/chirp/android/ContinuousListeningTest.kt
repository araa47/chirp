package dev.chirp.android

import android.os.Looper
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** "Keep listening until I stop" (#381) on the entry points that take one result: Quick dictate and the Scratchpad roll and join. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class ContinuousListeningTest {
    private val app get() = RuntimeEnvironment.getApplication()
    private val store get() = SettingsStore(app)
    private fun idle() = shadowOf(Looper.getMainLooper()).idle()
    private fun ChirpImeServiceTest.FakeCapture.speak(seconds: Double, loud: Boolean) =
        repeat((seconds * 25).toInt()) { frame(ByteArray(1280) { i -> if (!loud) 0 else if (i % 2 == 0) 0x40 else 0x1f }) }
    /** Talks past the first cut so the next segment opens and the old one is asked for its final. */
    private fun ChirpImeServiceTest.FakeCapture.rollOver(loud: Boolean = true) {
        speak(DictationSegmenter.MIN_SEGMENT, loud); speak(DictationSegmenter.PAUSE_CUT, false); idle()
    }
    @After fun reset() { store.continuousListening = false }

    @Test fun `the setting is off by default, round-trips and overrides stop on pause`() {
        assertFalse(store.continuousListening)
        store.stopOnPause = true; store.pauseSeconds = 3.0
        assertEquals(3.0, store.autoStopSeconds!!, 0.0)
        store.continuousListening = true
        assertTrue(SettingsStore(app).continuousListening); assertNull(SettingsStore(app).autoStopSeconds)
        store.continuousListening = false
        assertEquals(3.0, SettingsStore(app).autoStopSeconds!!, 0.0)
    }

    private class Quick(context: android.content.Context) {
        val wires = mutableListOf<Wire>()
        lateinit var capture: ChirpImeServiceTest.FakeCapture
        val model = QuickDictateModel(context, history = DictationHistory(context, SoftwareHistoryKeys()).also { it.disable() },
            captureFactory = { _, frame, _, done -> ChirpImeServiceTest.FakeCapture(frame, done, mutableListOf()).also { capture = it } },
            transportFactory = { _, _, event, failure -> Wire(event, failure).also { wires += it } },
            micGranted = { true }, pairing = { Pairing.from("https://speech.example.test/chirp", "synthetic") }, io = { it() })
    }

    @Test fun `Quick dictate rolls past the cap and through silence, joining every segment into one result`() {
        store.continuousListening = true
        val quick = Quick(app); val model = quick.model
        model.start(); quick.wires[0].ready(); quick.wires[0].partial(1, "one"); idle()
        assertEquals(CaptureLimit.UNLIMITED, quick.capture.limitSeconds); assertNull(quick.capture.pauseSeconds)
        quick.capture.rollOver()
        assertEquals(2, quick.wires.size); assertEquals(1, quick.wires[0].stops); assertTrue(model.active)
        quick.wires[1].ready(); quick.wires[1].partial(1, "two"); idle()
        quick.wires[0].final("One."); idle()
        assertEquals("One. two", model.partial); assertEquals(StatusLine.LISTENING, model.status)
        // A long silent stretch: the segment it fills finalizes empty, which is neither an error nor the end.
        quick.capture.rollOver(); quick.wires[2].ready(); quick.wires[1].final("Two."); idle()
        quick.capture.speak(DictationSegmenter.MIN_SEGMENT + 1, false); idle()
        assertEquals(4, quick.wires.size); quick.wires[3].ready(); quick.wires[2].final(""); idle()
        assertTrue(model.active); assertEquals(StatusLine.LISTENING, model.status); assertEquals("", model.text)
        model.stop(); idle()
        assertEquals(1, quick.wires[3].stops); quick.wires[3].final(""); idle()
        assertFalse(model.active); assertEquals("One. Two.", model.text); assertEquals(StatusLine.COPIED_PASTE, model.status)
    }

    @Test fun `Quick dictate in keep-listening mode still cancels at once`() {
        store.continuousListening = true
        val quick = Quick(app)
        quick.model.start(); quick.wires[0].ready(); quick.capture.rollOver(); quick.wires[1].ready()
        quick.model.cancel(); idle()
        assertFalse(quick.model.active); assertTrue(quick.wires.all { it.closed && it.cancelled }); assertEquals("", quick.model.text)
    }

    @Test fun `without the setting Quick dictate is still one utterance under the cap`() {
        val quick = Quick(app)
        quick.model.start(); quick.wires[0].ready()
        assertEquals(CaptureLimit.CAP_SECONDS, quick.capture.limitSeconds)
        quick.capture.rollOver(); assertEquals(1, quick.wires.size)
        quick.model.cancel()
    }

    @Test fun `the Scratchpad joins segments into one insertion and a failing segment keeps the words already landed`() {
        store.continuousListening = true
        val rig = Rig(app)
        rig.model.toggle(); rig.wire.ready(); rig.wire.partial(1, "one"); rig.idle()
        rig.capture.rollOver(); rig.wires[1].ready(); rig.wires[0].final("One."); rig.idle()
        rig.wires[1].partial(1, "two"); rig.idle()
        assertEquals("One. two", rig.model.partial); assertTrue(rig.model.active)
        rig.model.toggle(); rig.idle(); rig.wires[1].final("Two."); rig.idle()
        assertFalse(rig.model.active); assertEquals("One. Two.", rig.model.field.text)
        // Again, and the live segment's connection drops: the landed words still go in, and the reason shows.
        rig.model.clear()
        rig.model.toggle(); rig.wire.ready(); rig.capture.rollOver(); val live = rig.wire
        live.ready(); rig.wires[rig.wires.size - 2].final("Kept."); rig.idle()
        live.failure(); rig.idle()
        assertFalse(rig.model.active); assertEquals("Kept.", rig.model.field.text)
        assertTrue(rig.model.status.english(), rig.model.status != StatusLine.PAD_FINISHED && rig.model.status != StatusLine.PAD_POLISHED)
    }
}
