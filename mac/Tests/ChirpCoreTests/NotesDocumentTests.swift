import Foundation
import Testing
@testable import ChirpCore

/// A small deterministic generator, so the property test replays the same sequences on every run.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// `#require` for a mutating call (the macro cannot take one, nor nest).
func unwrap<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) throws -> T {
    try #require(value, sourceLocation: sourceLocation)
}

@Suite struct NotesDocumentTests {
    private func doc(_ texts: [String], typed: String = "") -> NotesDocument {
        var d = NotesDocument(startedAt: Date(timeIntervalSince1970: 0))
        if !typed.isEmpty { d.userEdit(NSRange(location: 0, length: 0), typed) }
        for (i, t) in texts.enumerated() { d.append(NotesSegment(id: i, offset: Double(i) * 30, raw: t)) }
        return d
    }
    private func ok(_ md: String) -> NotesStructureResponse { NotesStructureResponse(markdown: md, structured: true) }
    private let fail = NotesStructureResponse.failed("timeout")
    private let utc = TimeZone(identifier: "UTC")!
    private func end(_ d: NotesDocument) -> Int { d.text.utf16.count }

    // MARK: append

    @Test func nextRequestIsNilWithoutNewTextAndCarriesTheGeneration() throws {
        var d = doc([])
        #expect(d.nextStructureRequest() == nil)
        d.append(.gap(id: 0, offset: 0, reason: "busy"))
        #expect(d.nextStructureRequest() == nil)
        d.append(NotesSegment(id: 1, offset: 30, raw: "we ship friday"))
        d.append(NotesSegment(id: 2, offset: 60, raw: "maya sends the spec"))
        let r = try #require(d.nextStructureRequest())
        #expect(r.transcript == "we ship friday\nmaya sends the spec" && r.windowEnd == 2 && !r.final)
        #expect(r.windowGeneration == d.windowGeneration && r.version == d.version)
        let change = try unwrap(d.apply(ok("- Ship Friday"), for: r))
        #expect(change == NotesTextChange(range: NSRange(location: 0, length: 0), replacement: "- Ship Friday", kind: .append))
        #expect(d.text == "- Ship Friday" && d.tail == "- Ship Friday" && d.tailStart == 0)
        #expect(d.nextStructureRequest() == nil)
        d.append(NotesSegment(id: 3, offset: 90, raw: "more"))
        #expect(d.nextStructureRequest(final: true)?.transcript == "we ship friday\nmaya sends the spec\nmore")
        #expect(d.nextStructureRequest(final: true)?.final == true)
    }

    @Test(arguments: [("", ""), ("mine\n\n", ""), ("mine\n", "\n"), ("mine", "\n\n")])
    func theSeparatorBelongsToTheTail(typed: String, separator: String) throws {
        var d = doc(["a"], typed: typed)
        let r = try #require(d.nextStructureRequest())
        d.apply(ok("- a"), for: r)
        #expect(d.settledText == typed && d.tail == separator + "- a")
        // A later pass replaces the whole tail, separator included, and never touches the settled text.
        d.append(NotesSegment(id: 1, offset: 30, raw: "b"))
        let change = try unwrap(d.apply(ok("- a\n- b"), for: try #require(d.nextStructureRequest())))
        #expect(d.text == typed + separator + "- a\n- b")
        #expect(change.range.location >= typed.utf16.count && change.replacement == "\n- b")
    }

    /// "Hello, one, two, three" is not substantive: the pass answers the placeholder. A finished note keeps the words
    /// instead of reading "(nothing yet)"; while recording the placeholder stays.
    @Test func stopKeepsTheWordsWhereThePassFoundNothingSubstantive() throws {
        var d = doc(["Hello, one, two, three."], typed: "")
        d.apply(ok(NotesMarkdown.placeholder), for: try #require(d.nextStructureRequest(final: true)))
        #expect(d.tail == NotesMarkdown.placeholder)
        d.freezeAll()
        #expect(d.text == "Hello, one, two, three." && d.notesBody == "Hello, one, two, three." && d.tail.isEmpty)
        // Typed text above it stays; with structuring off nothing is rewritten.
        var typed = doc(["testing"], typed: "mine")
        typed.apply(ok(NotesMarkdown.placeholder), for: try #require(typed.nextStructureRequest(final: true)))
        typed.freezeAll()
        #expect(typed.text == "mine\n\ntesting")
        var off = doc(["testing"])
        off.apply(ok(NotesMarkdown.placeholder), for: try #require(off.nextStructureRequest(final: true)))
        off.freezeAll(structuring: false)
        #expect(off.text == NotesMarkdown.placeholder)
        // Real notes are never touched.
        var real = doc(["we ship friday"])
        real.apply(ok("- Ship Friday"), for: try #require(real.nextStructureRequest(final: true)))
        real.freezeAll()
        #expect(real.text == "- Ship Friday")
    }

    @Test func settlesAtFreezeChars() throws {
        var d = doc([String(repeating: "a", count: 1000)])
        var r = try #require(d.nextStructureRequest())
        d.apply(ok("## A\n- one"), for: r)
        #expect(d.tail == "## A\n- one")
        d.append(NotesSegment(id: 1, offset: 30, raw: String(repeating: "b", count: 1500)))
        r = try #require(d.nextStructureRequest())
        let generation = d.windowGeneration
        d.apply(ok("## A\n- one\n- two"), for: r)
        #expect(d.text == "## A\n- one\n- two" && d.tailStart == end(d) && d.tail.isEmpty)
        #expect(d.windowStart == 2 && d.headings == ["A"] && d.windowGeneration == generation + 1)
        #expect(d.nextStructureRequest() == nil)
        // The next pass starts a new tail after a blank line.
        d.append(NotesSegment(id: 2, offset: 60, raw: "c"))
        d.apply(ok("## C\n- c"), for: try #require(d.nextStructureRequest()))
        #expect(d.text == "## A\n- one\n- two\n\n## C\n- c" && d.tail == "\n\n## C\n- c")
        #expect(d.nextStructureRequest() == nil)
    }

    @Test func fallbackIsAppendedAsTextAfterTwoFailures() throws {
        var d = doc([String(repeating: "a", count: 2500)], typed: "mine")
        var r = try #require(d.nextStructureRequest())
        #expect(d.apply(fail, for: r) == nil)
        #expect(d.consecutiveFailures == 1 && d.text == "mine")
        r = try #require(d.nextStructureRequest())
        let change = try unwrap(d.apply(fail, for: r))
        #expect(d.text == "mine\n\n" + NotesDocument.fallbackHeader + "\n\n" + String(repeating: "a", count: 2500))
        #expect(change.range == NSRange(location: 4, length: 0) && change.kind == .append)
        #expect(d.tailStart == end(d) && d.windowStart == 1 && d.nextStructureRequest() == nil)
    }

    @Test func fallbackAtMaxWindowCharsKeepsTheStructuredPart() throws {
        var d = doc([String(repeating: "a", count: 1000)])
        d.apply(ok("- a"), for: try #require(d.nextStructureRequest()))
        d.append(NotesSegment(id: 1, offset: 30, raw: String(repeating: "b", count: 2500)))
        d.append(NotesSegment(id: 2, offset: 60, raw: String(repeating: "c", count: 2000)))
        d.freezeOverflow()
        #expect(d.text == "- a\n\n" + NotesDocument.fallbackHeader + "\n\n" + String(repeating: "b", count: 2500)
                + "\n\n" + String(repeating: "c", count: 2000))
        #expect(d.tail.isEmpty && d.nextStructureRequest() == nil)
    }

    @Test func overflowSettlesTheStructuredPartAndRetriesTheRest() throws {
        var d = doc([String(repeating: "a", count: 1550)])
        d.apply(ok("- a"), for: try #require(d.nextStructureRequest()))
        d.append(NotesSegment(id: 1, offset: 30, raw: String(repeating: "b", count: 2100)))
        d.freezeOverflow()
        #expect(d.text == "- a" && d.tail.isEmpty)
        #expect(d.nextStructureRequest()?.transcript == String(repeating: "b", count: 2100))
    }

    @Test func aRequestNeverExceedsTheWindowCap() {
        var d = doc([String(repeating: "a", count: 2000), String(repeating: "b", count: 2000)])
        #expect(d.windowChars() > NotesDocument.maxWindowChars)
        #expect(d.nextStructureRequest() == nil)
        d.freezeOverflow()
        #expect(d.text.hasPrefix(NotesDocument.fallbackHeader) && d.nextStructureRequest() == nil)
        d.append(NotesSegment(id: 2, offset: 60, raw: "c"))
        #expect(d.nextStructureRequest()?.transcript == "c")
    }

    @Test func staleResponsesAreIgnored() throws {
        var d = doc([String(repeating: "a", count: 2500)])
        let old = try #require(d.nextStructureRequest())
        d.apply(ok("- a"), for: old)            // settled: the window moved on
        d.append(NotesSegment(id: 1, offset: 30, raw: "b"))
        #expect(d.apply(ok("- stale"), for: old) == nil)
        #expect(d.text == "- a")
    }

    @Test func freezeAllAtStop() throws {
        var d = doc(["one"])
        d.apply(ok("- one"), for: try #require(d.nextStructureRequest()))
        d.append(NotesSegment(id: 1, offset: 30, raw: "two"))
        d.freezeAll()
        #expect(d.text == "- one\n\n" + NotesDocument.fallbackHeader + "\n\ntwo" && d.tail.isEmpty && d.windowStart == 2)
        var off = doc(["one"])
        #expect(off.freezeAll(structuring: false) == nil && off.text.isEmpty)
    }

    // MARK: tail tracking

    /// "mine\n" typed, then an AI tail `\n- a\n- b` after it.
    private func withTail() throws -> NotesDocument {
        var d = doc(["a", "b"], typed: "mine\n")
        d.apply(ok("- a\n- b"), for: try #require(d.nextStructureRequest()))
        #expect(d.tailStart == 5 && d.tail == "\n- a\n- b")
        return d
    }

    @Test func anEditBeforeTheTailShiftsIt() throws {
        var d = try withTail()
        let generation = d.windowGeneration, version = d.version
        d.userEdit(NSRange(location: 0, length: 4), "my notes")
        #expect(d.tailStart == 9 && d.tail == "\n- a\n- b" && d.windowGeneration == generation)
        #expect(d.version == version + 1 && d.isDirty)
        // A deletion that ends exactly at the tail is still before it.
        d.userEdit(NSRange(location: 8, length: 1), "")
        #expect(d.tailStart == 8 && d.tail == "\n- a\n- b")
    }

    @Test func anEditInsideTheTailClaimsIt() throws {
        var d = try withTail()
        let generation = d.windowGeneration
        d.userEdit(NSRange(location: 9, length: 0), "x")          // "- ax"
        #expect(d.tailStart == end(d) && d.tail.isEmpty && d.text == "mine\n\n- ax\n- b")
        #expect(d.windowStart == d.structuredEnd + 1 && d.windowStart == 2 && d.windowGeneration == generation + 1)
        #expect(d.consecutiveFailures == 0)
    }

    @Test func aDeleteAcrossUserTextAndTailClaimsIt() throws {
        var d = try withTail()
        d.userEdit(NSRange(location: 2, length: 6), "")
        #expect(d.text == "mia\n- b" && d.tailStart == end(d))
    }

    @Test func typingAtTheEndOfOnesOwnLineShiftsTheTail() throws {
        // The tail starts with its separator newline: an insertion right before it extends the user's line.
        var d = try withTail()
        d.userEdit(NSRange(location: 5, length: 0), "z")
        #expect(d.tailStart == 6 && d.tail == "\n- a\n- b" && !d.touchesTail(NSRange(location: 6, length: 0)))
        // A tail with no separator (the user's text ended in a blank line) starts with AI text: inserting there claims.
        var bare = doc(["a"], typed: "mine\n\n")
        bare.apply(ok("- a"), for: try #require(bare.nextStructureRequest()))
        #expect(bare.tail == "- a" && bare.touchesTail(NSRange(location: 6, length: 0)))
        bare.userEdit(NSRange(location: 6, length: 0), "z")
        #expect(bare.tailStart == end(bare))
    }

    @Test func typingAtTheEndWithAnEmptyTailStaysTheUsers() throws {
        var d = doc([], typed: "mine")
        let generation = d.windowGeneration
        d.userEdit(NSRange(location: 4, length: 0), " more")
        #expect(d.text == "mine more" && d.tailStart == end(d) && d.windowGeneration == generation)
    }

    @Test func anEmojiBeforeTheTailShiftsItByTwo() throws {
        var d = try withTail()
        d.userEdit(NSRange(location: 0, length: 0), "👋")
        #expect(d.tailStart == 7 && d.tail == "\n- a\n- b")
    }

    @Test func aClaimedTailDropsTheResponseAndResendsItsSegments() throws {
        var d = doc(["one"])
        d.apply(ok("- one"), for: try #require(d.nextStructureRequest()))
        d.append(NotesSegment(id: 1, offset: 30, raw: "two"))
        let r = try #require(d.nextStructureRequest())
        d.userEdit(NSRange(location: 2, length: 0), "first ")    // into the tail: claimed
        #expect(d.apply(ok("- one\n- two"), for: r) == nil)
        #expect(d.text == "- first one")
        // "one" is covered by the claimed text; "two" goes out again.
        #expect(d.nextStructureRequest()?.transcript == "two")
        d.apply(ok("- two"), for: try #require(d.nextStructureRequest()))
        #expect(d.text == "- first one\n\n- two")
    }

    @Test func toggleTaskIsAUserEdit() throws {
        var d = doc([], typed: "## A\n- [ ] one\n- [x] two\n")
        let change = try unwrap(d.toggleTask(atLine: 1))
        #expect(change.kind == .toggleTask && d.text == "## A\n- [x] one\n- [x] two\n")
        d.toggleTask(atLine: 2)
        #expect(d.text == "## A\n- [x] one\n- [ ] two\n")
        #expect(d.toggleTask(atLine: 0) == nil && d.toggleTask(atLine: 9) == nil)
    }

    /// Every change a mutation returns, replayed onto the text before it, gives the text after it.
    @Test func changesReplayExactly() throws {
        var rng = SeededRandom(seed: 17)
        let pieces = ["a", "word ", "\n", "- ", "## H\n", "👋", "日本", "\n\n", "**b**", ""]
        for _ in 0..<200 {
            var d = NotesDocument()
            var segment = 0
            for _ in 0..<Int.random(in: 4...14, using: &rng) {
                let before = d.text
                var change: NotesTextChange?
                switch Int.random(in: 0..<5, using: &rng) {
                case 0, 1:
                    let units = Array(d.text.utf16)
                    var a = Int.random(in: 0...units.count, using: &rng)
                    var b = Int.random(in: a...units.count, using: &rng)
                    while a > 0, a < units.count, UTF16.isTrailSurrogate(units[a]) { a -= 1 }
                    while b < units.count, UTF16.isTrailSurrogate(units[b]) { b += 1 }
                    change = d.userEdit(NSRange(location: a, length: b - a), pieces.randomElement(using: &rng)!)
                case 2, 3:
                    d.append(NotesSegment(id: segment, offset: 0, raw: String(repeating: "x", count: Int.random(in: 1...900, using: &rng))))
                    segment += 1
                    if let r = d.nextStructureRequest() {
                        let md = (0..<Int.random(in: 1...4, using: &rng)).map { _ in "- " + pieces.randomElement(using: &rng)! }.joined(separator: "\n")
                        change = d.apply(Bool.random(using: &rng) ? ok(md) : fail, for: r)
                    }
                default:
                    change = d.freezeAll()
                }
                if let change { #expect(change.applied(to: before) == d.text) } else { #expect(before == d.text) }
                #expect(d.tailStart <= d.text.utf16.count)
            }
        }
    }

    // MARK: reorganize

    private func section(_ title: String, _ chars: Int) -> String {
        "## \(title)\n" + String(repeating: "- point\n", count: max(1, (chars - title.count - 4) / 8))
    }

    @Test func scopeIsTheWholeDocumentWhenItFits() throws {
        let d = doc([], typed: "Some intro words written by hand before any heading.\n\n" + section("A", 300) + section("B", 300))
        let scope = try #require(d.reorganizeScope())
        #expect(scope.range == NSRange(location: 0, length: d.text.utf16.count) && scope.outline.isEmpty)
        let r = try #require(d.reorganizeRequest(final: false, manual: false))
        #expect(r.notes == d.text && r.version == d.version && r.range == scope.range)
    }

    @Test func overTheCapOnlyTrailingWholeSectionsGo() throws {
        let text = (1...5).map { section("S\($0)", 1000) }.joined()
        let d = doc([], typed: text)
        let scope = try #require(d.reorganizeScope())
        let sections = NotesMarkdown.sections(text)
        #expect(sections.count == 5)
        // Three sections of ~1000 fit in 3500; the fourth from the end does not.
        #expect(scope.range.location == sections[2].range.location && NSMaxRange(scope.range) == text.utf16.count)
        #expect(scope.outline == ["S1", "S2"])
    }

    @Test func nothingWhenTheLastSectionIsTooLongOrTheScopeTiny() {
        let long = doc([], typed: section("Short", 200) + section("Huge", 3600))
        #expect(long.reorganizeScope() == nil && long.reorganizeTooLong)
        let tiny = doc([], typed: "## A\n- one\n")
        #expect(tiny.reorganizeScope() == nil && !tiny.reorganizeTooLong)
        #expect(tiny.reorganizeRequest(final: true, manual: true) == nil)
    }

    @Test func autoNeedsAChangeSinceTheLastReorganize() throws {
        var d = doc([], typed: section("A", 400))
        let r = try #require(d.reorganizeRequest(final: false, manual: false))
        #expect(d.applyReorganize(NotesReorganizeResponse(markdown: r.notes, reorganized: true, changed: false), for: r) == nil)
        #expect(d.lastReorganizeVersion == d.version && d.charsSinceReorganize == 0)
        #expect(d.reorganizeRequest(final: false, manual: false) == nil)
        #expect(d.reorganizeRequest(final: false, manual: true) != nil)
    }

    @Test func applyReorganizeSettlesEverythingWhenTheTextIsUnchanged() throws {
        var d = doc(["one", "two"], typed: section("Budget", 200))
        d.apply(ok("## Budget\n- two\n- [ ] one"), for: try #require(d.nextStructureRequest()))
        #expect(!d.tail.isEmpty && d.charsSinceReorganize > 0)
        let r = try #require(d.reorganizeRequest(final: false, manual: true))
        let generation = d.windowGeneration
        let md = "## Budget\n- point\n- two\n\n## Action items\n- [ ] one"
        let change = try unwrap(d.applyReorganize(NotesReorganizeResponse(markdown: md, reorganized: true), for: r))
        #expect(change.kind == .reorganize && change.range == r.range)
        #expect(d.text == md && d.tailStart == d.text.utf16.count && d.windowGeneration == generation + 1)
        #expect(d.charsSinceReorganize == 0 && d.lastReorganizeVersion == d.version)
        #expect(d.nextStructureRequest() == nil)
    }

    @Test func applyReorganizeKeepsTheBlankLinesAroundTheScope() throws {
        let text = (1...5).map { section("S\($0)", 1000) + "\n" }.joined()
        var d = doc([], typed: text)
        let r = try #require(d.reorganizeRequest(final: false, manual: true))
        d.applyReorganize(NotesReorganizeResponse(markdown: "## S3\n- merged", reorganized: true), for: r)
        #expect(d.text.hasSuffix("- point\n\n## S3\n- merged\n\n"))
    }

    @Test func applyReorganizeIsDiscardedWhenTheTextChanged() throws {
        var d = doc([], typed: section("A", 400))
        let r = try #require(d.reorganizeRequest(final: false, manual: true))
        d.userEdit(NSRange(location: 0, length: 0), "x")
        let before = d.text
        #expect(d.applyReorganize(NotesReorganizeResponse(markdown: "## A\n- merged", reorganized: true), for: r) == nil)
        #expect(d.text == before)
        #expect(d.applyReorganize(.failed("rejected"), for: try #require(d.reorganizeRequest(final: false, manual: true))) == nil)
    }

    // MARK: export and the rest

    @Test func outlineComesFromSettledHeadingsAndIsCapped() throws {
        let headings = (0..<30).map { "## Topic \($0) " + String(repeating: "y", count: 150) + "\n- point\n" }.joined()
        let d = doc(["x"], typed: headings)
        let outline = d.outline
        #expect(outline.count <= NotesDocument.maxOutlineItems)
        #expect(outline.allSatisfy { $0.count <= NotesDocument.maxOutlineItemChars })
        #expect(outline.reduce(0) { $0 + $1.count } <= NotesDocument.maxOutlineChars)
        #expect(outline.last?.hasPrefix("Topic 29") == true)
        #expect(doc([], typed: "# One\n### Three\n").headings == ["One", "Three"])
    }

    @Test func exportIsTheTextThenTheTranscript() throws {
        var d = doc(["we kick off", "budget talk"])
        d.apply(ok("## Kickoff\n- Launch **March 3**\n_(nothing yet)_"), for: try #require(d.nextStructureRequest()))
        d.freezeAll()
        #expect(d.exportMarkdown(includeTranscript: false, timeZone: utc) == "# Notes — 1970-01-01 00:00\n\n## Kickoff\n- Launch **March 3**\n")
        #expect(d.exportMarkdown(timeZone: utc) == """
            # Notes — 1970-01-01 00:00

            ## Kickoff
            - Launch **March 3**

            ---

            ## Transcript

            **[00:00:00]** we kick off

            **[00:00:30]** budget talk

            """)
        #expect(d.exportMarkdown(includeNotes: false, timeZone: utc) == "# Notes — 1970-01-01 00:00\n\n## Transcript\n\n**[00:00:00]** we kick off\n\n**[00:00:30]** budget talk\n")
        #expect(d.suggestedFileName(timeZone: utc) == "Chirp Notes 1970-01-01 0000.md")
    }

    @Test func typedNotesExportWithoutStructuringAndAnEmptyTextIsTranscriptOnly() {
        let typed = doc(["hello"], typed: "  my own line \n\n")
        #expect(typed.exportMarkdown(includeTranscript: false, timeZone: utc) == "# Notes — 1970-01-01 00:00\n\nmy own line\n")
        #expect(doc(["hello"]).exportMarkdown(includeTranscript: false, timeZone: utc)
                == "# Notes — 1970-01-01 00:00\n\n## Transcript\n\n**[00:00:00]** hello\n")
        #expect(!doc([], typed: "x").isEmpty && doc([], typed: " \n").isEmpty)
    }

    @Test func startIsStampedOnlyWhileEmpty() {
        var d = NotesDocument(startedAt: Date(timeIntervalSince1970: 0))
        d.stampStart(Date(timeIntervalSince1970: 100))
        #expect(d.startedAt == Date(timeIntervalSince1970: 100))
        d.append(NotesSegment(id: 0, offset: 0, raw: "x"))
        d.stampStart(Date(timeIntervalSince1970: 200))
        #expect(d.startedAt == Date(timeIntervalSince1970: 100))
    }

    @Test func timestampsGapsAndKeptOriginal() {
        #expect(NotesDocument.timestamp(0) == "00:00:00")
        #expect(NotesDocument.timestamp(3725.9) == "01:02:05")
        var d = NotesDocument()
        d.append(NotesSegment(id: 0, offset: 12, raw: "um hello", text: "Hello.", corrected: true))
        d.append(.gap(id: 1, offset: 100, reason: "Server is busy"))
        d.append(NotesSegment(id: 2, offset: 190, raw: "raw words", keptOriginal: true))
        #expect(d.transcriptLines() == ["**[00:00:12]** Hello.", "**[00:01:40]** ⚠︎ audio not transcribed (Server is busy)",
                                        "**[00:03:10]** raw words _(kept original)_"])
        #expect(d.transcriptLines(raw: true).first == "**[00:00:12]** um hello")
    }

    @Test func dirtyTransitions() {
        var d = NotesDocument()
        #expect(!d.isDirty && d.isEmpty)
        d.append(.gap(id: 0, offset: 0, reason: "x"))
        #expect(!d.isDirty)
        d.append(NotesSegment(id: 1, offset: 0, raw: "text"))
        #expect(d.isDirty)
        _ = d.exportMarkdown()                    // what Copy does: the dirty flag stays
        #expect(d.isDirty)
        d.markSaved()
        #expect(!d.isDirty)
        d.userEdit(NSRange(location: 0, length: 0), "typed")
        #expect(d.isDirty && d.charsSinceReorganize == 5)
    }
}

/// Splitting rejected windows, fallback blocks and Organize's in-place replacement (orchestrator follow-up on #17).
@Suite struct NotesPiecesTests {
    private let sentence = "This is a sentence about the budget review. "

    @Test func splitsAtTheSentenceEndNearestTheMiddle() throws {
        let text = String(repeating: sentence, count: 24)              // ~1050 chars
        let (a, b) = try #require(NotesDocument.split(text))
        #expect(a.hasSuffix(".") && b.hasPrefix("This is"))
        #expect(a.count >= NotesDocument.minSplitChars && b.count >= NotesDocument.minSplitChars)
        #expect(abs(a.count - b.count) < sentence.count * 2)
        // Too short to split into two parts of the minimum size.
        #expect(NotesDocument.split(String(repeating: sentence, count: 15)) == nil)
        // No sentence end: the nearest space.
        let words = String(repeating: "word ", count: 200)
        let (c, d) = try #require(NotesDocument.split(words))
        #expect(c.hasSuffix("word") && d.hasPrefix("word"))
    }

    @Test func piecesReplaceTheTailInOrderAndSettleIt() throws {
        var d = NotesDocument()
        d.userEdit(NSRange(location: 0, length: 0), "mine")
        d.append(NotesSegment(id: 0, offset: 0, raw: "first half. second half."))
        let r = try #require(d.nextStructureRequest())
        let change = try unwrap(d.applyPieces([.markdown("## A\n- a"), .fallback("second half.")], for: r))
        #expect(d.text == "mine\n\n## A\n- a\n\n" + NotesDocument.fallbackHeader + "\n\nsecond half.")
        #expect(change.kind == .append && d.tail.isEmpty && d.nextStructureRequest() == nil)
        #expect(d.untouchedFallbacks.map(\.body) == ["second half."])
        // A stale request is ignored like any append.
        #expect(d.applyPieces([.markdown("- x")], for: r) == nil)
    }

    @Test func organizeReplacesUntouchedFallbacksInPlaceAndLeavesEditedOnes() throws {
        var d = NotesDocument()
        d.append(NotesSegment(id: 0, offset: 0, raw: "raw one"))
        d.freezeAll()
        d.userEdit(NSRange(location: d.text.utf16.count, length: 0), "\n\n## Mine\n- typed\n\n")
        d.append(NotesSegment(id: 1, offset: 0, raw: "raw two"))
        d.freezeAll()
        #expect(d.untouchedFallbacks.map(\.body) == ["raw one", "raw two"])
        // The user edits the first block: it is theirs now.
        let one = (d.text as NSString).range(of: "raw one")
        d.userEdit(NSRange(location: one.location, length: 3), "RAW")
        #expect(d.untouchedFallbacks.map(\.body) == ["raw two"])
        let before = d.text
        let changes = d.replaceFallbacks(d.untouchedFallbacks.map { ($0.block, [NotesPiece.markdown("- two, structured")]) },
                                         ifVersion: d.version)
        #expect(changes.count == 1 && changes[0].kind == .organize)
        #expect(changes[0].applied(to: before) == d.text)
        #expect(d.text.contains("RAW one") && d.text.hasSuffix("- typed\n\n- two, structured") && d.untouchedFallbacks.isEmpty)
        #expect(d.tailStart == d.text.utf16.count)
    }

    @Test func organizeReplacementsAreVersionChecked() {
        var d = NotesDocument()
        d.append(NotesSegment(id: 0, offset: 0, raw: "raw one"))
        d.freezeAll()
        let blocks = d.untouchedFallbacks
        let version = d.version
        d.userEdit(NSRange(location: 0, length: 0), "x")
        let before = d.text
        #expect(d.replaceFallbacks(blocks.map { ($0.block, [NotesPiece.markdown("- one")]) }, ifVersion: version).isEmpty)
        #expect(d.text == before)
    }

    @Test func severalBlocksReplayInOrder() {
        var d = NotesDocument()
        for i in 0..<3 {
            d.append(NotesSegment(id: i, offset: 0, raw: "raw \(i)"))
            d.freezeAll()
        }
        let before = d.text
        let changes = d.replaceFallbacks(d.untouchedFallbacks.map { ($0.block, [NotesPiece.markdown("- \($0.body)!")]) },
                                         ifVersion: d.version)
        #expect(changes.count == 3)
        #expect(changes.reduce(before) { $1.applied(to: $0) } == d.text)
        #expect(d.text == "- raw 0!\n\n- raw 1!\n\n- raw 2!")
    }

    @Test func failureLabelsCarryOnlyAGuardName() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let s = try decoder.decode(NotesStructureResponse.self, from: Data(#"{"markdown":null,"structured":false,"error":"rejected","reason":"novel_name"}"#.utf8))
        #expect(s.reason == "novel_name" && s.failureLabel == "rejected: novel_name")
        let r = try decoder.decode(NotesReorganizeResponse.self, from: Data(#"{"markdown":null,"reorganized":false,"error":"rejected","reason":"negation"}"#.utf8))
        #expect(r.failureLabel == "rejected: negation")
        #expect(NotesFailure.label(error: "rejected", reason: "Some free text!") == "rejected")
        #expect(NotesFailure.label(error: nil, reason: nil) == "http" && NotesFailure.label(error: "timeout", reason: nil) == "timeout")
        let preempted = try decoder.decode(NotesReorganizeResponse.self, from: Data(#"{"markdown":null,"reorganized":false,"changed":false,"error":"preempted"}"#.utf8))
        #expect(preempted.preempted && !NotesReorganizeResponse.failed("timeout").preempted)
    }

    @Test func crlfTextStillHasSectionsAndStyles() {
        let text = "intro\r\n## A\r\n- a\r\n## B\r\n- b"
        #expect(NotesMarkdown.sections(text).map(\.heading) == [nil, "A", "B"])
        #expect(NotesMarkdown.styleRuns(Substring(text)).contains(NotesStyleRun(NSRange(location: 7, length: 5), .heading(2))))
    }
}
