package dev.chirp.android

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class PcmCaptureTest {
    @Test fun `real PCM loop assembles short reads and releases source before completion`() {
        val order = mutableListOf<String>()
        var remaining = 640 * 6
        val input = object : PcmInput {
            override val finished get() = remaining == 0
            override fun start() { order += "start" }
            override fun read(samples: ShortArray, offset: Int, count: Int): Int {
                val size = minOf(remaining, count, 317)
                for (i in offset until offset + size) samples[i] = 1024
                remaining -= size
                return size
            }
            override fun stop() { order += "stop" }
            override fun close() { order += "release" }
        }
        val done = CountDownLatch(1)
        val error = AtomicReference<DictationStatus?>()
        val frames = mutableListOf<ByteArray>()
        PcmCapture({ bytes -> frames += bytes.copyOf(); bytes.fill(0); true }, {}, {
            error.set(it); order += "done"; done.countDown()
        }, input).start()
        assertTrue(done.await(10, TimeUnit.SECONDS)); assertNull(error.get())
        assertEquals(6, frames.size); assertTrue(frames.all { it.size == 1280 && it[1] == 4.toByte() })
        assertTrue(order.indexOf("release") < order.indexOf("done"))
    }
    @Test fun `capture initialization failure still closes source and exposes no exception message`() {
        val done = CountDownLatch(1)
        val error = AtomicReference<DictationStatus?>()
        var closed = false
        val input = object : PcmInput {
            override fun start() { throw SecurityException("synthetic private detail") }
            override fun read(samples: ShortArray, offset: Int, count: Int) = -1
            override fun stop() { throw IllegalStateException("synthetic private detail") }
            override fun close() { closed = true }
        }
        PcmCapture({ true }, {}, { error.set(it); done.countDown() }, input).start()
        assertTrue(done.await(10, TimeUnit.SECONDS)); assertTrue(closed)
        assertTrue(error.get()!!.english().contains("Microphone unavailable"))
        assertFalse(error.get()!!.english().contains("private"))
    }
    @Test fun `stop before first frame releases without reporting a microphone failure`() {
        val done = CountDownLatch(1)
        val error = AtomicReference<DictationStatus?>(StatusLine.UNEXPECTED)
        var opened = false
        var closed = false
        val input = object : PcmInput {
            override fun start() { opened = true }
            override fun read(samples: ShortArray, offset: Int, count: Int) = -1
            override fun stop() = Unit
            override fun close() { closed = true }
        }
        val capture = PcmCapture({ fail("No frame should be sent"); false }, {}, {
            error.set(it); done.countDown()
        }, input)
        capture.stop(); capture.start()
        assertTrue(done.await(10, TimeUnit.SECONDS)); assertNull(error.get())
        assertFalse(opened); assertTrue(closed)
    }
    /** Endless 16 kHz input: [level] gives each frame's constant sample value, indexed by seconds of audio so far. */
    private class Endless(val level: (Int) -> Short) : PcmInput {
        var frames = 0
        override fun start() = Unit
        override fun read(samples: ShortArray, offset: Int, count: Int): Int {
            val value = level(frames * 640 / 16000)
            for (i in offset until offset + count) samples[i] = value
            frames++; return count
        }
        override fun stop() = Unit
        override fun close() = Unit
    }
    private fun run(input: Endless, pause: Double? = null, countdown: MutableList<Int>? = null, limit: Int? = null): Pair<Int, String?> {
        val done = CountDownLatch(1)
        val error = AtomicReference<DictationStatus?>()
        var sent = 0
        val capture = PcmCapture({ sent++; true }, {}, { error.set(it); done.countDown() }, input)
        capture.pauseSeconds = pause
        if (limit != null) capture.limitSeconds = limit
        if (countdown != null) capture.countdown = { countdown += it }
        capture.start()
        assertTrue(done.await(20, TimeUnit.SECONDS))
        return sent to error.get()?.english()
    }
    @Test fun `capture stops itself at 119 seconds and counts down from 15 without an error`() {
        val left = mutableListOf<Int>()
        val (sent, error) = run(Endless { 1024 }, countdown = left)
        assertNull(error); assertEquals(119 * 25, sent)
        assertEquals((15 downTo 1).toList(), left)
    }
    @Test fun `a longer limit moves the stop and the countdown with it`() {
        val left = mutableListOf<Int>()
        val (sent, error) = run(Endless { 1024 }, countdown = left, limit = 140)
        assertNull(error); assertEquals(139 * 25, sent)
        assertEquals((15 downTo 1).toList(), left)
    }
    @Test fun `pause mode stops after the quiet that follows speech`() {
        val left = mutableListOf<Int>()
        val (sent, error) = run(Endless { second -> if (second < 1) 20 else if (second < 3) 4000 else 20 }, pause = 2.0, countdown = left)
        assertNull(error); assertTrue(left.isEmpty())
        assertTrue("stopped at ${sent / 25.0} s", Math.abs(sent / 25.0 - 5.0) <= 0.1)
    }
    @Test fun `pause mode never stops before speech and gives up after 10 seconds`() {
        val (sent, error) = run(Endless { 20 }, pause = 1.0)
        assertNull(error); assertTrue("stopped at ${sent / 25.0} s", Math.abs(sent / 25.0 - 10.0) <= 0.1)
    }
    @Test fun `tap mode ignores pauses`() {
        val (sent, error) = run(Endless { second -> if (second < 3) 4000 else 20 })
        assertNull(error); assertEquals(119 * 25, sent)
    }
}
