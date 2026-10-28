package dev.chirp.android

import android.provider.Settings
import androidx.compose.ui.res.stringResource
import androidx.activity.compose.PredictiveBackHandler
import androidx.compose.animation.*
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp

/** Moved to [dev.chirp.android.ui.ChirpTheme]; this name stays so existing callers compile unchanged. */
@Composable
internal fun ChirpTheme(dark: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) =
    dev.chirp.android.ui.ChirpTheme(dark, content = content)

internal class OnboardingActions(
    val grantMic: () -> Unit = {}, val keyboardSettings: () -> Unit = {}, val picker: () -> Unit = {}, val appSettings: () -> Unit = {},
    val scan: () -> Unit = {}, val pasteLink: (String) -> Unit = {}, val retry: () -> Unit = {}, val grantNetwork: () -> Unit = {},
    val openTailscale: () -> Unit = {}, val finish: () -> Unit = {},
    val chooseMode: (InputMode) -> Unit = {}, val accessibility: () -> Unit = {}, val skipFloatingMic: () -> Unit = {},
    val skipPairing: () -> Unit = {},
)

/** A page's one job: [onClick] is the primary button pinned to the bottom of the screen. */
internal class PrimaryAction(val label: String, val enabled: Boolean = true, val onClick: () -> Unit)

private fun animationsOn(context: android.content.Context) =
    Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) != 0f

/** Four full-screen pages (welcome, keyboard, microphone, pair) with one primary button each; [SetupState.step] says which. */
@Composable
internal fun Onboarding(state: SetupState, actions: OnboardingActions = OnboardingActions()) {
    val page = state.step.coerceIn(PAGE_WELCOME, PAGE_PAIR)
    val context = LocalContext.current
    val animate = remember(context) { animationsOn(context) }
    var backProgress by remember { mutableFloatStateOf(0f) }
    PredictiveBackHandler(enabled = page > state.entryStep) { events ->
        try { events.collect { backProgress = it.progress }; state.step = page - 1 } finally { backProgress = 0f }
    }
    Surface(Modifier.fillMaxSize()) {
        Box(Modifier.fillMaxSize().safeDrawingPadding(), contentAlignment = Alignment.TopCenter) {
            // No horizontal padding here: the welcome page's pond art bleeds edge to edge; each page pads its own text.
            Column(Modifier.widthIn(max = 560.dp).fillMaxSize().padding(top = 16.dp, bottom = 16.dp)) {
                PageIndicator(page)
                AnimatedContent(page, Modifier.weight(1f).fillMaxWidth().graphicsLayer {
                    val scale = 1f - .08f * backProgress; scaleX = scale; scaleY = scale; alpha = 1f - .3f * backProgress
                }, transitionSpec = {
                    if (!animate) fadeIn(tween(150)) togetherWith fadeOut(tween(150))
                    else { val way = if (targetState > initialState) 1 else -1
                        (slideInHorizontally(tween(300)) { it / 8 * way } + fadeIn(tween(300))) togetherWith
                            (slideOutHorizontally(tween(300)) { -it / 8 * way } + fadeOut(tween(150))) }
                }, label = "onboarding page") { shown -> OnboardingPage(shown, state, actions) }
            }
        }
    }
}

@Composable
private fun PageIndicator(page: Int) {
    val step = stringResource(R.string.setup_step, page + 1, 5)
    Row(Modifier.fillMaxWidth().padding(vertical = 16.dp).semantics(mergeDescendants = true) {
        contentDescription = step; progressBarRangeInfo = ProgressBarRangeInfo((page + 1).toFloat(), 1f..5f, 3)
    }, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        repeat(5) { index ->
            val color by animateColorAsState(if (index <= page) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant, label = "segment")
            Box(Modifier.weight(1f).height(6.dp).clip(CircleShape).background(color))
        }
    }
}
