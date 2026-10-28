package dev.chirp.android

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent

/**
 * Live Notes on the phone: record a meeting or a long think-aloud, and the Mac turns it into Markdown notes while the
 * transcript fills in beside them. Saved automatically to the sealed local notes library.
 * The screen itself is [NotesScreen], which the app shell also hosts as its Notes tab; both share one session ([NotesSessionHolder]).
 */
open class NotesActivity : ComponentActivity(), AppShortcutHost {
    override val appShortcuts = AppShortcuts()
    @android.annotation.SuppressLint("RestrictedApi") // Override of the public Activity callback, forwarded by AndroidX.
    override fun dispatchKeyEvent(event: android.view.KeyEvent): Boolean = appShortcuts.dispatch(event) || super.dispatchKeyEvent(event)
    override fun onKeyShortcut(keyCode: Int, event: android.view.KeyEvent): Boolean = appShortcuts.dispatch(event) || super.onKeyShortcut(keyCode, event)
    override fun onProvideKeyboardShortcuts(groups: MutableList<android.view.KeyboardShortcutGroup>, menu: android.view.Menu?, deviceId: Int) {
        super.onProvideKeyboardShortcuts(groups, menu, deviceId)
        appShortcuts.provide(groups, resources)
    }
    internal open fun createModel(): NotesModel = NotesModel(applicationContext)
    internal open val tailscale: TailscaleControl by lazy { AndroidTailscale(this) }
    internal val model: NotesModel by lazy { NotesSessionHolder.model(this, ::createModel) }
    private val host = NotesHost(this, { tailscale }, { model })
    private var recordOnResume = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Keep the notes out of the Recents thumbnail.
        if (Build.VERSION.SDK_INT >= 33) setRecentsScreenshotEnabled(false)
        handle(intent)
        setContent {
            ChirpTheme {
                NotesLibraryScreen(model, NotesSessionHolder.reader(this),
                    record = { id -> if (id == null) host.recordNew() else host.continueNote(id) },
                    copy = { host.copy(it) }, share = { host.share(it) }, save = { host.save(it) }, act = ::act,
                    initialDetail = model.state.active || recordOnResume,
                    connection = { startActivity(Intent(this, SetupActivity::class.java).putExtra("section", "connection")) },
                    dictate = { startActivity(Intent(this, ScratchpadActivity::class.java)) })
            }
        }
    }
    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); handle(intent) }
    override fun onStart() { super.onStart(); NotesSessionHolder.visible(model, this, true); model.refresh() }
    // Screen off or another app in front: the battery saver skips screen work until this is visible again.
    override fun onStop() { NotesSessionHolder.visible(model, this, false); super.onStop() }
    // The microphone service may only start from a visible screen: the tile's Record waits until this one is.
    override fun onResume() { super.onResume(); if (recordOnResume) { recordOnResume = false; if (!model.state.active) record() } }

    private fun handle(intent: Intent?) {
        when (intent?.action) {
            NotesService.ACTION_STOP -> if (model.state.live) model.stop()
            NotesService.ACTION_RECORD -> recordOnResume = true
            else -> return
        }
        setIntent(Intent(intent).setAction(null))
    }

    internal fun record() = host.record()

    /** Back while recording keeps it going in the background; otherwise flush the note before leaving. */
    internal fun leave(discard: Boolean) {
        when {
            model.state.active -> moveTaskToBack(true)
            else -> { model.keepSession(); finish() }
        }
    }

    internal fun copy() = host.copy()
    internal fun share() = host.share()
    internal fun save() = host.save()
    internal fun write(uri: Uri) = host.write(uri)
    internal fun act(action: DictationAction) = host.act(action)

    companion object {
        /** Opens Notes from outside (the recording notification), reusing the running screen. */
        fun intent(context: Context) = Intent(context, NotesActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
    }
}
