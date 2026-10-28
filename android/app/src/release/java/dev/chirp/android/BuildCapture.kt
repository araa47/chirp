package dev.chirp.android

import android.content.Context
import androidx.compose.runtime.Composable
import okhttp3.HttpUrl

internal fun allowedServer(base: HttpUrl) = base.isHttps
internal fun captureForBuild(context: Context, frame: (ByteArray) -> Boolean, level: (Double) -> Unit, done: (DictationStatus?) -> Unit): Capture =
    PcmCapture(frame, level, done)
internal fun notesInputForBuild(context: Context): PcmInput = MicrophoneInput()
@Composable internal fun BuildSetupOptions() { }

internal fun recordDebugNetworkFailure(context: Context, error: Exception) { }
