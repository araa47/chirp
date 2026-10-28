package dev.chirp.android

import android.os.Looper
import java.time.Duration
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** Long dictation over rolling sockets, with a fake microphone and fake sockets: 25 frames of 40 ms per second. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class RollingDictationTest {
    private class Harness(kept: Boolean = true) {
        val order = mutableListOf<String>()
        val transports = mutableListOf<ChirpImeServiceTest.FakeTransport>()
        lateinit var capture: ChirpImeServiceTest.FakeCapture
        val statuses = mutableListOf<String>()
        val partials = mutableListOf<String>()
        val landed = mutableListOf<String>()
        var nexts = 0
        val lasts = mutableListOf<Boolean>()
        var ended = 0
        var sent = 0
        val session: RollingDictation = RollingDictation(
            transportFactory = { event, failure -> ChirpImeServiceTest.FakeTransport(event, failure, order).also { transports += it } },
            captureFactory = { frame, _, done -> ChirpImeServiceTest.FakeCapture(frame, done, order).also { capture = it } },
            changed = { status, partial -> statuses += status.english(); if (partial != null) partials += partial.text },
            level = {}, retention = {}, final = { landed += "final:${it.text}"; lasts += session.landingLast }, ended = { ended++ },
            kept = if (kept) { heard, reason -> landed += "kept:$heard:${reason.english()}" } else null,
            next = { nexts++; landed += "next" },
        )
        fun advance(ms: Long = 0) { shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(ms)) }
        /** Frames carry their index in the first sample, so the sockets' frames show order and gaps. */
        fun speak(seconds: Double, loud: Boolean = true) = repeat((seconds * 25).toInt()) {
            val samples = ShortArray(640) { if (loud) 8000 else 0 }
            samples[0] = sent.toShort()
            val bytes = ByteArray(1280)
            for (i in samples.indices) { bytes[i * 2] = samples[i].toByte(); bytes[i * 2 + 1] = (samples[i].toInt() shr 8).toByte() }
            sent++
            capture.frame(bytes)
        }
        fun indices(transport: ChirpImeServiceTest.FakeTransport) = transport.frames.map { (it[0].toInt() and 0xff) or (it[1].toInt() shl 8) }
        /** Talk past the minimum segment, then pause until the segmenter cuts. */
        fun rollOver() { speak(DictationSegmenter.MIN_SEGMENT); speak(DictationSegmenter.PAUSE_CUT, loud = false); advance() }
        fun final(transport: ChirpImeServiceTest.FakeTransport, text: String) = transport.event(ServerEvent.Final(text, text, false))
    }

    @Test fun `segmenter waits for the minimum, prefers pauses, relaxes them and forces the maximum`() {
        fun cutAt(rms: (Double) -> Float): Double {
            val segmenter = DictationSegmenter()
            while (!segmenter.feed(rms(segmenter.elapsed), 0.04)) Unit
            return segmenter.elapsed
        }
        assertEquals(45.0, cutAt { 0f }, 0.05)
        assertEquals(50.6, cutAt { if (it < 50.0) 0.2f else 0f }, 0.05)
        assertEquals(70.3, cutAt { if (it < 70.0) 0.2f else 0f }, 0.1)
        assertEquals(90.0, cutAt { 0.2f }, 0.05)
        assertEquals(90.0, cutAt { if ((it * 10).toInt() % 5 == 0) 0f else 0.2f }, 0.05)
        assertTrue(DictationSegmenter.rms(ByteArray(1280)) < DictationSegmenter.QUIET_RMS)
    }
    @Test fun `a short dictation is one utterance and the microphone has a long limit`() {
        val h = Harness(); h.session.start(false); h.transports[0].ready()
        assertEquals(listOf("capture.start", "stream.start"), h.order)
        assertEquals(CaptureLimit.ROLLING_SECONDS, h.capture.limitSeconds)
        h.speak(30.0); h.speak(5.0, loud = false); h.advance()
        assertEquals(1, h.transports.size)
        h.session.stop(); h.advance(); assertEquals(1, h.transports[0].stops)
        h.final(h.transports[0], "One."); h.advance()
        assertEquals(listOf("final:One."), h.landed); assertEquals(1, h.ended); assertEquals(0, h.nexts)
    }
    @Test fun `the hand-off drops no frame and keeps capture order across sockets`() {
        val h = Harness(); h.session.start(false); h.transports[0].ready()
        h.rollOver()
        assertEquals(2, h.transports.size); assertEquals(1, h.transports[0].stops)
        assertFalse(h.capture.stopRequested)
        // The new socket is not ready yet: frames wait in its buffer, then flush in order.
        h.speak(2.0); assertTrue(h.transports[1].frames.isEmpty())
        h.transports[1].ready(); h.speak(1.0)
        assertEquals((0 until h.sent).toList(), h.indices(h.transports[0]) + h.indices(h.transports[1]))
        assertEquals(((45 + 0.6) * 25).toInt(), h.transports[0].frames.size)
        h.rollOver(); h.transports[2].ready(); h.speak(1.0)
        assertEquals((0 until h.sent).toList(), h.transports.flatMap(h::indices))
    }
    @Test fun `finals land in segment order even when a later one finishes first`() {
        val h = Harness(); h.session.start(true); h.transports[0].ready(); h.transports[0].partial(1, "one")
        h.rollOver(); h.transports[1].ready(); h.transports[1].partial(1, "two")
        h.session.stop(); h.advance()
        assertTrue(h.capture.released); assertEquals(1, h.transports[1].stops)
        h.final(h.transports[1], "Two."); h.advance()
        assertTrue(h.landed.isEmpty()); assertEquals(0, h.ended)
        h.final(h.transports[0], "One."); h.advance()
        assertEquals(listOf("final:One.", "next", "final:Two."), h.landed); assertEquals(1, h.ended)
        assertEquals(listOf(false, true), h.lasts)
    }
    @Test fun `only the oldest unfinished segment reaches the editor and later partials are replayed after it lands`() {
        val h = Harness(); h.session.start(false); h.transports[0].ready(); h.transports[0].partial(1, "one")
        h.rollOver(); h.transports[1].ready()
        h.transports[1].partial(1, "two"); h.transports[1].partial(2, "two more")
        assertEquals(listOf("one"), h.partials)
        assertEquals("Listening…", h.statuses.last())
        assertFalse(h.session.stopping)
        h.final(h.transports[0], "One."); h.advance()
        assertEquals(listOf("final:One.", "next"), h.landed)
        assertEquals(listOf("one", "two more"), h.partials)
        h.transports[1].partial(3, "two more words"); assertEquals("two more words", h.partials.last())
        assertEquals(0, h.ended)
    }
    @Test fun `cleanup runs per segment and polishing shows only once the dictation is stopping`() {
        val h = Harness(); val raws = mutableListOf<String>()
        val session = RollingDictation(
            transportFactory = { event, failure -> ChirpImeServiceTest.FakeTransport(event, failure, h.order).also { h.transports += it } },
            captureFactory = { frame, _, done -> ChirpImeServiceTest.FakeCapture(frame, done, h.order).also { h.capture = it } },
            changed = { status, _ -> h.statuses += status.english() }, level = {}, retention = {}, final = { h.landed += it.text }, ended = { h.ended++ },
            correcting = { raws += it.raw },
        )
        session.start(true); h.transports[0].ready(); h.rollOver(); h.transports[1].ready()
        assertTrue(h.transports.all { it.correctionRequested })
        h.transports[0].event(ServerEvent.Correcting(2, "raw one", "default"))
        assertEquals(listOf("raw one"), raws); assertFalse(session.polishing); assertEquals("Listening…", h.statuses.last())
        session.stop(); h.advance()
        assertTrue(session.polishing); assertEquals("Polishing…", h.statuses.last())
        h.transports[0].event(ServerEvent.Final("One.", "raw one", true)); h.advance(450)
        assertEquals(listOf("One."), h.landed)
        h.transports[1].event(ServerEvent.Correcting(2, "raw two", "default")); h.transports[1].event(ServerEvent.Final("Two.", "raw two", true)); h.advance(450)
        assertEquals(listOf("One.", "Two."), h.landed); assertEquals(listOf("raw one", "raw two"), raws); assertEquals(1, h.ended)
    }
    @Test fun `a failing live segment keeps what it heard after the earlier final and stops the microphone`() {
        val h = Harness(); h.session.start(false); h.transports[0].ready()
        h.rollOver(); h.transports[1].ready(); h.transports[1].partial(1, "heard")
        h.transports[1].failure(); h.advance()
        assertTrue(h.capture.stopRequested); assertTrue(h.session.stopping)
        assertTrue(h.landed.isEmpty()); assertEquals(0, h.ended)
        h.final(h.transports[0], "One."); h.advance()
        assertEquals("final:One.", h.landed[0]); assertEquals("next", h.landed[1])
        assertTrue(h.landed[2].startsWith("kept:heard:")); assertEquals(1, h.ended)
        assertEquals(2, h.transports.size)
    }
    @Test fun `a failing earlier segment keeps its heard text and dictation continues`() {
        val h = Harness(); h.session.start(false); h.transports[0].ready(); h.transports[0].partial(1, "one")
        h.rollOver(); h.transports[1].ready()
        h.transports[0].event(ServerEvent.Failure("engine")); h.advance()
        assertEquals(listOf("kept:one:Speech engine hiccup", "next"), h.landed)
        assertFalse(h.capture.stopRequested); assertFalse(h.session.stopping)
        h.speak(1.0); assertEquals(25, h.transports[1].frames.size)
        h.session.stop(); h.advance(); h.final(h.transports[1], "Two."); h.advance()
        assertEquals("final:Two.", h.landed.last()); assertEquals(1, h.ended)
    }
    @Test fun `an earlier segment that heard nothing is skipped quietly and a last one names the reason`() {
        val h = Harness(); h.session.start(false); h.transports[0].ready()
        h.rollOver(); h.transports[1].ready()
        h.transports[0].failure(); h.advance()
        assertEquals(listOf("next"), h.landed); assertEquals("Listening…", h.statuses.last())
        h.transports[1].failure(); h.advance()
        assertEquals(1, h.ended); assertTrue(h.statuses.last(), h.statuses.last().startsWith("Computer unreachable"))
    }
    @Test fun `the deadline of a segment still connecting fails only that segment`() {
        val h = Harness(); h.session.start(false); h.transports[0].ready()
        h.rollOver(); h.speak(1.0); h.advance(7000)
        assertTrue(h.transports[1].closed); assertTrue(h.capture.stopRequested)
        assertEquals(0, h.ended)
        h.final(h.transports[0], "One."); h.advance()
        assertEquals(listOf("final:One.", "next"), h.landed); assertEquals(1, h.ended)
    }
    @Test fun `cancel discards every segment not yet landed and fences late events`() {
        val h = Harness(); h.session.start(false); h.transports[0].ready()
        h.rollOver(); h.transports[1].ready(); h.transports[1].partial(1, "two")
        h.session.cancel(); h.advance()
        assertTrue(h.transports.all { it.cancelled }); assertTrue(h.capture.stopRequested); assertEquals(1, h.ended)
        h.final(h.transports[0], "late"); h.transports[1].failure(); h.speak(1.0); h.advance(60000)
        assertTrue(h.landed.isEmpty()); assertEquals(1, h.ended); assertEquals(2, h.transports.size)
    }
    @Test fun `no cut is made after stop and a microphone error ends the live segment`() {
        val h = Harness(); h.session.start(false); h.transports[0].ready()
        h.capture.deferRelease = true
        h.speak(DictationSegmenter.MIN_SEGMENT); h.session.stop(); h.speak(1.0, loud = false); h.advance()
        assertEquals(1, h.transports.size)
        val mic = Harness(); mic.session.start(false); mic.transports[0].ready(); mic.transports[0].partial(1, "heard")
        mic.capture.finish(statusOf("Microphone unavailable")); mic.advance()
        assertEquals(listOf("kept:heard:Microphone unavailable"), mic.landed); assertEquals(1, mic.ended)
    }
}
