package dev.chirp.android

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Process
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.sqrt

interface Capture {
    fun start(); fun stop()
    /** Quiet seconds after speech that end the capture on their own; null stops only on request. Set before [start]. */
    var pauseSeconds: Double? get() = null; set(_) {}
    /** Called once per second with the seconds left before the cap, from 15 down to 1. Set before [start]. */
    var countdown: ((Int) -> Unit)? get() = null; set(_) {}
    /** Seconds the capture may run; it stops one second early. Set before [start]. */
    var limitSeconds: Int get() = CaptureLimit.CAP_SECONDS; set(_) {}
}

/** Injectable PCM input keeps the real framing, buffering and transport path under test. */
internal interface PcmInput {
    val finished: Boolean get() = false
    fun start()
    fun read(samples: ShortArray, offset: Int, count: Int): Int
    fun stop()
    fun close()
}
internal class MicrophoneInput : PcmInput {
    private var recorder: AudioRecord? = null
    @SuppressLint("MissingPermission") // Host checks permission before capture; failed/revoked grants are handled below.
    override fun start() {
        val minimum = AudioRecord.getMinBufferSize(16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        check(minimum > 0)
        val audio = AudioRecord.Builder().setAudioSource(MediaRecorder.AudioSource.VOICE_RECOGNITION)
            .setAudioFormat(AudioFormat.Builder().setSampleRate(16000).setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
            .setBufferSizeInBytes(max(minimum, 1280 * 4)).build()
        recorder = audio
        audio.startRecording()
        check(audio.recordingState == AudioRecord.RECORDSTATE_RECORDING)
    }
    override fun read(samples: ShortArray, offset: Int, count: Int) = recorder?.read(samples, offset, count, AudioRecord.READ_BLOCKING) ?: -1
    override fun stop() { try { recorder?.stop() } catch (_: IllegalStateException) { } }
    override fun close() { recorder?.release(); recorder = null }
}

/** One frame in memory, explicit stop/release before completion, and no content logging. */
internal class PcmCapture(
    private val frame: (ByteArray) -> Boolean,
    private val level: (Double) -> Unit,
    private val done: (DictationStatus?) -> Unit,
    private val input: PcmInput,
) : Capture {
    constructor(frame: (ByteArray) -> Boolean, level: (Double) -> Unit, done: (DictationStatus?) -> Unit) : this(frame, level, done, MicrophoneInput())
    private val running = AtomicBoolean(true)
    private val lock = Any()
    private var thread: Thread? = null
    @Volatile override var pauseSeconds: Double? = null
    @Volatile override var countdown: ((Int) -> Unit)? = null
    @Volatile override var limitSeconds = CaptureLimit.CAP_SECONDS
    override fun start() {
        check(thread == null)
        thread = Thread({
            var error: DictationStatus? = null
            val samples = ShortArray(640)
            try {
                Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
                synchronized(lock) { if (running.get()) input.start() }
                var silentSamples = 0; var total = 0; var signalled = false; var frames = 0; var announced = 0
                val detector = pauseSeconds?.let(::AutoStopDetector)
                while (running.get()) {
                    var count = 0
                    while (count < samples.size && running.get()) {
                        val read = input.read(samples, count, samples.size - count)
                        if (read <= 0) { if (running.get() && !input.finished) error = StatusLine.MICROPHONE_UNAVAILABLE; break }
                        count += read
                    }
                    if (!running.get() || count != samples.size) break
                    var peak = 0; var energy = 0.0
                    for (sample in samples) { peak = max(peak, abs(sample.toInt())); energy += sample.toDouble() * sample }
                    silentSamples = if (peak == 0) silentSamples + count else 0
                    if (silentSamples >= 24000) { error = StatusLine.NO_SIGNAL; break }
                    if (peak > 0) signalled = true
                    if (++frames % 5 == 0) level(sqrt(energy / count) / 32768.0)
                    if (signalled) {
                        val bytes = ByteArray(count * 2)
                        for (i in samples.indices) { bytes[i * 2] = samples[i].toByte(); bytes[i * 2 + 1] = (samples[i].toInt() shr 8).toByte() }
                        if (!frame(bytes)) { error = ConnectionFailure.Kind.OTHER; break }
                    }
                    total += count
                    if (detector?.feed((sqrt(energy / count) / 32768.0).toFloat(), total / 16000.0) == true) break
                    val seconds = total / 16000
                    if (seconds >= limitSeconds - CaptureLimit.COUNTDOWN_SECONDS && seconds != announced) { announced = seconds; countdown?.invoke(limitSeconds - seconds) }
                    if (seconds >= limitSeconds - 1) break
                }
                if (!signalled && error == null && running.get()) error = StatusLine.NO_SIGNAL
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
        }, "ChirpCapture").also { it.start() }
    }
    override fun stop() {
        running.set(false)
        synchronized(lock) { try { input.stop() } catch (_: RuntimeException) { } }
    }
}
