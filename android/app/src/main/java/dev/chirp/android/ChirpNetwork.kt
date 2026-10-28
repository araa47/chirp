package dev.chirp.android

import java.io.IOException
import java.util.concurrent.TimeUnit
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString.Companion.toByteString

/** No logging interceptors, disk cache, redirects (bearer credential), pings or disk persistence. Idle resources are scoped to IME visibility. */
object ChirpNetwork {
    private val housekeeping = NetworkHousekeeping()
    fun release(client: OkHttpClient, cancel: Boolean = false) = housekeeping.release(client, cancel)
    fun cancel(call: okhttp3.Call?) = housekeeping.cancel(call)
    fun client(context: android.content.Context? = null): OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(6, TimeUnit.SECONDS).readTimeout(12, TimeUnit.SECONDS)
        .callTimeout(12, TimeUnit.SECONDS).webSocketCloseTimeout(1, TimeUnit.SECONDS).followRedirects(false).followSslRedirects(false)
        .retryOnConnectionFailure(false).connectionPool(okhttp3.ConnectionPool(2, 30, TimeUnit.SECONDS)).apply {
            if (context != null && android.os.Build.VERSION.SDK_INT >= 37) {
                val policy = context.localNetworkPolicy()
                dns(PermissionDns(okhttp3.Dns.SYSTEM, policy))
                addInterceptor(literalPermissionInterceptor(policy))
            }
        }.build()
    fun healthCall(client: OkHttpClient, pairing: Pairing): okhttp3.Call {
        val request = Request.Builder().url(pairing.endpoint("v1/health"))
            .header("Authorization", "Bearer ${pairing.token}").build()
        return client.newCall(request)
    }
    fun health(client: OkHttpClient, pairing: Pairing): Health = health(healthCall(client, pairing))
    /**
     * `POST /v1/speakers/model`: [action] `download`, `cancel` (idempotent; retains a ready model), or `remove`. The server's model state
     * after it (`downloading`, `ready`…).
     */
    fun speakerModel(client: OkHttpClient, pairing: Pairing, action: String): String {
        require(action in setOf("download", "cancel", "remove"))
        val request = Request.Builder().url(pairing.endpoint("v1/speakers/model")).header("Authorization", "Bearer ${pairing.token}")
            .post(org.json.JSONObject().put("action", action).toString().toRequestBody("application/json".toMediaType())).build()
        // These commands are idempotent; recover when an idle pooled socket was closed.
        client.newBuilder().retryOnConnectionFailure(true).build().newCall(request).execute().use { response ->
            if (response.code !in setOf(200, 202, 409)) throw IOException("Speaker model unavailable")
            val source = response.body.source()
            source.request(4097)
            if (source.buffer.size > 4096) throw IOException("Speaker model answer too large")
            return org.json.JSONObject(source.readUtf8()).getString("state").takeIf { it.matches(Regex("[a-z_]{1,32}")) }
                ?: throw IOException("Speaker model answer invalid")
        }
    }
    /** Authenticated server library; the response is bounded and held in memory only. */
    internal fun savedVoices(client: OkHttpClient, pairing: Pairing, action: VoiceAction? = null): SavedVoices {
        val request = Request.Builder().url(pairing.endpoint("v1/speakers/voices"))
            .header("Authorization", "Bearer ${pairing.token}").apply {
                if (action != null) post(action.json().toString().toRequestBody("application/json".toMediaType()))
            }.build()
        // The server can close an idle pooled socket between notes. GET is safe to retry;
        // enrollment is a weighted update and must never be replayed automatically.
        // Writes use a fresh connection, closed after the response, to avoid that idle-socket race.
        val reader = client.newBuilder().apply {
            if (action == null) retryOnConnectionFailure(true)
            else connectionPool(okhttp3.ConnectionPool(0, 1, TimeUnit.SECONDS))
        }.build()
        reader.newCall(request).execute().use { response ->
            val source = response.body.source()
            source.request(65537)
            if (source.buffer.size > 65536) throw VoiceLibraryError("failed")
            val text = source.readUtf8()
            if (!response.isSuccessful) {
                val code = try { org.json.JSONObject(text).optString("code") } catch (_: Exception) { "" }
                throw VoiceLibraryError(when {
                    code in setOf("gone", "too_short", "disabled", "full", "no_voice", "bad_speakers") -> code
                    response.code == 401 -> "auth"
                    response.code in setOf(404, 405) -> "unsupported"
                    else -> "failed"
                })
            }
            return try { SavedVoices.decode(text) } catch (_: Exception) { throw VoiceLibraryError("failed") }
        }
    }
    fun health(call: okhttp3.Call): Health {
        call.execute().use { response ->
            if (!response.isSuccessful) throw IOException("Health unavailable")
            val body = response.body
            // Bound memory and never include response/request details in exceptions shown to users.
            val source = body.source()
            source.request(65537)
            if (source.buffer.size > 65536) throw IOException("Health too large")
            return Protocol.health(source.readUtf8())
        }
    }
    fun profiles(client: OkHttpClient, pairing: Pairing): List<CorrectionProfile> {
        val request = Request.Builder().url(pairing.endpoint("v1/correction/profiles"))
            .header("Authorization", "Bearer ${pairing.token}").build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw IOException("Style prompts unavailable")
            val source = response.body.source()
            source.request(512001)
            if (source.buffer.size > 512000) throw IOException("Style prompts too large")
            return Protocol.profiles(source.readUtf8())
        }
    }
    fun dispose(client: OkHttpClient) {
        housekeeping.release(client, cancel = true, dispose = true)
    }
}

/** TLS eviction/cancellation can write close_notify. Never run them on the caller's looper.
 * One process-wide queue preserves release order and survives client dispatcher shutdown.
 * OkHttp cancellation, eviction and executor shutdown are all idempotent.
 */
internal class NetworkHousekeeping(
    private val executor: Executor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "ChirpNetworkCleanup").apply { isDaemon = true }
    },
    private val evict: (OkHttpClient) -> Unit = { it.connectionPool.evictAll() },
) {
    fun release(client: OkHttpClient, cancel: Boolean = false, dispose: Boolean = false) {
        // A hide/show can reuse this client before cleanup runs. Cancel only the calls
        // owned by the old visibility period, never the next utterance's new calls.
        val calls = if (cancel) client.dispatcher.queuedCalls() + client.dispatcher.runningCalls() else emptyList()
        executor.execute {
            calls.forEach { it.cancel() }
            evict(client)
            if (dispose) client.dispatcher.executorService.shutdown()
        }
    }
    fun cancel(call: okhttp3.Call?) { if (call != null) executor.execute { call.cancel() } }
}

internal interface ImeTransport {
    /** Optional versioned preferences for this utterance, set before start. */
    fun learned(payload: LearnedPayload?) {}
    fun retranscription(context: String?) {}
    fun connect()
    fun start(correction: Boolean, profile: String, instructions: String, prompt: String? = null): Boolean = start(correction)
    /** Live Notes: [speakers] is the note's speaker session (labels on), else null. */
    fun start(correction: Boolean, profile: String, instructions: String, prompt: String?, speakers: String?): Boolean =
        start(correction, profile, instructions, prompt)
    fun start(correction: Boolean): Boolean
    fun audio(bytes: ByteArray): Boolean
    fun stop(): Boolean
    fun close(cancel: Boolean = false, immediate: Boolean = false)
    /** Why the last socket attempt failed, classified from exception classes only. */
    val failureKind: ConnectionFailure.Kind get() = ConnectionFailure.Kind.OTHER
    /** System.nanoTime() in ms when the socket last opened, or -1. */
    val openedAt: Long get() = -1L
}

/** Main-thread control; audio() is also called by the capture thread. */
internal class StreamTransport(
    private val client: OkHttpClient,
    private val pairing: Pairing,
    private val dispatch: (() -> Unit) -> Unit,
    private val event: (ServerEvent) -> Unit,
    private val failure: () -> Unit,
    private val opened: () -> Unit = {},
    /** Audio queued on the socket beyond which a frame is refused (network backpressure). */
    private val maxQueued: Long = 160000,
) : ImeTransport {
    @Volatile private var socket: WebSocket? = null
    @Volatile private var ready = false
    @Volatile private var active = false
    @Volatile override var failureKind = ConnectionFailure.Kind.OTHER
        private set
    @Volatile override var openedAt = -1L
        private set
    private var closed = false
    private var connected = false
    private var startSent = false
    private var correction = false
    private var profile = "default"
    private var instructions = ""
    private var prompt: String? = null
    private var speakers: String? = null
    private var retried = false
    private var attempt = 0

    /** Upgrade with bearer authentication only. Do not allocate an engine utterance. */
    override fun connect() {
        if (closed || socket != null) return
        val id = ++attempt
        val request = Request.Builder().url(pairing.endpoint("v1/stream"))
            .header("Authorization", "Bearer ${pairing.token}").build()
        socket = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                dispatch {
                    if (closed || attempt != id) { webSocket.cancel(); return@dispatch }
                    connected = true; failureKind = ConnectionFailure.Kind.OTHER; openedAt = System.nanoTime() / 1_000_000
                    if (active) sendStart()
                    opened()
                }
            }
            override fun onMessage(webSocket: WebSocket, text: String) {
                dispatch {
                    if (closed || attempt != id) return@dispatch
                    val decoded = try { Protocol.decode(text) } catch (_: Exception) {
                        close(true); failure(); return@dispatch
                    }
                    when (decoded) {
                        is ServerEvent.Ready -> {
                            if (!active || !startSent || ready) return@dispatch
                            ready = true
                        }
                        is ServerEvent.Partial, is ServerEvent.Correcting, is ServerEvent.Final -> if (!active || !ready) return@dispatch
                        is ServerEvent.Failure -> if (!active) { close(); failure(); return@dispatch }
                        ServerEvent.Unknown -> return@dispatch
                    }
                    if (decoded is ServerEvent.Final || decoded is ServerEvent.Failure) {
                        active = false; ready = false; startSent = false
                    }
                    event(decoded)
                }
            }
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                // An HTTP response means the Mac answered; only a missing one says anything about reachability.
                failureKind = if (response == null) ConnectionFailure.classify(t) else ConnectionFailure.Kind.OTHER
                dispatch { if (!closed && attempt == id) {
                    if (retranscribe && response?.code == 401) { event(ServerEvent.Failure("auth")); close() } else failed()
                } }
            }
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                webSocket.close(code, null)
                dispatch { if (!closed && attempt == id) failed() }
            }
        })
    }
    private var retranscribe = false
    private var retranscribeContext: String? = null
    override fun retranscription(context: String?) { retranscribe = true; retranscribeContext = context }
    private var learnedPayload: LearnedPayload? = null
    override fun learned(payload: LearnedPayload?) { learnedPayload = payload }
    override fun start(correction: Boolean, profile: String, instructions: String, prompt: String?): Boolean =
        start(correction, profile, instructions, prompt, null)
    override fun start(correction: Boolean, profile: String, instructions: String, prompt: String?, speakers: String?): Boolean {
        this.profile = profile; this.instructions = instructions; this.prompt = prompt; this.speakers = speakers
        return start(correction)
    }
    override fun start(correction: Boolean): Boolean {
        if (closed || active) return false
        active = true; ready = false; startSent = false; retried = false
        this.correction = correction
        if (connected) sendStart() else connect()
        return !closed
    }
    private fun sendStart() {
        startSent = socket?.send(Protocol.start(correction, profile, instructions, prompt, speakers, learnedPayload, retranscribe)) == true
        if (!startSent) failed()
    }
    private fun failed() {
        if (closed) return
        val wasReady = ready
        socket?.cancel(); socket = null; connected = false; startSent = false; ready = false
        // No audio has left the pre-ready buffer: one reconnect can safely retry start.
        if (!retried && !wasReady) { retried = true; connect() }
        else { close(); failure() }
    }
    override fun audio(bytes: ByteArray): Boolean {
        if (!active || !ready) return false
        val ws = socket ?: return false
        if (ws.queueSize() + bytes.size > maxQueued) return false // Bound network backpressure as well.
        return ws.send(bytes.toByteString())
    }
    override fun stop(): Boolean = active && ready && socket?.send(Protocol.stop(retranscribeContext)) == true

    /** Cancel retires the socket: v1 has no cancel acknowledgement or session IDs on finals. */
    override fun close(cancel: Boolean, immediate: Boolean) {
        if (closed) return
        instructions = ""; prompt = null
        closed = true; ++attempt; active = false; ready = false; connected = false
        val ws = socket
        socket = null
        if (cancel) ws?.send(Protocol.CANCEL)
        if (immediate) ws?.cancel() else ws?.close(1000, null)
    }
}
