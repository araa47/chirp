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
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import dev.chirp.android.settings.connectionSummary
import dev.chirp.android.ui.*

/** Shared with iOS onboarding: the same page titles and secondary-link labels on both phones. */
internal const val WELCOME_TITLE = "Welcome to Chirp"
internal const val KEYBOARD_TITLE = "Turn on Chirp Keyboard"
internal const val ABOUT_KEYBOARD = "About the keyboard"
internal const val MICROPHONE_TITLE = "Allow the microphone"
internal const val ABOUT_MICROPHONE = "What Chirp keeps"
internal const val PAIR_PAGE_TITLE = "Pair your computer"
internal const val ABOUT_PAIRING = "About pairing"
internal const val PAIRING_COMMAND = "chirp-server pair"
internal const val PAIRING_STEPS =
    "On your computer, open Chirp → Settings → Devices → Pair a Phone, or run chirp-server pair on your server."

@Composable
internal fun OnboardingPage(page: Int, state: SetupState, actions: OnboardingActions) {
    val next = { state.step = page + 1 }
    when (page) {
        PAGE_WELCOME -> PageFrame(WELCOME_TITLE, { PondHero() }, PrimaryAction(stringResource(R.string.onboarding_get_started)) { next() }) {
            Body(stringResource(R.string.onboarding_welcome_body))
            Body(stringResource(R.string.onboarding_welcome_privacy))
        }
        PAGE_CHOICE -> PageFrame(stringResource(R.string.onboarding_choice_title), {}, PrimaryAction(stringResource(R.string.onboarding_continue), state.inputMode != null) { next() }) {
            InputModeCards(state, actions.chooseMode)
        }
        PAGE_KEYBOARD -> if (state.inputMode == InputMode.OWN_KEYBOARD) {
            PageFrame(stringResource(R.string.onboarding_bubble_title), {}, when {
                state.advancedProtection -> PrimaryAction(stringResource(R.string.onboarding_continue_without), onClick = actions.skipFloatingMic)
                state.bubbleEnabled -> PrimaryAction(stringResource(R.string.onboarding_continue)) { next() }
                else -> PrimaryAction(stringResource(R.string.setup_open_accessibility), onClick = actions.accessibility)
            }) {
                FloatingMicGuide(state, actions.accessibility, actions.appSettings,
                    useKeyboard = { actions.chooseMode(InputMode.KEYBOARD) })
                if (!state.advancedProtection) TextButton(actions.skipFloatingMic) { Text(stringResource(R.string.onboarding_skip)) }
            }
        } else PageFrame(KEYBOARD_TITLE, { Illustration(R.drawable.ic_keyboard) }, when {
            !state.inputEnabled -> PrimaryAction(stringResource(R.string.setup_enable_keyboard), onClick = actions.keyboardSettings)
            !state.inputSelected -> PrimaryAction(stringResource(R.string.onboarding_select_keyboard), onClick = actions.picker)
            else -> PrimaryAction(stringResource(R.string.onboarding_continue)) { next() }
        }) {
            Body(stringResource(R.string.onboarding_keyboard_body))
            SettingsGroup {
                CheckRow(stringResource(R.string.setup_keyboard_enabled), state.inputEnabled)
                CheckRow(stringResource(R.string.onboarding_selected_default), state.inputSelected)
            }
            val swipe = swipeTypingSummary(LocalContext.current)
            Tips(ABOUT_KEYBOARD, stringResource(R.string.ime_name), stringResource(R.string.onboarding_keyboard_tips, swipe))
        }
        PAGE_MIC -> PageFrame(MICROPHONE_TITLE, { Illustration(R.drawable.ic_mic) }, if (state.mic) PrimaryAction(stringResource(R.string.onboarding_continue)) { next() }
            else PrimaryAction(stringResource(R.string.onboarding_allow_mic), onClick = actions.grantMic)) {
            Body(stringResource(R.string.onboarding_mic_body))
            if (state.mic) SettingsGroup { CheckRow(stringResource(R.string.onboarding_mic_allowed), true) }
            else if (state.micDenied) StatusBanner(StatusKind.Warning, stringResource(R.string.onboarding_mic_denied), action = stringResource(R.string.onboarding_open_permissions), onAction = actions.appSettings, live = true)
            Tips(ABOUT_MICROPHONE, stringResource(R.string.onboarding_mic_tips_title), stringResource(R.string.onboarding_mic_tips))
        }
        else -> PairPage(state, actions)
    }
}

@Composable
private fun PairPage(state: SetupState, actions: OnboardingActions) {
    var paste by rememberSaveable { mutableStateOf(false) }
    val context = LocalContext.current
    if (state.connected) {
        val connection = connectionSummary(true, state.host, state.reachable, false, state.health)
        PageFrame(stringResource(R.string.onboarding_connected), { Illustration(R.drawable.ic_check_circle) }, PrimaryAction(stringResource(R.string.onboarding_finish), onClick = actions.finish)) {
            StatusBanner(connection.kind, connection.title, body = connection.summary, live = true)
            if (state.health?.debugRetention == true) StatusBanner(StatusKind.Error, stringResource(R.string.settings_debug_retention_on))
        }
        return
    }
    val busy = state.scanning || state.checking
    PageFrame(PAIR_PAGE_TITLE, { Illustration(R.drawable.ic_qr_scan) },
        PrimaryAction(stringResource(when { state.scanning -> R.string.onboarding_scanning; state.checking -> R.string.onboarding_connecting; else -> R.string.onboarding_scan }), !busy, actions.scan)) {
        PairingSteps()
        if (!state.pairFromShell) TextButton(actions.skipPairing, Modifier.align(Alignment.CenterHorizontally)) { Text(stringResource(R.string.onboarding_skip)) }
        if (state.wifiPermissionNeeded && !state.localNetwork) StatusBanner(StatusKind.Warning, stringResource(R.string.settings_allow_wifi),
            body = stringResource(R.string.settings_allow_wifi_summary), action = stringResource(R.string.quick_dictate_allow), onAction = actions.grantNetwork)
        if (state.checking) StatusBanner(StatusKind.Info, stringResource(R.string.onboarding_connecting_computer), live = true)
        else when (state.pairIssue) {
            PairIssue.Unreachable -> {
                val tailscale = remember(context) { AndroidTailscale(context).installed() }
                StatusBanner(StatusKind.Error, stringResource(R.string.onboarding_unreachable), body = stringResource(R.string.onboarding_unreachable_body),
                    action = stringResource(if (tailscale) R.string.settings_open_tailscale else R.string.onboarding_try_again), onAction = if (tailscale) actions.openTailscale else actions.retry, live = true)
            }
            PairIssue.ScannerUnavailable -> StatusBanner(StatusKind.Warning, stringResource(R.string.onboarding_scanner_unavailable), body = stringResource(R.string.onboarding_scanner_unavailable_body),
                action = stringResource(R.string.onboarding_paste_link), onAction = { paste = true }, live = true)
            PairIssue.InvalidLink -> StatusBanner(StatusKind.Error, stringResource(R.string.onboarding_invalid_code), action = stringResource(R.string.onboarding_scan_again), onAction = actions.scan, live = true)
            null -> {}
        }
        if (!paste && state.link.isEmpty()) { if (state.pairIssue != PairIssue.ScannerUnavailable) TextButton({ paste = true }, Modifier.align(Alignment.CenterHorizontally)) { Text(stringResource(R.string.onboarding_paste_link)) } }
        else {
            val invalid = state.link.isNotBlank() && runCatching { Pairing.parse(state.link) }.isFailure
            val linkDescription = stringResource(R.string.onboarding_link_description)
            OutlinedTextField(state.link, { actions.pasteLink(it) }, Modifier.fillMaxWidth().semantics { contentDescription = linkDescription },
                label = { Text(stringResource(R.string.onboarding_link_label)) }, singleLine = true, isError = invalid,
                supportingText = { Text(stringResource(if (invalid) R.string.onboarding_link_invalid else R.string.onboarding_link_hint)) },
                visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
        }
        Tips(ABOUT_PAIRING, stringResource(R.string.onboarding_pairing_tips_title), stringResource(R.string.onboarding_pairing_tips))
    }
}

/**
 * Title, hero and scrolling content, with the page's one primary button pinned below (inside the system bars, never scrolled away).
 * The hero runs edge to edge; the text keeps the page gutter. At 200% font the content scrolls under the hero, button still pinned.
 */
@Composable
internal fun PageFrame(title: String, hero: @Composable () -> Unit, primary: PrimaryAction, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) { hero() }
            Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Text(title, Modifier.fillMaxWidth().semantics { heading() }, style = MaterialTheme.typography.headlineMedium, textAlign = TextAlign.Center)
                content()
            }
        }
        Button(primary.onClick, Modifier.fillMaxWidth().padding(horizontal = 24.dp).heightIn(min = 56.dp), enabled = primary.enabled) { Text(primary.label) }
    }
}

/** The approved full-bleed pond artwork (spec §D), used as-is: no tiles, borders or overlays; a centre crop fills the width. */
@Composable
private fun PondHero() {
    Image(painterResource(R.drawable.chirp_pond), null, Modifier.fillMaxWidth().height(300.dp), contentScale = ContentScale.Crop)
}

@Composable
private fun Illustration(@DrawableRes icon: Int, wide: Boolean = false) {
    val scheme = MaterialTheme.colorScheme
    if (wide) Icon(painterResource(icon), null, Modifier.padding(horizontal = 24.dp, vertical = 8.dp), tint = scheme.primary)
    else Box(Modifier.size(152.dp).clip(CircleShape).background(scheme.surfaceContainerHigh), contentAlignment = Alignment.Center) {
        Icon(painterResource(icon), null, Modifier.size(72.dp), tint = scheme.primary)
    }
}

@Composable
private fun Body(text: String) = Text(text, Modifier.fillMaxWidth(), style = MaterialTheme.typography.bodyLarge, textAlign = TextAlign.Center,
    color = MaterialTheme.colorScheme.onSurfaceVariant)

/** Pairing steps, with the server command in code font. */
internal fun pairingStepsAnnotated() = buildAnnotatedString {
    val start = PAIRING_STEPS.indexOf(PAIRING_COMMAND)
    append(PAIRING_STEPS.substring(0, start))
    // A hyphen is a line-break point, so the shown command uses a non-breaking hyphen and space.
    withStyle(SpanStyle(fontFamily = FontFamily.Monospace)) {
        append(PAIRING_COMMAND.replace('-', '\u2011').replace(' ', '\u00A0'))
    }
    append(PAIRING_STEPS.substring(start + PAIRING_COMMAND.length))
}

@Composable
private fun PairingSteps() {
    Text(pairingStepsAnnotated(), Modifier.fillMaxWidth(), style = MaterialTheme.typography.bodyLarge, textAlign = TextAlign.Center,
        color = MaterialTheme.colorScheme.onSurfaceVariant)
}

/** One requirement: a check in a circle when met, an empty circle when not (an icon, not a "✓" character). */
@Composable
internal fun CheckRow(title: String, done: Boolean) {
    val doneState = stringResource(if (done) R.string.onboarding_done else R.string.onboarding_not_done)
    ListItem(headlineContent = { Text(title) }, modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp)
        .semantics(mergeDescendants = true) { stateDescription = doneState },
        leadingContent = { Icon(painterResource(if (done) R.drawable.ic_check_circle else R.drawable.ic_circle_outline), null,
            tint = if (done) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline) },
        colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surfaceContainer))
}

/** Secondary detail behind a text button, so a page keeps to one idea. */
@Composable
private fun ColumnScope.Tips(label: String, title: String, body: String) =
    LearnMore(title, body, Modifier.align(Alignment.CenterHorizontally), label)
