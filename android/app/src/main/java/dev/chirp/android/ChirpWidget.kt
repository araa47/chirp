package dev.chirp.android

import android.app.PendingIntent
import android.app.StatusBarManager
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Bundle
import android.view.View
import android.widget.RemoteViews
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import dev.chirp.android.ui.ActionRow
import dev.chirp.android.ui.SettingsItem

/** Static controls only: neither the launcher nor its pending intents ever receive dictated text. */
class ChirpWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        ids.forEach { id -> manager.updateAppWidget(id, views(context, manager.getAppWidgetOptions(id).getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 160))) }
    }
    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) {
        manager.updateAppWidget(id, views(context, options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 160)))
    }
    companion object {
        internal fun views(context: Context, width: Int): RemoteViews = RemoteViews(context.packageName, R.layout.chirp_widget).apply {
            setViewVisibility(R.id.widget_record, if (width < 150) View.GONE else View.VISIBLE)
            setOnClickPendingIntent(R.id.widget_dictate, PendingIntent.getActivity(context, 168,
                QuickDictateActivity.intent(context), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
            setOnClickPendingIntent(R.id.widget_record, PendingIntent.getActivity(context, 169,
                NotesActivity.intent(context).setAction(NotesService.ACTION_RECORD), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
            if (SettingsStore(context).appColour == AppColour.DYNAMIC) {
                setColorStateList(R.id.widget_root, "setBackgroundTintList", android.content.res.ColorStateList.valueOf(context.getColor(android.R.color.system_accent1_100)))
                setTextColor(R.id.widget_dictate, context.getColor(android.R.color.system_accent1_900))
                setTextColor(R.id.widget_record, context.getColor(android.R.color.system_accent1_900))
            }
        }
    }
}

internal class DictationEntryRequests(private val context: Context) {
    fun tile(notes: Boolean): String {
        val name = context.getString(if (notes) R.string.notes_short else R.string.dictate_short)
        if (Build.VERSION.SDK_INT < 33) return context.getString(R.string.widget_tile_manual, name)
        return try {
            context.getSystemService(StatusBarManager::class.java).requestAddTileService(
                ComponentName(context, if (notes) NotesTileService::class.java else DictateTileService::class.java),
                name, Icon.createWithResource(context, if (notes) R.drawable.ic_notes else R.drawable.ic_mic),
                context.mainExecutor) { }
            context.getString(R.string.widget_tile_prompt)
        } catch (_: RuntimeException) { context.getString(R.string.widget_tile_fallback) }
    }
    fun widget(): String {
        val manager = context.getSystemService(AppWidgetManager::class.java)
        return if (manager.isRequestPinAppWidgetSupported) {
            manager.requestPinAppWidget(ComponentName(context, ChirpWidgetProvider::class.java), null, null)
            context.getString(R.string.widget_pin_prompt)
        } else context.getString(R.string.widget_pin_manual)
    }
}

@Composable
internal fun OtherDictationEntries() {
    val context = LocalContext.current
    val requests = remember(context) { DictationEntryRequests(context) }
    var message by remember { mutableStateOf<String?>(null) }
    SettingsItem { Text(stringResource(R.string.widget_quick_dictate_body)) }
    ActionRow(stringResource(R.string.widget_add_dictate_tile), { message = requests.tile(false) })
    ActionRow(stringResource(R.string.widget_add_notes_tile), { message = requests.tile(true) })
    ActionRow(stringResource(R.string.widget_add_widget), { message = requests.widget() })
    message?.let { SettingsItem { Text(it) } }
    SettingsItem { Text(stringResource(R.string.widget_recognizer_body)) }
}
