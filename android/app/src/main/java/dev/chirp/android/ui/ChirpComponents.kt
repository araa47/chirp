package dev.chirp.android.ui

import androidx.annotation.DrawableRes
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.*
import androidx.compose.ui.graphics.Color
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import dev.chirp.android.R

/** Rows in one rounded container, 2 dp apart, with an optional header: the Android 16 / Gboard settings layout. */
@Composable
internal fun SettingsGroup(title: String?, modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) =
    Group(title, modifier, content)

@Composable
internal fun SettingsGroup(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) = Group(null, modifier, content)

@Composable
private fun Group(title: String?, modifier: Modifier, content: @Composable ColumnScope.() -> Unit) {
    Column(modifier.fillMaxWidth()) {
        if (title != null) Text(title, Modifier.padding(start = 16.dp, end = 16.dp, bottom = 8.dp).semantics { heading() },
            style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.primary)
        Column(Modifier.fillMaxWidth().clip(ChirpTokens.group), verticalArrangement = Arrangement.spacedBy(2.dp), content = content)
    }
}

/** Free-form content (chips, notes, buttons) on a row container, for use inside a [SettingsGroup]. */
@Composable
internal fun SettingsItem(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Column(modifier.fillMaxWidth().clip(MaterialTheme.shapes.extraSmall).background(MaterialTheme.colorScheme.surfaceContainer)
        .padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp), content = content)
}

@Composable
private fun rowColors(destructive: Boolean = false) = ListItemDefaults.colors(
    containerColor = MaterialTheme.colorScheme.surfaceContainer,
    headlineColor = if (destructive) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface,
    leadingIconColor = if (destructive) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
)

@Composable
private fun SettingsRow(title: String, summary: String?, @DrawableRes icon: Int?, modifier: Modifier, destructive: Boolean = false,
                summaryMaxLines: Int = Int.MAX_VALUE, titleMaxLines: Int = Int.MAX_VALUE, trailing: (@Composable () -> Unit)? = null) {
    ListItem(headlineContent = { Text(title, maxLines = titleMaxLines, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis) }, modifier = modifier,
        supportingContent = summary?.let { { Text(it, maxLines = summaryMaxLines, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis) } },
        leadingContent = icon?.let { { Icon(painterResource(it), null) } },
        trailingContent = trailing, colors = rowColors(destructive))
}

private fun Modifier.row() = fillMaxWidth().heightIn(min = 56.dp)

/** ⓘ: the paragraph behind a row (spec §D Settings), so the row itself keeps to one line. */
@Composable
private fun InfoIcon(title: String, body: String) {
    var open by rememberSaveable { mutableStateOf(false) }
    val about = stringResource(R.string.settings_about_row, title)
    IconButton({ open = true }, Modifier.semantics { contentDescription = about }) {
        Icon(painterResource(R.drawable.ic_info), null, Modifier.size(20.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    if (open) InfoSheet(title, body) { open = false }
}

/** The whole row toggles (one merged node: title, summary, switch, on/off); the [Switch] itself takes no input. */
@Composable
internal fun SwitchRow(title: String, checked: Boolean, onCheckedChange: (Boolean) -> Unit, modifier: Modifier = Modifier,
                       summary: String? = null, @DrawableRes icon: Int? = null, enabled: Boolean = true,
                       infoTitle: String? = null, infoBody: String? = null) {
    SettingsRow(title, summary, icon, modifier.row().clip(MaterialTheme.shapes.extraSmall)
        .toggleable(checked, enabled = enabled, role = Role.Switch, onValueChange = onCheckedChange)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (infoTitle != null && infoBody != null) InfoIcon(infoTitle, infoBody)
            Switch(checked, onCheckedChange = null, enabled = enabled)
        }
    }
}

/** Opens another screen, dialog or app: trailing chevron. */
internal val LocalNavSummaryLines = staticCompositionLocalOf { Int.MAX_VALUE }

@Composable
internal fun NavRow(title: String, onClick: () -> Unit, modifier: Modifier = Modifier, summary: String? = null,
                    @DrawableRes icon: Int? = null, enabled: Boolean = true, infoTitle: String? = null, infoBody: String? = null,
                    summaryMaxLines: Int = LocalNavSummaryLines.current) {
    SettingsRow(title, summary, icon, modifier.row().clip(MaterialTheme.shapes.extraSmall)
        .clickable(enabled = enabled, role = Role.Button, onClick = onClick),
        summaryMaxLines = summaryMaxLines, titleMaxLines = if (summaryMaxLines == 1) 1 else Int.MAX_VALUE) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (infoTitle != null && infoBody != null) InfoIcon(infoTitle, infoBody)
            Icon(painterResource(R.drawable.ic_chevron_right), null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** Does something in place. [destructive] actions use the error colour. */
@Composable
internal fun ActionRow(title: String, onClick: () -> Unit, modifier: Modifier = Modifier, summary: String? = null,
                       @DrawableRes icon: Int? = null, destructive: Boolean = false, enabled: Boolean = true,
                       infoTitle: String? = null, infoBody: String? = null) {
    SettingsRow(title, summary, icon, modifier.row().clip(MaterialTheme.shapes.extraSmall)
        .clickable(enabled = enabled, role = Role.Button, onClick = onClick), destructive) {
        if (infoTitle != null && infoBody != null) InfoIcon(infoTitle, infoBody)
    }
}

/** Single-select chip row (Stop dictation, Keep for, App colours). */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun <T> ChoiceChips(options: List<T>, selected: T, label: (T) -> String, modifier: Modifier = Modifier, onSelect: (T) -> Unit) {
    FlowRow(modifier.selectableGroup(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        options.forEach { option -> FilterChip(option == selected, { onSelect(option) }, label = { Text(label(option)) }) }
    }
}

internal enum class StatusKind(@DrawableRes val icon: Int) { Info(R.drawable.ic_info), Success(R.drawable.ic_check_circle), Warning(R.drawable.ic_warning), Error(R.drawable.ic_error) }

/** The card's fill and text colour. A full-width card is never the koi container (muddy brown in dark): Success is a tonal surface, its lily check carries the meaning. */
internal fun statusColors(scheme: ColorScheme, kind: StatusKind): Pair<Color, Color> = when (kind) {
    StatusKind.Info -> scheme.secondaryContainer to scheme.onSecondaryContainer
    StatusKind.Success -> scheme.surfaceContainerHigh to scheme.onSurface
    StatusKind.Warning -> scheme.tertiaryContainer to scheme.onTertiaryContainer
    StatusKind.Error -> scheme.errorContainer to scheme.onErrorContainer
}

/** Status card. [live] announces changes politely, as the setup status line always has. */
@Composable
internal fun StatusBanner(kind: StatusKind, title: String, modifier: Modifier = Modifier, body: String? = null,
                          action: String? = null, onAction: () -> Unit = {}, live: Boolean = false) {
    val (container, content) = statusColors(MaterialTheme.colorScheme, kind)
    Surface(modifier.fillMaxWidth(), shape = MaterialTheme.shapes.large, color = container, contentColor = content) {
        Row(Modifier.padding(16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Icon(painterResource(kind.icon), null, tint = if (kind == StatusKind.Success) LocalChirpRoles.current.lily else LocalContentColor.current)
            Column(Modifier.weight(1f).semantics(mergeDescendants = true) { if (live) liveRegion = LiveRegionMode.Polite },
                verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(title, style = if (body == null) MaterialTheme.typography.bodyLarge else MaterialTheme.typography.titleSmall)
                body?.let { Text(it, style = MaterialTheme.typography.bodyMedium) }
            }
            if (action != null) TextButton(onAction, Modifier.align(Alignment.CenterVertically),
                colors = ButtonDefaults.textButtonColors(contentColor = content)) { Text(action) }
        }
    }
}

/** Long explanations live here so screens can show one line plus "Learn more". */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun InfoSheet(title: String, body: String, onDismiss: () -> Unit) {
    ModalBottomSheet(onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        InfoSheetContent(title, body, onDismiss)
    }
}

@Composable
internal fun InfoSheetContent(title: String, body: String, onDismiss: () -> Unit) {
    Column(Modifier.fillMaxWidth().padding(start = 24.dp, end = 24.dp, bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(title, Modifier.semantics { heading() }, style = MaterialTheme.typography.titleLarge)
        Text(body, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        TextButton(onDismiss, Modifier.align(Alignment.End)) { Text(stringResource(R.string.settings_close)) }
    }
}

/** "Learn more" link that opens an [InfoSheet]. */
@Composable
internal fun LearnMore(title: String, body: String, modifier: Modifier = Modifier, label: String = stringResource(R.string.settings_learn_more)) {
    var open by rememberSaveable { mutableStateOf(false) }
    TextButton({ open = true }, modifier) { Text(label) }
    if (open) InfoSheet(title, body) { open = false }
}
