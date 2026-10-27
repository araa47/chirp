package dev.chirp.android

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

@RunWith(RobolectricTestRunner::class)
class CleanupStylesTest {
    private val profiles = listOf("default", "chat", "email", "code", "notes", "custom").map { CorrectionProfile(it, it) }
    @Test fun `local cleanup default preserves explicit choices after reopening`() {
        val context = RuntimeEnvironment.getApplication()
        val store = SettingsStore(context)
        store.health = Health(true, false, true, false, null)
        assertTrue(store.correction)
        listOf(false, true).forEach { choice ->
            store.correction = choice
            assertEquals(choice, SettingsStore(context).correction)
        }
    }
    @Test fun `exact package defaults overrides removals and missing profiles`() {
        val cases = mapOf("com.slack" to "chat", "com.whatsapp" to "chat", "com.discord" to "chat",
            "com.google.android.apps.messaging" to "chat", "com.samsung.android.messaging" to "chat",
            "com.google.android.gm" to "email", "com.microsoft.office.outlook" to "email",
            "com.samsung.android.email.provider" to "email", "com.termux" to "code", "com.foxdebug.acode" to "code",
            "com.samsung.android.app.notes" to "notes", "com.google.android.keep" to "notes", "md.obsidian" to "notes", "notion.id" to "notes")
        cases.forEach { (app, expected) -> assertEquals(expected, CleanupStyles.resolve(app, "default", CleanupStyles.defaults, profiles).id) }
        assertEquals("email", CleanupStyles.resolve("com.slack", "default", mapOf("com.slack" to "email"), profiles).id)
        assertEquals("notes", CleanupStyles.resolve("com.slack", "notes", emptyMap(), profiles).id)
        assertEquals("default", CleanupStyles.resolve("com.slack.fake", "default", CleanupStyles.defaults, profiles).id)
        assertEquals("default", CleanupStyles.resolve("com.slack", "missing", CleanupStyles.defaults, profiles.take(1)).id)
    }
    @Test fun `settings persist profile metadata app edits and unicode instruction limit`() {
        val store = SettingsStore(RuntimeEnvironment.getApplication())
        store.defaultStyle = "notes"
        store.appStyles = mapOf("com.slack" to "email")
        store.customInstructions = "🙂".repeat(2001)
        val health = Health(true, false, true, false, null, correctionProfiles = profiles)
        store.health = health
        val restored = SettingsStore(RuntimeEnvironment.getApplication())
        assertEquals(health, restored.health)
        assertEquals("email", restored.style("com.slack").id)
        assertEquals("notes", restored.style("com.other").id)
        assertEquals(2000, CleanupStyles.characterCount(restored.customInstructions))
        assertFalse(Character.isHighSurrogate(restored.customInstructions.last()))
        assertThrows(IllegalArgumentException::class.java) { store.appStyles = mapOf("invalid package" to "chat") }
    }
    @Test fun `wire profiles correcting failures and legacy health decode`() {
        val health = Protocol.health("""{"ok":true,"ready":true,"debug_retention":false,"correction":"available","correction_profiles":[{"id":"notes","name":"Notes","description":"Lists","rewrites":true},{"id":"bad id"}]}""")
        assertEquals(listOf(CorrectionProfile("notes", "Notes", "Lists", true)), health.correctionProfiles)
        assertEquals(ServerEvent.Correcting(4, "synthetic", "notes"), Protocol.decode("""{"type":"correcting","seq":4,"raw":"synthetic","profile":"notes"}"""))
        assertEquals("timeout", (Protocol.decode("""{"type":"final","text":"synthetic","raw":"synthetic","corrected":false,"correction_error":"timeout"}""") as ServerEvent.Final).correctionError)
        val frame = JSONObject(Protocol.start(true, "custom", "🙂".repeat(2000)))
        assertEquals("custom", frame.getString("correction_profile"))
        assertEquals(2000, CleanupStyles.characterCount(frame.getString("correction_instructions")))
        assertEquals("", JSONObject(Protocol.start(true, "chat", "private preference")).getString("correction_instructions"))
        assertThrows(IllegalArgumentException::class.java) { Protocol.start(true, "custom", "x".repeat(2001)) }
        assertThrows(IllegalArgumentException::class.java) { Protocol.start(true, "bad id") }
    }
    @Test fun `editable prompts decode limits migrate reset and are omitted unless edited`() {
        val profiles = Protocol.profiles("""{"profiles":[{"id":"chat","name":"Chat","description":"Casual","rewrites":false,"prompt":"Keep it casual","max_prompt_chars":4000}]}""")
        assertEquals("Keep it casual", profiles.single().prompt)
        assertFalse(JSONObject(Protocol.start(true, "chat")).has("correction_prompt"))
        assertEquals("", JSONObject(Protocol.start(true, "custom", prompt = "")).getString("correction_prompt"))
        assertEquals(4000, CleanupStyles.characterCount(JSONObject(Protocol.start(true, "chat", prompt = "🙂".repeat(4000))).getString("correction_prompt")))
        assertThrows(IllegalArgumentException::class.java) { Protocol.start(true, "chat", prompt = "x".repeat(4001)) }
        val store = SettingsStore(RuntimeEnvironment.getApplication())
        store.customInstructions = "fixture preference"
        assertEquals(mapOf("custom" to "fixture preference"), store.promptEdits)
        assertEquals("", store.customInstructions)
        store.promptEdits = store.promptEdits + ("chat" to "lowercase")
        assertEquals("lowercase", SettingsStore(RuntimeEnvironment.getApplication()).promptEdits["chat"])
        store.promptEdits = store.promptEdits - "chat"
        assertNull(store.promptEdits["chat"])
        assertThrows(IllegalArgumentException::class.java) { store.promptEdits = mapOf("chat" to "x".repeat(4001)) }
    }

}
