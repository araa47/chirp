package dev.chirp.android

import java.util.TimeZone
import org.junit.Assert.*
import org.junit.Test

class NotesDocumentTest {
    private fun segment(id: Int, text: String) = NotesSegment(id, id * 20.0, text)
    private fun ok(md: String) = NotesStructureResponse(md, true)

    @Test fun `segmenter cuts at a pause after the minimum, sooner after thirty seconds, and always at the maximum`() {
        val s = notesSegmenter()
        fun run(seconds: Double, rms: Float): Boolean { var cut = false; repeat((seconds / 0.04).toInt()) { if (s.feed(rms, 0.04)) cut = true }; return cut }
        assertFalse(run(5.0, 0.1f)); assertFalse("a pause before 12 s never cuts", run(1.0, 0f))
        assertFalse(run(7.0, 0.1f))
        assertTrue("0.6 s of quiet after 12 s cuts", run(0.6, 0f))
        s.reset(); assertFalse(run(31.0, 0.1f)); assertTrue("0.3 s is enough after 30 s", run(0.32, 0f))
        s.reset(); assertFalse(run(44.9, 0.1f)); assertTrue("45 s cuts mid-speech", run(0.12, 0.1f))
        assertEquals(0f, DictationSegmenter.rms(ByteArray(1280)))
        assertEquals(0.5f, DictationSegmenter.rms(byteArrayOf(0, 64, 0, -64)), 0.001f)
    }

    @Test fun `router sends every frame to exactly one target and asks for one cut until the swap`() {
        val got = mutableMapOf<String, Int>()
        val router = FrameRouter<String>(DictationSegmenter(maxSegment = 0.2)) { target, _ -> got.merge(target, 1, Int::plus) }
        assertFalse(router.route(ByteArray(1280), 0.1f)) // no target: dropped, not counted
        router.swap("a")
        val cuts = (1..10).count { router.route(ByteArray(1280), 0.1f) }
        assertEquals(1, cuts)
        val (old, offset) = router.swap("b")
        assertEquals("a", old); assertEquals(0.4, offset, 1e-9)
        router.route(ByteArray(1280), 0.1f)
        assertEquals(mapOf("a" to 10, "b" to 1), got)
        assertEquals(0.44, router.seconds, 1e-9)
    }

    @Test fun `appends replace only the tail and a stale answer is ignored`() {
        val d = NotesDocument(text = "My agenda")
        d.append(segment(0, "we talked about the launch"))
        val first = requireNotNull(d.nextStructureRequest())
        val change = requireNotNull(d.apply(ok("## Launch\n- Talked about it"), first))
        assertEquals("My agenda\n\n## Launch\n- Talked about it", d.text)
        assertEquals(NotesChange(9, 9, "\n\n## Launch\n- Talked about it", NotesChange.Kind.APPEND), change)
        d.append(segment(1, "and the budget"))
        val second = requireNotNull(d.nextStructureRequest())
        assertEquals("we talked about the launch\nand the budget", second.transcript)
        assertEquals(emptyList<String>(), second.outline)
        // The user edits inside the tail: it becomes theirs, and the pass in flight for the old tail is dropped.
        d.userEdit(d.text.length, d.text.length, " today")
        assertNull(d.apply(ok("## Launch\n- Talked\n## Budget"), second))
        assertTrue(d.text.endsWith("Talked about it today"))
        assertEquals(listOf("Launch"), requireNotNull(d.nextStructureRequest()).outline)
        assertEquals("and the budget", d.nextStructureRequest()?.transcript)
    }

    @Test fun `typing before the tail shifts it and does not claim it`() {
        val d = NotesDocument(text = "Intro")
        d.append(segment(0, "first point"))
        d.apply(ok("- First point"), requireNotNull(d.nextStructureRequest()))
        val tail = d.tail
        d.userEdit(5, 5, " line")
        assertEquals(tail, d.tail)
        assertFalse(d.touchesTail(10, 10)) // right before the separator newline: the user's own line
        assertTrue(d.touchesTail(12, 12))
    }

    @Test fun `a long window settles and failures fall back to an editable raw block`() {
        val d = NotesDocument()
        val long = "word ".repeat(340).trim()
        d.append(segment(0, long))
        d.apply(ok("- Long"), requireNotNull(d.nextStructureRequest()))
        assertEquals("over 1600 characters the tail settles", d.text.length, d.tailStart)
        d.append(segment(1, long))
        val failed = requireNotNull(d.nextStructureRequest())
        d.apply(NotesStructureResponse.failed("timeout"), failed)
        assertEquals(1, d.consecutiveFailures)
        d.apply(NotesStructureResponse.failed("busy"), failed)
        assertTrue("two failures past 1600 characters fall back", d.text.contains(NotesDocument.FALLBACK_HEADER))
        assertEquals(1, d.untouchedFallbacks.size)
        assertNull(d.nextStructureRequest())
    }

    @Test fun `reorganize applies only to the text it was made from`() {
        val d = NotesDocument(text = "## Budget\n- Spend less on travel this quarter\n\n## Launch\n- Ship the beta to the first ten customers\n")
        val request = requireNotNull(d.reorganizeRequest(final = false, manual = true))
        assertEquals(0, request.start)
        val answer = NotesReorganizeResponse("## Budget\n- Spend less on travel\n\n## Launch\n- Ship the beta", true, true)
        d.userEdit(0, 0, "x")
        assertNull("an edit while it ran discards the result", d.applyReorganize(answer, request))
        val fresh = requireNotNull(d.reorganizeRequest(final = false, manual = true))
        assertNotNull(d.applyReorganize(answer, fresh))
        assertTrue(d.text.startsWith("## Budget\n- Spend less on travel\n"))
        assertNull("unchanged since the last one", d.reorganizeRequest(final = false, manual = false))
    }

    @Test fun `stop keeps the words where the passes found nothing substantive`() {
        val d = NotesDocument(startedAt = 0)
        d.append(segment(0, "Hello, one, two, three."))
        d.apply(ok(NotesMarkdown.PLACEHOLDER), requireNotNull(d.nextStructureRequest()))
        assertEquals("while recording the placeholder stays", NotesMarkdown.PLACEHOLDER, d.text)
        d.append(segment(1, "Testing."))
        d.freezeAll()
        assertEquals("Hello, one, two, three.\n\n" + NotesDocument.FALLBACK_HEADER + "\n\nTesting.", d.text)
        assertEquals("Hello, one, two, three.", d.libraryTitle())

        val off = NotesDocument(startedAt = 0)
        off.append(segment(0, "Hello."))
        off.apply(ok(NotesMarkdown.PLACEHOLDER), requireNotNull(off.nextStructureRequest()))
        off.freezeAll(structuring = false)
        assertEquals("structuring off leaves the text alone", NotesMarkdown.PLACEHOLDER, off.text)

        val real = NotesDocument(startedAt = 0)
        real.append(segment(0, "We ship Friday."))
        real.apply(ok("- Ship **Friday**"), requireNotNull(real.nextStructureRequest()))
        real.freezeAll()
        assertEquals("- Ship **Friday**", real.text)

        val two = NotesDocument(startedAt = 0)
        two.append(NotesSegment(0, 0.0, "Hello. Hi.", turns = listOf(SpeakerTurn(1, 0.0, "Hello."), SpeakerTurn(2, 1.0, "Hi."))))
        two.apply(ok(NotesMarkdown.PLACEHOLDER), requireNotNull(two.nextStructureRequest()))
        two.freezeAll()
        assertEquals("Person 1: Hello.\n\nPerson 2: Hi.", two.text)
    }

    @Test fun `split, diff and export`() {
        val text = "One sentence here. ".repeat(50).trim()
        val (a, b) = requireNotNull(NotesDocument.split(text))
        assertTrue(a.endsWith(".") && a.length >= 400 && b.length >= 400)
        assertNull(NotesDocument.split("too short"))
        assertEquals(NotesChange(1, 2, "😀", NotesChange.Kind.USER), NotesDocument.diff("abc", "a😀c", NotesChange.Kind.USER))
        val emoji = NotesDocument.diff("a😀c", "a😃c", NotesChange.Kind.USER)!!
        assertEquals("never splits a surrogate pair", 1, emoji.start)
        val d = NotesDocument(startedAt = 0, text = "- Note\n_(nothing yet)_")
        d.append(segment(0, "said this"))
        d.append(NotesSegment.gap(1, 20.0, "timed out"))
        d.append(NotesSegment(2, 40.0, "raw words", "Raw words.", keptOriginal = true))
        assertEquals("# Notes — 1970-01-01 00:00\n\n- Note\n\n---\n\n## Transcript\n\n**[00:00:00]** said this\n\n" +
            "**[00:00:20]** ⚠︎ audio not transcribed (timed out)\n\n**[00:00:40]** Raw words. _(kept original)_\n",
            d.exportMarkdown(zone = TimeZone.getTimeZone("UTC")))
        assertEquals("**[00:00:40]** raw words", d.transcriptLines(raw = true).last())
    }

    @Test fun `wire format carries only the server's keys and decodes fail-closed answers`() {
        val structure = org.json.JSONObject(NotesStructureRequest("t", listOf("A"), true, 9, 9, 9, 9).json())
        assertEquals(setOf("transcript", "outline", "final"), structure.keys().asSequence().toSet())
        assertEquals("A", structure.getJSONArray("outline").getString(0)); assertTrue(structure.getBoolean("final"))
        assertEquals(setOf("notes", "outline", "final"), org.json.JSONObject(NotesReorganizeRequest("n", start = 3, end = 4).json()).keys().asSequence().toSet())
        assertEquals(NotesStructureResponse(null, false, "rejected", "novel_name"),
            NotesStructureResponse.decode("""{"markdown":null,"structured":false,"error":"rejected","reason":"novel_name"}"""))
        assertEquals("rejected: novel_name", NotesStructureResponse(null, false, "rejected", "novel_name").failureLabel)
        assertEquals("free text is never shown", "http", NotesFailure.label("Some <b>text</b>", "a b"))
        assertTrue(NotesReorganizeResponse.decode("""{"markdown":null,"reorganized":false,"changed":false,"error":"preempted"}""").preempted)
        assertFalse(NotesReorganizeResponse.decode("""{"markdown":null,"reorganized":true,"changed":true}""").reorganized)
    }
}
