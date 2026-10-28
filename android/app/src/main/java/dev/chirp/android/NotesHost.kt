package dev.chirp.android

import android.Manifest
import android.app.Application
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PersistableBundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.ViewModelStoreOwner
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory

/**
 * One Live Notes session per process, shared by [NotesActivity] and the app shell's Notes tab: the recording notification,
 * the tile and either screen all reach the same notes. Cleared (kept or left for recovery, as [NotesModel.onCleared] does)
 * when the last screen showing it finishes for good; a rotation or fold keeps it.
 */
internal object NotesSessionHolder : ViewModelStoreOwner {
    override val viewModelStore = ViewModelStore()
    private var app: Application? = null
    private val hosts = mutableSetOf<ComponentActivity>()
    private val shown = mutableSetOf<Any>()
    /** The live session, if any screen has opened one (Home's Notes tile says "Recording"). */
    var current by mutableStateOf<NotesModel?>(null)
        private set

    fun model(host: ComponentActivity, create: () -> NotesModel): NotesModel {
        // A new process image (each Robolectric test) never inherits a session from the last.
        if (app !== host.application) { clear(force = true); hosts.clear(); shown.clear(); app = host.application }
        if (hosts.add(host)) host.lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onDestroy(owner: LifecycleOwner) {
                hosts.remove(host); shown.remove(host)
                if (hosts.isEmpty() && !host.isChangingConfigurations && app === host.application) clear()
            }
        })
        return ViewModelProvider(this, viewModelFactory { initializer { create() } })[NotesModel::class.java].also { current = it }
    }
    /** A separate document for browsing while the shared live model keeps recording. Never owns a microphone. */
    fun reader(host: ComponentActivity): NotesModel {
        val live = requireNotNull(current)
        return ViewModelProvider(this, viewModelFactory { initializer {
            NotesModel(host.applicationContext, journal = null, sessions = live.library)
        } })["notes-reader", NotesModel::class.java].also { browsing = it }
    }
    private var browsing: NotesModel? = null

    /** Main thread only: a loaded note must be edited in its model, even when its screen is hidden. */
    fun owner(id: String): NotesModel? = listOfNotNull(current, browsing).firstOrNull { it.document.uid == id }

    private fun clear(force: Boolean = false) { if (!force && RetranscribeGate.owner != null) return; current = null; browsing = null; viewModelStore.clear() }

    /** The notes are on screen somewhere; the battery saver may quiet them only when no host shows them. */
    fun visible(model: NotesModel, host: Any, on: Boolean) {
        if (on) shown.add(host) else shown.remove(host)
        model.visible(shown.isNotEmpty())
    }
}

/** What a screen hosting [NotesScreen] needs from its activity: permission prompts, the save picker, copy, share and fix actions. */
internal class NotesHost(private val activity: ComponentActivity, private val tailscale: () -> TailscaleControl, private val model: () -> NotesModel) {
    private val micPermission = activity.registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) recordWith(pendingRecord ?: { model().start() }) else model().message = NotesStatus.MICROPHONE_PERMISSION
    }
    /** Optional: without it the recording still runs, only its notification (with Stop) stays hidden. */
    private val notificationPermission = activity.registerForActivityResult(ActivityResultContracts.RequestPermission()) { val action = pendingRecord; pendingRecord = null; action?.invoke() }
    private var pendingRecord: (() -> Unit)? = null
    private var exportModel: NotesModel? = null
    private val saveFile = activity.registerForActivityResult(ActivityResultContracts.CreateDocument("text/markdown")) { uri -> uri?.let(::write) }
    private var asked = false

    fun record() {
        val model = model()
        if (model.state.active) { model.toggle(); return }
        recordWith { model.start() }
    }

    fun recordNew() = recordWith { model().let { it.keepSession(); it.clear(); it.start() } }
    fun continueNote(id: String) = recordWith { model().continueRecording(id, stopCurrent = true) }

    private fun recordWith(start: () -> Unit) {
        pendingRecord = start
        when {
            activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED -> micPermission.launch(Manifest.permission.RECORD_AUDIO)
            Build.VERSION.SDK_INT >= 33 && activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED &&
                !asked -> { asked = true; notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS) }
            else -> { pendingRecord = null; start() }
        }
    }

    fun copy() = copy(model())
    fun copy(model: NotesModel) {
        if (!model.hasContent) return
        val clip = ClipData.newPlainText("Chirp notes", model.export())
        // Keeps the notes out of clipboard previews and overlays where the system supports it.
        clip.description.extras = PersistableBundle().apply {
            putBoolean(if (Build.VERSION.SDK_INT >= 33) ClipDescription.EXTRA_IS_SENSITIVE else "android.content.extra.IS_SENSITIVE", true)
        }
        activity.getSystemService(ClipboardManager::class.java)?.setPrimaryClip(clip)
        model.message = NotesStatus.COPIED
    }
    fun share() = share(model())
    fun share(model: NotesModel) {
        if (!model.hasContent) return
        activity.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/markdown")
            .putExtra(Intent.EXTRA_SUBJECT, model.document.title().removePrefix("# ")).putExtra(Intent.EXTRA_TEXT, model.export()), null))
    }
    fun save() = save(model())
    fun save(model: NotesModel) {
        if (!model.hasContent) return
        exportModel = model
        try { saveFile.launch(model.document.fileName()) } catch (_: android.content.ActivityNotFoundException) { model.message = NotesStatus.NO_SAVE_APP }
    }
    fun write(uri: Uri) {
        val note = exportModel ?: model(); exportModel = null
        note.save { activity.contentResolver.openOutputStream(uri, "wt") }
    }
    fun act(action: DictationAction) {
        fun setup(section: String) = activity.startActivity(Intent(activity, SetupActivity::class.java).putExtra("section", section)
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP))
        val tailscale = tailscale()
        when (action) {
            DictationAction.PAIR -> setup("pair")
            DictationAction.MICROPHONE -> activity.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", activity.packageName, null)))
            DictationAction.NETWORK, DictationAction.TAILSCALE_OPEN -> if (!tailscale.open()) setup("network")
            DictationAction.TAILSCALE_SETUP -> setup("network")
            DictationAction.TAILSCALE_ON -> if (tailscale.connect()) model().message = NotesStatus.CONNECTING_TAILSCALE else if (!tailscale.open()) setup("network")
        }
    }
}
