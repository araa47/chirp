package dev.chirp.android

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ProtocolTest {
    @Test fun `start uses frozen android pcm contract with correction opt in`() {
        val start = JSONObject(Protocol.start(false))
        assertEquals("start", start.getString("type"))
        assertEquals("android", start.getString("client"))
        assertEquals(16000, start.getInt("sample_rate"))
        assertEquals("pcm_s16le", start.getString("encoding"))
        assertFalse(start.getBoolean("correction"))
        assertTrue(JSONObject(Protocol.start(true)).getBoolean("correction"))
        assertFalse(start.has("token"))
    }
    @Test fun `decode all events and tolerate additive fields`() {
        assertEquals(ServerEvent.Ready(true, "fake"), Protocol.decode("""{"type":"ready","debug_retention":true,"engine":"fake"}"""))
        assertEquals(ServerEvent.Partial(9, "synthetic text", "synthetic"), Protocol.decode("""{"type":"partial","seq":9,"text":"synthetic text","stable":"synthetic"}"""))
        assertEquals(ServerEvent.Final("Synthetic.", "synthetic", true), Protocol.decode("""{"type":"final","text":"Synthetic.","raw":"synthetic","corrected":true,"timings_ms":{}}"""))
        assertEquals(ServerEvent.Failure("auth"), Protocol.decode("""{"type":"error","code":"auth","message":"never shown"}"""))
        assertEquals(ServerEvent.Unknown, Protocol.decode("""{"type":"future"}"""))
    }
    @Test fun `health keeps the pairing name for This device, bounded and without control characters`() {
        fun device(value: String) = Protocol.health("""{"ok":true,"ready":true,"debug_retention":false,"device":$value}""").device
        assertEquals("Pixel Fold", device("\"Pixel Fold\""))
        assertNull(device("null")); assertNull(device("\"\""))
        assertNull(device("\"bad\\u0007name\""))
        assertEquals(64, device("\"${"x".repeat(100)}\"")!!.length)
        assertNull(Protocol.health("""{"ok":true,"ready":true,"debug_retention":false}""").device)
    }
    @Test fun `authenticated health is required and privacy metadata preserved`() {
        val health = Protocol.health("""{"ok":true,"ready":true,"debug_retention":true,"correction":"available","correction_leaves_machine":true,"correction_host":"example.test"}""")
        assertTrue(health.ready); assertTrue(health.debugRetention); assertTrue(health.correctionLeavesMachine)
        assertEquals("example.test", health.correctionHost)
        assertThrows(Exception::class.java) { Protocol.health("""{"ok":true}""") }
        assertThrows(Exception::class.java) { Protocol.decode("not json") }
        assertThrows(Exception::class.java) { Protocol.decode("""{"type":"final","text":"incomplete"}""") }
        assertThrows(Exception::class.java) { Protocol.decode("x".repeat(1_000_001)) }
    }
    @Test fun `operation deadlines use CPU and override budgets with bounded transport margin`() {
        val health = Protocol.health("""{"ok":true,"ready":true,"debug_retention":false,"operation_deadlines":{"dictation":30,"notes_correction":45,"notes_structure":90,"notes_reorganize":120,"notes_edit":180.25}}""")
        val d = health.operationDeadlines
        assertEquals(35000L, d.timeoutMs("dictation", 12000))
        assertEquals(50000L, d.timeoutMs("notes_correction", 25000))
        assertEquals(95000L, d.timeoutMs("notes_structure", 35000))
        assertEquals(125000L, d.timeoutMs("notes_reorganize", 50000))
        assertEquals(185250L, d.timeoutMs("notes_edit", 50000))
    }
    @Test fun `old partial and malformed deadlines fall back independently`() {
        for (field in listOf("null", "[]", "{}", """{"dictation":0,"notes_structure":-1,"notes_reorganize":"120","notes_edit":true}""")) {
            val d = Protocol.health("""{"ok":true,"ready":true,"debug_retention":false,"operation_deadlines":$field}""").operationDeadlines
            assertEquals(12000L, d.timeoutMs("dictation", 12000))
            assertEquals(35000L, d.timeoutMs("notes_structure", 35000))
            assertEquals(50000L, d.timeoutMs("notes_reorganize", 50000))
            assertEquals(50000L, d.timeoutMs("notes_edit", 50000))
        }
        val tooLong = OperationDeadlines(mapOf("notes_structure" to 3_000_000.0))
        assertEquals(35000L, tooLong.timeoutMs("notes_structure", 35000))
        val old = Protocol.health("""{"ok":true,"ready":true,"debug_retention":false}""")
        assertEquals(12000L, old.operationDeadlines.timeoutMs("dictation", 12000))
        val partial = OperationDeadlines.decode(JSONObject("""{"dictation":"bad","notes_structure":135,"notes_edit":1e100}"""))
        assertEquals(12000L, partial.timeoutMs("dictation", 12000))
        assertEquals(140000L, partial.timeoutMs("notes_structure", 35000))
        assertEquals(50000L, partial.timeoutMs("notes_edit", 50000))
    }
}
