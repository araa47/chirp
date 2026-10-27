package dev.chirp.android.shell

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Drawable
import android.os.Build
import android.os.PersistableBundle
import androidx.annotation.DrawableRes
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import dev.chirp.android.DictationHistory
import dev.chirp.android.HistoryEntry
import dev.chirp.android.HistorySettings
import dev.chirp.android.NotesDocument
import dev.chirp.android.NotesIndexEntry
import dev.chirp.android.NotesSessionHolder
import dev.chirp.android.NotesSessions
import dev.chirp.android.R
import dev.chirp.android.historyAge
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal enum class HistoryDay(val label: String) { Today("Today"), Yesterday("Yesterday"), Earlier("Earlier") }

/** Calendar day in [zone], not a 24-hour window: a dictation from 23:50 is Yesterday at 00:10. */
internal fun historyDay(now: Long, time: Long, zone: ZoneId = ZoneId.systemDefault()): HistoryDay {
    val today = Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
    val day = Instant.ofEpochMilli(time).atZone(zone).toLocalDate()
    return when { !day.isBefore(today) -> HistoryDay.Today; day == today.minusDays(1) -> HistoryDay.Yesterday; else -> HistoryDay.Earlier }
}

internal fun historyMatches(entry: HistoryEntry, query: String): Boolean =
    query.isBlank() || listOfNotNull(entry.text, entry.raw, entry.app).any { it.contains(query.trim(), ignoreCase = true) }

/** "Gmail · 2 min ago · Polished": app, age and whether clean-up changed it. Never any of the text. */
internal fun historyMeta(entry: HistoryEntry, now: Long): String =
    listOfNotNull(entry.app, historyAge(now, entry.time).first, if (entry.partial) "partial" else if (entry.raw != null) "Polished" else null).joinToString(" · ")

/** Dictated text on the clipboard, kept out of clipboard previews and overlays where the system supports it. */
internal fun copyPrivately(context: Context, label: String, text: String) {
    val clip = ClipData.newPlainText(label, text)
    clip.description.extras = PersistableBundle().apply {
        putBoolean(if (Build.VERSION.SDK_INT >= 33) ClipDescription.EXTRA_IS_SENSITIVE else "android.content.extra.IS_SENSITIVE", true)
    }
    context.getSystemService(ClipboardManager::class.java)?.setPrimaryClip(clip)
}

/** What a History note action did, for the snackbar. */
internal sealed interface AddToNoteResult {
    data class Added(val createdNote: Boolean, val unreadableNote: Boolean = false) : AddToNoteResult
    data object Off : AddToNoteResult
    data object Failed : AddToNoteResult
}

/**
 * Runs from the UI coroutine: loaded documents are edited on Main; otherwise a revision-checked write on IO retries
 * against the latest record. [destination] pins the note named in the menu, even if the library order changes.
 */
internal suspend fun addDictationToNote(kept: NotesSessions, text: String, destination: NotesIndexEntry? = null,
                                      saveAsNew: Boolean = false): AddToNoteResult = try {
    if (!kept.enabled) return AddToNoteResult.Off
    val trimmed = text.trim()
    if (trimmed.isEmpty()) return AddToNoteResult.Failed
    suspend fun createNote(unreadableNote: Boolean = false): AddToNoteResult = withContext(Dispatchers.IO) {
        val note = NotesDocument().apply { userEdit(0, 0, trimmed) }
        if (kept.put(note.uid, note.toJson())) AddToNoteResult.Added(createdNote = true, unreadableNote = unreadableNote)
        else AddToNoteResult.Failed
    }
    val recent = if (saveAsNew) null else destination ?: withContext(Dispatchers.IO) { kept.entries().firstOrNull() }
    if (recent == null) {
        createNote()
    } else {
        var result: AddToNoteResult = AddToNoteResult.Failed
        // Conflicts are uncommon, but never fall back to an unconditional whole-document write.
        for (attempt in 0 until 3) {
            val appended = withContext(Dispatchers.Main.immediate) {
                NotesSessionHolder.owner(recent.id)?.let { it.appendText(trimmed); true } ?: false
            }
            if (appended) return AddToNoteResult.Added(createdNote = false)
            val record = withContext(Dispatchers.IO) { kept.open(recent.id) }
                ?: return createNote(unreadableNote = true)
            if (record.entry.deleted) return AddToNoteResult.Failed
            val note = runCatching { NotesDocument.fromJson(record.document) }.getOrNull()
                ?: return createNote(unreadableNote = true)
            val separator = if (note.text.isBlank()) "" else "\n\n"
            note.userEdit(note.text.length, note.text.length, separator + trimmed)
            val document = note.toJson().put("elapsed", record.document.optDouble("elapsed", recent.duration))
            if (withContext(Dispatchers.IO) { kept.put(recent.id, document, expectedRevision = record.revision) }) {
                result = AddToNoteResult.Added(createdNote = false)
                break
            }
        }
        result
    }
} catch (cancelled: CancellationException) { throw cancelled }
catch (_: Exception) { AddToNoteResult.Failed }

private val LIST_DETAIL = 600.dp

/**
 * The History tab: search, entries grouped by day, a detail sheet (a side pane from 600 dp) with Copy, Copy raw, Share and Delete,
 * and swipe-to-delete with Undo. Opt-in, retention and clear sit behind ⋮. Long-press names the latest note to append to
 * and offers "Save as new note". [selected]/[select] hoist the open entry (null: kept here).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun HistoryScreen(store: DictationHistory? = null, now: () -> Long = System::currentTimeMillis, zone: ZoneId = ZoneId.systemDefault(),
                           selected: String? = null, select: ((String?) -> Unit)? = null, notes: NotesSessions? = null) {
    val context = LocalContext.current
    val searchFocus = remember { androidx.compose.ui.focus.FocusRequester() }
    val history = store ?: remember { DictationHistory(context) }
    val fallbackLibrary = remember { NotesSessions(context) }
    val library = notes ?: NotesSessionHolder.current?.library ?: fallbackLibrary
    val noteRows by library.index.collectAsState()
    val latest = noteRows.firstOrNull { !it.deleted }
    val scope = rememberCoroutineScope()
    val snackbar = remember { SnackbarHostState() }
    var enabled by remember { mutableStateOf(history.enabled) }
    var entries by remember { mutableStateOf<List<HistoryEntry>?>(null) }
    var reload by remember { mutableIntStateOf(0) }
    /** Bumped by Undo: a restored row must not come back with its saved "swiped away" state. */
    var restores by rememberSaveable { mutableIntStateOf(0) }
    var query by rememberSaveable { mutableStateOf("") }
    var settings by rememberSaveable { mutableStateOf(false) }
    var menu by remember { mutableStateOf(false) }
    var teach by remember { mutableStateOf<HistoryEntry?>(null) }
    var own by rememberSaveable { mutableStateOf<String?>(null) }
    val open = if (select == null) own else selected
    val choose: (String?) -> Unit = select ?: { own = it }
    dev.chirp.android.AppShortcutActions(dev.chirp.android.AppCommand.Search to {
        if (enabled || !entries.isNullOrEmpty()) { searchFocus.requestFocus(); true } else false
    })
    LaunchedEffect(reload, enabled) { entries = withContext(Dispatchers.IO) { history.entries() } }
    // New dictations arrive from the keyboard while this screen is in the background.
    LifecycleResumeEffect(history, library) {
        enabled = history.enabled; reload++
        scope.launch { withContext(Dispatchers.IO) { library.refresh() } }
        onPauseOrDispose { }
    }
    val shown = entries.orEmpty().filter { historyMatches(it, query) }
    val current = open?.let { id -> entries?.firstOrNull { it.id == id } }
    fun delete(entry: HistoryEntry) {
        if (open == entry.id) choose(null)
        entries = entries?.filter { it.id != entry.id }
        scope.launch {
            withContext(Dispatchers.IO) { history.delete(entry.id) }
            snackbar.currentSnackbarData?.dismiss()
            if (snackbar.showSnackbar("Dictation deleted", actionLabel = "Undo", duration = SnackbarDuration.Long) == SnackbarResult.ActionPerformed) {
                withContext(Dispatchers.IO) { history.restore(entry) }; restores++; reload++
            }
        }
    }
    fun addToNote(entry: HistoryEntry, destination: NotesIndexEntry? = null, newNote: Boolean = false) {
        scope.launch {
            val result = addDictationToNote(library, entry.text, destination, saveAsNew = newNote)
            snackbar.currentSnackbarData?.dismiss()
            val message = when (result) {
                is AddToNoteResult.Added -> when {
                    result.unreadableNote -> "Couldn't open that note, saved as a new note"
                    result.createdNote -> "Saved as a new note"
                    else -> "Added to your latest note"
                }
                AddToNoteResult.Off -> "Notes are off — turn on Keep notes on this phone in Settings → Notes"
                AddToNoteResult.Failed -> "Couldn't add the note"
            }
            snackbar.showSnackbar(message, duration = SnackbarDuration.Long)
        }
    }
    val icons = rememberAppIcons()
    val actions = DetailActions(copy = { label, text -> copyPrivately(context, label, text) },
        share = { text -> context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text), null)) },
        delete = ::delete, teach = { teach = it })
    Surface(Modifier.fillMaxSize()) {
        BoxWithConstraints(Modifier.fillMaxSize().safeDrawingPadding(), contentAlignment = Alignment.TopCenter) {
            // Off or empty there is nothing to show beside the list: one centred column instead.
            val wide = maxWidth >= LIST_DETAIL
            val twoPane = wide && !entries.isNullOrEmpty()
            Row(if (twoPane) Modifier.fillMaxSize() else Modifier.widthIn(max = 600.dp).fillMaxSize()) {
                Column(if (twoPane) Modifier.weight(.45f).widthIn(max = 480.dp).fillMaxHeight() else Modifier.fillMaxSize()) {
                    Row(Modifier.fillMaxWidth().padding(start = 24.dp, end = 12.dp, top = 24.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text("Dictation history", Modifier.semantics { heading() }, style = MaterialTheme.typography.headlineMedium)
                            Text("What you dictated, encrypted on this phone only", style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        Box {
                            IconButton({ menu = true }) { Icon(painterResource(R.drawable.ic_more_vert), "More options") }
                            DropdownMenu(menu, { menu = false }) {
                                DropdownMenuItem({ Text("History settings") }, { menu = false; settings = true })
                            }
                        }
                    }
                    if (enabled || !entries.isNullOrEmpty()) DockedSearchBar(inputField = {
                        SearchBarDefaults.InputField(query, { query = it }, { }, expanded = false, onExpandedChange = { },
                            modifier = Modifier.focusRequester(searchFocus), placeholder = { Text("Search history") }, leadingIcon = { Icon(painterResource(R.drawable.ic_search), null) },
                            trailingIcon = if (query.isEmpty()) null else ({ IconButton({ query = "" }) { Icon(painterResource(R.drawable.ic_close), "Clear search") } }))
                    }, expanded = false, onExpandedChange = { }, modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) { }
                    when {
                        !enabled && entries.isNullOrEmpty() -> EmptyHistory(R.drawable.ic_history, "Dictation history is off",
                            "Turn it on to keep recent dictations here, encrypted on this phone only.", "Turn on") { settings = true }
                        entries == null -> Unit
                        shown.isEmpty() && query.isNotBlank() -> EmptyHistory(R.drawable.ic_search, "No matches", "Nothing in your history matches. Try other words.")
                        shown.isEmpty() -> EmptyHistory(R.drawable.ic_history, "No dictations yet", "New dictations stay here for ${history.retention.label}.")
                        else -> LazyColumn(Modifier.fillMaxWidth().weight(1f), contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 88.dp),
                            verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            shown.groupBy { historyDay(now(), it.time, zone) }.forEach { (day, group) ->
                                item(key = day.name) {
                                    Text(day.label, Modifier.padding(start = 8.dp, top = 16.dp, bottom = 8.dp).semantics { heading() },
                                        style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
                                }
                                items(group, key = { "${it.id}/$restores" }) { entry ->
                                    HistoryRow(entry, historyMeta(entry, now()), icons[entry.app], twoPane && entry.id == open,
                                        { choose(entry.id) }, latest, { target -> addToNote(entry, target) },
                                        { addToNote(entry, newNote = true) }, { scope.launch { withContext(Dispatchers.IO) { library.refresh() } } }, { delete(entry) })
                                }
                            }
                        }
                    }
                }
                if (twoPane) Box(Modifier.weight(.55f).fillMaxHeight().padding(16.dp).clip(MaterialTheme.shapes.extraLarge)
                    .background(MaterialTheme.colorScheme.surfaceContainer)) {
                    if (current != null) Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp)) {
                        HistoryDetail(current, now(), zone, actions)
                    } else Text(if (shown.isNotEmpty()) "Select a dictation to see it in full." else "", Modifier.align(Alignment.Center).padding(24.dp),
                        style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            SnackbarHost(snackbar, Modifier.align(Alignment.BottomCenter))
            if (!wide && current != null) ModalBottomSheet({ choose(null) }) {
                Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(start = 24.dp, end = 24.dp, bottom = 24.dp)) {
                    HistoryDetail(current, now(), zone, actions)
                }
            }
        }
    }
    teach?.let { dev.chirp.android.TeachChirp(it) { teach = null } }
    if (settings) ModalBottomSheet({ settings = false }) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(start = 16.dp, end = 16.dp, bottom = 24.dp)) {
            HistorySettings(showOpen = false, store = history) { enabled = history.enabled; reload++ }
        }
    }
}

/** The target app's icon by label (what history stores), computed once per screen; missing apps fall back to a glyph. */
@Composable
private fun rememberAppIcons(): Map<String, Drawable> {
    val context = LocalContext.current
    return remember(context) {
        val map = mutableMapOf<String, Drawable>()
        runCatching {
            val pm = context.packageManager
            // Launchable apps (the manifest's <queries> covers them): dictation targets are launchable.
            val launcher = android.content.Intent(android.content.Intent.ACTION_MAIN).addCategory(android.content.Intent.CATEGORY_LAUNCHER)
            for (info in pm.queryIntentActivities(launcher, 0)) {
                val label = runCatching { info.loadLabel(pm).toString() }.getOrNull() ?: continue
                val icon = runCatching { info.loadIcon(pm) }.getOrNull() ?: continue
                map.putIfAbsent(label, icon)
            }
        }
        map
    }
}

private class DetailActions(val copy: (String, String) -> Unit, val share: (String) -> Unit, val delete: (HistoryEntry) -> Unit, val teach: (HistoryEntry) -> Unit)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun HistoryRow(entry: HistoryEntry, meta: String, icon: Drawable?, selected: Boolean, open: () -> Unit,
                       latest: NotesIndexEntry?, addToNote: (NotesIndexEntry) -> Unit, saveAsNew: () -> Unit,
                       refreshNotes: () -> Unit, delete: () -> Unit) {
    val dismiss = rememberSwipeToDismissBoxState()
    SwipeToDismissBox(dismiss, backgroundContent = {
        Box(Modifier.fillMaxSize().clip(MaterialTheme.shapes.extraSmall).background(MaterialTheme.colorScheme.errorContainer).padding(horizontal = 24.dp),
            contentAlignment = if (dismiss.dismissDirection == SwipeToDismissBoxValue.StartToEnd) Alignment.CenterStart else Alignment.CenterEnd) {
            Icon(painterResource(R.drawable.ic_delete), null, tint = MaterialTheme.colorScheme.onErrorContainer)
        }
    }, onDismiss = { delete() }) {
        var menu by remember { mutableStateOf(false) }
        val addLabel = latest?.let { "Add to latest note (“${it.title}”)" }
        Box {
            ListItem(headlineContent = { Text(entry.text, maxLines = 2, overflow = TextOverflow.Ellipsis) }, supportingContent = { Text(meta) },
                leadingContent = { AppIcon(entry.app, icon) },
                modifier = Modifier.clip(MaterialTheme.shapes.extraSmall).combinedClickable(onClickLabel = "Open", onClick = open, onLongClickLabel = "More options",
                    onLongClick = { refreshNotes(); menu = true })
                    .semantics { customActions = listOfNotNull(
                        latest?.let { target -> CustomAccessibilityAction(requireNotNull(addLabel)) { addToNote(target); true } },
                        CustomAccessibilityAction("Save as new note") { saveAsNew(); true }, CustomAccessibilityAction("Delete") { delete(); true }) },
                colors = ListItemDefaults.colors(containerColor = if (selected) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surfaceContainer))
            DropdownMenu(menu, { menu = false }) {
                if (latest != null) DropdownMenuItem(leadingIcon = { Icon(painterResource(R.drawable.ic_notes_tab), null) },
                    text = { Text(requireNotNull(addLabel)) }, onClick = { menu = false; addToNote(latest) })
                DropdownMenuItem(leadingIcon = { Icon(painterResource(R.drawable.ic_add), null) }, text = { Text("Save as new note") },
                    onClick = { menu = false; saveAsNew() })
            }
        }
    }
}

/** The target app's icon when PackageManager knows the app, else a neutral glyph in a tonal circle. */
@Composable
private fun AppIcon(app: String?, icon: Drawable?) {
    if (icon != null) Box(Modifier.size(40.dp), contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(28.dp)) {
            icon.setBounds(0, 0, size.width.toInt(), size.height.toInt())
            icon.draw(drawContext.canvas.nativeCanvas)
        }
    } else Box(Modifier.size(40.dp).clip(CircleShape).background(MaterialTheme.colorScheme.surfaceContainerHighest), contentAlignment = Alignment.Center) {
        Icon(painterResource(if (app == null) R.drawable.ic_mic else R.drawable.ic_history), null, Modifier.size(20.dp),
            tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun ButtonIcon(@DrawableRes icon: Int) {
    Icon(painterResource(icon), null, Modifier.size(18.dp)); Spacer(Modifier.width(8.dp))
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun HistoryDetail(entry: HistoryEntry, now: Long, zone: ZoneId, actions: DetailActions) {
    val time = remember(entry.time, zone) { DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT).withZone(zone).format(Instant.ofEpochMilli(entry.time)) }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(listOfNotNull(entry.app, time, if (entry.partial) "partial" else null).joinToString(" · "), style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        SelectionContainer { Text(entry.text, style = MaterialTheme.typography.bodyLarge) }
        entry.raw?.let { raw ->
            Text("Before clean-up", Modifier.semantics { heading() }, style = MaterialTheme.typography.titleSmall)
            SelectionContainer { Text(raw, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
        Text(historyAge(now, entry.time).second, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            FilledTonalButton({ actions.copy("Chirp dictation", entry.text) }) { ButtonIcon(R.drawable.ic_copy); Text("Copy") }
            entry.raw?.let { raw -> OutlinedButton({ actions.copy("Chirp dictation (raw)", raw) }) { Text("Copy raw") } }
            if (!entry.partial) OutlinedButton({ actions.teach(entry) }) { Text("Teach Chirp") }
            OutlinedButton({ actions.share(entry.text) }) { ButtonIcon(R.drawable.ic_share); Text("Share") }
            TextButton({ actions.delete(entry) }, colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)) {
                ButtonIcon(R.drawable.ic_delete); Text("Delete")
            }
        }
    }
}

@Composable
private fun ColumnScope.EmptyHistory(@DrawableRes icon: Int, title: String, body: String, action: String? = null, onAction: () -> Unit = {}) {
    Column(Modifier.fillMaxWidth().weight(1f).padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically)) {
        Icon(painterResource(icon), null, Modifier.size(56.dp), tint = MaterialTheme.colorScheme.primary)
        Column(Modifier.semantics(mergeDescendants = true) { }, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            Text(body, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        }
        if (action != null) FilledTonalButton(onAction) { Text(action) }
    }
}
