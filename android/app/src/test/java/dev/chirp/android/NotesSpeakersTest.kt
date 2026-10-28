package dev.chirp.android

import android.graphics.Bitmap
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.unit.dp
import java.io.File
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

private fun result(generation: String, vararg turns: ServerTurn) = SpeakersResult(generation, turns.toList())
private fun turn(slot: Int, start: Double, text: String) = ServerTurn(slot, start, text, text.lowercase().trimEnd('.', '?', '!'))

/** Speaker labels (#187): the protocol fields, the roster, the document, the recorder and the screens. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37])
class NotesSpeakersTest {
    // Protocol

    @Test fun `start carries the speaker session only when labels are on`() {
        assertFalse(JSONObject(Protocol.start(false)).has("speakers"))
        val session = NotesRecorder.newSpeakerSession()
        assertTrue(Protocol.SPEAKER_SESSION.matches(session))
        assertEquals(session, JSONObject(Protocol.start(true, "live_notes", speakers = session)).getJSONObject("speakers").getString("session"))
        assertThrows(IllegalArgumentException::class.java) { Protocol.start(false, speakers = "short") }
    }

    @Test fun `final decodes turns, errors, and ignores malformed labels`() {
        val final = Protocol.decode("""{"type":"final","text":"We ship. Okay.","raw":"we ship okay","corrected":true,"speakers":
            {"generation":"g1","turns":[{"speaker":0,"start":0.5,"end":1.2,"text":"We ship.","raw":"we ship","approximate":false,"kept_original":false},
            {"speaker":1,"start":2.0,"end":2.4,"text":"Okay.","raw":"okay","approximate":true,"kept_original":true}]}}""") as ServerEvent.Final
        assertEquals(SpeakersResult("g1", listOf(ServerTurn(0, 0.5, "We ship.", "we ship"), ServerTurn(1, 2.0, "Okay.", "okay", true, true))), final.speakers)
        val missing = Protocol.decode("""{"type":"final","text":"a","raw":"a","corrected":false,"speakers":{"error":"unavailable"}}""") as ServerEvent.Final
        assertEquals("unavailable", missing.speakers?.error)
        // A broken label payload never breaks the segment's text.
        val broken = Protocol.decode("""{"type":"final","text":"a","raw":"a","corrected":false,"speakers":{"generation":"g","turns":[{"speaker":99}]}}""") as ServerEvent.Final
        assertEquals("a", broken.text); assertNull(broken.speakers)
        assertNull((Protocol.decode("""{"type":"final","text":"a","raw":"a","corrected":false}""") as ServerEvent.Final).speakers)
    }

    @Test fun `health says whether the Mac labels speakers and where its model is`() {
        val health = Protocol.health("""{"ok":true,"ready":true,"debug_retention":false,"notes_speakers":true,"speakers_model":{"state":"not_downloaded","size_bytes":1}}""")
        assertTrue(health.notesSpeakers); assertEquals("not_downloaded", health.speakersModel); assertEquals(1L, health.speakersModelBytes)
        val old = Protocol.health("""{"ok":true,"ready":true,"debug_retention":false}""")
        assertFalse(old.notesSpeakers); assertNull(old.speakersModel)
        // The cached copy keeps both.
        val store = SettingsStore(RuntimeEnvironment.getApplication())
        store.health = health
        assertEquals("not_downloaded", store.health?.speakersModel); assertTrue(store.health!!.notesSpeakers); assertEquals(1L, store.health?.speakersModelBytes)
        assertTrue(store.notesLabelSpeakers)
    }

    // Roster

    @Test fun `people are numbered by first appearance and a new generation keeps them`() {
        val roster = SpeakerRoster()
        assertEquals(1, roster.id(3, "g1")); assertEquals(2, roster.id(0, "g1")); assertEquals(1, roster.id(3, "g1"))
        // The Mac restarted: its slots mean new voices now, the people stay.
        assertEquals(3, roster.id(3, "g2"))
        assertEquals(listOf(1, 2, 3), roster.active)
        assertEquals("Person 2", roster.displayName(2))
    }

    @Test fun `rename, merge and separate resolve everywhere`() {
        val roster = SpeakerRoster()
        repeat(3) { roster.addPerson() }
        roster.rename(2, "  Maya ")
        assertEquals("Maya", roster.displayName(2))
        roster.rename(2, " "); assertEquals("Person 2", roster.displayName(2))
        roster.rename(1, "Sam")
        roster.merge(3, 1)
        assertEquals("Sam", roster.displayName(3)); assertEquals(1, roster.resolve(3)); assertEquals(roster.colorIndex(1), roster.colorIndex(3))
        assertEquals(listOf(1, 2), roster.active); assertEquals(listOf(3), roster.merged(1))
        roster.merge(1, 3) // a cycle is refused
        assertEquals(1, roster.resolve(1))
        roster.separate(3)
        assertEquals("Person 3", roster.displayName(3))
        val copy = SpeakerRoster.fromJson(roster.apply { merge(2, 1) }.toJson())
        assertEquals(listOf("Sam", "Sam", "Person 3"), (1..3).map(copy::displayName))
    }

    // Document

    private fun labelledDocument() = NotesDocument(0L).apply {
        roster.id(0, "g"); roster.id(1, "g")
        append(NotesSegment(0, 0.0, "we ship friday okay", "We ship Friday. Okay.", turns = listOf(
            SpeakerTurn(1, 0.4, "We ship Friday.", "we ship friday"), SpeakerTurn(2, 65.0, "Okay.", "okay"))))
        append(NotesSegment(1, 70.0, "plain words", "Plain words."))
    }

    @Test fun `structuring reads Name lines and a rename applies across the note`() {
        val document = labelledDocument()
        assertEquals("Person 1: We ship Friday.\nPerson 2: Okay.\nPlain words.", document.nextStructureRequest()!!.transcript)
        document.renameSpeaker(2, "Maya")
        assertEquals(1, document.speakerVersion)
        assertEquals("Person 1: We ship Friday.\nMaya: Okay.\nPlain words.", document.nextStructureRequest()!!.transcript)
        assertEquals(listOf("**[00:00:00] Person 1:** We ship Friday.\n\n**[00:01:05] Maya:** Okay.", "**[00:01:10]** Plain words."),
            document.transcriptLines())
        assertTrue(document.exportMarkdown().contains("**[00:01:05] Maya:** Okay."))
        assertEquals("**[00:00:00] Person 1:** we ship friday\n\n**[00:01:05] Maya:** okay", document.transcriptLines(raw = true)[0])
    }

    @Test fun `one turn override survives storage structuring raw export merges and new segments`() {
        val document = labelledDocument()
        document.renameSpeaker(1, "Sam")
        assertTrue(document.reassignTurn(0, 1, 1))
        val changed = document.segments[0].turns!![1]
        assertEquals(2, changed.person)
        assertEquals(1, changed.effectivePerson)
        assertEquals("Okay.", changed.text); assertEquals("okay", changed.raw)
        assertTrue(document.nextStructureRequest()!!.transcript.contains("Sam: Okay."))
        assertTrue(document.exportMarkdown().contains("Sam:** Okay."))
        assertTrue(document.transcriptMarkdown(raw = true).contains("Sam:** okay"))
        assertTrue(document.reassignTurn(0, 1, null))
        assertEquals(3, document.segments[0].turns!![1].effectivePerson)
        document.renameSpeaker(3, "Maya")
        document.mergeSpeaker(3, 1)
        assertTrue(document.transcriptMarkdown().contains("Sam:** Okay."))
        document.separateSpeaker(3)
        val copy = NotesDocument.fromJson(document.toJson())
        assertTrue(copy.nextStructureRequest()!!.transcript.contains("Maya: Okay."))
        assertTrue(copy.exportMarkdown().contains("Maya:** Okay."))
        document.append(NotesSegment(2, 80.0, "More.", turns = listOf(SpeakerTurn(2, 80.0, "More."))))
        assertEquals("Person 2: More.", document.spoken(document.segments.last()))
        val people = document.roster.people.size
        assertFalse(document.reassignTurn(99, 0, null)); assertFalse(document.reassignTurn(0, 99, null))
        assertFalse(document.reassignTurn(0, 0, 999))
        assertEquals(people, document.roster.people.size)
    }

    @Test fun `names are replaced as whole words only`() {
        val document = NotesDocument(0L, "- [ ] **Person 2** to send the spec\n- Person 21 joins\n- Ask Person 2")
        assertEquals(2, document.nameCount("Person 2"))
        assertEquals("- [ ] **Maya** to send the spec\n- Person 21 joins\n- Ask Maya", document.replacingName("Person 2", "Maya"))
        assertEquals(0, document.nameCount(""))
    }

    @Test fun `turns and people survive the saved note`() {
        val document = labelledDocument().apply { renameSpeaker(1, "Sam"); mergeSpeaker(2, 1) }
        val copy = NotesDocument.fromJson(document.toJson())
        assertEquals(document.segments.map { it.turns }, copy.segments.map { it.turns })
        assertEquals("Sam", copy.roster.displayName(2))
        assertTrue(copy.labelled)
        // An unlabelled note writes nothing new.
        val plain = NotesDocument(0L).apply { append(NotesSegment(0, 0.0, "a")) }.toJson()
        assertFalse(plain.has("people")); assertFalse(plain.getJSONArray("segments").getJSONObject(0).has("turns"))
    }

    // Recorder

    @Test fun `segments ask for labels only when on, with one session per note`() {
        val rig = NotesRig()
        rig.recorder.start(); rig.wire.ready(); rig.idle()
        assertNull(rig.wire.speakers)
        rig.recorder.labelSpeakers = true
        rig.segment()
        val session = rig.wire.speakers
        assertNotNull(session); assertTrue(Protocol.SPEAKER_SESSION.matches(session!!))
        rig.segment()
        assertEquals(session, rig.wire.speakers)
        rig.recorder.cancel(); rig.recorder.reset()
        rig.recorder.start(); rig.wire.ready(); rig.idle()
        assertNotEquals("New starts a new speaker session", session, rig.wire.speakers)
    }

    @Test fun `people are numbered in transcript order even when finals arrive out of order`() {
        val rig = NotesRig()
        rig.recorder.labelSpeakers = true
        rig.recorder.start(); rig.wire.ready(); rig.idle()
        val first = rig.segment(); val second = rig.segment()
        second.final("Okay. Sure.", speakers = result("g", turn(1, 0.0, "Okay."), turn(1, 1.0, "Sure.")))
        first.final("We ship.", speakers = result("g", turn(0, 0.2, "We ship.")))
        rig.idle()
        val segments = rig.recorder.document.segments
        assertEquals(listOf(SpeakerTurn(1, 0.2, "We ship.", "we ship")), segments[0].turns)
        // One person's turns in a row join; the start is in note seconds.
        assertEquals(listOf(SpeakerTurn(2, 45.0, "Okay. Sure.", "okay sure")), segments[1].turns)
        assertNull(rig.recorder.speakerError)
    }

    @Test fun `a missing model leaves segments unlabelled and says so`() {
        val rig = NotesRig()
        rig.recorder.labelSpeakers = true
        rig.recorder.start(); rig.wire.ready(); rig.idle()
        rig.segment().final("Hello.", speakers = SpeakersResult(null, emptyList(), "unavailable")); rig.idle()
        assertNull(rig.recorder.document.segments.single().turns)
        assertEquals("unavailable", rig.recorder.speakerError)
    }

    // The model

    private val speakersMac = notesMac.copy(notesSpeakers = true, speakersModel = "not_downloaded")

    @Test fun `default recording starts immediately and downloads without writing a preference`() {
        val app = RuntimeEnvironment.getApplication()
        val requests = mutableListOf<String>()
        val store = SettingsStore(app).apply { health = speakersMac }
        val model = NotesModel(app, store, captureFactory = { frame, _, done -> FakeNotesCapture(frame, done) },
            transportFactory = { _, _, event, failure -> NotesWire(event, failure) }, apiFactory = { _, _ -> ScriptedNotesApi() },
            micGranted = { true }, pairing = { Pairing.from("https://mac.example.test/chirp", "synthetic") }, fetchHealth = { _, _ -> null },
            speakerModel = { _, _, action -> requests += action; if (action == "cancel") "not_downloaded" else "downloading" },
            tailscale = TailscalePromptTest.FakeTailscale(), foreground = {}, io = { it() }, journal = null, sessions = null,
            background = { it() }, audioWork = { it() })
        model.start()
        assertTrue(model.state.active)
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
        assertEquals(listOf("download"), requests)
        assertTrue(model.labelSpeakers); assertFalse(model.recorder.labelSpeakers)
        assertFalse(app.getSharedPreferences(SettingsStore.FILE, android.content.Context.MODE_PRIVATE).contains("notes_label_speakers"))
        model.setSpeakerLabels(false)
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
        assertEquals(listOf("download", "cancel"), requests)
        assertFalse(model.recorder.labelSpeakers); assertTrue(store.notesSpeakersOptedOut)
    }

    @Test fun `unset defaults on and explicit off survives a new store`() {
        val app = RuntimeEnvironment.getApplication()
        val store = SettingsStore(app)
        assertTrue(store.notesLabelSpeakers); assertFalse(store.notesSpeakersOptedOut)
        store.notesLabelSpeakers = false
        assertFalse(SettingsStore(app).notesLabelSpeakers); assertTrue(SettingsStore(app).notesSpeakersOptedOut)
        store.notesLabelSpeakers = true
        assertTrue(SettingsStore(app).notesLabelSpeakers); assertFalse(store.notesSpeakersOptedOut)
    }

    private class ModelRig(initial: Health, off: Boolean = false) {
        val store = SettingsStore(RuntimeEnvironment.getApplication()).apply { health = initial; if (off) notesLabelSpeakers = false }
        val scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.Main.immediate)
        var latest: Health? = null
        var answer: String? = "downloading"
        val requests = mutableListOf<String>()
        val model = NotesSpeakerModel(store, scope, { it() }, { latest }, { requests += it; answer })
        fun idle() = org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
    }

    @Test fun `off and old server never request a model or show status`() {
        for ((health, off) in listOf(speakersMac to true, notesMac to false)) {
            val rig = ModelRig(health, off)
            rig.model.activate(); rig.idle()
            assertTrue(rig.requests.isEmpty()); assertFalse(rig.model.ready); assertNull(rig.model.status)
        }
        val rig = NotesModelRig(RuntimeEnvironment.getApplication(), notesMac)
        rig.record()
        assertFalse(rig.model.recorder.labelSpeakers); assertNull(rig.wire.speakers)
    }

    @Test fun `health polling starts labels once ready without changing preference`() {
        val rig = ModelRig(speakersMac)
        rig.model.activate(); rig.idle()
        assertEquals(listOf("download"), rig.requests); assertFalse(rig.model.ready)
        rig.latest = speakersMac.copy(speakersModel = "ready")
        rig.model.refresh(); rig.idle()
        assertTrue(rig.model.ready); assertNull(rig.model.status)
        assertTrue(rig.store.notesLabelSpeakers)
    }

    @Test fun `failed download offers retry and cancellation failure keeps explicit off`() {
        val rig = ModelRig(speakersMac)
        rig.answer = null
        rig.model.activate(); rig.idle()
        assertTrue(rig.model.retryable); assertEquals(SpeakerModelNotice.DownloadFailed, rig.model.status)
        assertEquals("Couldn’t download the speaker model.", rig.model.status!!.ui.notesEnglish())
        rig.latest = speakersMac; rig.model.refresh(); rig.idle()
        assertTrue(rig.model.retryable) // A health refresh never hides a failed POST.
        rig.latest = null
        rig.answer = "downloading"; rig.model.retry(); rig.idle()
        assertEquals(listOf("download", "download"), rig.requests)
        rig.model.setLabels(false); rig.idle()
        assertTrue(rig.model.cancelFailed); assertTrue(rig.store.notesSpeakersOptedOut)
        rig.answer = "not_downloaded"; rig.model.retry(); rig.idle()
        assertFalse(rig.model.cancelFailed); assertNull(rig.model.status); assertFalse(rig.model.ready)
        assertEquals(listOf("download", "download", "cancel", "cancel"), rig.requests)
    }

    @Test fun `turn off queues cancellation after an in-flight download POST`() {
        val app = RuntimeEnvironment.getApplication()
        val store = SettingsStore(app).apply { health = speakersMac }
        val scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.Main.immediate)
        val release = kotlinx.coroutines.CompletableDeferred<Unit>()
        val requests = mutableListOf<String>()
        var calls = 0
        val model = NotesSpeakerModel(store, scope, { work -> if (++calls == 1) release.await(); work() }, { null },
            { requests += it; if (it == "download") "downloading" else "not_downloaded" })
        model.activate()
        model.setLabels(false)
        release.complete(Unit)
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
        assertEquals(listOf("download", "cancel"), requests)
        assertFalse(model.enabled); assertFalse(model.ready); assertNull(model.status)
        assertTrue(store.notesSpeakersOptedOut)
    }

    @Test fun `an installed model that cannot load is replaced on Retry`() {
        val app = RuntimeEnvironment.getApplication()
        val store = SettingsStore(app).apply { health = speakersMac.copy(speakersModel = "ready") }
        val scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.Main.immediate)
        val requests = mutableListOf<String>()
        val model = NotesSpeakerModel(store, scope, { it() }, { null },
            { requests += it; if (it == "remove") "not_downloaded" else "downloading" })
        model.unavailable()
        assertFalse(model.ready); assertTrue(model.retryable)
        model.refresh(); org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
        model.retry(); org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
        assertEquals(listOf("remove", "download"), requests)
        assertTrue(store.notesLabelSpeakers)
    }

    @Test fun `damaged model waits for retry and settings refresh sees the latest health`() {
        val rig = ModelRig(speakersMac.copy(speakersModel = "failed", speakersModelBytes = 26_530_309))
        rig.model.activate(); rig.idle()
        assertTrue(rig.requests.isEmpty()); assertTrue(rig.model.retryable)
        rig.model.retry(); rig.idle()
        assertEquals(SpeakerModelNotice.Preparing(27), rig.model.status)
        assertEquals("Getting the speaker model ready (27 MB, once)…", rig.model.status!!.ui.notesEnglish())
        rig.latest = speakersMac.copy(speakersModel = "ready")
        rig.model.refresh(); rig.idle()
        assertEquals("ready", rig.store.health?.speakersModel); assertTrue(rig.model.ready)
    }

    @Test fun `renaming offers to replace the old name in the notes`() {
        val rig = NotesModelRig(RuntimeEnvironment.getApplication(), speakersMac)
        rig.model.recorder.document.apply { roster.id(0, "g") }
        rig.model.edit(androidx.compose.ui.text.input.TextFieldValue("- [ ] **Person 1** to send the spec"))
        rig.model.renameSpeaker(1, "Maya", replaceInNotes = true)
        assertEquals("- [ ] **Maya** to send the spec", rig.model.document.text)
        assertEquals("Maya", rig.model.document.roster.displayName(1))
        rig.model.renameSpeaker(1, "Sam")
        assertEquals("- [ ] **Maya** to send the spec", rig.model.document.text)
    }

    // Name speakers

    @Test fun `naming several people at once replaces old names in one pass, swaps included`() {
        val rig = NotesModelRig(RuntimeEnvironment.getApplication(), speakersMac)
        rig.model.recorder.document.apply { roster.id(0, "g"); roster.id(1, "g"); roster.id(2, "g"); renameSpeaker(1, "Maya"); renameSpeaker(2, "Sam") }
        rig.model.edit(androidx.compose.ui.text.input.TextFieldValue("- Maya sends the spec\n- Sam reviews\n- Person 3 joins late, Person 31 not"))
        val document = rig.model.document
        assertEquals(3, document.nameCount(listOf("Maya", "Sam", "Person 3")))
        // Maya ↔ Sam swap, Person 3 becomes Lee; blank for nobody; an unchanged name is not a change.
        rig.model.renameSpeakers(mapOf(1 to "Sam", 2 to "Maya", 3 to " Lee "), replaceInNotes = true)
        assertEquals("- Sam sends the spec\n- Maya reviews\n- Lee joins late, Person 31 not", document.text)
        assertEquals(listOf("Sam", "Maya", "Lee"), (1..3).map(document.roster::displayName))
        val version = document.speakerVersion
        rig.model.renameSpeakers(mapOf(1 to "Sam", 3 to "Lee"), replaceInNotes = true)
        assertEquals(version, document.speakerVersion)
        // Blank goes back to "Person N"; without the toggle the notes' text stays.
        rig.model.renameSpeakers(mapOf(3 to ""), replaceInNotes = false)
        assertEquals("Person 3", document.roster.displayName(3)); assertTrue(document.text.contains("Lee joins late"))
    }

    @Test fun `who was speaking asks once after Stop for people with no name`() {
        val rig = NotesModelRig(RuntimeEnvironment.getApplication(), notesMac.copy(notesSpeakers = true, speakersModel = "ready"))
        rig.model.recorder.labelSpeakers = true
        assertFalse(rig.model.askToNameSpeakers)
        rig.record().final("We ship. Okay.", speakers = result("g", turn(0, 0.2, "We ship."), turn(1, 2.0, "Okay.")))
        rig.idle()
        assertFalse("not while recording", rig.model.askToNameSpeakers)
        rig.model.toggle(); rig.idle(); rig.wire.final("Bye."); rig.idle()
        assertTrue(rig.model.askToNameSpeakers)
        // It goes while recording again, and comes back after the next Stop.
        rig.model.toggle(); rig.wire.ready(); rig.idle()
        assertFalse(rig.model.askToNameSpeakers)
        // Naming everyone settles it; naming one leaves the other for the sheet.
        val named = NotesModelRig(RuntimeEnvironment.getApplication(), notesMac.copy(notesSpeakers = true, speakersModel = "ready"))
        named.model.recorder.labelSpeakers = true
        named.record().final("We ship. Okay.", speakers = result("g", turn(0, 0.2, "We ship."), turn(1, 2.0, "Okay."))); named.idle()
        named.model.toggle(); named.idle(); named.wire.final("Bye."); named.idle()
        assertTrue(named.model.askToNameSpeakers)
        named.model.renameSpeakers(mapOf(1 to "Maya", 2 to "Sam"))
        assertFalse(named.model.askToNameSpeakers); assertTrue(named.model.document.roster.unnamed.isEmpty())
    }

    @Test fun `autocomplete offers names from recent notes, newest first, without this note's own or used names`() {
        var clock = 1_800_000_000_000L
        val sessions = NotesSessions(RuntimeEnvironment.getApplication(), SoftwareHistoryKeys(), clock = { ++clock })
        fun note(id: String, vararg names: String?) = sessions.put(id, labelledDocument().apply {
            names.forEachIndexed { i, n -> if (n != null) renameSpeaker(i + 1, n) }
            roster.addPerson(); roster.merge(3, 1)
        }.toJson().put("elapsed", 1.0))
        assertTrue(note("a", "Maya", "Sam")); assertTrue(note("b", "sam", "Lee")); assertTrue(note("c", null, null)); assertTrue(note("d", "Zed", null))
        val names = sessions.speakerNames()
        // Newest note first; "Sam" and "sam" are one name, and the newer spelling stays.
        assertEquals(listOf("Zed", "sam", "Lee", "Maya"), names)
        assertFalse(sessions.speakerNames(excluding = "d").contains("Zed"))
        assertEquals(listOf("Maya"), suggestions(listOf("Maya", "Sam", "Lee"), "ma", emptySet()))
        assertEquals(listOf("Maya", "Lee"), suggestions(listOf("Maya", "Sam", "Lee"), "", setOf("sam")))
        assertEquals(emptyList<String>(), suggestions(listOf("Maya"), "maya", emptySet()))
        assertEquals(4, suggestions(listOf("A", "B", "C", "D", "E"), "", emptySet()).size)
    }

    @Test fun `batch merges replace every original name and persist together`() {
        val rig = NotesModelRig(RuntimeEnvironment.getApplication(), speakersMac)
        rig.model.recorder.document.apply { roster.id(0, "g"); roster.id(1, "g"); roster.id(2, "g") }
        rig.model.edit(androidx.compose.ui.text.input.TextFieldValue("Person 1 and Person 2 and Person 3"))
        rig.model.renameSpeakers(mapOf(1 to "Maya"), replaceInNotes = true, merges = linkedMapOf(3 to 2, 2 to 1))
        assertEquals("Maya and Maya and Maya", rig.model.document.text)
        assertEquals(listOf(1, 1, 1), (1..3).map(rig.model.document.roster::resolve))
    }

    @Test fun `samples start at the person's turn within the segment`() {
        val document = NotesDocument()
        document.roster.id(0, "g"); document.roster.id(1, "g")
        document.append(NotesSegment(0, 30.0, "hello", "Hello.", turns = listOf(
            SpeakerTurn(1, 31.5, "Hello."), SpeakerTurn(2, 34.0, "Hi."))))
        assertEquals(1500, document.sampleOffset(1)); assertEquals(4000, document.sampleOffset(2))
        assertEquals(0, document.sampleOffset(9))
    }

    @Test fun `a person's first line is what they said first, merges included`() {
        val document = labelledDocument()
        assertEquals(0 to "We ship Friday.", document.firstTurn(1)); assertEquals(0 to "Okay.", document.firstTurn(2))
        document.mergeSpeaker(2, 1)
        assertEquals(0 to "We ship Friday.", document.firstTurn(1)); assertNull(document.firstTurn(9))
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class NotesSpeakersRenderTest {
    @get:Rule val compose = createComposeRule()

    private fun rig(): NotesModelRig {
        val rig = NotesModelRig(RuntimeEnvironment.getApplication(), notesMac.copy(notesSpeakers = true, speakersModel = "ready"))
        rig.model.rename("Launch sync")
        rig.model.recorder.labelSpeakers = true
        rig.record().final("We ship the beta on Friday. Who owns the invite? I can draft it today.",
            speakers = result("g", turn(0, 0.4, "We ship the beta on Friday."), turn(1, 4.0, "Who owns the invite?"),
                turn(2, 7.5, "I can draft it today.")))
        rig.idle()
        return rig
    }

    @Test @Config(qualifiers = "w411dp-h891dp-mdpi") fun `transcript chips, rename and merge`() {
        val output = File(System.getProperty("chirp.screenshots")).apply { mkdirs() }
        val rig = rig()
        val dark = mutableStateOf(false)
        compose.setContent {
            dev.chirp.android.ui.ChirpTheme(dark.value) {
                // The sheet's and the side pane's surface.
                androidx.compose.material3.Surface(color = androidx.compose.material3.MaterialTheme.colorScheme.surfaceContainer) {
                    TranscriptPane(rig.model, androidx.compose.ui.Modifier.padding(horizontal = 24.dp))
                }
            }
        }
        fun shot(name: String) {
            compose.mainClock.advanceTimeBy(2000); compose.waitForIdle()
            val target = if (name == "rename") compose.onNode(isRoot() and hasAnyDescendant(hasText("Rename “Person 2”"))) else compose.onRoot()
            val bitmap = notesScreenshot(target)
            File(output, "notes-speakers-$name-${if (dark.value) "dark" else "light"}.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
        for (night in listOf(false, true)) { compose.runOnIdle { dark.value = night }; shot("transcript") }
        compose.runOnIdle { dark.value = false }
        listOf("Person 1", "Person 2", "Person 3").forEach { compose.onNodeWithText(it).assertIsDisplayed() }
        compose.onNodeWithText("Who owns the invite?").assertIsDisplayed()
        // Rename from the chip: everywhere in the note at once.
        compose.onNodeWithContentDescription("Person 2. Rename, merge or reassign this speaker").performClick()
        compose.onNodeWithText("Rename “Person 2”…").performClick()
        compose.onNode(hasSetTextAction()).performTextInput("Maya")
        for (night in listOf(false, true)) { compose.runOnIdle { dark.value = night }; shot("rename") }
        compose.runOnIdle { dark.value = false }
        compose.onNodeWithText("Rename").performClick()
        compose.onNodeWithText("Maya").assertIsDisplayed()
        assertTrue(rig.model.export().contains("Maya:** Who owns the invite?"))
        // Same person as: Person 3 becomes Maya, and Separate undoes it.
        compose.onNodeWithContentDescription("Person 3. Rename, merge or reassign this speaker").performClick()
        compose.onAllNodesWithText("Maya").onLast().performClick()
        compose.waitForIdle()
        assertEquals("Maya", rig.model.document.roster.displayName(3))
        compose.onNodeWithText("Person 3").assertDoesNotExist()
        for (night in listOf(false, true)) { compose.runOnIdle { dark.value = night }; shot("merged") }
        compose.runOnIdle { dark.value = false }
        compose.onAllNodesWithContentDescription("Maya. Rename, merge or reassign this speaker").onFirst().performClick()
        compose.onNodeWithText("Separate Person 3").performClick()
        compose.onNodeWithText("Person 3").assertIsDisplayed()
    }

    @Test @Config(qualifiers = "w411dp-h891dp-mdpi") fun `each turn can be reassigned from its menu including consecutive turns`() {
        val rig = rig()
        val dark = mutableStateOf(false)
        compose.setContent { dev.chirp.android.ui.ChirpTheme(dark.value) {
            androidx.compose.material3.Surface { TranscriptPane(rig.model, androidx.compose.ui.Modifier.padding(24.dp)) }
        } }
        fun shot(name: String, popup: Boolean = false) {
            for (night in listOf(false, true)) {
                compose.runOnIdle { dark.value = night }; compose.mainClock.advanceTimeBy(2000); compose.waitForIdle()
                val target = if (popup) compose.onNode(isRoot() and hasAnyDescendant(hasText("New person"))) else compose.onRoot()
                val bitmap = notesScreenshot(target)
                File(System.getProperty("chirp.screenshots"), "notes-speakers-$name-${if (night) "dark" else "light"}.png")
                    .outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            }
        }
        compose.onNodeWithText("Person 2").performClick()
        compose.onNodeWithText("This turn is…").performClick()
        shot("reassign-menu", popup = true)
        compose.onAllNodesWithText("Person 1").onLast().performClick()
        assertEquals(1, rig.model.document.segments[0].turns!![1].effectivePerson)
        compose.onAllNodesWithText("Person 1").assertCountEquals(2)
        compose.onAllNodesWithText("Person 1")[1].performClick()
        compose.onNodeWithText("This turn is…").performClick()
        compose.onNodeWithText("New person").performClick()
        compose.onNodeWithText("Person 4").assertIsDisplayed()
        shot("reassigned")
        val kept = NotesDocument.fromJson(rig.sessions.open(rig.model.document.uid)!!.document)
        assertEquals(4, kept.segments[0].turns!![1].effectivePerson)
        assertTrue(kept.exportMarkdown().contains("Person 4:** Who owns the invite?"))
    }

    @Test @Config(qualifiers = "w411dp-h891dp-mdpi") fun `preparing status and turn off are visible in light and dark`() {
        val output = File(System.getProperty("chirp.screenshots")).apply { mkdirs() }
        val rig = NotesModelRig(RuntimeEnvironment.getApplication(), notesMac.copy(notesSpeakers = true,
            speakersModel = "not_downloaded", speakersModelBytes = 26_530_309))
        val dark = mutableStateOf(false)
        compose.setContent { dev.chirp.android.ui.ChirpTheme(dark.value) { NotesScreen(rig.model, rig.model::toggle, {}, {}, {}, {}) } }
        compose.onNodeWithText("Getting the speaker model ready (27 MB, once)…").assertIsDisplayed()
        for (night in listOf(false, true)) {
            compose.runOnIdle { dark.value = night }; compose.mainClock.advanceTimeBy(2000); compose.waitForIdle()
            val bitmap = notesScreenshot(compose.onRoot())
            File(output, "notes-speakers-preparing-${if (night) "dark" else "light"}.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
        compose.onNodeWithText("Turn off").performClick()
        assertFalse(rig.model.labelSpeakers)
    }

    @Test @Config(qualifiers = "w411dp-h891dp-mdpi") fun `settings refreshes cached health and offers remove with no consent`() {
        val app = RuntimeEnvironment.getApplication()
        val store = SettingsStore(app).apply { health = notesMac }
        val scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.Main.immediate)
        val requests = mutableListOf<String>()
        val speakers = NotesSpeakerModel(store, scope, { it() },
            { notesMac.copy(notesSpeakers = true, speakersModel = "ready") }, { requests += it; "not_downloaded" })
        compose.setContent { dev.chirp.android.ui.ChirpTheme(false) {
            androidx.compose.foundation.lazy.LazyColumn { item { NotesSettings(speakerState = speakers) } }
        } }
        compose.onNodeWithText("Remove speaker model").performScrollTo().assertIsDisplayed()
        assertEquals("ready", store.health?.speakersModel)
        compose.onNodeWithText("Remove speaker model").performClick()
        compose.waitForIdle()
        assertEquals(listOf("remove"), requests)
        compose.onNodeWithText("Label speakers?").assertDoesNotExist()
    }

    @Test @Config(qualifiers = "w411dp-h891dp-mdpi") fun `model status has inline retry and turn off in light and dark`() {
        val output = File(System.getProperty("chirp.screenshots")).apply { mkdirs() }
        val rig = NotesModelRig(RuntimeEnvironment.getApplication(), notesMac.copy(notesSpeakers = true, speakersModel = "failed"))
        val dark = mutableStateOf(false)
        compose.setContent { dev.chirp.android.ui.ChirpTheme(dark.value) { NotesScreen(rig.model, rig.model::toggle, {}, {}, {}, {}) } }
        compose.onNodeWithText("Couldn’t download the speaker model.").assertIsDisplayed()
        compose.onNodeWithText("Retry").assertIsDisplayed()
        compose.onNodeWithText("Label speakers?").assertDoesNotExist()
        for (night in listOf(false, true)) {
            compose.runOnIdle { dark.value = night }; compose.mainClock.advanceTimeBy(2000); compose.waitForIdle()
            val bitmap = notesScreenshot(compose.onRoot())
            File(output, "notes-speakers-status-${if (night) "dark" else "light"}.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
        compose.onNodeWithText("Turn off").performClick()
        assertFalse(rig.model.labelSpeakers)
        compose.onNodeWithText("Couldn’t download the speaker model.").assertDoesNotExist()
    }

    @Test @Config(qualifiers = "w411dp-h891dp-mdpi") fun `Name speakers names everyone at once and the banner asks after Stop`() {
        val output = File(System.getProperty("chirp.screenshots")).apply { mkdirs() }
        val rig = rig()
        // Recent notes' names, for the autocomplete.
        rig.sessions.put("old", NotesDocument(0L).apply {
            roster.id(0, "g"); roster.id(1, "g"); renameSpeaker(1, "Maya"); renameSpeaker(2, "Akshay")
            append(NotesSegment(0, 0.0, "hello", "Hello.", turns = listOf(SpeakerTurn(1, 0.0, "Hello."), SpeakerTurn(2, 1.0, "Hi.")))) }.toJson().put("elapsed", 1.0))
        rig.model.toggle(); rig.idle(); rig.wire.final("Bye."); rig.idle()
        rig.model.edit(androidx.compose.ui.text.input.TextFieldValue("- [ ] **Person 2** drafts the invite\n- Person 1 owns the beta"))
        val dark = mutableStateOf(false)
        compose.setContent { dev.chirp.android.ui.ChirpTheme(dark.value) { NotesScreen(rig.model, rig.model::toggle, {}, {}, {}, {}) } }
        compose.onNodeWithText("Who was speaking?").assertIsDisplayed()
        compose.onAllNodesWithText("Name speakers").onFirst().performClick()
        compose.waitForIdle()
        listOf("Person 1", "Person 2", "Person 3").forEach { compose.onNodeWithTag("name_speaker_${it.last()}").assertExists() }
        compose.onNodeWithText("“Who owns the invite?”").assertIsDisplayed()
        compose.onNodeWithText("Also replace names in the notes", substring = true).assertDoesNotExist()
        // Typing a few letters offers a name from a recent note.
        compose.onNodeWithContentDescription("Name for Person 2").performClick()
        compose.onNodeWithContentDescription("Name for Person 2").performTextInput("Ma")
        compose.onNodeWithText("Maya").assertIsDisplayed()
        compose.onNodeWithText("Maya").performClick()
        compose.onNodeWithContentDescription("Name for Person 1").performTextInput("Akshay")
        compose.onNodeWithText("Also replace names in the notes (2 places)").assertIsDisplayed()
        for (night in listOf(false, true)) {
            compose.runOnIdle { dark.value = night }
            compose.mainClock.advanceTimeBy(2000); compose.waitForIdle()
            val bitmap = notesScreenshot(compose.onNode(isRoot() and hasAnyDescendant(hasTestTag("name_speakers_done"))))
            File(output, "notes-speakers-name-sheet-${if (night) "dark" else "light"}.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
        compose.onNodeWithTag("name_speakers_done").performClick()
        compose.waitForIdle()
        val roster = rig.model.document.roster
        assertEquals(listOf("Akshay", "Maya", "Person 3"), (1..3).map(roster::displayName))
        assertEquals("- [ ] **Maya** drafts the invite\n- Akshay owns the beta", rig.model.document.text)
        compose.onNodeWithTag("name_speaker_1").assertDoesNotExist()
        // Person 3 is still unnamed, but the line was settled by naming.
        compose.onNodeWithText("Who was speaking?").assertDoesNotExist()
    }

    @Test @Config(qualifiers = "w840dp-h700dp-mdpi") fun `Fold inner screen uses a dialog in light and dark`() {
        val output = File(System.getProperty("chirp.screenshots")).apply { mkdirs() }
        val rig = rig()
        val dark = mutableStateOf(false)
        compose.setContent { dev.chirp.android.ui.ChirpTheme(dark.value) { NameSpeakersSheet(rig.model) {} } }
        compose.onNodeWithTag("name_speakers_dialog").assertIsDisplayed()
        compose.onNodeWithTag("name_speakers_done").assertIsDisplayed()
        for (night in listOf(false, true)) {
            compose.runOnIdle { dark.value = night }; compose.mainClock.advanceTimeBy(2000); compose.waitForIdle()
            val bitmap = notesScreenshot(compose.onNode(isRoot() and hasAnyDescendant(hasTestTag("name_speakers_dialog"))))
            File(output, "notes-speakers-name-dialog-${if (night) "dark" else "light"}.png").outputStream().use {
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
            }
        }
    }

    @Test @Config(qualifiers = "w411dp-h891dp-mdpi") fun `Name speakers can merge a person, and Cancel changes nothing`() {
        val rig = rig()
        rig.model.toggle(); rig.idle(); rig.wire.final("Bye."); rig.idle()
        compose.setContent { dev.chirp.android.ui.ChirpTheme(false) { NotesScreen(rig.model, rig.model::toggle, {}, {}, {}, {}) } }
        // The banner opens it; Cancel changes nothing.
        compose.onAllNodesWithText("Name speakers").onFirst().performClick()
        compose.onNodeWithContentDescription("Name for Person 1").performTextInput("Nobody")
        compose.onNodeWithText("Cancel").performClick()
        assertEquals("Person 1", rig.model.document.roster.displayName(1))
        // The transcript's own button opens the same sheet.
        compose.onNodeWithText("Transcript").performClick()
        compose.onAllNodesWithText("Name speakers").onLast().performClick()
        compose.onNodeWithTag("name_speaker_3").assertExists()
        compose.onNode(hasText("Same as ▸") and hasAnyAncestor(hasTestTag("name_speaker_3"))).performClick()
        compose.onNode(hasText("Person 1") and hasAnyAncestor(isPopup())).performClick()
        compose.waitForIdle()
        assertEquals("merge is only a draft", 3, rig.model.document.roster.resolve(3))
        compose.onNodeWithTag("name_speaker_3").assertDoesNotExist()
        compose.onNodeWithText("Cancel").performClick()
        assertEquals(3, rig.model.document.roster.resolve(3))
        compose.onAllNodesWithText("Name speakers").onLast().performClick()
        compose.onNode(hasText("Same as ▸") and hasAnyAncestor(hasTestTag("name_speaker_3"))).performClick()
        compose.onNode(hasText("Person 1") and hasAnyAncestor(isPopup())).performClick()
        compose.onNodeWithTag("name_speakers_done").performClick()
        assertEquals(1, rig.model.document.roster.resolve(3))
    }
}
