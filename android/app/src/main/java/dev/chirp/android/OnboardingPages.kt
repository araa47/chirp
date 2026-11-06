package dev.chirp.android

import androidx.annotation.DrawableRes
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import dev.chirp.android.settings.connectionSummary
import dev.chirp.android.ui.*

/** Page titles and secondary-link labels are shared with iOS (strings_labels.xml, `onboarding_title_*` / `onboarding_about_*`): word for word the same on both phones. */
internal const val PAIRING_COMMAND = "chirp-server pair"

@Composable
internal fun OnboardingPage(page: Int, state: SetupState, actions: OnboardingActions) {
    val next = { state.step = page + 1 }
    // "Skip for now" under the primary button on every page, as on iOS: it moves on, and on the last page it finishes.
    val skip = Skip(stringResource(R.string.onboarding_skip)) { next() }
    when (page) {
        PAGE_WELCOME -> PageFrame(stringResource(R.string.onboarding_title_welcome), { PondHero() }, PrimaryAction(stringResource(R.string.onboarding_get_started)) { next() },
            Skip(stringResource(R.string.onboarding_skip_setup), actions.skipPairing), large = true) {
            Feature(R.drawable.ic_mic, stringResource(R.string.onboarding_welcome_dictate))
            Feature(R.drawable.ic_notes_tab, stringResource(R.string.onboarding_welcome_notes))
            Feature(R.drawable.ic_lock, stringResource(R.string.onboarding_welcome_private))
            Text(stringResource(R.string.onboarding_welcome_privacy), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        // Skipping the choice skips its setup page too.
        PAGE_CHOICE -> PageFrame(stringResource(R.string.onboarding_choice_title), {}, PrimaryAction(stringResource(R.string.onboarding_continue), state.inputMode != null) { next() },
            Skip(skip.label) { state.step = PAGE_MIC }) {
            InputModeCards(state, actions.chooseMode)
        }
        PAGE_KEYBOARD -> if (state.inputMode == InputMode.OWN_KEYBOARD) {
            PageFrame(stringResource(R.string.onboarding_bubble_title), {}, when {
                state.advancedProtection -> PrimaryAction(stringResource(R.string.onboarding_continue_without), onClick = actions.skipFloatingMic)
                state.bubbleEnabled -> PrimaryAction(stringResource(R.string.onboarding_continue)) { next() }
                else -> PrimaryAction(stringResource(R.string.setup_open_accessibility), onClick = actions.accessibility)
            }, if (state.advancedProtection || state.bubbleEnabled) null else Skip(skip.label, actions.skipFloatingMic)) {
                FloatingMicGuide(state, actions.accessibility, actions.appSettings,
                    useKeyboard = { actions.chooseMode(InputMode.KEYBOARD) })
            }
        } else PageFrame(stringResource(R.string.onboarding_title_keyboard), { Badge(R.drawable.ic_keyboard, state.inputEnabled && state.inputSelected) }, when {
            !state.inputEnabled -> PrimaryAction(stringResource(R.string.setup_enable_keyboard), onClick = actions.keyboardSettings)
            !state.inputSelected -> PrimaryAction(stringResource(R.string.onboarding_select_keyboard), onClick = actions.picker)
            else -> PrimaryAction(stringResource(R.string.onboarding_continue)) { next() }
        }, if (state.inputEnabled && state.inputSelected) null else skip) {
            Body(stringResource(R.string.onboarding_keyboard_body))
            SettingsGroup {
                CheckRow(stringResource(R.string.setup_keyboard_enabled), state.inputEnabled)
                CheckRow(stringResource(R.string.onboarding_selected_default), state.inputSelected)
            }
            val swipe = swipeTypingSummary(LocalContext.current)
            Tips(stringResource(R.string.onboarding_about_keyboard), stringResource(R.string.ime_name), stringResource(R.string.onboarding_keyboard_tips, swipe))
        }
        PAGE_MIC -> PageFrame(stringResource(R.string.onboarding_title_microphone), { Badge(R.drawable.ic_mic, state.mic) }, when {
            state.mic -> PrimaryAction(stringResource(R.string.onboarding_continue)) { next() }
            state.micDenied -> PrimaryAction(stringResource(R.string.onboarding_open_permissions), onClick = actions.appSettings)
            else -> PrimaryAction(stringResource(R.string.onboarding_allow_mic), onClick = actions.grantMic)
        }, if (state.mic) null else skip) {
            Body(stringResource(R.string.onboarding_mic_body))
            if (state.mic) SettingsGroup { CheckRow(stringResource(R.string.onboarding_mic_allowed), true) }
            else if (state.micDenied) StatusBanner(StatusKind.Warning, stringResource(R.string.onboarding_mic_denied), body = stringResource(R.string.onboarding_mic_denied_body), live = true)
            Tips(stringResource(R.string.onboarding_about_microphone), stringResource(R.string.onboarding_mic_tips_title), stringResource(R.string.onboarding_mic_tips))
        }
        else -> PairPage(state, actions)
    }
}

/** What the pair form needs, from onboarding or Settings → Change pairing. */
internal class PairingActions(val scan: () -> Unit = {}, val pasteLink: (String) -> Unit = {}, val retry: () -> Unit = {},
                              val grantNetwork: () -> Unit = {}, val openTailscale: () -> Unit = {})

/**
 * The pair page stays "Pair your computer" through every outcome, as on iOS: the badge turns lily and a banner says
 * "Connected to <computer>", or "Couldn't pair with your computer" with the reason and one fix.
 */
@Composable
private fun PairPage(state: SetupState, actions: OnboardingActions) {
    val busy = state.scanning || state.checking
    // Opened on its own (a pairing link before setup): nothing to skip to.
    val standalone = state.pairFromShell && state.entryStep == PAGE_PAIR
    PageFrame(stringResource(R.string.onboarding_title_pair), { Badge(R.drawable.ic_qr_scan, state.connected) },
        if (state.connected) PrimaryAction(stringResource(R.string.onboarding_continue), onClick = actions.finish)
        else PrimaryAction(stringResource(when { state.scanning -> R.string.onboarding_scanning; state.checking -> R.string.onboarding_connecting; else -> R.string.onboarding_scan }), !busy, actions.scan),
        if (state.connected || standalone) null else Skip(stringResource(R.string.onboarding_skip), actions.skipPairing)) {
        if (!state.connected) PairingSteps()
        PairingForm(state, PairingActions(actions.scan, actions.pasteLink, actions.retry, actions.grantNetwork, actions.openTailscale))
        Tips(stringResource(R.string.onboarding_about_pairing), stringResource(R.string.onboarding_pairing_tips_title), stringResource(R.string.onboarding_pairing_tips))
    }
}

/** The pair form's outcome and the paste field; the Scan code button belongs to the page that hosts it. */
@Composable
internal fun PairingForm(state: SetupState, actions: PairingActions) = Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(16.dp)) {
    var paste by rememberSaveable { mutableStateOf(false) }
    val context = LocalContext.current
    if (state.connected) {
        val connection = connectionSummary(true, state.host, state.reachable, false, state.health)
        StatusBanner(StatusKind.Success, stringResource(R.string.onboarding_pair_connected, state.host), body = connection.summary?.text(), live = true)
        if (state.health?.debugRetention == true) StatusBanner(StatusKind.Error, stringResource(R.string.settings_debug_retention_on))
        return@Column
    }
    if (state.wifiPermissionNeeded && !state.localNetwork) StatusBanner(StatusKind.Warning, stringResource(R.string.settings_allow_wifi),
        body = stringResource(R.string.settings_allow_wifi_summary), action = stringResource(R.string.quick_dictate_allow), onAction = actions.grantNetwork)
    val connecting = stringResource(R.string.onboarding_connecting_computer)
    if (state.checking) Row(Modifier.heightIn(min = 48.dp).semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite; contentDescription = connecting },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
        Text(connecting, style = MaterialTheme.typography.titleSmall)
    }
    else when (state.pairIssue) {
        PairIssue.Unreachable -> {
            // The specific reason (asleep, not on the tailnet, no secure connection), then one fix.
            val tailscale = remember(context) { AndroidTailscale(context).installed() } && state.failure?.action == DictationAction.NETWORK
            StatusBanner(StatusKind.Error, stringResource(R.string.onboarding_pair_failed),
                body = state.failure?.resolve(LocalResources.current) ?: stringResource(R.string.onboarding_pair_failed_body),
                action = stringResource(if (tailscale) R.string.settings_open_tailscale else R.string.onboarding_try_again), onAction = if (tailscale) actions.openTailscale else actions.retry, live = true)
        }
        PairIssue.ScannerUnavailable -> StatusBanner(StatusKind.Warning, stringResource(R.string.onboarding_scanner_unavailable), body = stringResource(R.string.onboarding_scanner_unavailable_body),
            action = stringResource(R.string.onboarding_paste_link), onAction = { paste = true }, live = true)
        PairIssue.InvalidLink -> StatusBanner(StatusKind.Error, stringResource(R.string.onboarding_invalid_code), action = stringResource(R.string.onboarding_scan_again), onAction = actions.scan, live = true)
        null -> {}
    }
    if (!paste && state.link.isEmpty()) { if (state.pairIssue != PairIssue.ScannerUnavailable) TextButton({ paste = true }) { Text(stringResource(R.string.onboarding_paste_link)) } }
    else {
        val invalid = state.link.isNotBlank() && runCatching { Pairing.parse(state.link) }.isFailure
        val linkDescription = stringResource(R.string.onboarding_link_description)
        OutlinedTextField(state.link, { actions.pasteLink(it) }, Modifier.fillMaxWidth().semantics { contentDescription = linkDescription },
            label = { Text(stringResource(R.string.onboarding_link_label)) }, singleLine = true, isError = invalid,
            supportingText = { Text(stringResource(if (invalid) R.string.onboarding_link_invalid else R.string.onboarding_link_hint)) },
            visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
    }
}

/** A quiet secondary action under the primary button. */
internal class Skip(val label: String, val onClick: () -> Unit)

/**
 * Hero, then a left-aligned bold title and the page's content, as on iOS; the primary button and "Skip for now" stay pinned
 * below (inside the system bars, never scrolled away). The welcome hero runs edge to edge; text keeps the page gutter.
 */
@Composable
internal fun PageFrame(title: String, hero: @Composable () -> Unit, primary: PrimaryAction, skip: Skip? = null, large: Boolean = false,
                       content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxSize()) {
        Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            if (large) hero()
            Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(top = 8.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                if (!large) hero()
                Text(title, Modifier.fillMaxWidth().semantics { heading() }, fontWeight = FontWeight.Bold,
                    style = if (large) MaterialTheme.typography.headlineLarge else MaterialTheme.typography.headlineMedium)
                content()
            }
        }
        Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(top = 12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Button(primary.onClick, Modifier.fillMaxWidth().heightIn(min = 56.dp), enabled = primary.enabled) { Text(primary.label) }
            if (skip != null) TextButton(skip.onClick, Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text(skip.label) }
        }
    }
}

/** The approved full-bleed pond artwork (spec §D), used as-is: no tiles, borders or overlays; a centre crop fills the width. */
@Composable
private fun PondHero() {
    Image(painterResource(R.drawable.chirp_pond), null, Modifier.fillMaxWidth().height(260.dp), contentScale = ContentScale.Crop)
}

/** One Welcome line: a koi icon and a sentence, as iOS's feature rows. */
@Composable
private fun Feature(@DrawableRes icon: Int, text: String) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        Icon(painterResource(icon), null, Modifier.size(28.dp), tint = MaterialTheme.colorScheme.primary)
        Text(text, style = MaterialTheme.typography.titleLarge)
    }
}

/**
 * The page's badge, as on iOS: a 72 dp koiContainer circle (surfaceContainer in dark) with the step's glyph, turning lily
 * with a check once the step is done.
 */
@Composable
internal fun Badge(@DrawableRes icon: Int, done: Boolean) {
    val scheme = MaterialTheme.colorScheme
    val lily = LocalChirpRoles.current.lily
    val dark = scheme.background.luminance() < .5f
    Box(Modifier.size(72.dp).clip(CircleShape).background(if (done) lily.copy(alpha = .16f) else if (dark) scheme.surfaceContainer else scheme.primaryContainer),
        contentAlignment = Alignment.Center) {
        Icon(painterResource(if (done) R.drawable.ic_check else icon), null, Modifier.size(32.dp),
            tint = if (done) lily else if (dark) scheme.primary else scheme.onPrimaryContainer)
    }
}

@Composable
private fun Body(text: String) = Text(text, Modifier.fillMaxWidth(), style = MaterialTheme.typography.bodyLarge,
    color = MaterialTheme.colorScheme.onSurfaceVariant)

/** The pairing steps sentence; [PAIRING_COMMAND] is its one argument, so the command stays findable in any language. */
internal fun pairingSteps(resources: android.content.res.Resources) = resources.getString(R.string.onboarding_pairing_steps, PAIRING_COMMAND)

/** Pairing steps, with the server command in code font. */
@Composable
internal fun pairingStepsAnnotated(): AnnotatedString {
    val steps = pairingSteps(LocalResources.current)
    val start = steps.indexOf(PAIRING_COMMAND)
    return buildAnnotatedString {
        append(steps.substring(0, start))
        // A hyphen is a line-break point, so the shown command uses a non-breaking hyphen and space.
        withStyle(SpanStyle(fontFamily = FontFamily.Monospace)) {
            append(PAIRING_COMMAND.replace('-', '\u2011').replace(' ', '\u00A0'))
        }
        append(steps.substring(start + PAIRING_COMMAND.length))
    }
}

@Composable
private fun PairingSteps() {
    Text(pairingStepsAnnotated(), Modifier.fillMaxWidth(), style = MaterialTheme.typography.bodyLarge,
        color = MaterialTheme.colorScheme.onSurfaceVariant)
}

/** One requirement: a check in a circle when met, an empty circle when not (an icon, not a "✓" character). */
@Composable
internal fun CheckRow(title: String, done: Boolean) {
    val doneState = stringResource(if (done) R.string.onboarding_done else R.string.onboarding_not_done)
    ListItem(headlineContent = { Text(title) }, modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp)
        .semantics(mergeDescendants = true) { stateDescription = doneState },
        leadingContent = { Icon(painterResource(if (done) R.drawable.ic_check_circle else R.drawable.ic_circle_outline), null,
            tint = if (done) LocalChirpRoles.current.lily else MaterialTheme.colorScheme.outline) },
        colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surfaceContainer))
}

/** Secondary detail behind a text button, so a page keeps to one idea. */
@Composable
private fun Tips(label: String, title: String, body: String) = LearnMore(title, body, label = label)
