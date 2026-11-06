import Foundation

/// One committed segment of a Live Notes recording: an ordinary utterance's final, or a gap where it failed.
public struct NotesSegment: Equatable, Sendable, Identifiable, Codable {
    public var id: Int
    /// Seconds from the start of the session to the segment's first audio.
    public var offset: TimeInterval
    public var raw: String
    /// The corrected text, or the raw text when correction was off or failed.
    public var text: String
    public var corrected: Bool
    /// Correction was asked for but did not deliver, so the raw text was kept.
    public var keptOriginal: Bool
    /// Set for a gap: why this stretch of audio was not transcribed.
    public var failure: String?
    /// Who said what (speaker labels on); nil without labels: off, a gap, or no model.
    public var turns: [SpeakerTurn]?
    /// The labels were attached before the diarizer settled this stretch (they waited the maximum time).
    public var labelsTentative = false
    /// Seconds from the start of the session to the end of its audio; nil when not known (older documents, tests).
    public var end: TimeInterval?
    /// The quiet between the previous segment's last speech and this one's first, when it follows that segment
    /// without a break (a cut, not Stop and Record); nil starts a new paragraph.
    public var pauseBefore: TimeInterval?
    /// The speech engine that produced the text (`ready.engine`); nil in notes recorded before it was kept.
    public var engine: String?

    public init(id: Int, offset: TimeInterval, raw: String, text: String? = nil, corrected: Bool = false,
                keptOriginal: Bool = false, failure: String? = nil) {
        self.id = id
        self.offset = offset
        self.raw = raw
        self.text = text ?? raw
        self.corrected = corrected
        self.keptOriginal = keptOriginal
        self.failure = failure
    }

    public static func gap(id: Int, offset: TimeInterval, reason: String) -> NotesSegment {
        NotesSegment(id: id, offset: offset, raw: "", failure: reason)
    }

    public var isGap: Bool { failure != nil }
}

/// Part of a window's notes after the server rejected the whole window and it was split: structured Markdown, or
/// a part that still failed at the smallest size and stays as raw text under the fallback header.
public enum NotesPiece: Equatable, Sendable {
    case markdown(String)
    case fallback(String)
}

/// One change to the notes text, UTF-16 `range` in the text before the change. Every AI mutation returns the change
/// it applied, so the editor can replay exactly that delta onto its text storage.
public struct NotesTextChange: Equatable, Sendable {
    /// `organize`: Organize re-structured fallback blocks in place (one undo group with the rest of its batch).
    public enum Kind: Equatable, Sendable {
        case user, append, reorganize, toggleTask, organize
        /// A speaker rename replaced the old name in the notes (one undo group, "Rename Speaker").
        case rename
        /// A voice edit (#97), one undo group ("Edit by Voice").
        case edit
        /// Restore Notes Before Organize put an earlier text back (one undo step).
        case restore
        /// Re-transcribe's "Also rebuild the notes": the body structured again from the new transcript (one undo step).
        case rebuild
    }

    public var range: NSRange
    public var replacement: String
    public var kind: Kind
    /// A whole-document Organize: every change of one run is one undo step together.
    public var run: Int?

    public init(range: NSRange, replacement: String, kind: Kind, run: Int? = nil) {
        self.range = range
        self.replacement = replacement
        self.kind = kind
        self.run = run
    }

    /// `text` with this change applied.
    public func applied(to text: String) -> String {
        (text as NSString).replacingCharacters(in: range, with: replacement)
    }
}

/// A local notes document. The library journals text and capture metadata continuously; exports are separate.
public struct NotesDocument: Equatable, Sendable, Codable {
    /// The tail settles once a pass succeeded on at least this many transcript characters (from the M1 bench:
    /// longer windows lose guard pass rate on the default Qwen).
    public static let freezeChars = 1600
    /// The open window never grows past this (the server takes up to 6000, but 4000-char windows hit the 768-token
    /// output cap): it is appended as a fallback block instead.
    public static let maxWindowChars = 3600
    /// The most notes one reorganize pass sends (the server's `MAX_REORGANIZE_CHARS`), Unicode scalars.
    public static let maxReorganizeChars = 3500
    /// A scope shorter than this (trimmed) has nothing to reorganize.
    public static let minReorganizeChars = 80
    /// The scope of an automatic reorganize while recording: about 5 s of generation, so it fits between two segment
    /// cuts (a queued segment clean-up preempts it on the server). Stop and the button use the full scope.
    public static let recordingReorganizeChars = 1200
    public static let maxOutlineItems = 24
    public static let maxOutlineItemChars = 120
    public static let maxOutlineChars = 1500
    public static let fallbackHeader = "_Not structured — see transcript_"

    /// This document, as opposed to one that New or a discarded close replaced: a pass carries it, so a late answer
    /// for a discarded document is never applied to the next one.
    public private(set) var id = UUID()
    /// Optional so schema 1 documents continue to decode.
    public internal(set) var libraryMetadata: NotesMetadata?
    public internal(set) var segments: [NotesSegment] = []
    /// The notes, Markdown source, user and AI text (without the `# Notes — date` title export adds).
    public internal(set) var text = ""
    /// UTF-16 offset; `text[tailStart...]` is the AI-owned open block.
    public internal(set) var tailStart = 0
    /// +1 on every change to `text` (user or AI).
    public private(set) var version = 0
    /// +1 whenever the tail is claimed, settles or a reorganize lands: a pass asked for an earlier generation is stale.
    public private(set) var windowGeneration = 0
    /// The first segment index of the open window.
    public private(set) var windowStart = 0
    /// The last segment index the tail covers; below `windowStart` before any pass succeeded in this window.
    public private(set) var structuredEnd = -1
    public private(set) var consecutiveFailures = 0
    /// `version` right after the last applied (or unchanged) reorganize.
    public private(set) var lastReorganizeVersion = 0
    /// UTF-16 units inserted (user or AI) since the last reorganize.
    public private(set) var charsSinceReorganize = 0
    /// Every fallback block the client appended, exactly as appended. One still found verbatim in `text` is one the
    /// user has not edited, which Organize may re-structure in place.
    public internal(set) var fallbackBlocks: [String] = []
    /// The current segment's live partial. Display only: never exported.
    public var livePartial = ""
    /// There is content that was not saved with Save… (Copy does not count).
    public internal(set) var isDirty = false
    public private(set) var startedAt: Date
    /// The people speaker labels found in this document (Person 1, Person 2…).
    public internal(set) var roster = SpeakerRoster()
    /// +1 whenever a committed segment's labels change; the log keeps the newest (revision, segment) pairs, so the
    /// window rebuilds its transcript only from there.
    public var labelRevision: Int { labelLog?.revision ?? 0 }
    /// When each heading was first said: the offset of the first segment of the window its section came from, by
    /// `NotesDocument.headingKey`. A renamed heading loses it; merged headings keep the earliest.
    public internal(set) var sectionOffsets: [String: TimeInterval] {
        get { stamps ?? [:] }
        set { stamps = newValue }
    }
    /// The transcript the last re-transcribe replaced (Undo, Restore previous transcript); nil when there is none.
    /// Optional storage, so older notes decode.
    public internal(set) var previousTranscript: NotesPreviousTranscript?
    /// Optional storage, so a journal written before section times decodes.
    private var stamps: [String: TimeInterval]?
    /// Optional storage too.
    private var labelLog: LabelLog?
    private struct LabelLog: Equatable, Sendable, Codable {
        var revision = 0
        var recent: [Relabel] = []
    }
    private struct Relabel: Equatable, Sendable, Codable { var revision: Int, segment: Int }

    /// What the recovery journal stores: everything but `livePartial` (display only).
    private enum CodingKeys: String, CodingKey {
        case id, segments, text, tailStart, version, windowGeneration, windowStart, structuredEnd, consecutiveFailures
        case lastReorganizeVersion, charsSinceReorganize, fallbackBlocks, isDirty, startedAt, roster
        case stamps = "sectionOffsets", labelLog, libraryMetadata, previousTranscript
    }

    public init(startedAt: Date = Date(), text: String = "") {
        self.startedAt = startedAt
        self.text = text
        tailStart = text.utf16.count
    }

    /// The first recording of an empty document starts now: the title and the Save… name use this time, not
    /// when the (empty) document was created.
    public mutating func stampStart(_ date: Date) {
        guard segments.isEmpty else { return }
        startedAt = date
    }

    /// Nothing to show, copy or save.
    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !segments.contains { !$0.isGap && !$0.text.isEmpty }
    }

    var count: Int { text.utf16.count }
    /// The AI-owned open block.
    public var tail: String { (text as NSString).substring(from: tailStart) }
    /// Everything before the tail: the user's and settled AI text.
    public var settledText: String { (text as NSString).substring(to: tailStart) }

    // MARK: adding content

    /// Commits the next segment (the recorder keeps them in order).
    public mutating func append(_ segment: NotesSegment) {
        var s = segment
        s.id = segments.count
        segments.append(s)
        if !s.isGap, !s.text.isEmpty { isDirty = true }
    }

    public mutating func markSaved() { isDirty = false }

    // MARK: speakers

    /// Labels a committed segment: each turn's diarizer slot becomes a person, numbered by first appearance. Turns
    /// the user reassigned are never changed: they keep their person, and their segment its turns unless the new
    /// ones split the text the same way.
    public mutating func attachSpeakers(_ turns: [SpeakerAttribution.Turn], toSegment id: Int, tentative: Bool = false) {
        guard segments.indices.contains(id), !segments[id].isGap, !turns.isEmpty else { return }
        var labelled = turns.map {
            SpeakerTurn(person: roster.id(forSlot: $0.slot), start: $0.start, text: $0.text, raw: $0.raw,
                        approximate: $0.approximate, keptOriginal: $0.keptOriginal)
        }
        if let old = segments[id].turns, old.contains(where: \.manual) {
            guard old.map(\.text) == labelled.map(\.text) else { return }
            for i in old.indices where old[i].manual { labelled[i] = old[i] }
        }
        segments[id].turns = labelled
        segments[id].labelsTentative = tentative
        relabelled(id)
    }

    /// Labels a committed segment with the server's turns (server-side labels): each turn's slot, in the server's
    /// `generation`, becomes a person numbered by first appearance in transcript order. Turns of one person in a row
    /// are one turn.
    public mutating func attachServerTurns(_ turns: [ServerTurn], generation: String?, toSegment id: Int) {
        guard segments.indices.contains(id), !segments[id].isGap else { return }
        var labelled: [SpeakerTurn] = []
        for t in turns {
            let text = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let raw = t.raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let person = roster.id(forSlot: t.speaker, generation: generation)
            if let last = labelled.last, last.person == person {
                labelled[labelled.count - 1].text += " " + text
                labelled[labelled.count - 1].raw = (last.raw + " " + raw).trimmingCharacters(in: .whitespaces)
            } else {
                labelled.append(SpeakerTurn(person: person, start: segments[id].offset + t.start, text: text, raw: raw,
                                            approximate: t.approximate, keptOriginal: t.keptOriginal))
            }
        }
        guard !labelled.isEmpty else { return }
        segments[id].turns = labelled
        segments[id].labelsTentative = false
        relabelled(id)
    }

    /// Segment `id`'s turns changed: the window rebuilds its transcript from there.
    mutating func relabelled(_ id: Int) {
        isDirty = true
        var log = labelLog ?? LabelLog()
        log.revision += 1
        log.recent.append(Relabel(revision: log.revision, segment: id))
        if log.recent.count > 64 { log.recent.removeFirst(log.recent.count - 64) }
        labelLog = log
    }

    /// The first segment whose labels changed after `revision`: `segments.count` when none did, 0 when that is too
    /// long ago to tell.
    public func firstRelabelled(since revision: Int) -> Int {
        guard revision < labelRevision else { return segments.count }
        guard let recent = labelLog?.recent, let oldest = recent.first, oldest.revision <= revision + 1 else { return 0 }
        return recent.filter { $0.revision > revision }.map(\.segment).min() ?? segments.count
    }

    /// A recovered document's new diarizer starts with its own slots: keep the people, forget which slot was whom.
    public mutating func forgetSpeakerSlots() { roster.forgetSlots() }

    /// The diarizer slot of the last labelled turn, for words the diarizer never placed.
    public var lastSpeakerSlot: Int? {
        segments.last { $0.turns?.isEmpty == false }?.turns?.last.flatMap { roster.slot(for: $0.person) }
    }

    /// People heard so far (after merges).
    public var speakerCount: Int {
        Set(segments.flatMap { $0.turns ?? [] }.map { roster.resolve($0.person) }).count
    }

    /// A segment's text as passes see it: one `Person 2: …` line per turn when labelled, else the text.
    public func labelledText(_ s: NotesSegment, separator: String = "\n") -> String {
        guard let turns = s.turns?.filter({ !$0.text.isEmpty }), !turns.isEmpty else { return s.text }
        return turns.map { roster.displayName($0.person) + ": " + $0.text }.joined(separator: separator)
    }

    // MARK: user edits

    /// The editor changed its text storage (typing, paste, undo/redo, a task toggle). Applies the edit and moves the
    /// tail: an edit wholly before it shifts it; an edit that touches a non-empty tail claims it, so the whole tail
    /// becomes user text and the next pass starts a new, empty tail after it. Typing at the end of the user's own last
    /// line (an insertion at `tailStart`, where the tail starts with its separator newline) only shifts it.
    @discardableResult
    public mutating func userEdit(_ range: NSRange, _ replacement: String, kind: NotesTextChange.Kind = .user) -> NotesTextChange {
        let change = NotesTextChange(range: range, replacement: replacement, kind: kind)
        let claims = touchesTail(range)
        text = change.applied(to: text)
        if claims {
            settleTail()
            consecutiveFailures = 0
        } else {
            tailStart += replacement.utf16.count - range.length
        }
        changed(inserted: replacement.utf16.count)
        return change
    }

    /// Whether an edit of `range` would claim the tail (and so whether an append would land under a caret there).
    public func touchesTail(_ range: NSRange) -> Bool {
        guard tailStart < count else { return false }
        if range.upperBound > tailStart { return true }
        // An insertion right before the separator extends the user's line; right before AI text, it edits the tail.
        return range.location == tailStart && range.length == 0 && (text as NSString).character(at: tailStart) != 10
    }

    /// Toggles the task box on `line` (0-based) as a user edit; nil when that line is not a task.
    @discardableResult
    public mutating func toggleTask(atLine line: Int) -> NotesTextChange? {
        let ns = text as NSString
        var location = 0
        for _ in 0..<line {
            let r = ns.range(of: "\n", range: NSRange(location: location, length: ns.length - location))
            guard r.location != NSNotFound else { return nil }
            location = r.upperBound
        }
        let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
        let boxAt = (ns.substring(with: lineRange) as NSString).range(of: "[").location
        guard boxAt != NSNotFound, let toggle = NotesMarkdown.taskToggle(text, at: lineRange.location + boxAt) else { return nil }
        return userEdit(toggle.range, toggle.replacement, kind: .toggleTask)
    }

    mutating func changed(inserted: Int) {
        version += 1
        charsSinceReorganize += inserted
        isDirty = true
    }

    /// Everything is settled and the open window starts at segment `start` (a rebuilt body covers what is before it).
    mutating func resetWindow(to start: Int) {
        windowStart = start
        structuredEnd = start - 1
        consecutiveFailures = 0
        windowGeneration += 1
    }

    /// The tail becomes settled text: the window moves past what it covered, so those segments are never re-sent,
    /// and segments no pass structured yet stay in the window for the next one.
    private mutating func settleTail() {
        tailStart = count
        if structuredEnd >= windowStart { windowStart = structuredEnd + 1 }
        windowGeneration += 1
    }

    // MARK: the open window

    /// The open window's segments that carry text.
    var windowSegments: [NotesSegment] {
        guard windowStart < segments.count else { return [] }
        return segments[windowStart...].filter { !$0.isGap && !$0.text.isEmpty }
    }

    /// The open window's transcript as a pass sends it (segments joined with newlines, a labelled segment one
    /// `Person 2: …` line per turn), up to segment index `end`.
    func windowTranscript(through end: Int? = nil) -> String {
        windowSegments.filter { $0.id <= (end ?? Int.max) }.map { labelledText($0) }.joined(separator: "\n")
    }

    /// Transcript characters in the open window as sent, up to segment index `end` (all of it when nil).
    public func windowChars(through end: Int? = nil) -> Int { windowTranscript(through: end).count }

    /// The window's text that no pass has structured yet: the start of the Hearing strip.
    public var unstructuredTail: String {
        windowSegments.filter { $0.id > structuredEnd }.map(\.text).joined(separator: " ")
    }

    /// `unstructuredTail` by speaker: each labelled turn with its person (after merges), unlabelled segments with nil.
    public var unstructuredParts: [(person: Int?, text: String)] {
        windowSegments.filter { $0.id > structuredEnd }.flatMap { s -> [(person: Int?, text: String)] in
            guard let turns = s.turns, !turns.isEmpty else { return [(nil, s.text)] }
            return turns.map { (roster.resolve($0.person), $0.text) }
        }
    }

    /// The headings (levels 1–3) of the settled text, oldest first.
    public var headings: [String] { NotesMarkdown.headings(settledText) }

    /// The outline sent with a pass: the newest headings, each at most 120 chars, at most 24 and 1500 chars in all.
    public var outline: [String] { Self.capOutline(headings) }

    static func capOutline(_ headings: [String]) -> [String] {
        var items = headings.suffix(maxOutlineItems).map { String($0.prefix(maxOutlineItemChars)) }
        while items.reduce(0, { $0 + $1.count }) > maxOutlineChars { items.removeFirst() }
        return items
    }

    /// The next pass, or nil when the open window has no text a successful pass has not already seen. Never over
    /// `maxWindowChars`: an oversize window returns nil until `freezeOverflow()` has settled it.
    public func nextStructureRequest(final: Bool = false) -> NotesStructureRequest? {
        let window = windowSegments
        guard let last = window.last, last.id > structuredEnd else { return nil }
        let transcript = windowTranscript()
        guard transcript.count <= Self.maxWindowChars,
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return NotesStructureRequest(transcript: transcript, outline: outline, final: final, windowEnd: segments.count - 1,
                                     version: version, windowGeneration: windowGeneration, documentID: id)
    }

    /// Takes a pass's answer. A success replaces the tail (separator included) and settles it once the window is long
    /// enough; a failure keeps the previous tail. Either way the window is appended as a fallback when it grows too
    /// long or keeps failing, so the session never wedges. A response for a tail that was claimed, settled or
    /// reorganized since is ignored: its segments are still in the window, so the next pass re-sends them. Returns
    /// the text change it made, if any.
    @discardableResult
    public mutating func apply(_ response: NotesStructureResponse, for request: NotesStructureRequest) -> NotesTextChange? {
        guard request.documentID == id, request.windowGeneration == windowGeneration, request.windowEnd >= windowStart,
              request.windowEnd < segments.count, request.windowEnd > structuredEnd else { return nil }
        return recordingChange(.append) { d in
            if response.structured, let md = response.markdown?.trimmingCharacters(in: .whitespacesAndNewlines), !md.isEmpty {
                d.stampSections(md)
                d.replaceTail(with: md)
                d.structuredEnd = request.windowEnd
                d.consecutiveFailures = 0
                if d.windowChars(through: request.windowEnd) >= Self.freezeChars { d.settleTail() }
            } else {
                d.consecutiveFailures += 1
            }
            d.overflow()
        }
    }

    /// The separator between the settled text and the tail's Markdown: none at the start or after a blank line.
    var tailSeparator: String {
        let settled = settledText
        if settled.isEmpty || settled.hasSuffix("\n\n") { return "" }
        return settled.hasSuffix("\n") ? "\n" : "\n\n"
    }

    private mutating func replaceTail(with markdown: String) {
        text = settledText + tailSeparator + markdown
    }

    /// When the window is past `maxWindowChars`, or past `freezeChars` after two failures in a row: the tail settles,
    /// and only a remainder that still qualifies on its own is appended as a fallback. Text that no pass has been
    /// tried on is otherwise left for the next pass.
    @discardableResult
    public mutating func freezeOverflow() -> NotesTextChange? { recordingChange(.append) { $0.overflow() } }

    private mutating func overflow() {
        func qualifies(_ chars: Int) -> Bool {
            chars > Self.maxWindowChars || (consecutiveFailures >= 2 && chars >= Self.freezeChars)
        }
        guard qualifies(windowChars()) else { return }
        settleTail()
        guard qualifies(windowChars()) else { return }
        appendFallback()
        consecutiveFailures = 0
    }

    /// At Stop, after the final pass: the tail settles, and with structuring on, whatever it did not cover is
    /// appended as a fallback. Recording again continues the same document with a new, empty tail at the end.
    @discardableResult
    public mutating func freezeAll(structuring: Bool = true) -> NotesTextChange? {
        recordingChange(.append) { d in
            if structuring { d.keepWordsOverPlaceholder() }
            d.settleTail()
            if structuring { d.appendFallback() }
            d.consecutiveFailures = 0
        }
    }

    /// A finished note never reads "(nothing yet)" when words were heard: when the passes judged the whole open window
    /// not substantive (a few words, a test phrase), its tail is only the placeholder, and Stop puts the window's own
    /// words there instead (labelled when more than one person spoke). Nothing changes while recording, or when the
    /// window had no words.
    private mutating func keepWordsOverPlaceholder() {
        guard tail.trimmingCharacters(in: .whitespacesAndNewlines) == NotesMarkdown.placeholder else { return }
        let covered = windowSegments.filter { $0.id <= structuredEnd }
        let labelled = speakerCount > 1
        let words = covered.map { labelled ? labelledText($0, separator: "\n\n") : $0.text }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return }
        replaceTail(with: words.joined(separator: "\n\n"))
    }

    /// The window's corrected text under "Not structured — see transcript", as ordinary (user-editable) text.
    private mutating func appendFallback() {
        let rest = windowSegments
        if !rest.isEmpty {
            // Labelled, one paragraph per turn, so the text and an Organize pass over it keep who said what.
            let block = Self.fallbackBlock(rest.map { labelledText($0, separator: "\n\n") }.joined(separator: "\n\n"))
            fallbackBlocks.append(block)
            text = settledText + tailSeparator + block
        }
        windowStart = segments.count
        structuredEnd = windowStart - 1
        settleTail()
    }

    /// Runs `body` (AI mutations, which only ever change a suffix) and returns the minimal change it made to `text`,
    /// bumping `version` and the inserted count once.
    private mutating func recordingChange(_ kind: NotesTextChange.Kind, _ body: (inout NotesDocument) -> Void) -> NotesTextChange? {
        let before = text
        body(&self)
        guard let change = Self.diff(before, text, kind: kind) else { return nil }
        changed(inserted: change.replacement.utf16.count)
        return change
    }

    /// The smallest single replacement that turns `old` into `new` (common prefix and suffix trimmed).
    public static func diff(_ old: String, _ new: String, kind: NotesTextChange.Kind) -> NotesTextChange? {
        guard old != new else { return nil }
        let a = Array(old.utf16), b = Array(new.utf16)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        // Never split a surrogate pair: back off to whole characters.
        func splits(_ u: [UTF16.CodeUnit], at i: Int) -> Bool { i < u.count && UTF16.isTrailSurrogate(u[i]) }
        while prefix > 0, splits(a, at: prefix) || splits(b, at: prefix) { prefix -= 1 }
        while suffix > 0, splits(a, at: a.count - suffix) || splits(b, at: b.count - suffix) { suffix -= 1 }
        let replacement = String(decoding: b[prefix..<(b.count - suffix)], as: UTF16.self)
        return NotesTextChange(range: NSRange(location: prefix, length: a.count - suffix - prefix), replacement: replacement, kind: kind)
    }

    // MARK: split windows and fallback blocks

    /// The smallest part a rejected window is split into.
    public static let minSplitChars = 400

    public static func fallbackBlock(_ body: String) -> String { fallbackHeader + "\n\n" + body }

    /// Pieces as notes text: the Markdown parts and the fallback blocks, a blank line apart.
    public static func render(_ pieces: [NotesPiece]) -> String {
        pieces.map { piece -> String in
            switch piece {
            case .markdown(let md): md.trimmingCharacters(in: .whitespacesAndNewlines)
            case .fallback(let body): fallbackBlock(body.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Splits `text` in two at the sentence end nearest its middle (else the nearest space), each part at least
    /// `minPart` characters; nil when it is too short to split.
    public static func split(_ text: String, minPart: Int = minSplitChars) -> (String, String)? {
        let chars = Array(text)
        guard chars.count >= 2 * minPart else { return nil }
        let middle = chars.count / 2
        func cut(_ isBoundary: (Int) -> Bool) -> Int? {
            (minPart...(chars.count - minPart)).filter(isBoundary).min { abs($0 - middle) < abs($1 - middle) }
        }
        let sentence = cut { i in
            chars[i].isWhitespace && (chars[i - 1] == "." || chars[i - 1] == "?" || chars[i - 1] == "!" || chars[i - 1] == "\n")
        }
        guard let at = sentence ?? cut({ chars[$0].isWhitespace }) else { return nil }
        let a = String(chars[..<at]).trimmingCharacters(in: .whitespacesAndNewlines)
        let b = String(chars[at...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return a.isEmpty || b.isEmpty ? nil : (a, b)
    }

    /// Takes the parts of a window that was split after a rejection: they replace the tail in order (a part that
    /// still failed as a fallback block), and the tail settles, so that text is never sent again as one window.
    @discardableResult
    public mutating func applyPieces(_ pieces: [NotesPiece], for request: NotesStructureRequest) -> NotesTextChange? {
        guard request.documentID == id, request.windowGeneration == windowGeneration, request.windowEnd >= windowStart,
              request.windowEnd < segments.count, request.windowEnd > structuredEnd, !pieces.isEmpty else { return nil }
        return recordingChange(.append) { d in
            d.stampSections(Self.render(pieces))
            d.replaceTail(with: Self.render(pieces))
            for case .fallback(let body) in pieces {
                d.fallbackBlocks.append(Self.fallbackBlock(body.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            d.structuredEnd = request.windowEnd
            d.consecutiveFailures = 0
            d.settleTail()
            d.overflow()
        }
    }

    /// The fallback blocks still in the text exactly as appended, with the raw text under each header.
    public var untouchedFallbacks: [(block: String, body: String)] {
        fallbackBlocks.filter { text.contains($0) }.map { ($0, String($0.dropFirst(Self.fallbackHeader.count + 2))) }
    }

    /// Organize: each untouched fallback block replaced in place by its re-structured pieces, only when the text is
    /// still exactly `version`. Returns the changes in the order to replay them (one undo group); empty when nothing
    /// applied.
    public mutating func replaceFallbacks(_ replacements: [(block: String, pieces: [NotesPiece])], ifVersion expected: Int)
        -> [NotesTextChange] {
        guard version == expected else { return [] }
        var located: [(range: NSRange, block: String, pieces: [NotesPiece])] = []
        for r in replacements {
            let found = (text as NSString).range(of: r.block)
            if found.location != NSNotFound { located.append((found, r.block, r.pieces)) }
        }
        // From the end backwards, so every range is still where it was found when its change is replayed.
        var changes: [NotesTextChange] = []
        var inserted = 0
        for item in located.sorted(by: { $0.range.location > $1.range.location }) {
            let change = NotesTextChange(range: item.range, replacement: Self.render(item.pieces), kind: .organize)
            text = change.applied(to: text)
            let delta = change.replacement.utf16.count - item.range.length
            if NSMaxRange(item.range) <= tailStart { tailStart += delta } else { settleTail() }
            fallbackBlocks.removeAll { $0 == item.block }
            for case .fallback(let body) in item.pieces {
                fallbackBlocks.append(Self.fallbackBlock(body.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            inserted += change.replacement.utf16.count
            changes.append(change)
        }
        if !changes.isEmpty { changed(inserted: inserted) }
        return changes
    }

    // MARK: reorganize

    /// What a reorganize pass may rewrite: the longest suffix of whole sections within `maxChars` (Unicode scalars),
    /// and the headings above it (context only). Nil when even the last section is too long, or the scope is under
    /// `minReorganizeChars`. Sections before the scope are settled and never change.
    public func reorganizeScope(maxChars: Int = maxReorganizeChars) -> (range: NSRange, outline: [String])? {
        let ns = text as NSString
        let sections = NotesMarkdown.sections(text)
        var start = ns.length, chars = 0
        for section in sections.reversed() {
            let size = ns.substring(with: section.range).unicodeScalars.count
            guard chars + size <= maxChars else { break }
            chars += size
            start = section.range.location
        }
        let range = NSRange(location: start, length: ns.length - start)
        guard range.length > 0,
              ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).count >= Self.minReorganizeChars else { return nil }
        let outline = start == 0 ? [] : Self.capOutline(NotesMarkdown.headings(ns.substring(to: start)))
        return (range, outline)
    }

    /// The last section alone is over `maxReorganizeChars`, so nothing can be reorganized until it is split.
    public var reorganizeTooLong: Bool {
        guard let last = NotesMarkdown.sections(text).last else { return false }
        return (text as NSString).substring(with: last.range).unicodeScalars.count > Self.maxReorganizeChars
    }

    /// The next reorganize, or nil when the scope is empty or (unless `manual`) nothing changed since the last one.
    public func reorganizeRequest(final: Bool, manual: Bool, maxChars: Int = maxReorganizeChars) -> NotesReorganizeRequest? {
        guard manual || version != lastReorganizeVersion, let scope = reorganizeScope(maxChars: maxChars) else { return nil }
        let notes = (text as NSString).substring(with: scope.range)
        return NotesReorganizeRequest(notes: notes, outline: scope.outline, final: final, version: version, range: scope.range,
                                      documentID: id)
    }

    /// Takes a reorganize answer, only when the text is exactly what the request was made from (`version`). A changed
    /// result replaces the scope and settles everything; an unchanged one only counts as done. Returns the change, or
    /// nil (and the caller records a conflict when `version` moved).
    @discardableResult
    public mutating func applyReorganize(_ response: NotesReorganizeResponse, for request: NotesReorganizeRequest) -> NotesTextChange? {
        guard request.documentID == id, request.version == version, NSMaxRange(request.range) <= count,
              response.reorganized else { return nil }
        guard response.changed, let md = response.markdown?.trimmingCharacters(in: .whitespacesAndNewlines), !md.isEmpty else {
            lastReorganizeVersion = version
            charsSinceReorganize = 0
            return nil
        }
        let old = (text as NSString).substring(with: request.range)
        // Keep the blank lines that frame the scope, so the sections around it stay separated as they were.
        let lead = String(old.prefix { $0.isNewline })
        let trail = String(old.reversed().prefix { $0.isWhitespace }.reversed())
        let change = NotesTextChange(range: request.range, replacement: lead + md + trail, kind: .reorganize)
        text = change.applied(to: text)
        settleTail()
        changed(inserted: change.replacement.utf16.count)
        lastReorganizeVersion = version
        charsSinceReorganize = 0
        return change
    }

    /// Organize's merge pass: the answer replaces the first section and the other sections it was sent with go, only
    /// when the text is exactly what the request was made from. The changes in replay order (from the end back), or
    /// empty (unchanged, failed or stale).
    public mutating func applyMerge(_ response: NotesReorganizeResponse, for request: NotesReorganizeRequest, run: Int?) -> [NotesTextChange] {
        guard request.documentID == id, request.version == version, response.reorganized,
              ([request.range] + request.merged).allSatisfy({ NSMaxRange($0) <= count }) else { return [] }
        guard response.changed, let md = response.markdown?.trimmingCharacters(in: .whitespacesAndNewlines), !md.isEmpty else {
            lastReorganizeVersion = version
            return []
        }
        let ns = text as NSString
        let old = ns.substring(with: request.range)
        let trail = String(old.reversed().prefix { $0.isWhitespace }.reversed())
        var changes: [NotesTextChange] = []
        for r in request.merged.sorted(by: { $0.location > $1.location }) {
            changes.append(NotesTextChange(range: r, replacement: "", kind: .reorganize, run: run))
        }
        changes.append(NotesTextChange(range: request.range, replacement: md + (trail.isEmpty ? "\n\n" : trail), kind: .reorganize, run: run))
        for c in changes { text = c.applied(to: text) }
        settleTail()
        changed(inserted: md.utf16.count)
        lastReorganizeVersion = version
        charsSinceReorganize = 0
        return changes
    }

    // MARK: export

    /// `[hh:mm:ss]` from the session start.
    public static func timestamp(_ offset: TimeInterval) -> String {
        let s = max(0, Int(offset.rounded(.down)))
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }

    private static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = format
        return f
    }

    public func title(timeZone: TimeZone = .current) -> String {
        "# Notes — " + Self.formatter("yyyy-MM-dd HH:mm", timeZone).string(from: startedAt)
    }

    /// `Chirp Notes 2026-10-20 1403.md`.
    public func suggestedFileName(timeZone: TimeZone = .current) -> String {
        "Chirp Notes " + Self.formatter("yyyy-MM-dd HHmm", timeZone).string(from: startedAt) + ".md"
    }

    /// The notes body: `text` without placeholder lines, trimmed.
    public var notesBody: String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.trimmingCharacters(in: .whitespaces) != NotesMarkdown.placeholder }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One line per paragraph (`transcriptParagraphs`): `**[00:00:12]** text`, gaps and "kept original" marked. `raw`
    /// swaps in the raw text. A labelled paragraph names its person: `**[00:01:12] Person 1:** text`.
    public func transcriptLines(raw: Bool = false) -> [String] {
        transcriptParagraphs.map { p in
            let time = "[\(Self.timestamp(p.offset))]"
            if let failure = p.failure { return "**\(time)** ⚠︎ audio not transcribed (\(failure))" }
            let stamp = p.person.map { "**\(time) \(roster.displayName($0)):** " } ?? "**\(time)** "
            return stamp + p.parts.map { ($0.text(raw)) + ($0.keptOriginal && !raw ? " _(kept original)_" : "") }.joined(separator: " ")
        }
    }

    public func transcriptMarkdown(raw: Bool = false) -> String {
        // A blank line between paragraphs, so Markdown renderers keep them apart.
        (["## Transcript"] + transcriptLines(raw: raw)).joined(separator: "\n\n")
    }

    /// Save…'s format: the title, the notes (whoever wrote them), then the transcript appendix. With no notes (or
    /// `includeNotes` false: Copy on the Transcript tab) only the transcript section follows the title.
    public func exportMarkdown(includeNotes: Bool = true, includeTranscript: Bool = true, timeZone: TimeZone = .current) -> String {
        var parts = [title(timeZone: timeZone)]
        let body = includeNotes ? notesBody : ""
        if !body.isEmpty { parts.append(body) }
        if includeTranscript || body.isEmpty {
            if !body.isEmpty { parts.append("---") }
            parts.append(transcriptMarkdown())
        }
        return parts.joined(separator: "\n\n") + "\n"
    }
}

// Capture boundaries also invalidate any outstanding AI window.
extension NotesDocument {
    /// A new capture, including Continue. Pausing/resuming inside a capture does not add a boundary.
    public mutating func beginCapture(at date: Date = Date(), offset: TimeInterval) {
        windowGeneration += 1
        ensureMetadata()
        libraryMetadata?.sessions.append(NotesCaptureBoundary(startedAt: date, offset: offset, firstSegment: segments.count))
        libraryMetadata?.updatedAt = date
    }
}
