package dev.chirp.android

import android.view.KeyEvent
import org.junit.Assert.*
import org.junit.Test
import androidx.compose.ui.test.assertIsFocused
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37])
class AppShortcutsTest {
    @Test fun `only mounted actions dispatch and extra modifiers are rejected`() {
        val shortcuts = AppShortcuts()
        val owner = Any()
        var count = 0
        fun key(code: Int, modifiers: Int, action: Int = KeyEvent.ACTION_DOWN, repeat: Int = 0) =
            KeyEvent(0, 0, action, code, repeat, modifiers)
        assertFalse(shortcuts.dispatch(key(KeyEvent.KEYCODE_R, KeyEvent.META_CTRL_ON or KeyEvent.META_SHIFT_ON)))
        shortcuts.bind(owner) { mapOf(AppCommand.NewNote to { count++; true }) }
        assertFalse(shortcuts.dispatch(key(KeyEvent.KEYCODE_N, KeyEvent.META_CTRL_ON or KeyEvent.META_ALT_ON)))
        assertTrue(shortcuts.dispatch(key(KeyEvent.KEYCODE_N, KeyEvent.META_CTRL_ON)))
        assertTrue(shortcuts.dispatch(key(KeyEvent.KEYCODE_N, KeyEvent.META_CTRL_ON, repeat = 1)))
        assertEquals(1, count)
        assertTrue(shortcuts.dispatch(key(KeyEvent.KEYCODE_N, 0, KeyEvent.ACTION_UP)))
        val groups = mutableListOf<android.view.KeyboardShortcutGroup>()
        shortcuts.provide(groups, english)
        assertEquals("Chirp", groups.single().label)
        assertEquals("New note", groups.single().items.single().label)
        shortcuts.unbind(owner)
        assertFalse(shortcuts.dispatch(key(KeyEvent.KEYCODE_N, KeyEvent.META_CTRL_ON)))
    }
    @Test fun `child handles Escape before its parent and may decline`() {
        val shortcuts = AppShortcuts()
        var dismissed = ""
        shortcuts.bind("library") { mapOf(AppCommand.Escape to { dismissed = "library"; true }) }
        shortcuts.bind("sheet") { mapOf(AppCommand.Escape to { dismissed = "sheet"; true }) }
        shortcuts.dispatch(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ESCAPE))
        assertEquals("sheet", dismissed)
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37])
@org.robolectric.annotation.GraphicsMode(org.robolectric.annotation.GraphicsMode.Mode.NATIVE)
class AppShortcutsScreenTest {
    @get:org.junit.Rule val compose = androidx.compose.ui.test.junit4.createAndroidComposeRule<SetupActivity>()

    @Test fun `shell publishes Chirp commands and keys route to the mounted screen`() {
        compose.runOnIdle { compose.activity.state.shellOpen = true }
        compose.waitForIdle()
        val groups = mutableListOf<android.view.KeyboardShortcutGroup>()
        compose.runOnIdle { compose.activity.onProvideKeyboardShortcuts(groups, null, -1) }
        assertTrue(groups.any { it.label == "Chirp" && it.items.any { row -> row.label == "New note" } })
        fun press(code: Int, mods: Int = KeyEvent.META_CTRL_ON) {
            compose.runOnIdle {
                assertTrue(compose.activity.dispatchKeyEvent(KeyEvent(0, 0, KeyEvent.ACTION_DOWN, code, 0, mods)))
                compose.activity.dispatchKeyEvent(KeyEvent(0, 0, KeyEvent.ACTION_UP, code, 0, mods))
            }
            compose.waitForIdle()
        }
        press(KeyEvent.KEYCODE_3)
        assertEquals(dev.chirp.android.shell.ShellTab.Settings, compose.activity.state.tab)
        compose.runOnIdle {
            assertFalse(compose.activity.appShortcuts.dispatch(KeyEvent(0, 0, KeyEvent.ACTION_DOWN,
                KeyEvent.KEYCODE_R, 0, KeyEvent.META_CTRL_ON or KeyEvent.META_SHIFT_ON)))
        }
        press(KeyEvent.KEYCODE_1)
        assertEquals(dev.chirp.android.shell.ShellTab.Notes, compose.activity.state.tab)
        press(KeyEvent.KEYCODE_F)
        compose.onNode(androidx.compose.ui.test.hasSetTextAction()).assertIsFocused()
        press(KeyEvent.KEYCODE_2)
        assertEquals(dev.chirp.android.shell.ShellTab.History, compose.activity.state.tab)
    }
}
