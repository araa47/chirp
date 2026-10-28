package dev.chirp.android

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import java.io.File

/** Hands a verified APK to Android's installer. Android still shows its own confirmation, and only accepts an update signed by the installed key. */
internal object UpdateInstaller {
    fun directory(context: Context) = File(context.cacheDir, "updates")
    fun canInstall(context: Context) = context.packageManager.canRequestPackageInstalls()

    /** Null on success, otherwise a short reason. The archive must be this app at the announced version, so a bad manifest can't loop. */
    fun install(context: Context, apk: File, info: UpdateInfo): String? = try {
        val archive = context.packageManager.getPackageArchiveInfo(apk.path, 0)
        if (archive?.packageName != context.packageName || archive.longVersionCode != info.versionCode) context.getString(R.string.update_wrong_archive)
        else {
            val installer = context.packageManager.packageInstaller
            val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
                setAppPackageName(context.packageName); setSize(apk.length())
                setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
            }
            val id = installer.createSession(params)
            installer.openSession(id).use { session ->
                apk.inputStream().use { input -> session.openWrite("chirp.apk", 0, apk.length()).use { out ->
                    input.copyTo(out); session.fsync(out)
                } }
                val result = Intent(context, UpdateInstallReceiver::class.java)
                session.commit(PendingIntent.getBroadcast(context, id, result, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE).intentSender)
            }
            null
        }
    } catch (_: Exception) { context.getString(R.string.update_install_failed) }
}

/** Opens Android's confirmation when the installer asks for it. Success replaces this process, so nothing else is needed. */
class UpdateInstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, 0) != PackageInstaller.STATUS_PENDING_USER_ACTION) return
        @Suppress("DEPRECATION")
        val confirm = (if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
            else intent.getParcelableExtra(Intent.EXTRA_INTENT)) ?: return
        try { context.startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) } catch (_: Exception) {}
    }
}
