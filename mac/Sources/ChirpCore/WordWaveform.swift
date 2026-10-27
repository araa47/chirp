import Foundation

/// The input levels of the whole utterance, one per captured frame, on the HUD's bar scale (0…1). Frame `i` covers
/// `i * frameDuration ..< (i + 1) * frameDuration` seconds from the first sample sent, which is also the server's time
/// origin for word timings, so a word's span maps straight onto a slice of these.
public struct UtteranceLevels: Equatable, Sendable {
    /// One 50 ms PCM frame per level (`PCMConverter.frameBytes`).
    public static let frameDuration = 0.05
    public private(set) var samples: [Float] = []

    public init() {}
    public init(samples: [Float]) { self.samples = samples }

    public var duration: Double { Double(samples.count) * Self.frameDuration }
    public var isEmpty: Bool { samples.isEmpty }

    /// RMS 0...1 to a bar height 0...1 on a decibel scale: -50 dBFS and below is 0, -14 dBFS and above is 1 (speech
    /// sits around -35...-15 dBFS, so a linear RMS would barely move the bars).
    public static func normalize(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(1, max(0, (db + 50) / 36))
    }

    public mutating func push(rms: Float) { samples.append(Self.normalize(rms: rms)) }
    public mutating func clear() { samples.removeAll() }

    /// `count` bars across `start..<end` seconds: each bar is the peak of the frames it covers (so short bursts stay
    /// visible), 0 where there is no frame yet. A span narrower than a frame still gets its frame.
    public func bars(from start: Double, to end: Double, count: Int) -> [Float] {
        guard count > 0 else { return [] }
        let first = max(0, Int((start / Self.frameDuration).rounded(.down)))
        var last = Int((end / Self.frameDuration).rounded(.up))
        if last <= first { last = first + 1 }
        let frames = samples.indices.contains(first) ? Array(samples[first..<min(last, samples.count)]) : []
        guard !frames.isEmpty else { return Array(repeating: 0, count: count) }
        return (0..<count).map { bar in
            let lo = frames.count * bar / count
            let hi = max(lo + 1, frames.count * (bar + 1) / count)
            return frames[lo..<min(hi, frames.count)].max() ?? 0
        }
    }

    /// The loudest level inside `start..<end` (0 when nothing was captured there yet).
    public func peak(from start: Double, to end: Double) -> Float { bars(from: start, to: end, count: 1).first ?? 0 }
}

/// One word of the live transcript with the audio it came from, ready for the HUD to draw above the word.
public struct WordCell: Equatable, Sendable, Identifiable {
    /// The word's position in the utterance; a revised word keeps its position, so the HUD can crossfade it in place.
    public var id: Int
    public var text: String
    /// Seconds from the utterance's first sample.
    public var start: Double
    public var end: Double
    /// Later partials leave this word alone: its bars settle to the solid colour.
    public var stable: Bool
    /// Silence between the previous word and this one, in seconds (0 for the first word).
    public var gapBefore: Double

    public init(id: Int, text: String, start: Double, end: Double, stable: Bool = false, gapBefore: Double = 0) {
        self.id = id
        self.text = text
        self.start = start
        self.end = end
        self.stable = stable
        self.gapBefore = gapBefore
    }

    public var duration: Double { max(0, end - start) }
}

/// Builds the word cells the HUD's word waveform shows from the server's word timings, and trims them for long
/// dictation. Pure, so the alignment is unit-tested and the snapshots show real layouts.
public enum WordWaveform {
    /// The most characters of transcript laid out as word cells: a bound on layout work, like `HUDText.lineBudget`. It is
    /// about ten rows at 440 pt, well above the HUD's viewport (three rows and the words of a fourth), so the cut stays out of view.
    public static let characterLimit = 600
    /// A pause shorter than this is drawn as the ordinary word gap.
    public static let silenceThreshold = 0.3

    /// Cells for the transcript `text` and its `words`. The server aligns them (joining the word texts with spaces gives
    /// the text), so the words carry the shown text; if they disagree in count the server's words win, since only they
    /// have spans. Without words (an old server, the ONNX engine) there is nothing to draw: the HUD shows plain text.
    public static func cells(text: String, words: [WordTiming]?) -> [WordCell] {
        guard let words, !words.isEmpty else { return [] }
        let shown = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var cells: [WordCell] = []
        var previousEnd = 0.0
        for (i, word) in words.enumerated() {
            let label = shown.count == words.count ? shown[i] : word.text
            let start = max(word.start, 0), end = max(word.end, start)
            let gap = i == 0 ? 0 : max(0, start - previousEnd)
            cells.append(WordCell(id: i, text: label, start: start, end: end, stable: word.stable, gapBefore: gap))
            previousEnd = max(previousEnd, end)
        }
        return cells
    }

    /// Long dictation keeps only the newest words (the live end is what matters): drops whole words from the front
    /// until at most `limit` characters remain, and says whether anything was dropped so the HUD can mark the cut.
    public static func tail(_ cells: [WordCell], limit: Int = characterLimit) -> (cells: [WordCell], truncated: Bool) {
        var total = cells.reduce(0) { $0 + $1.text.count + 1 }
        var first = 0
        while first < cells.count - 1, total > limit {
            total -= cells[first].text.count + 1
            first += 1
        }
        guard first > 0 else { return (cells, false) }
        var kept = Array(cells[first...])
        kept[0].gapBefore = 0
        return (kept, true)
    }

    /// Applies a newer transcript to the cells on screen. Ids are positions, so unchanged words do not move and a
    /// revised word (same position, new text) is replaced in place and reported, for the HUD's in-place crossfade;
    /// new words at the end are additions, not revisions.
    public static func revised(_ old: [WordCell], to new: [WordCell]) -> (changed: Set<Int>, cells: [WordCell]) {
        let before = Dictionary(old.map { ($0.id, $0.text) }, uniquingKeysWith: { a, _ in a })
        let changed = Set(new.compactMap { cell in before[cell.id].flatMap { $0 != cell.text ? cell.id : nil } })
        return (changed, new)
    }
}
