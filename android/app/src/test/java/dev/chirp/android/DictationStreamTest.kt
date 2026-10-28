package dev.chirp.android

import android.os.Looper
import java.time.Duration
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class DictationStreamTest {
    private class Harness(deadlines: OperationDeadlines = OperationDeadlines()) {
        val order = mutableListOf<String>()
        lateinit var transport: ChirpImeServiceTest.FakeTransport
        lateinit var capture: ChirpImeServiceTest.FakeCapture
        val statuses = mutableListOf<String>()
        val partials = mutableListOf<ServerEvent.Partial>()
        val finals = mutableListOf<ServerEvent.Final>()
        var ended = 0
        var retention = false
        val session = DictationStream(
            deadlines = deadlines,
            transportFactory = { event, failure -> ChirpImeServiceTest.FakeTransport(event, failure, order).also { transport = it } },
            captureFactory = { frame, _, done -> ChirpImeServiceTest.FakeCapture(frame, done, order).also { capture = it } },
            changed = { status, partial -> statuses += status.english(); if (partial != null) partials += partial },
            level = {}, retention = { retention = it }, final = { finals += it }, ended = { ended++ },
        )
        fun advance(ms: Long = 0) { shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(ms)) }
    }
    @Test fun `buffered hold stops only after release and Ready then final shuts down transport`() {
        val h = Harness(); h.session.start(false)
        assertEquals(listOf("capture.start", "stream.start"), h.order)
        val frame = byteArrayOf(1, 2); h.capture.frame(frame)
        h.capture.deferRelease = true
        h.session.stop(); h.advance()
        assertEquals(0, h.transport.stops)
        h.capture.finish(); h.advance()
        assertEquals(0, h.transport.stops)
        h.transport.ready()
        assertEquals(1, h.transport.stops)
        assertArrayEquals(byteArrayOf(0, 0), frame)
        assertArrayEquals(byteArrayOf(1, 2), h.transport.frames.single())
        h.transport.final()
        assertTrue(h.transport.closed); assertTrue(h.transport.immediate)
        assertEquals(1, h.finals.size); assertEquals(1, h.ended)
        h.transport.final(); assertEquals(1, h.finals.size)
    }
    @Test fun `pause length reaches the capture and countdown is relayed until stopping`() {
        val left = mutableListOf<Int>()
        val order = mutableListOf<String>()
        lateinit var capture: ChirpImeServiceTest.FakeCapture
        val session = DictationStream(
            transportFactory = { event, failure -> ChirpImeServiceTest.FakeTransport(event, failure, order) },
            captureFactory = { frame, _, done -> ChirpImeServiceTest.FakeCapture(frame, done, order).also { capture = it } },
            changed = { _, _ -> }, level = {}, retention = {}, final = {}, ended = {},
            pauseSeconds = 3.0, countdown = { left += it },
        )
        session.start(false)
        assertEquals(3.0, capture.pauseSeconds!!, 0.0)
        capture.countdown!!(15); capture.countdown!!(14)
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(listOf(15, 14), left)
        capture.deferRelease = true; session.stop()
        capture.countdown!!(13); shadowOf(Looper.getMainLooper()).idle()
        assertEquals(listOf(15, 14), left)
    }
    @Test fun `partials stay ordered and cancellation fences late callbacks and releases microphone`() {
        val h = Harness(); h.session.start(false); h.transport.ready()
        h.transport.partial(2, "synthetic"); h.transport.partial(1, "stale")
        assertEquals(listOf("synthetic"), h.partials.map { it.text })
        h.session.cancel(); h.advance()
        assertTrue(h.capture.released); assertTrue(h.transport.cancelled)
        h.transport.partial(3, "late"); h.transport.final(); h.advance(18000)
        assertEquals(1, h.ended); assertTrue(h.finals.isEmpty())
    }
    @Test fun `startup and finalization timeouts release all resources`() {
        val startup = Harness(); startup.session.start(false); startup.advance(7000)
        assertTrue(startup.capture.released); assertTrue(startup.transport.closed)
        assertEquals(ConnectionFailure.Kind.DOWN.english(), startup.statuses.last()); assertEquals(1, startup.ended)
        val finish = Harness(); finish.session.start(false); finish.transport.ready(); finish.session.stop(); finish.advance()
        assertTrue(finish.capture.released); finish.advance(60000)
        assertEquals(1, finish.ended); assertTrue(finish.transport.closed)
    }
    @Test fun `pre-Ready deadline is 7 seconds and Ready cancels it`() {
        val slow = Harness(); slow.session.start(false); slow.advance(6900)
        assertEquals(0, slow.ended); slow.advance(100); assertEquals(1, slow.ended)
        val ok = Harness(); ok.session.start(false); ok.advance(5000); ok.transport.ready(); ok.advance(60000)
        assertEquals(0, ok.ended); assertEquals("Listening…", ok.statuses.last())
    }
    @Test fun `transport failures name the recorded reason and never a server message`() {
        for ((kind, expected) in listOf(ConnectionFailure.Kind.DNS to "Can't find your computer on the tailnet", ConnectionFailure.Kind.DOWN to "asleep",
            ConnectionFailure.Kind.TLS to "secure connection", ConnectionFailure.Kind.OTHER to "Computer unreachable")) {
            val h = Harness(); h.session.start(false)
            h.transport.failureKind = kind; h.transport.failure(); h.advance()
            assertTrue("${kind.name}: ${h.statuses.last()}", h.statuses.last().contains(expected)); assertEquals(1, h.ended)
        }
    }
    @Test fun `a full pre-Ready buffer is reported as a connect timeout unless the transport knows better`() {
        val h = Harness(); h.session.start(false); h.capture.finish(statusOf("Computer unreachable — is Tailscale on?")); h.advance()
        assertEquals(ConnectionFailure.Kind.DOWN.english(), h.statuses.last())
        val dns = Harness(); dns.session.start(false); dns.transport.failureKind = ConnectionFailure.Kind.DNS
        dns.capture.finish(statusOf("Computer unreachable — is Tailscale on?")); dns.advance()
        assertEquals(ConnectionFailure.Kind.DNS.english(), dns.statuses.last())
    }
    @Test fun `debug retention changes before partials and no final is accepted before stop`() {
        val h = Harness(); h.session.start(false)
        h.transport.event(ServerEvent.Ready(true)); assertTrue(h.retention)
        h.transport.final(); assertTrue(h.finals.isEmpty()); assertTrue(h.capture.released)
        assertEquals("Unexpected server response", h.statuses.last())
    }
    @Test fun `polishing fences late partials and commits raw once on timeout or disconnect`() {
        for (disconnect in listOf(false, true)) {
            val h = Harness(); h.session.start(true); h.transport.ready(); h.session.stop(); h.advance()
            h.transport.event(ServerEvent.Correcting(2, "synthetic raw", "chat"))
            assertTrue(h.session.polishing); assertEquals("Polishing…", h.statuses.last())
            h.transport.partial(3, "late partial"); assertTrue(h.partials.isEmpty())
            if (disconnect) h.transport.failure() else h.advance(12000)
            assertEquals(ServerEvent.Final("synthetic raw", "synthetic raw", false, "unavailable"), h.finals.single())
            h.transport.final(); assertEquals(1, h.finals.size); assertEquals(1, h.ended)
        }
    }
    @Test fun `cancel during polishing discards raw and final success wins over timeout`() {
        val h = Harness(); h.session.start(true); h.transport.ready(); h.session.stop(); h.advance()
        h.transport.event(ServerEvent.Correcting(2, "synthetic", "chat")); h.session.cancel(); h.advance(12000)
        assertTrue(h.finals.isEmpty()); assertEquals(1, h.ended)
        val success = Harness(); success.session.start(true); success.transport.ready(); success.session.stop(); success.advance()
        success.transport.event(ServerEvent.Correcting(2, "synthetic", "chat")); success.transport.final(true); success.advance(12000)
        assertTrue(success.finals.single().corrected); assertEquals(1, success.ended)
    }

    @Test fun `CPU polishing survives legacy deadline then keeps raw or accepts a late valid final`() {
        for (complete in listOf(false, true)) {
            val h = Harness(OperationDeadlines(mapOf("dictation" to 30.0)))
            h.session.start(true); h.transport.ready(); h.session.stop(); h.advance()
            h.transport.event(ServerEvent.Correcting(2, "synthetic raw", "default"))
            h.advance(12000); assertEquals(0, h.ended)
            h.advance(22999); assertEquals(0, h.ended)
            if (complete) h.transport.final(true)
            h.advance(1)
            assertEquals(1, h.ended)
            assertEquals(complete, h.finals.single().corrected)
            if (!complete) assertEquals("synthetic raw", h.finals.single().text)
        }
    }

    @Test fun `fast cleanup has a readable transition and cancellation fences pending commit`() {
        val h = Harness(); h.session.start(true); h.transport.ready(); h.session.stop(); h.advance()
        h.transport.event(ServerEvent.Correcting(2, "synthetic", "chat")); h.transport.final(true)
        h.advance(449); assertTrue(h.finals.isEmpty())
        h.advance(1); assertEquals(1, h.finals.size)
        val cancelled = Harness(); cancelled.session.start(true); cancelled.transport.ready(); cancelled.session.stop(); cancelled.advance()
        cancelled.transport.event(ServerEvent.Correcting(2, "synthetic", "chat")); cancelled.transport.final(true)
        cancelled.session.cancel(); cancelled.advance(450)
        assertTrue(cancelled.finals.isEmpty()); assertEquals(1, cancelled.ended)
    }

    @Test fun `blank finals after stop discard polishing raw and terminate once`() {
        for (polishing in listOf(false, true)) {
            val h = Harness(); h.session.start(true); h.transport.ready(); h.session.stop(); h.advance()
            if (polishing) h.transport.event(ServerEvent.Correcting(2, "synthetic raw", "default"))
            h.transport.event(ServerEvent.Final(" ", "", false)); h.advance(450)
            assertTrue(h.finals.isEmpty()); assertEquals("Didn't catch that", h.statuses.last())
            h.session.cancel(); h.transport.failure(); h.transport.final(); h.advance(12000)
            assertEquals(1, h.ended); assertTrue(h.transport.closed)
        }
    }

}
