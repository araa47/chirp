package dev.chirp.android

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.material3.adaptive.ExperimentalMaterial3AdaptiveApi
import androidx.compose.material3.adaptive.currentWindowAdaptiveInfoV2
import androidx.compose.material3.adaptive.layout.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import dev.chirp.android.ui.ChirpTokens
import dev.chirp.android.ui.LocalChirpRoles
import dev.chirp.android.ui.Ripple
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext

/** Calendar groups, including midnight and month/year boundaries, in the device's time zone. */
internal fun notesGroup(now: Long, time: Long, zone: ZoneId = ZoneId.systemDefault()): UiText {
    val today = Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
    val date = Instant.ofEpochMilli(time).atZone(zone).toLocalDate()
    return when (ChronoUnit.DAYS.between(date, today)) {
        in Long.MIN_VALUE..0L -> UiText.Res(R.string.notes_library_group_today)
        1L -> UiText.Res(R.string.notes_library_group_yesterday)
        in 2L..7L -> UiText.Res(R.string.notes_library_group_week)
        in 8L..30L -> UiText.Res(R.string.notes_library_group_month)
        else -> UiText.Raw(date.format(DateTimeFormatter.ofPattern(if (date.year == today.year) "MMMM" else "MMMM yyyy")))
    }
}

@Composable
internal fun notesDuration(seconds: Double): String {
    val count = if (seconds < 60) seconds.toInt().coerceAtLeast(0) else (seconds / 60).toInt()
    return pluralStringResource(if (seconds < 60) R.plurals.notes_duration_seconds else R.plurals.notes_duration_minutes, count, count)
}

/** Highlight every match (including a title match), without copying note text into semantics or logs. */
@Composable
internal fun highlightedNote(text: String, query: String): AnnotatedString {
    val needle = query.trim()
    val style = SpanStyle(background = MaterialTheme.colorScheme.tertiaryContainer, color = MaterialTheme.colorScheme.onTertiaryContainer,
        fontWeight = FontWeight.SemiBold)
    return remember(text, needle, style) {
        val builder = AnnotatedString.Builder(text)
        if (needle.isNotEmpty()) {
            var at = text.indexOf(needle, ignoreCase = true)
            while (at >= 0) {
                builder.addStyle(style, at, at + needle.length)
                at = text.indexOf(needle, at + needle.length, ignoreCase = true)
            }
        }
        builder.toAnnotatedString()
    }
}

/**
 * Notes is the app's starting point. The live model owns the microphone; the reader can open and edit other documents
 * without moving it. Both share the same library/index. Query, selection and list position survive pane and tab changes.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3AdaptiveApi::class, androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
internal fun NotesLibraryScreen(
    live: NotesModel, reader: NotesModel,
    record: (String?) -> Unit, copy: (NotesModel) -> Unit, share: (NotesModel) -> Unit, save: (NotesModel) -> Unit,
    act: (DictationAction) -> Unit, state: SetupState? = null, connection: () -> Unit = {}, dictate: () -> Unit = {},
    now: () -> Long = System::currentTimeMillis,
    initialDetail: Boolean = false,
) {
    val searchFocus = remember { androidx.compose.ui.focus.FocusRequester() }
    var searchRequest by remember { mutableIntStateOf(0) }
    val setup = state?.let { dev.chirp.android.shell.setupProgress(it.paired, it.mic, it.inputEnabled, it.inputSelected,
        it.bubbleEnabled, it.inputMode == InputMode.OWN_KEYBOARD) }
    val library = live.library
    val context = LocalContext.current
    val resources = LocalResources.current
    val scope = rememberCoroutineScope()
    val focus = LocalFocusManager.current
    val snackbar = remember { SnackbarHostState() }
    val rows by (library?.index ?: remember { kotlinx.coroutines.flow.MutableStateFlow(emptyList<NotesIndexEntry>()) }).collectAsState()
    var query by rememberSaveable { mutableStateOf("") }
    var selected by rememberSaveable { mutableStateOf(if (initialDetail) live.document.uid else null) }
    var trash by rememberSaveable { mutableStateOf(false) }
    var selection by rememberSaveable { mutableStateOf(emptyList<String>()) }
    var setupDismissed by rememberSaveable { mutableStateOf(SettingsStore(context).tryItDismissed) }
    var enabled by remember { mutableStateOf(library?.enabled == true) }
    var menu by remember { mutableStateOf(false) }
    var emptyTrash by remember { mutableStateOf(false) }
    var pendingRecord by remember { mutableStateOf<String?>(null) }
    var typedSelection by rememberSaveable { mutableStateOf<String?>(null) }
    var pendingNew by remember { mutableStateOf(false) }
    var restoreVersion by remember { mutableIntStateOf(0) }
    var hits by remember { mutableStateOf<List<NotesSearchHit>>(emptyList()) }
    var searched by remember { mutableStateOf("") }
    val list = rememberLazyListState()
    var captureHeight by remember { mutableIntStateOf(0) }
    val trashList = rememberLazyListState()
    val liveId = live.document.uid
    val recording = live.state.active
    val shownModel = if (selected == liveId) live else reader
    val window = LocalWindowInfo.current.containerSize
    val width = with(LocalDensity.current) { window.width.toDp() }
    val twoPane = width >= 600.dp
    val extraPane = width >= 1200.dp && window.width > window.height && selected != null && !trash
    val directive = calculatePaneScaffoldDirective(currentWindowAdaptiveInfoV2()).copy(
        maxHorizontalPartitions = if (extraPane) 3 else if (twoPane && (rows.any { !it.deleted } || recording || trash || selected != null)) 2 else 1,
        maxVerticalPartitions = 1, horizontalPartitionSpacerSize = if (twoPane) 8.dp else 0.dp,
    )
    val value = calculateThreePaneScaffoldValue(directive.maxHorizontalPartitions, ListDetailPaneScaffoldDefaults.adaptStrategies(),
        ThreePaneScaffoldDestinationItem(if (selected != null && !trash) ListDetailPaneScaffoldRole.Detail else ListDetailPaneScaffoldRole.List, selected))
    LifecycleResumeEffect(library) {
        enabled = library?.enabled == true
        scope.launch { withContext(Dispatchers.IO) { library?.refresh() } }
        onPauseOrDispose { live.keepSession(); reader.keepSession() }
    }
    // Searching the document and transcript happens on IO; cancellation prevents stale queries from replacing new ones.
    LaunchedEffect(query, rows, trash) {
        hits = if (query.isBlank() || trash) emptyList() else withContext(Dispatchers.IO) { library?.search(query).orEmpty() }
        searched = query
    }
    LaunchedEffect(selected) {
        selected?.takeIf { it != liveId && it != reader.document.uid }?.let { reader.open(it) }
    }
    // New search terms show their results from the top; the first value is the restored query, whose position is kept.
    LaunchedEffect(trash) { snapshotFlow { query }.drop(1).collect { (if (trash) trashList else list).scrollToItem(0) } }
    // The recording card joins the top of the list; keep it in view rather than leaving the list anchored on the row below.
    LaunchedEffect(recording, trash) { if (recording && !trash && list.firstVisibleItemIndex <= 1) list.scrollToItem(0) }
    fun open(id: String) { focus.clearFocus(); reader.keepSession(); selected = id }
    fun close() { shownModel.keepSession(); selected = null }
    BackHandler(selected != null) { close() }
    BackHandler(trash) { trash = false; selection = emptyList() }
    BackHandler(selection.isNotEmpty()) { selection = emptyList() }
    fun delete(ids: List<String>) {
        val deletable = ids.filterNot { recording && it == liveId }
        if (deletable.isEmpty()) return
        deletable.forEach { RetranscribeGate.owner?.cancelRetranscribeFor(it); RetranscribeGate.rebuilds.remove(it) }
        if (selected in deletable) close()
        reader.keepSession(); live.keepSession()
        selection = emptyList()
        scope.launch {
            val deleted = withContext(Dispatchers.IO) { deletable.filter { library?.trash(it) == true } }
            if (deleted.isEmpty()) return@launch
            // Forget loaded copies, otherwise an edited copy could later resurrect a trashed record.
            if (reader.document.uid in deleted) reader.clear()
            if (!live.state.active && live.document.uid in deleted) live.clear()
            snackbar.currentSnackbarData?.dismiss()
            if (snackbar.showSnackbar(resources.getQuantityString(R.plurals.notes_library_deleted, deleted.size, deleted.size), resources.getString(R.string.notes_action_undo), duration = SnackbarDuration.Long) == SnackbarResult.ActionPerformed) {
                withContext(Dispatchers.IO) { deleted.forEach { library?.restore(it) } }; restoreVersion++
            }
        }
    }
    fun start(id: String?) {
        focus.clearFocus()
        if (recording && id == liveId) { live.stop(); return }
        if (recording && id != liveId) { if (id == null) pendingNew = true else pendingRecord = id; return }
        reader.keepSession(); record(id); selected = if (id == null) live.document.uid else id
    }
    fun newNote() {
        focus.clearFocus(); reader.newNote()
        trash = false; selection = emptyList(); query = ""
        selected = reader.document.uid; typedSelection = selected
    }
    AppShortcutActions(
        AppCommand.NewNote to { if (!trash) { newNote(); true } else false },
        AppCommand.Record to { if (!trash) { start(null); true } else false },
        AppCommand.Search to { if (selected != null) close(); searchRequest++; true },
        AppCommand.Escape to {
            when {
                pendingNew || pendingRecord != null -> { pendingNew = false; pendingRecord = null; true }
                emptyTrash -> { emptyTrash = false; true }
                menu -> { menu = false; true }
                selection.isNotEmpty() -> { selection = emptyList(); true }
                trash -> { trash = false; true }
                selected != null -> { close(); true }
                else -> false
            }
        },
    )
    LaunchedEffect(searchRequest) {
        if (searchRequest > 0) {
            // On the cover, the list and its search field must mount after closing the detail.
            withFrameNanos { }
            searchFocus.requestFocus()
        }
    }
    // A new recording/continued note can finish loading asynchronously; follow it once it owns the microphone.
    LaunchedEffect(live.document.uid, live.state.active) { if (live.state.active && selected != null && selected != typedSelection && (pendingRecord == null && !pendingNew)) selected = live.document.uid }
    if (pendingNew || pendingRecord != null) AlertDialog(onDismissRequest = { pendingNew = false; pendingRecord = null },
        title = { Text(stringResource(if (pendingNew) R.string.notes_library_new_recording_title else R.string.notes_library_continue_title)) },
        text = { Text(stringResource(R.string.notes_library_another_recording)) },
        confirmButton = { TextButton({
            val id = pendingRecord; val new = pendingNew; pendingNew = false; pendingRecord = null
            reader.keepSession()
            if (new) {
                live.stop()
                scope.launch { snapshotFlow { live.state.active }.first { !it }; record(null); selected = live.document.uid }
            } else { record(id); selected = id }
        }) { Text(stringResource(if (pendingNew) R.string.notes_library_stop_and_record else R.string.notes_library_stop_and_continue)) } },
        dismissButton = { TextButton({ pendingNew = false; pendingRecord = null }) { Text(stringResource(R.string.notes_action_cancel)) } })
    if (emptyTrash) AlertDialog(onDismissRequest = { emptyTrash = false }, title = { Text(stringResource(R.string.notes_library_empty_trash_title)) },
        text = { Text(stringResource(R.string.notes_library_empty_trash_message)) },
        confirmButton = { TextButton({ emptyTrash = false; scope.launch { withContext(Dispatchers.IO) { library?.emptyTrash() } }; selection = emptyList() }) { Text(stringResource(R.string.notes_library_delete_permanently)) } },
        dismissButton = { TextButton({ emptyTrash = false }) { Text(stringResource(R.string.notes_action_cancel)) } })
    val shown = if (trash) rows.filter { it.deleted && (query.isBlank() || it.title.contains(query.trim(), true) || it.snippet.contains(query.trim(), true)) }
        else if (query.isNotBlank()) hits.map { it.entry } else rows.filterNot { it.deleted }
    val currentTime = now()
    val deletedGroup = UiText.Res(R.string.notes_library_group_deleted)
    val primaryDescription = stringResource(if (!recording) R.string.notes_library_record_new else if (live.paused) R.string.notes_library_open_paused_recording else R.string.notes_library_open_current_recording)
    val scrollBehavior = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    Surface(Modifier.fillMaxSize().semantics { testTagsAsResourceId = true }, color = MaterialTheme.colorScheme.background) {
        Box(Modifier.fillMaxSize().safeDrawingPadding()) {
            ListDetailPaneScaffold(directive, value,
                listPane = { AnimatedPane(Modifier.preferredWidth(320.dp)) {
                    Scaffold(containerColor = MaterialTheme.colorScheme.background, modifier = Modifier.nestedScroll(scrollBehavior.nestedScrollConnection),
                        topBar = { Column {
                            LargeTopAppBar(title = { Text(if (selection.isNotEmpty()) pluralStringResource(R.plurals.notes_library_selected, selection.size, selection.size) else stringResource(if (trash) R.string.notes_library_trash else R.string.notes_library_title),
                                fontFamily = if (selection.isEmpty()) FontFamily.Serif else FontFamily.Default, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                                navigationIcon = { if (trash || selection.isNotEmpty()) IconButton({ if (selection.isNotEmpty()) selection = emptyList() else trash = false }) {
                                    Icon(painterResource(if (selection.isNotEmpty()) R.drawable.ic_close else R.drawable.ic_arrow_back), stringResource(if (selection.isNotEmpty()) R.string.notes_library_clear_selection else R.string.notes_library_back)) } },
                                actions = {
                                    if (selection.isNotEmpty()) {
                                        if (trash) TextButton({ val ids = selection; selection = emptyList(); scope.launch { withContext(Dispatchers.IO) { ids.forEach { library?.restore(it) } } } }) { Text(stringResource(R.string.notes_library_restore)) }
                                        else IconButton({ delete(selection) }) { Icon(painterResource(R.drawable.ic_delete), stringResource(R.string.notes_library_delete_selected)) }
                                    } else {
                                        if (!trash) {
                                            IconButton(::newNote) { Icon(painterResource(R.drawable.ic_edit), stringResource(R.string.notes_library_new_note)) }
                                            ConnectionChip(state, connection)
                                        }
                                        Box {
                                            IconButton({ menu = true }) { Icon(painterResource(R.drawable.ic_more_vert), stringResource(R.string.notes_library_options)) }
                                            DropdownMenu(menu, { menu = false }) {
                                                // While a note holds the microphone, the primary action opens it; a new recording stays deliberate, behind its confirmation.
                                                if (!trash && recording) DropdownMenuItem({ Column { Text(stringResource(R.string.notes_library_record_new)); Text(stringResource(R.string.notes_library_record_new_detail),
                                                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) } },
                                                    { menu = false; start(null) }, leadingIcon = { Icon(painterResource(R.drawable.ic_record), null) })
                                                if (!trash) DropdownMenuItem({ Text(stringResource(R.string.notes_library_trash)) }, { menu = false; trash = true; selected = null; selection = emptyList() },
                                                    leadingIcon = { Icon(painterResource(R.drawable.ic_delete), null) })
                                                else DropdownMenuItem({ Text(stringResource(R.string.notes_library_empty_trash)) }, { menu = false; emptyTrash = true }, enabled = shown.isNotEmpty())
                                            }
                                        }
                                    }
                                }, scrollBehavior = scrollBehavior, expandedHeight = 104.dp,
                                colors = TopAppBarDefaults.largeTopAppBarColors(containerColor = MaterialTheme.colorScheme.background, scrolledContainerColor = MaterialTheme.colorScheme.background))
                            DockedSearchBar(inputField = { SearchBarDefaults.InputField(query, { query = it }, { focus.clearFocus() }, false, {},
                                modifier = Modifier.focusRequester(searchFocus), placeholder = { Text(stringResource(if (trash) R.string.notes_library_search_trash else R.string.notes_library_search)) }, leadingIcon = { Icon(painterResource(R.drawable.ic_search), null) },
                                trailingIcon = if (query.isEmpty()) null else ({ IconButton({ query = "" }) { Icon(painterResource(R.drawable.ic_close), stringResource(R.string.notes_library_clear_search)) } })) },
                                expanded = false, onExpandedChange = {}, modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(bottom = 12.dp)) { }
                        } },
                        floatingActionButton = { if (!trash && selection.isEmpty()) FlowRow(Modifier.widthIn(max = width - 32.dp).onSizeChanged { captureHeight = it.height },
                            horizontalArrangement = Arrangement.spacedBy(12.dp, Alignment.End), verticalArrangement = Arrangement.spacedBy(8.dp), itemVerticalAlignment = Alignment.CenterVertically) {
                            SmallFloatingActionButton(dictate, containerColor = MaterialTheme.colorScheme.surfaceContainerHigh, contentColor = MaterialTheme.colorScheme.onSurface,
                                elevation = FloatingActionButtonDefaults.elevation(0.dp)) { Icon(painterResource(R.drawable.ic_mic), stringResource(R.string.notes_library_dictate)) }
                            // The strongest affordance follows the microphone: Record when idle; while a note holds it, open that note — never silently stop it.
                            ExtendedFloatingActionButton(onClick = { if (recording) open(liveId) else start(null) },
                                icon = { Icon(painterResource(if (recording) R.drawable.ic_note else R.drawable.ic_record), null) },
                                text = { Text(stringResource(if (!recording) R.string.notes_library_record else if (live.paused) R.string.notes_library_open_paused else R.string.notes_library_open_recording)) },
                                modifier = Modifier.semantics { contentDescription = primaryDescription },
                                containerColor = MaterialTheme.colorScheme.primary, contentColor = MaterialTheme.colorScheme.onPrimary, elevation = FloatingActionButtonDefaults.elevation(0.dp))
                        } },
                    ) { padding ->
                        // Reserve the actual controls, including a wrapped action row at large text sizes.
                        val largeText = LocalDensity.current.fontScale >= 1.5f
                        val captureInset = if (!trash && selection.isEmpty()) with(LocalDensity.current) { captureHeight.toDp() } + 16.dp else 0.dp
                        LazyColumn(Modifier.fillMaxSize().padding(padding).padding(bottom = captureInset).testTag("notes-library-list"), if (trash) trashList else list,
                            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 16.dp)) {
                            // Pinned in the list flow, not the top bar: it stays in reach while scrolling and never
                            // crowds the rows out of a 200%-font viewport.
                            val recordingHeader: @Composable () -> Unit = {
                                Column(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.background).padding(bottom = 12.dp)) {
                                    Text(stringResource(if (live.paused) R.string.notes_library_section_paused else R.string.notes_library_section_recording), Modifier.padding(start = 8.dp, bottom = 8.dp),
                                        style = MaterialTheme.typography.titleMedium, fontFamily = FontFamily.Serif)
                                    RecordingNoteCard(live, { open(liveId) })
                                }
                            }
                            if (!trash && recording) {
                                // Large text can make a sticky card taller than the usable row viewport.
                                if (largeText) item(key = "recording", content = { recordingHeader() })
                                else stickyHeader(key = "recording", content = { recordingHeader() })
                            }
                            if (!trash && !setupDismissed && setup?.missing != null) item(key = "setup") {
                                SetupCard(setup, fix = { context.startActivity(android.content.Intent(context, SetupActivity::class.java).putExtra("section", setup.missing.section)) },
                                    dismiss = { setupDismissed = true; state?.tryIt = false; SettingsStore(context).tryItDismissed = true })
                            }
                            if (!trash && !enabled) item(key = "opt-out") {
                                Surface(shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.surfaceContainer) {
                                    Column(Modifier.padding(16.dp)) {
                                        Text(stringResource(R.string.notes_settings_enable_library), style = MaterialTheme.typography.titleMedium)
                                        Text(stringResource(R.string.notes_library_enable_detail), style = MaterialTheme.typography.bodyMedium)
                                        TextButton({ library?.enable(); enabled = true; live.keepSession() }) { Text(stringResource(R.string.notes_settings_enable_library)) }
                                    }
                                }
                            }
                            if (trash) item(key = "trash-info") { Text(stringResource(R.string.notes_library_trash_info),
                                Modifier.padding(horizontal = 8.dp, vertical = 16.dp), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                            val grouped = shown.filterNot { !trash && recording && it.id == liveId }.groupBy { if (trash) deletedGroup else notesGroup(currentTime, it.updatedAt) }
                            grouped.forEach { (group, entries) ->
                                item(key = "group-$group") { Text(group.text(), Modifier.padding(start = 8.dp, top = 24.dp, bottom = 8.dp).semantics { heading() },
                                    style = MaterialTheme.typography.titleMedium, fontFamily = FontFamily.Serif, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                                items(entries, key = { "${if (trash) "trash" else "note"}-${it.id}-$restoreVersion" }) { entry ->
                                    val select = {
                                        selection = if (entry.id in selection) selection - entry.id else selection + entry.id
                                    }
                                    NoteLibraryRow(entry, query, hits.firstOrNull { it.entry.id == entry.id }?.snippet ?: entry.snippet,
                                        selected == entry.id || entry.id in selection, selection.isNotEmpty(), trash,
                                        click = { if (trash || selection.isNotEmpty()) select() else open(entry.id) }, longClick = select,
                                        delete = { delete(listOf(entry.id)) }, restore = { scope.launch { withContext(Dispatchers.IO) { library?.restore(entry.id) } } }, now = currentTime)
                                }
                            }
                            if (shown.isEmpty() && !(recording && !trash && query.isBlank()) && (query.isBlank() || searched == query)) item(key = "empty") {
                                val state = when {
                                    trash -> "trash"; query.isBlank() -> "blank"; else -> "no-results"
                                }
                                LibraryEmpty(if (state == "trash") stringResource(R.string.notes_library_trash_empty_title) else if (state == "blank") stringResource(R.string.notes_library_blank_title) else stringResource(R.string.notes_library_no_results_title, query.trim()),
                                    stringResource(if (state == "trash") R.string.notes_library_trash_empty_detail else if (state == "blank") R.string.notes_library_blank_detail else R.string.notes_library_no_results_detail),
                                    glyph = query.isBlank(), modifier = Modifier.fillMaxWidth().padding(top = 48.dp)) {
                                    if (state == "blank") FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally)) {
                                        Button(::newNote) { Text(stringResource(R.string.notes_library_new_note)) }
                                        TextButton({ start(null) }) { Text(stringResource(R.string.notes_library_record)) }
                                    }
                                    if (state == "no-results") TextButton({ query = "" }) { Text(stringResource(R.string.notes_library_clear_search)) }
                                }
                            }

                        }
                    }
                } },
                detailPane = { AnimatedPane {
                    if (selected != null && !trash) {
                        key(selected) {
                            if (shownModel.document.uid == selected) NotesScreen(shownModel, record = { start(selected) }, copy = { copy(shownModel) }, share = { share(shownModel) },
                                act = act, leave = { close() }, save = { save(shownModel) }, handleBack = false, back = ::close, externalTranscript = extraPane,
                                recordingElsewhere = live.takeIf { recording && shownModel !== live }, jumpToRecording = { open(liveId) },
                                deleteNote = { delete(listOf(shownModel.document.uid)) }, initiallyEditing = selected == typedSelection)
                            else Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                                if (reader.message != null) LibraryEmpty(stringResource(R.string.notes_library_open_failed_title), stringResource(R.string.notes_library_open_failed_detail), false,
                                    Modifier.verticalScroll(androidx.compose.foundation.rememberScrollState()).padding(24.dp)) {
                                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally)) {
                                        Button({ reader.message = null; reader.open(selected!!) }) { Text(stringResource(R.string.notes_library_try_again)) }
                                        TextButton(::close) { Text(stringResource(R.string.notes_library_back)) }
                                    }
                                }
                                else CircularProgressIndicator()
                            }
                        }
                    } else Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        LibraryEmpty(stringResource(R.string.notes_library_detail_empty_title), stringResource(R.string.notes_library_detail_empty_detail), true, Modifier.widthIn(max = 360.dp).padding(24.dp)) {
                            Button(::newNote) { Text(stringResource(R.string.notes_library_new_note)) }
                        }
                    }
                } },
                extraPane = if (extraPane) ({ AnimatedPane { Surface(Modifier.fillMaxSize(), shape = MaterialTheme.shapes.large,
                    color = MaterialTheme.colorScheme.surfaceContainer) { TranscriptPane(shownModel, Modifier.fillMaxSize().padding(20.dp)) } } }) else null,
            )
            SnackbarHost(snackbar, Modifier.align(Alignment.BottomCenter).padding(16.dp))
        }
    }
}

@Composable
private fun ConnectionChip(state: SetupState?, click: () -> Unit) {
    val status = dev.chirp.android.shell.notesConnectionStatus(state?.paired == true, state?.reachable, state?.tailscaleOff == true, SettingsStore(LocalContext.current).phoneFallback)
    val label = stringResource(status.label)
    val color = if (status.connected) LocalChirpRoles.current.lily else MaterialTheme.colorScheme.onSurfaceVariant
    val description = stringResource(R.string.notes_library_connection, label)
    AssistChip(click, label = { Text(label) }, leadingIcon = { Box(Modifier.size(7.dp).clip(CircleShape).background(color)) },
        modifier = Modifier.semantics { contentDescription = description },
        colors = AssistChipDefaults.assistChipColors(labelColor = color), border = AssistChipDefaults.assistChipBorder(true))
}

@Composable
private fun SetupCard(progress: dev.chirp.android.shell.SetupProgress, fix: () -> Unit, dismiss: () -> Unit) {
    Surface(Modifier.fillMaxWidth().padding(bottom = 8.dp), shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.surfaceContainer) {
        Row(Modifier.padding(start = 16.dp, top = 8.dp, bottom = 8.dp, end = 4.dp), verticalAlignment = Alignment.Top) {
            Column(Modifier.weight(1f).padding(top = 8.dp)) {
                Text(stringResource(R.string.notes_library_setup_title), style = MaterialTheme.typography.titleMedium)
                Text(stringResource(R.string.notes_library_setup_next, stringResource(progress.missing!!.next)), Modifier.padding(top = 4.dp), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                TextButton(fix, contentPadding = PaddingValues(vertical = 8.dp)) { Text(stringResource(progress.missing!!.action)) }
            }
            IconButton(dismiss) { Icon(painterResource(R.drawable.ic_close), stringResource(R.string.notes_library_setup_dismiss)) }
        }
    }
}

@Composable
internal fun LibraryEmpty(title: String, body: String, glyph: Boolean, modifier: Modifier = Modifier, actions: @Composable () -> Unit = {}) {
    val roles = LocalChirpRoles.current
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.size(112.dp), contentAlignment = Alignment.Center) {
            if (glyph) {
                listOf(112, 88, 64).forEach { size -> Box(Modifier.size(size.dp).border(1.dp, roles.koiDecor.copy(alpha = .22f), CircleShape)) }
                Icon(painterResource(R.drawable.ic_chirp_notification), null, Modifier.size(44.dp), tint = MaterialTheme.colorScheme.primary)
            } else Icon(painterResource(R.drawable.ic_search), null, Modifier.size(40.dp), tint = MaterialTheme.colorScheme.outline)
        }
        Text(title, Modifier.padding(top = 16.dp), style = MaterialTheme.typography.titleLarge.copy(fontFamily = FontFamily.Serif), textAlign = TextAlign.Center)
        Text(body, Modifier.widthIn(max = 290.dp).padding(top = 8.dp), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
        actions()
        if (glyph && title == stringResource(R.string.notes_library_blank_title)) Text(stringResource(R.string.notes_library_blank_footer), Modifier.padding(top = 24.dp), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/**
 * The way back to the live note. One button for TalkBack — title, truthful recording/paused state and the frozen preview in
 * a single node, a named open action — while the running clock stays visible but quiet: no live region, so it never
 * re-announces every second.
 */
@Composable
private fun RecordingNoteCard(model: NotesModel, click: () -> Unit) {
    // The preview freezes at the beginning of each capture, so live text never rearranges the library.
    val preview = remember(model.document.uid, model.state.active) { model.document.snippet }
    val paused = model.paused
    val state = captureState(model)
    Surface(Modifier.fillMaxWidth().combinedClickable(onClickLabel = stringResource(if (paused) R.string.notes_library_open_paused_recording else R.string.notes_library_open_the_recording), onClick = click)
        .semantics(mergeDescendants = true) { role = Role.Button; stateDescription = state },
        shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.surfaceContainer) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (paused) Icon(painterResource(R.drawable.ic_pause), null, Modifier.size(28.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                else if (model.recording) Ripple(model.level.toFloat(), Modifier.size(28.dp).clearAndSetSemantics { })
                else Ripple(0f, Modifier.size(28.dp).clearAndSetSemantics { }, animate = false)
                Text(model.displayTitle, Modifier.weight(1f), fontFamily = FontFamily.Serif, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Text(stringResource(R.string.notes_library_recording_state, state, model.elapsedText.text()), style = ChirpTokens.timer,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(preview.ifBlank { stringResource(if (paused) R.string.notes_library_preview_paused else R.string.notes_library_preview_recording) }, maxLines = 2, overflow = TextOverflow.Ellipsis,
                style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun NoteLibraryRow(entry: NotesIndexEntry, query: String, snippet: String, selected: Boolean, selecting: Boolean, trash: Boolean,
                           click: () -> Unit, longClick: () -> Unit, delete: () -> Unit, restore: () -> Unit, now: Long) {
    val scheme = MaterialTheme.colorScheme
    val swipe = rememberSwipeToDismissBoxState()
    val selectedState = stringResource(if (selected) R.string.notes_library_row_selected else R.string.notes_library_row_not_selected)
    val restoreLabel = stringResource(R.string.notes_library_restore)
    val deleteLabel = stringResource(R.string.notes_library_row_delete)
    val selectLabel = stringResource(R.string.notes_library_row_select)
    SwipeToDismissBox(swipe, modifier = Modifier.padding(bottom = 8.dp), onDismiss = { delete() }, enableDismissFromStartToEnd = false, enableDismissFromEndToStart = !trash && !selecting,
        backgroundContent = { Box(Modifier.fillMaxSize().clip(RoundedCornerShape(10.dp)).background(scheme.errorContainer).padding(20.dp), Alignment.CenterEnd) {
            Icon(painterResource(R.drawable.ic_delete), stringResource(R.string.notes_library_delete_note), tint = scheme.onErrorContainer)
        } }) {
        Surface(shape = RoundedCornerShape(10.dp), color = if (selected) scheme.secondaryContainer else scheme.surface,
            modifier = Modifier.fillMaxWidth().testTag("note-library-row").combinedClickable(onClick = click, onLongClick = longClick).semantics(mergeDescendants = true) {
                if (selecting) { role = Role.Checkbox; stateDescription = selectedState }
                customActions = if (trash) listOf(CustomAccessibilityAction(restoreLabel) { restore(); true }) else listOf(CustomAccessibilityAction(deleteLabel) { delete(); true }, CustomAccessibilityAction(selectLabel) { longClick(); true })
            }.then(if (selected && !selecting) Modifier.border(1.5.dp, scheme.secondary, RoundedCornerShape(10.dp)) else Modifier)) {
            Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                if (selecting) { Checkbox(selected, null); Spacer(Modifier.width(12.dp)) }
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    // The title takes the whole row; age and facts wrap below, so narrow screens and 200% text never squeeze it.
                    Text(highlightedNote(entry.title, query), fontFamily = FontFamily.Serif, style = MaterialTheme.typography.titleMedium,
                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(highlightedNote(snippet, query), style = MaterialTheme.typography.bodyMedium, color = scheme.onSurfaceVariant, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(historyAge(LocalResources.current, now, entry.updatedAt).first, style = MaterialTheme.typography.bodyMedium, color = scheme.onSurfaceVariant)
                        if (entry.duration >= 1) Text(notesDuration(entry.duration), style = MaterialTheme.typography.bodyMedium, color = scheme.onSurfaceVariant)
                        if (entry.openTodos > 0) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                            Icon(painterResource(R.drawable.ic_checklist), null, Modifier.size(18.dp), tint = scheme.onSurfaceVariant)
                            Text(pluralStringResource(R.plurals.notes_library_open_tasks, entry.openTodos, entry.openTodos), style = MaterialTheme.typography.bodyMedium, color = scheme.onSurfaceVariant)
                        }
                        if (entry.recovered) Text(stringResource(R.string.notes_library_recovered), style = MaterialTheme.typography.bodyMedium, color = LocalChirpRoles.current.moon)
                        if (RetranscribeGate.progress?.noteId == entry.id) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                        else if (entry.audioBytes > 0) Icon(painterResource(R.drawable.ic_mic), stringResource(R.string.notes_library_kept_audio), Modifier.size(14.dp), tint = scheme.onSurfaceVariant)
                    }
                }
                if (trash && !selecting) TextButton(restore) { Text(restoreLabel) }
            }
        }
    }
}
