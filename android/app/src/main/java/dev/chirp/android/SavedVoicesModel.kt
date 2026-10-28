package dev.chirp.android

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** The shared server library's current view. No local store or optimistic writes. */
internal class SavedVoicesModel(
    private val scope: CoroutineScope,
    private val io: suspend (suspend () -> Unit) -> Unit,
    private val request: (VoiceAction?) -> SavedVoices,
) {
    var library by mutableStateOf<SavedVoices?>(null)
        private set
    var busy by mutableStateOf(false)
        private set
    var error by mutableStateOf<UiText?>(null)
        private set
    var errorCode: String? = null
        private set
    private val mutex = Mutex()
    fun refresh() = scope.launch { perform(null) }
    fun action(action: VoiceAction, complete: (SavedVoices) -> Unit = {}) = scope.launch {
        perform(action)?.let(complete)
    }
    suspend fun perform(action: VoiceAction?): SavedVoices? = mutex.withLock {
        busy = true; error = null; errorCode = null
        try {
            var result: SavedVoices? = null
            io { result = request(action) }
            result.also { library = it }
        } catch (e: CancellationException) { throw e }
        catch (e: VoiceLibraryError) { errorCode = e.code; error = VoiceLibraryError.text(e.code); null }
        catch (_: Exception) { errorCode = "failed"; error = VoiceLibraryError.text("failed"); null }
        finally { busy = false }
    }
}
