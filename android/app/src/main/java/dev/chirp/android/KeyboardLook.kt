package dev.chirp.android

import androidx.annotation.StringRes
import android.content.Context
import android.content.SharedPreferences
import android.content.res.Configuration
import android.graphics.Color
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.core.content.edit
import androidx.core.graphics.ColorUtils
import dev.chirp.android.ui.SettingsGroup
import dev.chirp.android.ui.SettingsItem
import helium314.keyboard.keyboard.ColorSetting
import helium314.keyboard.keyboard.KeyboardSwitcher
import helium314.keyboard.keyboard.KeyboardTheme
import helium314.keyboard.latin.R as KeyboardR
import helium314.keyboard.latin.common.ColorType
import helium314.keyboard.latin.common.DynamicColors
import helium314.keyboard.latin.settings.Defaults
import helium314.keyboard.latin.settings.Settings
import helium314.keyboard.latin.utils.DeviceProtectedUtils

internal const val SAMSUNG_LIGHT = "Samsung-like"
internal const val SAMSUNG_DARK = "Samsung-like dark"
private const val LOOK_SEEDED = "chirp_keyboard_look_v1"

/** Chirp's keyboard looks, expressed purely as HeliBoard theme preferences. */
internal enum class KeyboardLook(@StringRes val label: Int, @StringRes val description: Int, val style: String,
                                 val borders: Boolean, val day: String, val night: String) {
    GBOARD(R.string.look_gboard, R.string.look_gboard_description,
        KeyboardTheme.STYLE_ROUNDED, true, KeyboardTheme.THEME_DYNAMIC, KeyboardTheme.THEME_DYNAMIC),
    SAMSUNG(R.string.look_samsung, R.string.look_samsung_description,
        KeyboardTheme.STYLE_ROUNDED, true, SAMSUNG_LIGHT, SAMSUNG_DARK),
    HELIBOARD(R.string.look_heliboard, R.string.look_heliboard_description,
        KeyboardTheme.STYLE_MATERIAL, false, KeyboardTheme.THEME_LIGHT, KeyboardTheme.THEME_DARK),
    HELIBOARD_ROUNDED(R.string.look_heliboard_rounded, R.string.look_heliboard_rounded_description,
        KeyboardTheme.STYLE_ROUNDED, true, KeyboardTheme.THEME_LIGHT, KeyboardTheme.THEME_DARK),
    HELIBOARD_HOLO(R.string.look_heliboard_holo, R.string.look_heliboard_holo_description,
        KeyboardTheme.STYLE_HOLO, false, KeyboardTheme.THEME_HOLO_WHITE, KeyboardTheme.THEME_HOLO_WHITE);

    companion object {
        val DEFAULT = GBOARD
    }
}

private val THEME_KEYS = listOf(Settings.PREF_THEME_STYLE, Settings.PREF_THEME_KEY_BORDERS,
    Settings.PREF_THEME_COLORS, Settings.PREF_THEME_COLORS_NIGHT)

/** The preset matching HeliBoard's current theme preferences, or null for a custom Appearance choice. */
internal fun currentKeyboardLook(prefs: SharedPreferences): KeyboardLook? {
    val style = prefs.getString(Settings.PREF_THEME_STYLE, Defaults.PREF_THEME_STYLE)
    val borders = prefs.getBoolean(Settings.PREF_THEME_KEY_BORDERS, Defaults.PREF_THEME_KEY_BORDERS)
    val day = prefs.getString(Settings.PREF_THEME_COLORS, Defaults.PREF_THEME_COLORS)
    val night = prefs.getString(Settings.PREF_THEME_COLORS_NIGHT, Defaults.PREF_THEME_COLORS_NIGHT)
    return KeyboardLook.entries.firstOrNull { it.style == style && it.borders == borders && it.day == day && it.night == night }
}

internal fun applyKeyboardLook(prefs: SharedPreferences, look: KeyboardLook) {
    if (look == KeyboardLook.SAMSUNG) {
        // User-defined HeliBoard colour themes, so Appearance can still show and fine-tune them.
        writeColors(prefs, SAMSUNG_LIGHT, SamsungColors.LIGHT)
        writeColors(prefs, SAMSUNG_DARK, SamsungColors.DARK)
    }
    prefs.edit(commit = true) {
        putString(Settings.PREF_THEME_STYLE, look.style)
        putBoolean(Settings.PREF_THEME_KEY_BORDERS, look.borders)
        putString(Settings.PREF_THEME_COLORS, look.day)
        putString(Settings.PREF_THEME_COLORS_NIGHT, look.night)
        putBoolean(Settings.PREF_THEME_DAY_NIGHT, true)
    }
    KeyboardSwitcher.getInstance().setThemeNeedsReload()
}

/**
 * One-time migration: installs that never picked a theme get the Gboard-like look.
 * Any theme preference already written means the user chose it in Appearance; leave it alone.
 */
internal fun seedKeyboardLook(prefs: SharedPreferences) {
    if (prefs.getBoolean(LOOK_SEEDED, false)) return
    if (THEME_KEYS.none(prefs::contains)) applyKeyboardLook(prefs, KeyboardLook.DEFAULT)
    prefs.edit(commit = true) { putBoolean(LOOK_SEEDED, true) }
}

private fun writeColors(prefs: SharedPreferences, name: String, colors: SamsungColors) {
    KeyboardTheme.writeUserColors(prefs, name, colors.settings())
    KeyboardTheme.writeUserMoreColors(prefs, name, 0)
}

internal enum class SamsungColors(val background: Int, val keys: Int, val functional: Int, val text: Int, val hint: Int, val accent: Int) {
    LIGHT(0xFFF1F1F4.toInt(), 0xFFFFFFFF.toInt(), 0xFFDDDEE3.toInt(), 0xFF1B1B1F.toInt(), 0xFF8A8A90.toInt(), 0xFF2F7CF6.toInt()),
    DARK(0xFF111113.toInt(), 0xFF2B2B2F.toInt(), 0xFF3B3B40.toInt(), 0xFFF0F0F3.toInt(), 0xFF96969C.toInt(), 0xFF3E91FF.toInt());
    fun settings() = listOf(
        KeyboardTheme.COLOR_BACKGROUND to background, KeyboardTheme.COLOR_KEYS to keys,
        KeyboardTheme.COLOR_FUNCTIONAL_KEYS to functional, KeyboardTheme.COLOR_SPACEBAR to keys,
        KeyboardTheme.COLOR_TEXT to text, KeyboardTheme.COLOR_SUGGESTION_TEXT to text,
        KeyboardTheme.COLOR_HINT_TEXT to hint, KeyboardTheme.COLOR_SPACEBAR_TEXT to hint,
        KeyboardTheme.COLOR_ACCENT to accent, KeyboardTheme.COLOR_GESTURE to accent,
    ).map { (name, color) -> ColorSetting(name, false, color) }
}

/** Colours for the Chirp row, taken from the keyboard's own HeliBoard theme so the row blends in. */
internal data class StripColors(val ink: Int, val muted: Int, val accent: Int, val onAccent: Int, val highlight: Int, val chip: Int,
                                val background: Int, val tints: StripTints) {
    companion object {
        fun of(context: Context): StripColors {
            val colors = runCatching { Settings.getValues()?.mColors }.getOrNull()
            if (colors == null) {
                val fallback = VoicePalette.of(context)
                return derive(fallback.background, fallback.ink, fallback.muted, fallback.accent)
            }
            return derive(colors.get(ColorType.STRIP_BACKGROUND), colors.get(ColorType.KEY_TEXT),
                colors.get(ColorType.KEY_HINT_TEXT), colors.get(ColorType.ACTION_KEY_BACKGROUND))
        }
        fun derive(background: Int, ink: Int, muted: Int, accent: Int): StripColors {
            val base = opaque(background)
            val solidAccent = opaque(accent)
            val onAccent = listOf(Color.WHITE, 0xFF1B1B1F.toInt()).maxBy { ColorUtils.calculateContrast(it, solidAccent) }
            return StripColors(opaque(ink), opaque(muted), solidAccent, onAccent, readable(solidAccent, base),
                ColorUtils.setAlphaComponent(solidAccent, 0x40), base, StripTints.derive(base, ink, solidAccent))
        }
        private fun opaque(color: Int) = color or 0xFF000000.toInt()
        /** Waveform and shimmer need 3:1 against the row even when the theme accent is pale. */
        private fun readable(color: Int, background: Int): Int {
            val target = if (ColorUtils.calculateLuminance(background) > .5) Color.BLACK else Color.WHITE
            var result = color
            var step = 0
            while (ColorUtils.calculateContrast(result, background) < 3.0 && step < 10) {
                step++; result = ColorUtils.blendARGB(color, target, step / 10f)
            }
            return result
        }
    }
}

internal fun keyboardPrefs(context: Context): SharedPreferences = DeviceProtectedUtils.getSharedPreferences(context)

private data class Swatch(val background: Int, val key: Int?, val functional: Int?, val accent: Int, val text: Int)

private fun swatch(context: Context, look: KeyboardLook, night: Boolean): Swatch {
    val config = Configuration(context.resources.configuration).apply {
        uiMode = (uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or
            (if (night) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO)
    }
    val themed = context.createConfigurationContext(config)
    fun res(id: Int) = ContextCompat.getColor(themed, id)
    return when (look) {
        KeyboardLook.GBOARD -> DynamicColors(themed, look.style, true).let {
            Swatch(it.get(ColorType.MAIN_BACKGROUND), it.get(ColorType.KEY_BACKGROUND), it.get(ColorType.FUNCTIONAL_KEY_BACKGROUND),
                it.get(ColorType.ACTION_KEY_BACKGROUND), it.get(ColorType.KEY_TEXT))
        }
        KeyboardLook.SAMSUNG -> (if (night) SamsungColors.DARK else SamsungColors.LIGHT).let {
            Swatch(it.background, it.keys, it.functional, it.accent, it.text)
        }
        KeyboardLook.HELIBOARD_HOLO -> Swatch(0xFF282828.toInt(), null, null, Color.WHITE, Color.WHITE)
        else -> {
            val bordered = look.borders
            if (night) Swatch(0xFF263238.toInt(), if (bordered) 0xFF364248.toInt() else null, if (bordered) 0xFF2D393F.toInt() else null,
                res(KeyboardR.color.gesture_trail_color_lxx_dark), Color.WHITE)
            else Swatch(res(KeyboardR.color.keyboard_background_lxx_light_border),
                if (bordered) res(KeyboardR.color.key_background_normal_lxx_light_border) else null,
                if (bordered) res(KeyboardR.color.key_background_functional_lxx_light_border) else null,
                res(KeyboardR.color.gesture_trail_color_lxx_light), Color.BLACK)
        }
    }
}

@Composable
private fun LookPreview(look: KeyboardLook, night: Boolean) {
    val context = LocalContext.current
    val colors = remember(look, night) { runCatching { swatch(context, look, night) }.getOrNull() } ?: return
    Canvas(Modifier.size(width = 72.dp, height = 44.dp)) {
        drawRoundRect(androidx.compose.ui.graphics.Color(colors.background), cornerRadius = CornerRadius(6.dp.toPx()))
        val gap = 2.5.dp.toPx(); val rows = 3; val cols = 6
        val keyW = (size.width - gap * (cols + 1)) / cols
        val keyH = (size.height - gap * (rows + 1)) / rows
        val radius = CornerRadius(if (look.style == KeyboardTheme.STYLE_ROUNDED) 2.5.dp.toPx() else 1.dp.toPx())
        for (row in 0 until rows) for (col in 0 until cols) {
            val last = row == rows - 1
            val fill = when {
                last && col == cols - 1 -> colors.accent
                last && col == 0 -> colors.functional ?: colors.background
                else -> colors.key ?: colors.background
            }
            val topLeft = Offset(gap + col * (keyW + gap), gap + row * (keyH + gap))
            drawRoundRect(androidx.compose.ui.graphics.Color(fill), topLeft, Size(keyW, keyH), radius)
            if (fill != colors.accent) drawCircle(androidx.compose.ui.graphics.Color(colors.text).copy(alpha = .7f),
                radius = 1.2.dp.toPx(), center = Offset(topLeft.x + keyW / 2, topLeft.y + keyH / 2))
        }
    }
}

/** Chirp's theme chooser. Presets only write HeliBoard's own theme preferences. */
@Composable
internal fun KeyboardLookChooser() {
    val context = LocalContext.current
    val prefs = remember { keyboardPrefs(context) }
    var selected by remember { mutableStateOf(currentKeyboardLook(prefs)) }
    val night = androidx.compose.foundation.isSystemInDarkTheme()
    SettingsGroup(stringResource(R.string.look_title), Modifier.selectableGroup()) {
        for (look in KeyboardLook.entries) {
            Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).clip(MaterialTheme.shapes.extraSmall)
                .background(MaterialTheme.colorScheme.surfaceContainer).selectable(selected == look, role = Role.RadioButton) {
                    applyKeyboardLook(prefs, look); selected = look
                }.padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                RadioButton(selected == look, onClick = null)
                LookPreview(look, night)
                Column(Modifier.weight(1f)) {
                    Text(if (look == KeyboardLook.DEFAULT) stringResource(R.string.look_default, stringResource(look.label)) else stringResource(look.label), style = MaterialTheme.typography.bodyLarge)
                    Text(stringResource(look.description), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
        SettingsItem {
            if (selected == null) Text(stringResource(R.string.look_custom),
                style = MaterialTheme.typography.bodySmall)
            Text(stringResource(R.string.look_fine_tune),
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
