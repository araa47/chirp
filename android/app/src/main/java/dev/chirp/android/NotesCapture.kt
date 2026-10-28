package dev.chirp.android

import android.os.Process
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.sqrt

/**
 * The Notes microphone: like [PcmCapture] but for a whole session, so no 120 s cap and no stop on digital silence (a
 * muted mic in a meeting is a pause, not an error). Each 40 ms frame is a fresh array handed to [frame] with its RMS;
 * nothing is kept or logged.
 */
internal class NotesCapture(
    private val frame: (ByteArray, Float) -> Unit,
    private val level: (Double) -> Unit,
    private val done: (DictationStatus?) -> Unit,
    private val input: PcmInput = MicrophoneInput(),
) : Capture {
    private val running = AtomicBoolean(true)
    private val lock = Any()
    private var thread: Thread? = null

    override fun start() {
        check(thread == null)
        thread = Thread({
            var error: DictationStatus? = null
            val samples = ShortArray(640)
            try {
                Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
                synchronized(lock) { if (running.get()) input.start() }
                var frames = 0
                while (running.get()) {
                    var count = 0
                    while (count < samples.size && running.get()) {
                        val read = input.read(samples, count, samples.size - count)
                        if (read <= 0) { if (running.get() && !input.finished) error = StatusLine.MICROPHONE_UNAVAILABLE; break }
                        count += read
                    }
                    if (!running.get() || count != samples.size) break
                    var energy = 0.0
                    val bytes = ByteArray(count * 2)
                    for (i in samples.indices) {
                        val sample = samples[i].toInt()
                        energy += sample.toDouble() * sample
                        bytes[i * 2] = sample.toByte(); bytes[i * 2 + 1] = (sample shr 8).toByte()
                    }
                    val rms = sqrt(energy / count) / 32768.0
                    if (++frames % 5 == 0) level(rms)
                    frame(bytes, rms.toFloat())
                }
            } catch (_: Exception) {
                if (running.get()) error = StatusLine.MICROPHONE_BLOCKED
            } finally {
                running.set(false); samples.fill(0)
                synchronized(lock) {
                    try { input.stop() } catch (_: RuntimeException) { }
                    try { input.close() } catch (_: RuntimeException) { }
                }
                done(error)
            }
        }, "ChirpNotesCapture").also { it.start() }
    }

    override fun stop() {
        running.set(false)
        synchronized(lock) { try { input.stop() } catch (_: RuntimeException) { } }
    }
}
