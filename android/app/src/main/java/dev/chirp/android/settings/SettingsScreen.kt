package dev.chirp.android.settings

import androidx.activity.compose.BackHandler
import androidx.annotation.StringRes
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import dev.chirp.android.DictationHistory
import dev.chirp.android.R
import dev.chirp.android.SetupState
import dev.chirp.android.UpdateController

/** The seven categories (spec §D): each row opens one detail page. */
internal enum class SettingsPage(@StringRes val title: Int) {
    Connection(R.string.settings_page_connection), HowYouDictate(R.string.settings_page_how_you_dictate), Dictation(R.string.settings_page_dictation),
    Keyboard(R.string.settings_page_keyboard), Feedback(R.string.settings_page_feedback), Notes(R.string.notes_short),
    History(R.string.settings_page_history), About(R.string.settings_page_about),
    /** Connection → Change pairing / Pair computer: a sub-page whose Back returns to Connection, as on iOS. Not a home row. */
    Pair(R.string.settings_change_pairing),
}

/** The page's title: Pair says "Pair computer" until there is a pairing to change. */
@Composable
internal fun SettingsPage.label(state: SetupState): String =
    stringResource(if (this == SettingsPage.Pair && !state.paired) R.string.settings_pair_computer else title)

/** Where Back goes from [page]: Pair returns to Connection; every other page to the list. */
internal fun settingsParent(page: SettingsPage?): SettingsPage? = if (page == SettingsPage.Pair) SettingsPage.Connection else null

internal class SettingsActions(
    val checkConnection: () -> Unit = {}, val changePairing: () -> Unit = {}, val forgetPairing: () -> Unit = {},
    /** The Pair sub-page's scanner, paste field and retry; [paired] runs once the computer answered and the pairing saved. */
    val pairing: dev.chirp.android.PairingActions = dev.chirp.android.PairingActions(), val paired: () -> Unit = {},
    /** About → Show setup again: the onboarding from Welcome; Back returns to Settings. */
    val showSetup: () -> Unit = {},
    val allowWifi: () -> Unit = {}, val floatingMicSettings: () -> Unit = {}, val keyboardPreferences: () -> Unit = {},
    val chooseMode: (dev.chirp.android.InputMode) -> Unit = {}, val picker: () -> Unit = {},
    val appSettings: () -> Unit = {}, val keyboardSettings: () -> Unit = {},
    /** Opens the Tailscale app; null when it is not installed. */
    val openTailscale: (() -> Unit)? = null,
)

private val TWO_PANE = 600.dp

/**
 * The one Chirp settings destination: seven category rows with a live one-line summary each, and the detail behind them.
 * From 600 dp wide the list stays on the left and the detail shows on the right; narrower, rows push a page and back
 * returns to the list. Every screen's large top bar collapses as its content scrolls. [onExit] runs on back from the
 * list (null: let the system leave).
 */
@Composable
internal fun SettingsScreen(state: SetupState, actions: SettingsActions = SettingsActions(), initialPage: SettingsPage? = null,
                            history: DictationHistory? = null, updates: UpdateController? = null, onExit: (() -> Unit)? = null) {
    var page by rememberSaveable { mutableStateOf(initialPage) }
    Surface(Modifier.fillMaxSize()) {
        BoxWithConstraints(Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
            val twoPane = maxWidth >= TWO_PANE
            BackHandler(enabled = onExit != null || (page != null && (!twoPane || settingsParent(page) != null))) {
                if (page != null && (!twoPane || settingsParent(page) != null)) page = settingsParent(page) else onExit?.invoke()
            }
            // One scroll position per page: a long page (Notes) must not keep the list's offset, nor leave it behind on Back.
            val shown = if (twoPane) (page ?: SettingsPage.Connection) else page
            val scroll = rememberSaveable(twoPane, shown, saver = ScrollState.Saver) { ScrollState(0) }
            if (twoPane) Row(Modifier.fillMaxSize()) {
                // The category column is not inside a Scaffold, so it keeps clear of the status and gesture areas itself (#181).
                Column(Modifier.widthIn(min = 320.dp, max = 400.dp).width(400.dp).fillMaxHeight().windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Vertical))
                    .verticalScroll(rememberScrollState())
                    .padding(start = 24.dp, end = 16.dp, top = 32.dp, bottom = 24.dp)) {
                    Text(stringResource(R.string.settings_title), Modifier.padding(bottom = 16.dp).semantics { heading() }, style = MaterialTheme.typography.titleLarge)
                    // Keyed on the open page so the summaries re-read the store after something changes beside them.
                    CompositionLocalProvider(dev.chirp.android.ui.LocalNavSummaryLines provides
                        if (androidx.compose.ui.platform.LocalDensity.current.fontScale >= 1.5f) 2 else 1) {
                        key(page) { SettingsList(state, actions, history) { page = it } }
                    }
                }
                PageScaffold(shown!!.label(state), back = settingsParent(shown)?.let { parent -> { page = parent } }, scroll, Modifier.weight(1f).fillMaxHeight()) {
                    SettingsDetail(shown, state, actions, history, updates)
                }
            } else if (shown == null) PageScaffold(stringResource(R.string.settings_title), back = null, scroll, Modifier.widthIn(max = 600.dp).fillMaxSize()) {
                SettingsList(state, actions, history) { page = it }
            } else PageScaffold(shown.label(state), back = { page = settingsParent(shown) }, scroll, Modifier.widthIn(max = 600.dp).fillMaxSize()) {
                SettingsDetail(shown, state, actions, history, updates)
            }
        }
    }
}

/** A page: large title that collapses as the rows scroll under it, with Back on the cover screen. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun PageScaffold(title: String, back: (() -> Unit)?, scroll: ScrollState, modifier: Modifier = Modifier,
                         content: @Composable ColumnScope.() -> Unit) {
    val behaviour = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    Scaffold(modifier, topBar = {
        MediumTopAppBar(
            title = { Text(title, Modifier.semantics { heading() }) },
            navigationIcon = { if (back != null) IconButton(back) { Icon(painterResource(R.drawable.ic_arrow_back), stringResource(R.string.settings_back)) } },
            scrollBehavior = behaviour,
        )
    }) { padding ->
        Column(Modifier.fillMaxSize().nestedScroll(behaviour.nestedScrollConnection).verticalScroll(scroll)
            .padding(padding).padding(start = 24.dp, end = 24.dp, bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp), content = content)
    }
}
