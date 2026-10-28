package dev.chirp.android.ui

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.res.stringResource
import dev.chirp.android.AppColour
import dev.chirp.android.R
import dev.chirp.android.SettingsStore

/** The Pond palette (spec §C): koi on a midnight pond, from the app icon's identity. */
internal val PondDark = darkColorScheme(
    primary = Color(0xFFFF8A4C), onPrimary = Color(0xFF0D1526),
    primaryContainer = Color(0xFF5C2207), onPrimaryContainer = Color(0xFFFFD9C2),
    secondary = Color(0xFFA3ADBF), onSecondary = Color(0xFF1A2333),
    secondaryContainer = Color(0xFF1A2640), onSecondaryContainer = Color(0xFFE8ECF3),
    tertiary = Color(0xFFF5C566), onTertiary = Color(0xFF443000),
    tertiaryContainer = Color(0xFF4E3B00), onTertiaryContainer = Color(0xFFF5C566),
    surface = Color(0xFF121C30), onSurface = Color(0xFFE8ECF3),
    surfaceVariant = Color(0xFF26324B), onSurfaceVariant = Color(0xFFA3ADBF),
    surfaceContainerLowest = Color(0xFF0D1526), surfaceContainerLow = Color(0xFF0D1526),
    surfaceContainer = Color(0xFF1A2640), surfaceContainerHigh = Color(0xFF222F4C), surfaceContainerHighest = Color(0xFF2A3859),
    background = Color(0xFF0D1526), onBackground = Color(0xFFE8ECF3),
    outline = Color(0xFF8A93A8), outlineVariant = Color(0xFF3A4661),
    error = Color(0xFFFF6B6B), onError = Color(0xFF0D1526),
    errorContainer = Color(0xFF5C1D1D), onErrorContainer = Color(0xFFFFD9D4),
    inverseSurface = Color(0xFFE8ECF3), inverseOnSurface = Color(0xFF121C30), inversePrimary = Color(0xFFC2410C),
)
internal val PondLight = lightColorScheme(
    primary = Color(0xFFC2410C), onPrimary = Color.White,
    primaryContainer = Color(0xFFFFE4D4), onPrimaryContainer = Color(0xFF7A2A08),
    secondary = Color(0xFF5B6577), onSecondary = Color.White,
    secondaryContainer = Color(0xFFECEFF5), onSecondaryContainer = Color(0xFF1A2333),
    tertiary = Color(0xFF8A5A00), onTertiary = Color.White,
    tertiaryContainer = Color(0xFFF5C566), onTertiaryContainer = Color(0xFF402D00),
    surface = Color.White, onSurface = Color(0xFF1A2333),
    surfaceVariant = Color(0xFFECEFF5), onSurfaceVariant = Color(0xFF5B6577),
    surfaceContainerLowest = Color.White, surfaceContainerLow = Color(0xFFF6F7FA),
    surfaceContainer = Color(0xFFECEFF5), surfaceContainerHigh = Color(0xFFE2E6EE), surfaceContainerHighest = Color(0xFFD8DDE8),
    background = Color(0xFFF6F7FA), onBackground = Color(0xFF1A2333),
    outline = Color(0xFF767F92), outlineVariant = Color(0xFFC6CCD9),
    error = Color(0xFFD93636), onError = Color.White,
    errorContainer = Color(0xFFFFDAD5), onErrorContainer = Color(0xFF5C1313),
    inverseSurface = Color(0xFF2A3859), inverseOnSurface = Color(0xFFF0F2F7), inversePrimary = Color(0xFFFF8A4C),
)

/**
 * Brand roles that stay fixed even under "Match wallpaper" dynamic colour, where the scheme's roles
 * follow the wallpaper: the record/stop dot and errors (`record`), AI/polish gold (`moon`), the
 * Ripple rings (`koiDecor`) and success/decisions (`lily`). The spec pairs `moon` text with the
 * `moonFill` golden fill; the scheme's tonal tertiary pair keeps its own AA-safe on-colours.
 */
internal data class ChirpRoles(
    val record: Color, val moon: Color, val moonFill: Color, val koiDecor: Color, val lily: Color,
) {
    companion object {
        val Light = ChirpRoles(
            record = Color(0xFFD93636), moon = Color(0xFF8A5A00), moonFill = Color(0xFFF5C566),
            koiDecor = Color(0xFFF26A1B), lily = Color(0xFF2F7A4F))
        val Dark = ChirpRoles(
            record = Color(0xFFFF6B6B), moon = Color(0xFFF5C566), moonFill = Color(0xFFF5C566),
            koiDecor = Color(0xFFFF8A4C), lily = Color(0xFF7CCB9B))
    }
}

/** The fixed brand roles for the current dark/light mode; read this, never the scheme, under dynamic colour. */
internal val LocalChirpRoles = staticCompositionLocalOf { ChirpRoles.Light }

/** The fixed brand roles outside Compose (the floating mic panel and the keyboard strip fallback). */
internal fun chirpRoles(night: Boolean): ChirpRoles = if (night) ChirpRoles.Dark else ChirpRoles.Light

/** Shape and type tokens shared by every Chirp screen. */
internal object ChirpTokens {
    val shapes = Shapes(extraSmall = RoundedCornerShape(4.dp), small = RoundedCornerShape(8.dp),
        medium = RoundedCornerShape(12.dp), large = RoundedCornerShape(16.dp), extraLarge = RoundedCornerShape(28.dp))
    /** Outer corners of a [SettingsGroup]; rows inside keep [Shapes.extraSmall]. */
    val group = RoundedCornerShape(16.dp)
    val typography = Typography().run {
        copy(displaySmall = displaySmall.copy(fontWeight = FontWeight.Medium),
            titleMedium = titleMedium.copy(fontWeight = FontWeight.SemiBold))
    }
    /** A note title: the device serif (spec §C), for note titles and library section headers. */
    val noteTitle = TextStyle(fontSize = 28.sp, lineHeight = 34.sp, fontWeight = FontWeight.SemiBold, fontFamily = FontFamily.Serif)
    /** Timer readouts: tabular digits, so the numbers don't jitter as they tick. */
    val timer = TextStyle(fontSize = 15.sp, lineHeight = 20.sp, fontWeight = FontWeight.Medium, fontFeatureSettings = "tnum")
    val timerSmall = TextStyle(fontSize = 12.sp, lineHeight = 16.sp, fontWeight = FontWeight.Medium, fontFeatureSettings = "tnum")
}

/** Pond (the default) or wallpaper colours (minSdk 31, so always available) when "App colours" says so. */
internal fun chirpColorScheme(context: Context, dark: Boolean, colour: AppColour = SettingsStore(context).appColour): ColorScheme = when {
    colour == AppColour.DYNAMIC && dark -> dynamicDarkColorScheme(context)
    colour == AppColour.DYNAMIC -> dynamicLightColorScheme(context)
    dark -> PondDark
    else -> PondLight
}

@Composable
internal fun ChirpTheme(dark: Boolean = isSystemInDarkTheme(), colour: AppColour = rememberAppColour(), content: @Composable () -> Unit) {
    val context = LocalContext.current
    val colors = remember(context, dark, colour) { chirpColorScheme(context, dark, colour) }
    // MotionScheme.expressive() and MaterialExpressiveTheme are not public in material3 1.4.0 (BOM 2026.09.00); standard motion until they are.
    CompositionLocalProvider(LocalChirpRoles provides if (dark) ChirpRoles.Dark else ChirpRoles.Light) {
        MaterialTheme(colorScheme = colors, shapes = ChirpTokens.shapes, typography = ChirpTokens.typography, content = content)
    }
}

/** Follows the "App colours" choice live, so switching it restyles the open screen. */
@Composable
private fun rememberAppColour(): AppColour {
    val context = LocalContext.current
    val store = remember(context) { SettingsStore(context) }
    var colour by remember(store) { mutableStateOf(store.appColour) }
    DisposableEffect(store) {
        val prefs = context.getSharedPreferences(SettingsStore.FILE, Context.MODE_PRIVATE)
        val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, _ -> colour = store.appColour }
        prefs.registerOnSharedPreferenceChangeListener(listener)
        onDispose { prefs.unregisterOnSharedPreferenceChangeListener(listener) }
    }
    return colour
}

@Composable
internal fun AppColoursSettings() {
    val context = LocalContext.current
    val store = remember { SettingsStore(context) }
    var colour by remember { mutableStateOf(store.appColour) }
    val dynamic = stringResource(R.string.settings_colour_dynamic)
    val pond = stringResource(R.string.settings_colour_pond)
    SettingsGroup(stringResource(R.string.settings_app_colours)) {
        SettingsItem {
            ChoiceChips(listOf(AppColour.POND, AppColour.DYNAMIC), colour, { if (it == AppColour.DYNAMIC) dynamic else pond }) {
                colour = it; store.appColour = it
            }
        }
    }
}
