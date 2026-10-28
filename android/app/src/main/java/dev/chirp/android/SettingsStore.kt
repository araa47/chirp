package dev.chirp.android

import androidx.annotation.StringRes
import android.content.Context
import androidx.core.content.edit
import android.annotation.SuppressLint
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONObject
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** The "App colours" choices: Pond is Chirp's own scheme, DYNAMIC matches the wallpaper. */
enum class AppColour { POND, DYNAMIC }

class SettingsStore(context: Context) {
    private val prefs = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
    init { PrivateSession.initialize(context) }
    var privateSession: Boolean
        get() = PrivateSession.enabled
        set(value) { PrivateSession.set(value) }
    /** Non-sensitive choice; null means the fresh-install choice page is still unanswered. */
    var inputMode: InputMode?
        get() = prefs.getString("input_mode", null)?.let { saved -> InputMode.entries.firstOrNull { it.name == saved } }
        set(value) { prefs.edit { if (value == null) remove("input_mode") else putString("input_mode", value.name) } }
    var floatingMicSkipped: Boolean
        get() = prefs.getBoolean("floating_mic_skipped", false)
        set(value) { prefs.edit { putBoolean("floating_mic_skipped", value) } }
    fun migrateInputMode(enabled: Boolean, selected: Boolean, bubbleEnabled: Boolean): InputMode? {
        inputMode?.let { return it }
        return migratedInputMode(enabled, selected, bubbleEnabled).also { if (it != null) inputMode = it }
    }
    var correction: Boolean
        get() {
            val current = health
            if (!current.cleanupAvailable() || prefs.getBoolean("correction_suspended", false)) return false
            // 0.5.0 wrote a default false without recording consent. Only new explicit
            // choices override the on-Mac default; external correction remains opt-in.
            return if (prefs.getBoolean("correction_explicit", false)) prefs.getBoolean("correction", false)
                else current?.correctionLeavesMachine == false
        }
        set(value) { prefs.edit {
            putBoolean("correction", value)
            putBoolean("correction_explicit", true)
            putBoolean("correction_suspended", false)
        } }
    /** The first-run "Try it" card on Home was dismissed. */
    var tryItDismissed: Boolean
        get() = prefs.getBoolean("try_it_dismissed", false)
        set(value) { prefs.edit { putBoolean("try_it_dismissed", value) } }
    /** Onboarding finished once: the launcher opens the app shell from then on, even if a requirement later lapses. */
    var onboarded: Boolean
        get() = prefs.getBoolean("onboarded", false)
        set(value) { prefs.edit { putBoolean("onboarded", value) } }
    var defaultStyle: String
        get() = prefs.getString("default_style", "default") ?: "default"
        set(value) { require(CleanupStyles.validId(value)); prefs.edit { putString("default_style", value) } }
    var customInstructions: String
        get() = prefs.getString("custom_instructions", "").orEmpty()
        set(value) { prefs.edit { putString("custom_instructions", CleanupStyles.limitInstructions(value)) } }
    var appStyles: Map<String, String>
        get() = try {
            val saved = prefs.getString("app_styles", null)
            if (saved == null) CleanupStyles.defaults else JSONObject(saved).let { json ->
                json.keys().asSequence().associateWith { json.getString(it) }
            }
        } catch (_: Exception) { CleanupStyles.defaults }
        set(value) {
            require(value.all { (app, style) -> app.matches(Regex("[a-zA-Z0-9_]+(\\.[a-zA-Z0-9_]+)+")) && CleanupStyles.validId(style) })
            prefs.edit { putString("app_styles", JSONObject(value).toString()) }
        }
    fun style(packageName: String?) = CleanupStyles.resolve(packageName, defaultStyle, appStyles, CleanupStyles.profiles(health))
    var promptEdits: Map<String, String>
        get() {
            val saved = prefs.getString("prompt_edits", null)
            if (saved == null) {
                val migrated = customInstructions.takeIf { it.isNotEmpty() }?.let { mapOf("custom" to it) }.orEmpty()
                promptEdits = migrated
                prefs.edit { remove("custom_instructions") }
                return migrated
            }
            return try { JSONObject(saved).let { json -> json.keys().asSequence().associateWith { json.getString(it) } } }
                catch (_: Exception) { emptyMap() }
        }
        set(value) {
            require(value.all { (id, prompt) -> CleanupStyles.validId(id) && CleanupStyles.characterCount(prompt) <= CleanupStyles.MAX_PROMPT })
            prefs.edit { putString("prompt_edits", JSONObject(value).toString()) }
        }
    var haptics: Boolean
        get() = prefs.getBoolean("haptics", true)
        set(value) { prefs.edit { putBoolean("haptics", value) } }
    var spokenCommands: Boolean
        get() = prefs.getBoolean("spoken_commands", false)
        set(value) { prefs.edit { putBoolean("spoken_commands", value) } }
    var stopOnPause: Boolean
        get() = prefs.getBoolean("stop_on_pause", false)
        set(value) { prefs.edit { putBoolean("stop_on_pause", value) } }
    var autoEnter: AutoEnterMode
        get() = AutoEnterMode.of(prefs.getString("auto_enter", null))
        set(value) { prefs.edit { putString("auto_enter", value.key) } }
    var pauseSeconds: Double
        get() = AutoStopDetector.nearest(prefs.getFloat("pause_seconds", AutoStopDetector.DEFAULT_SILENCE.toFloat()).toDouble())
        set(value) { prefs.edit { putFloat("pause_seconds", AutoStopDetector.nearest(value).toFloat()) } }
    /** The pause that ends a dictation on its own, or null when it stops only on tap. */
    val autoStopSeconds: Double? get() = pauseSeconds.takeIf { stopOnPause }
    var hardwareShortcut: Boolean
        get() = prefs.getBoolean("hardware_shortcut", true)
        set(value) { prefs.edit { putBoolean("hardware_shortcut", value) } }
    var soundCues: Boolean
        get() = prefs.getBoolean("sound_cues", false)
        set(value) { prefs.edit { putBoolean("sound_cues", value) } }
    var largerMic: Boolean
        get() = prefs.getBoolean("larger_mic", false)
        set(value) { prefs.edit { putBoolean("larger_mic", value) } }
    var returnToPrevious: Boolean
        get() = prefs.getBoolean("return_to_previous", false)
        set(value) { prefs.edit { putBoolean("return_to_previous", value) } }
    /**
     * "App colours": Pond (the default) or the wallpaper's dynamic colour. Migrated lazily from the
     * pre-Pond boolean, which was only written on an explicit chip tap: an explicit "Match wallpaper"
     * stays wallpaper, an explicit "Chirp green" becomes Pond (its replacement), and no earlier
     * choice at all starts on Pond.
     */
    var appColour: AppColour
        get() {
            prefs.getString("app_colours", null)?.let { saved -> return AppColour.entries.firstOrNull { it.name == saved } ?: AppColour.POND }
            val chosen = if (prefs.contains("dynamic_color") && prefs.getBoolean("dynamic_color", true)) AppColour.DYNAMIC else AppColour.POND
            prefs.edit { putString("app_colours", chosen.name); remove("dynamic_color") }
            return chosen
        }
        set(value) { prefs.edit { putString("app_colours", value.name) } }
    var debugOverlay: Boolean
        get() = prefs.getBoolean("overlay", false)
        set(value) { prefs.edit { putBoolean("overlay", value) } }
    /** Opt-in: when the Mac can't be reached, dictate with the phone's on-device recogniser. */
    var phoneFallback: Boolean
        get() = prefs.getBoolean("phone_fallback", false)
        set(value) { prefs.edit { putBoolean("phone_fallback", value) } }
    /** Notes: a sealed recovery copy of unsaved notes, on by default. */
    var notesAllowRetranscribe: Boolean
        get() = prefs.getBoolean("notes_allow_retranscribe", true)
        set(value) { prefs.edit { putBoolean("notes_allow_retranscribe", value) }; RetranscribeGate.allowed.value = value }
    var notesRebuild: Boolean
        get() = prefs.getBoolean("notes_rebuild", false)
        set(value) { prefs.edit { putBoolean("notes_rebuild", value) } }
    var notesRetranscribeInterrupted: Boolean
        get() = prefs.getBoolean("notes_retranscribe_interrupted", false)
        set(value) { prefs.edit(commit = true) { putBoolean("notes_retranscribe_interrupted", value) } }
    var notesRecovery: Boolean
        get() = prefs.getBoolean("notes_recovery", true)
        set(value) { prefs.edit { putBoolean("notes_recovery", value) } }
    /** Notes: label who said what (the Mac compares voices in its memory). On by default; a stored false is always an explicit user choice. */
    var notesLabelSpeakers: Boolean
        get() = prefs.getBoolean("notes_label_speakers", true)
        set(value) { prefs.edit { putBoolean("notes_label_speakers", value) } }
    val notesSpeakersOptedOut: Boolean get() = prefs.contains("notes_label_speakers") && !notesLabelSpeakers
    /** Notes: skip screen work (live partials, the level meter, editor updates) while the screen is off. On by default. */
    var notesBatterySaver: Boolean
        get() = prefs.getBoolean("notes_battery_saver", true)
        set(value) { prefs.edit { putBoolean("notes_battery_saver", value) } }
    var health: Health?
        get() = try { prefs.getString("health", null)?.let(Protocol::health) } catch (_: Exception) { null }
        set(value) {
            val previous = health
            if (previous != null && (previous.cleanupAvailable() && !value.cleanupAvailable() ||
                    previous.correctionLeavesMachine != value?.correctionLeavesMachine ||
                    previous.correctionHost != value?.correctionHost)) {
                prefs.edit { putBoolean("correction_suspended", true) }
            }
            if (value == null) prefs.edit { remove("health") }
            else prefs.edit { putString("health", JSONObject().put("ok", true).put("ready", value.ready)
                .put("debug_retention", value.debugRetention).put("engine", value.engine.orEmpty())
                .put("notes_retranscribe", value.notesRetranscribe).put("notes_context", value.notesContext).put("speech_model", value.speechModel)
                .put("operation_deadlines", value.operationDeadlines.json())
                .put("correction", if (value.correctionAvailable) "available" else "off")
                .put("correction_leaves_machine", value.correctionLeavesMachine)
                .put("correction_host", value.correctionHost.orEmpty())
                .put("notes_structure", value.notesStructure).put("notes_reorganize", value.notesReorganize).put("notes_correction", value.notesCorrection).put("notes_edit", value.notesEdit)
                .put("speaker_voices", value.speakerVoices).apply { value.speakersVoices?.let { v ->
                    put("speakers_voices", JSONObject().put("enabled", v.enabled).put("count", v.count).put("model", v.model))
                } }
                .put("notes_speakers", value.notesSpeakers).apply { value.speakersModel?.let { put("speakers_model", JSONObject().put("state", it).put("size_bytes", value.speakersModelBytes)) } }
                .put("correction_profiles", org.json.JSONArray().apply {
                    value.correctionProfiles.forEach { profile -> put(JSONObject().put("id", profile.id)
                        .put("name", profile.name).put("description", profile.description).put("rewrites", profile.rewrites)) }
                }).toString()) }
        }
    fun pairing(): Pairing? = try {
        val encrypted = prefs.getString("token", null)
        val iv = prefs.getString("iv", null)
        val url = prefs.getString("url", null)
        if (encrypted == null || iv == null || url == null) null else {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(iv, Base64.NO_WRAP)))
            Pairing.from(url, String(cipher.doFinal(Base64.decode(encrypted, Base64.NO_WRAP)), Charsets.UTF_8))
        }
    } catch (_: Exception) { null } // Key lost after reinstall/restore: pair again.

    @SuppressLint("UseKtx") // Need commit() success to guarantee encrypted credentials were persisted.
    fun save(pairing: Pairing, health: Health) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key()) // Fresh random GCM IV on every write.
        val encrypted = cipher.doFinal(pairing.token.toByteArray(Charsets.UTF_8))
        check(prefs.edit().putString("url", pairing.base.toString())
            .putString("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            .putString("token", Base64.encodeToString(encrypted, Base64.NO_WRAP)).commit())
        this.health = health
    }
    /** Forget pairing: the Mac's address, token and what it said (clean-up consent is per Mac), not the other settings. */
    fun forget() {
        forgetPairingPrefs()
        KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry(KEY_ALIAS) }
    }
    internal fun forgetPairingPrefs() = prefs.edit { PAIRING_KEYS.forEach(::remove) }
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).build())
        }.generateKey()
    }
    /** Floating mic: where the user dropped the bubble on one screen posture (an edge and a height), never text. */
    internal fun bubbleSpot(posture: String): BubbleSpot? {
        val edge = BubbleEdge.entries.firstOrNull { it.name == prefs.getString("bubble_edge_$posture", null) } ?: return null
        return BubbleSpot(edge, prefs.getFloat("bubble_y_$posture", .5f).coerceIn(0f, 1f))
    }
    internal fun saveBubbleSpot(posture: String, spot: BubbleSpot) = prefs.edit {
        putString("bubble_edge_$posture", spot.edge.name); putFloat("bubble_y_$posture", spot.yFraction.coerceIn(0f, 1f))
    }
    companion object {
        internal const val FILE = "chirp"
        private val PAIRING_KEYS = listOf("url", "iv", "token", "health", "correction", "correction_explicit", "correction_suspended")
        private const val KEY_ALIAS = "chirp_pairing_v1"
    }
}

/** Memory-only, shared by every entry point. Process death also ends a private session. */
internal object PrivateSession {
    const val LIMIT_MS = 3_600_000L
    @StringRes val HELP = R.string.private_session_help
    private val main = android.os.Handler(android.os.Looper.getMainLooper())
    @Volatile private var until = 0L
    private var app: android.app.Application? = null
    private val mutable = kotlinx.coroutines.flow.MutableStateFlow(false)
    val state: kotlinx.coroutines.flow.StateFlow<Boolean> = mutable
    private val observers = mutableSetOf<() -> Unit>()
    private val expiry = Runnable { set(false) }
    private val lock = object : android.content.BroadcastReceiver() {
        override fun onReceive(context: Context, intent: android.content.Intent) {
            if (intent.action == android.content.Intent.ACTION_SCREEN_OFF) set(false)
        }
    }
    @Synchronized fun initialize(context: Context) {
        val application = context.applicationContext as android.app.Application
        if (app === application) return
        app?.let { runCatching { it.unregisterReceiver(lock) } }
        val filter = android.content.IntentFilter(android.content.Intent.ACTION_SCREEN_OFF)
        if (android.os.Build.VERSION.SDK_INT >= 33) application.registerReceiver(lock, filter, Context.RECEIVER_NOT_EXPORTED)
        else application.registerReceiver(lock, filter) // Protected system broadcast; no app-supplied events.
        app = application
    }
    val enabled: Boolean get() {
        if (until == 0L) return false
        if (android.os.SystemClock.elapsedRealtime() >= until ||
            app?.getSystemService(android.app.KeyguardManager::class.java)?.isKeyguardLocked == true) { set(false); return false }
        return true
    }
    fun set(value: Boolean) {
        main.removeCallbacks(expiry)
        until = if (value) android.os.SystemClock.elapsedRealtime() + LIMIT_MS else 0L
        mutable.value = value
        if (value) main.postDelayed(expiry, LIMIT_MS)
        val notify = { observers.toList().forEach { it() } }
        if (android.os.Looper.myLooper() == android.os.Looper.getMainLooper()) notify() else main.post { notify() }
    }
    /** Observe only while attached; no keyboard or overlay View is retained after removal. */
    fun observe(view: android.view.View, changed: () -> Unit) {
        initialize(view.context)
        changed()
        view.addOnAttachStateChangeListener(object : android.view.View.OnAttachStateChangeListener {
            override fun onViewAttachedToWindow(v: android.view.View) { observers.add(changed); changed() }
            override fun onViewDetachedFromWindow(v: android.view.View) { observers.remove(changed) }
        })
        if (view.isAttachedToWindow) observers.add(changed)
    }
}
