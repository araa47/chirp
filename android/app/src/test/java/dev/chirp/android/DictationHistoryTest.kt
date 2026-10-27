package dev.chirp.android

import android.os.UserManager
import android.text.InputType
import android.view.inputmethod.EditorInfo
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.File
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

/** Robolectric has no AndroidKeyStore; a software AES key exercises the same GCM sealing path. */
internal class SoftwareHistoryKeys : HistoryKeys {
    var key: SecretKey? = null
    var deletes = 0
    override fun get(create: Boolean): SecretKey? = key ?: if (create) KeyGenerator.getInstance("AES").apply { init(256) }.generateKey().also { key = it } else null
    override fun delete() { key = null; deletes++ }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class DictationHistoryTest {
    private val context = RuntimeEnvironment.getApplication()
    private val keys = SoftwareHistoryKeys()
    private var now = 1_800_000_000_000L
    private val history = DictationHistory(context, keys) { now }
    private val file get() = File(context.filesDir, DictationHistory.FILE_NAME)
    private val text = EditorInfo().apply { inputType = InputType.TYPE_CLASS_TEXT }
    private fun editor(type: Int, options: Int = 0) = EditorInfo().apply { inputType = type; imeOptions = options }

    @Before fun reset() { PrivateSession.set(false); history.disable(deleteHistory = true) }

    @Test fun `explicit history opt out stores nothing`() {
        assertFalse(history.enabled)
        assertNull(history.record("Meet at noon", null, "Slack", text))
        assertFalse(file.exists()); assertNull(keys.key)
        assertTrue(history.entries().isEmpty())
    }

    @Test fun `new installs and upgrades without a choice default on while explicit choices survive`() {
        val prefs = context.getSharedPreferences("chirp_history", 0)
        prefs.edit().remove("enabled").commit()
        assertTrue(DictationHistory(context, keys).enabled)
        history.disable()
        assertFalse(DictationHistory(context, keys).enabled)
        history.enable()
        assertTrue(DictationHistory(context, keys).enabled)
    }

    @Test fun `retention defaults only when unset and all explicit values survive reopening`() {
        val prefs = context.getSharedPreferences("chirp_history", 0)
        prefs.edit().remove("retention_days").commit()
        assertEquals(HistoryRetention.WEEK, DictationHistory(context, keys).retention)
        HistoryRetention.entries.forEach { choice ->
            prefs.edit().putInt("retention_days", choice.days).commit()
            assertEquals(choice, DictationHistory(context, keys).retention)
        }
    }

    @Test fun `turning off keeps history readable and blocks new entries until expiry or delete`() {
        history.enable(); history.retention = HistoryRetention.DAY
        val entry = history.record("fixture", null, null, text)!!
        val key = keys.key
        history.disable()
        val reopened = DictationHistory(context, keys) { now }
        assertFalse(reopened.enabled)
        assertEquals(entry.id, reopened.entries().single().id)
        assertSame(key, keys.key)
        assertNull(reopened.record("late completion", null, null, text))
        now += 86_400_001L
        reopened.pruneIfDue()
        assertTrue(reopened.entries().isEmpty()); assertFalse(file.exists())
        reopened.clear()
        assertNull(keys.key); assertFalse(reopened.enabled)
    }

    @Test fun `existing entries can be deleted or expired with a shorter retention while off`() {
        history.enable(); history.retention = HistoryRetention.MONTH
        val old = history.record("old fixture", null, null, text)!!
        now += 2 * 86_400_000L
        val newer = history.record("new fixture", null, null, text)!!
        history.disable()
        history.delete(newer.id)
        assertEquals(old.id, history.entries().single().id)
        history.retention = HistoryRetention.DAY
        assertTrue(history.entries().isEmpty())
    }

    @Test fun `private session skips every final and preserves existing history`() {
        assertFalse(SettingsStore(context).privateSession)
        history.enable()
        history.record("Earlier", null, "Scratchpad", text)
        val before = file.readBytes()
        SettingsStore(context).privateSession = true
        assertNull(history.record("Synthetic private text", "raw words", "Keyboard", text))
        assertNull(DictationHistory(context, keys).record("Other entry point", null, "Quick dictate", text, partial = true))
        assertArrayEquals(before, file.readBytes())
        SettingsStore(context).privateSession = false
        assertNotNull(history.record("After", null, "Floating mic", text))
        assertEquals(listOf("After", "Earlier"), history.entries().map { it.text })
    }

    @Test fun `private session expires on screen off or one hour`() {
        SettingsStore(context).privateSession = true
        context.sendBroadcast(android.content.Intent(android.content.Intent.ACTION_SCREEN_OFF))
        shadowOf(android.os.Looper.getMainLooper()).idle()
        assertFalse(SettingsStore(context).privateSession)
        SettingsStore(context).privateSession = true
        shadowOf(android.os.Looper.getMainLooper()).idleFor(java.time.Duration.ofMinutes(59))
        assertTrue(SettingsStore(context).privateSession)
        shadowOf(android.os.Looper.getMainLooper()).idleFor(java.time.Duration.ofMinutes(1))
        assertFalse(SettingsStore(context).privateSession)
    }

    @Test fun `entries round trip through AES-GCM and the file never holds plaintext`() {
        history.enable()
        val entry = history.record("Meet at noon by the pier", "meet at noon um by the pier", "Slack", text)!!
        val bytes = file.readBytes()
        assertEquals("CH", String(bytes.copyOfRange(0, 2), Charsets.US_ASCII))
        val stored = String(bytes, Charsets.ISO_8859_1)
        listOf("Meet at noon", "pier", "Slack", entry.id).forEach { assertFalse("$it leaked", stored.contains(it)) }
        assertFalse(entry.toString().contains("noon"))
        val reread = DictationHistory(context, keys) { now }.entries().single()
        assertEquals("Meet at noon by the pier", reread.text); assertEquals("meet at noon um by the pier", reread.raw)
        assertEquals("Slack", reread.app); assertEquals(now, reread.time)
        // Each write uses a fresh IV, so rewriting identical content never repeats the ciphertext.
        val first = file.readBytes()
        history.retention = HistoryRetention.WEEK
        assertFalse(first.contentEquals(file.readBytes()))
        assertEquals(entry.id, history.entries().single().id)
    }

    @Test fun `text kept after a failure stays marked partial across reads and Use raw`() {
        history.enable()
        val kept = history.record("heard so far", null, null, text, partial = true)!!
        history.record("Finished.", "finished", null, text)
        assertEquals(listOf(false, true), history.entries().map { it.partial })
        history.usedRaw(kept.id)
        assertTrue(history.entries().first { it.id == kept.id }.partial)
    }
    @Test fun `a lost or different key discards unreadable history instead of crashing`() {
        history.enable(); history.record("Private words", null, null, text)
        keys.key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        assertTrue(history.entries().isEmpty()); assertFalse(file.exists())
        history.record("After", null, null, text)
        keys.key = null
        assertTrue(history.entries().isEmpty()); assertFalse(file.exists())
    }

    @Test fun `password incognito and missing editors are never recorded`() {
        history.enable()
        listOf(
            editor(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD),
            editor(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD),
            editor(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD),
            editor(InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD),
            editor(InputType.TYPE_CLASS_TEXT, EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING),
            null,
        ).forEach { assertNull(history.record("secret", null, null, it)) }
        assertNull(history.record("   ", null, null, text))
        assertFalse(file.exists())
        assertNotNull(history.record("ok", null, null, editor(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_EMAIL_SUBJECT)))
    }

    @Test fun `retention prunes expired entries and caps the newest two hundred`() {
        history.enable()
        history.record("old", null, null, text)
        now += 2 * 86_400_000L; history.record("recent", null, null, text)
        now += 6 * 86_400_000L
        assertEquals(listOf("recent"), history.entries().map { it.text })
        history.retention = HistoryRetention.DAY
        assertTrue(history.entries().isEmpty()); assertFalse(file.exists())
        history.retention = HistoryRetention.MONTH
        repeat(205) { index -> now += 1000; history.record("entry $index", null, null, text) }
        val kept = history.entries()
        assertEquals(DictationHistory.MAX_ENTRIES, kept.size)
        assertEquals("entry 204", kept.first().text); assertEquals("entry 5", kept.last().text)
    }

    @Test fun `prune on keyboard show removes expired history without new dictation`() {
        history.enable(); history.retention = HistoryRetention.DAY
        history.record("yesterday", null, null, text)
        now += 3_600_000L; history.pruneIfDue(); assertTrue(file.exists())
        now += 86_400_000L; history.pruneIfDue(); assertFalse(file.exists())
    }

    @Test fun `explicit deletion removes entries and key and clear keeps the switch unchanged`() {
        history.enable(); history.record("one", null, null, text); history.record("two", null, null, text)
        history.clear()
        assertTrue(history.enabled); assertFalse(file.exists()); assertNull(keys.key)
        history.record("three", null, null, text)
        history.disable(deleteHistory = true)
        assertFalse(history.enabled); assertFalse(file.exists()); assertNull(keys.key)
        history.enable(); assertTrue(history.entries().isEmpty())
    }

    @Test fun `use raw and delete update only the matching entry`() {
        history.enable()
        val cleaned = history.record("Cleaned text.", "cleaned text um", "Notes", text)!!
        val other = history.record("Other", null, null, text)!!
        history.usedRaw(cleaned.id)
        val updated = history.entries().first { it.id == cleaned.id }
        assertEquals("cleaned text um", updated.text); assertNull(updated.raw)
        history.delete(other.id)
        assertEquals(listOf(cleaned.id), history.entries().map { it.id })
    }

    @Test fun `locked or device protected storage never reads or writes history`() {
        history.enable()
        shadowOf(context.getSystemService(UserManager::class.java)).setUserUnlocked(false)
        assertFalse(history.available)
        assertNull(history.record("before unlock", null, null, text)); assertFalse(file.exists())
        shadowOf(context.getSystemService(UserManager::class.java)).setUserUnlocked(true)
        assertFalse(DictationHistory(context.createDeviceProtectedStorageContext(), keys).available)
    }

    @Test fun `backup and device transfer exclude app files`() {
        val rules = context.resources.getXml(R.xml.data_extraction_rules)
        val excluded = mutableListOf<String>()
        while (rules.next() != org.xmlpull.v1.XmlPullParser.END_DOCUMENT) {
            if (rules.eventType == org.xmlpull.v1.XmlPullParser.START_TAG && rules.name == "exclude")
                excluded += rules.getAttributeValue(null, "domain") + ":" + rules.getAttributeValue(null, "path")
        }
        assertEquals(2, excluded.count { it == "file:." }); assertEquals(2, excluded.count { it == "root:." })
        val info = context.packageManager.getApplicationInfo(context.packageName, 0)
        assertEquals(0, info.flags and android.content.pm.ApplicationInfo.FLAG_ALLOW_BACKUP)
    }
}
