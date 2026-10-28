package dev.chirp.android

import android.content.Context
import helium314.keyboard.latin.settings.Settings
import helium314.keyboard.latin.utils.LayoutType
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

@RunWith(RobolectricTestRunner::class)
class KeyboardLayoutDefaultsTest {
    private val key = Settings.PREF_LAYOUT_PREFIX + LayoutType.FUNCTIONAL.name
    // HeliBoard's Settings is a process-wide singleton; don't depend on an earlier test having set it up.
    @Before fun setUp() { Settings.init(RuntimeEnvironment.getApplication()) }

    @Test fun `existing installs and fresh installs get phone function keys once`() {
        val prefs = RuntimeEnvironment.getApplication().getSharedPreferences("layout-defaults", Context.MODE_PRIVATE)
        seedKeyboardLayoutDefaults(prefs)
        assertEquals("functional_keys", Settings.readDefaultLayoutName(LayoutType.FUNCTIONAL, prefs))
        // Resetting to HeliBoard's automatic default later is an explicit user choice.
        prefs.edit().remove(key).apply()
        seedKeyboardLayoutDefaults(prefs)
        assertFalse(prefs.contains(key))
    }

    @Test fun `explicit global layouts and subtype choices survive migration`() {
        for (layout in listOf("functional_keys_tablet", "functional_keys_khipro", "custom_user_layout")) {
            val prefs = RuntimeEnvironment.getApplication().getSharedPreferences(layout, Context.MODE_PRIVATE)
            val subtype = "en-US§KeyboardLayoutSet=MAIN:qwerty|FUNCTIONAL:$layout"
            prefs.edit().putString(key, layout).putString(Settings.PREF_SELECTED_SUBTYPE, subtype)
                .putString(Settings.PREF_ENABLED_SUBTYPES, subtype).apply()
            seedKeyboardLayoutDefaults(prefs)
            assertEquals(layout, Settings.readDefaultLayoutName(LayoutType.FUNCTIONAL, prefs))
            assertEquals(subtype, prefs.getString(Settings.PREF_SELECTED_SUBTYPE, null))
            assertEquals(subtype, prefs.getString(Settings.PREF_ENABLED_SUBTYPES, null))
        }
    }
}
