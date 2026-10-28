import AppKit
import ChirpCore
import Observation
import SwiftUI

/// What the leading symbol of the HUD shows: the live waveform while listening, otherwise the outcome.
public enum HUDIndicator: Equatable, Sendable {
    case waveform, success, clipboard, warning, none
    /// Clean-up is running or just finished: a sparkle, which moves unless Reduce Motion is on.
    case sparkle

    var symbol: (name: String, label: String)? {
        switch self {
        case .waveform, .none, .sparkle: nil
        case .success: ("checkmark.circle.fill", "Done")
        case .clipboard: ("doc.on.clipboard.fill", "Copied")
        case .warning: ("exclamationmark.triangle.fill", "Problem")
        }
    }
}

/// The HUD's short status wording, in one place so the controller, the snapshots and the tests agree.
public enum HUDStatus {
    public static let connecting = "Connecting…"
    public static let listening = "Listening…"
    public static let finishing = "Finishing…"
    public static let polishing = "Polishing…"
    public static let polished = "Polished"
    public static let inserting = "Inserting…"
    public static let noSpeech = "No speech detected"
    /// Appended to the outcome when auto-Return pressed Return.
    public static let returnSent = " · ↵ sent"
}

@MainActor @Observable
public final class HUDModel {
    public var status = ""
    public var privateSession = false
    public var duration: String?
    public var stable = ""
    public var unstable = ""
    /// Recent input levels for the waveform, newest last.
    public var levels = LevelHistory()
    /// The word waveform (Settings → Dictation): each word's audio drawn above it. Off keeps the HUD as it always was.
    public var wordWaveform = false
    /// Every level of the utterance so far, kept only while the word waveform is on.
    public var utterance = UtteranceLevels()
    /// The words on screen with their audio spans (empty without timings: the plain text shows instead).
    public var wordCells: [WordCell] = []
    /// Words whose text was revised by the latest partial, for the brief in-place crossfade.
    public var revisedWords: Set<Int> = []
    /// Older words were dropped from the front of a long dictation.
    public var wordsTruncated = false
    /// A fixed pulse position (0...1) for the current word in the snapshots; nil lets it run on the clock.
    public var pulsePhase: Double?
    public var indicator: HUDIndicator = .waveform
    public var debugRetention = false
    public var isError = false
    public var showUseRaw = false
    /// The inserted text was rewritten by the server's clean-up.
    public var cleaned = false
    /// The clean-up style in use ("Email"), shown as a small chip.
    public var styleName: String?
    /// The raw transcript is on screen as solid text while clean-up runs: a shimmer sweeps across it.
    public var polishing = false
    /// A fixed shimmer position (0...1) for the snapshots; nil lets the shimmer run on the clock.
    public var shimmerPhase: Double?
    /// The brief highlight of what clean-up changed, in reading order; nil outside that moment.
    public var diff: [WordDiff.Segment]?
    /// How far the removed words have faded, 0 (struck through, fully visible) to 1 (gone).
    public var diffFade = 0.0
    /// Clean-up did not deliver, so the raw transcript was kept: a small "kept original" note.
    public var keptOriginal = false
    /// System display options, read each time the HUD is shown.
    public var reduceMotion = false
    public var increaseContrast = false
    /// Draws an opaque stand-in for the blur: used for Increase Contrast and the offscreen snapshots, which have no
    /// window to blur through. The live panel's translucency is an `NSVisualEffectView` behind this view.
    public var flatSurface = false
    /// The live panel draws `.glassEffect()` (macOS 26); the controller sets it where the system has it.
    public var usesGlass = false
    public var onUseRaw: (() -> Void)?

    public init() {}

    public func pushLevel(_ rms: Float) {
        levels.push(rms: rms)
        if wordWaveform { utterance.push(rms: rms) }
    }

    /// A partial (or the raw transcript at `correcting`) with its word timings: lays the words out above their audio.
    /// Without timings the cells clear and the plain text shows, so an old server or the ONNX engine degrade gracefully.
    public func showWords(text: String, words: [WordTiming]?) {
        guard wordWaveform else { return }
        let trimmed = WordWaveform.tail(WordWaveform.cells(text: text, words: words))
        let (changed, cells) = WordWaveform.revised(wordCells, to: trimmed.cells)
        if reduceMotion {
            wordCells = cells; revisedWords = changed; wordsTruncated = trimmed.truncated
        } else {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                wordCells = cells; revisedWords = changed; wordsTruncated = trimmed.truncated
            }
        }
    }

    /// The uncorrected final arrived: its words are the whole utterance, settled, shown until the HUD fades.
    public func finishWords(text: String, words: [WordTiming]) {
        showWords(text: text, words: words.map { WordTiming(text: $0.text, start: $0.start, end: $0.end, stable: true) })
        revisedWords = []
        polishing = false
        diff = nil
        diffFade = 0
        stable = text
        unstable = ""
    }

    /// Whether the word waveform draws instead of the plain transcript right now.
    public var showsWordWaveform: Bool { wordWaveform && !wordCells.isEmpty && diff == nil }

    /// Clean-up started: the raw transcript stays on screen as solid text with a shimmer and the "Polishing…" status.
    /// With the word waveform on, the raw words keep their audio (`words` is the final decode's timing) and settle,
    /// since the cleaned text cannot map onto the audio word for word: the ribbon fades out when the cleaned text lands.
    public func beginPolishing(raw: String, style: String?, words: [WordTiming]? = nil) {
        if let style { styleName = style }
        status = HUDStatus.polishing
        indicator = .sparkle
        isError = false
        stable = raw
        unstable = ""
        if wordWaveform {
            if let words {
                showWords(text: raw, words: words)
            } else if !raw.hasSuffix(wordCells.map(\.text).joined(separator: " ")) {
                // The final decode reworded the live words and brought no timings: nothing honest to draw.
                wordCells = []
            }
            // The audio is complete: every word settles.
            wordCells = wordCells.map { var c = $0; c.stable = true; return c }
            revisedWords = []
        }
        withAnimation(.easeInOut(duration: 0.2)) { polishing = true }
    }

    /// The change highlight still playing; settling or resetting cancels it, so it never lands on the next dictation.
    @ObservationIgnored private var highlightTask: Task<Void, Never>?

    /// The cleaned text arrived: crossfade to it with the changes highlighted (removed words struck through and fading,
    /// changed words tinted) for `OutcomePresentation.highlightDuration`, then settle on the plain cleaned text.
    /// Without a usable diff (or nothing changed) it is a plain crossfade. Reduce Motion shows the highlight without the fade.
    /// Returns at once with the highlight running: the text is inserted while it plays, never after it.
    @discardableResult
    public func startChangeHighlight(raw: String, cleaned: String) -> Task<Void, Never> {
        highlightTask?.cancel()
        let segments = WordDiff.segments(raw: raw, cleaned: cleaned)
        status = HUDStatus.polished
        indicator = .sparkle
        if let segments {
            diffFade = 0
            withAnimation(.easeInOut(duration: 0.22)) { polishing = false; diff = segments }
        }
        let reduceMotion = reduceMotion
        let task = Task { [weak self] in
            func pause(_ seconds: Double) async -> Bool {
                (try? await Task.sleep(for: .seconds(seconds))) != nil
            }
            if segments != nil {
                let total = OutcomePresentation.highlightDuration
                if reduceMotion {
                    guard await pause(total) else { return }
                } else {
                    // Hold the strike-through for a beat, then fade the removed words out; the model is stepped by hand
                    // because a concatenated Text cannot animate individual runs.
                    let hold = 0.3, steps = 12, fadeTime = total - hold
                    guard await pause(hold) else { return }
                    for step in 1...steps {
                        self?.diffFade = Double(step) / Double(steps)
                        guard await pause(fadeTime / Double(steps)) else { return }
                    }
                }
            } else {
                guard await pause(reduceMotion ? 0.2 : 0.3) else { return }
            }
            self?.settle(on: cleaned)
        }
        highlightTask = task
        return task
    }

    /// `startChangeHighlight`, waiting for it to finish.
    public func playChangeHighlight(raw: String, cleaned: String) async {
        await startChangeHighlight(raw: raw, cleaned: cleaned).value
    }

    /// Shows `text` as plain solid text: no shimmer, no highlight, and no word waveform (its words were the raw ones).
    public func settle(on text: String) {
        highlightTask?.cancel()
        highlightTask = nil
        withAnimation(.easeInOut(duration: 0.2)) {
            polishing = false
            diff = nil
            diffFade = 0
            stable = text
            unstable = ""
            wordCells = []
        }
    }
    public func silence() { levels.clear() }

    public func reset() {
        highlightTask?.cancel(); highlightTask = nil
        privateSession = false; duration = nil
        status = ""; stable = ""; unstable = ""; levels.clear(); indicator = .waveform
        isError = false; showUseRaw = false; cleaned = false; onUseRaw = nil
        styleName = nil; polishing = false; diff = nil; diffFade = 0; keptOriginal = false
        utterance.clear(); wordCells = []; revisedWords = []; wordsTruncated = false
    }
}

/// The live level history behind the waveform: the last `capacity` input levels, mapped to 0...1 on a decibel scale
/// (speech sits around -35...-15 dBFS, so a linear RMS would barely move the bars).
public struct LevelHistory: Equatable, Sendable {
    public static let capacity = 16
    public private(set) var samples = [Float](repeating: 0, count: capacity)

    public init() {}

    /// RMS 0...1 to a bar height 0...1: -50 dBFS and below is 0, -14 dBFS and above is 1 (`UtteranceLevels.normalize`).
    public static func normalize(rms: Float) -> Float { UtteranceLevels.normalize(rms: rms) }

    /// Adds a sample. Bars rise at once and fall by a third of the way, so the waveform reads as speech, not as jitter.
    public mutating func push(rms: Float) {
        let target = Self.normalize(rms: rms)
        let last = samples.last ?? 0
        samples.removeFirst()
        samples.append(target >= last ? target : last * 0.65 + target * 0.35)
    }

    public mutating func clear() { samples = [Float](repeating: 0, count: Self.capacity) }

    /// A fixed, speech-like history for the snapshots.
    public static func demo(peak: Float) -> LevelHistory {
        var h = LevelHistory()
        let shape: [Float] = [0.1, 0.25, 0.5, 0.35, 0.7, 0.9, 0.6, 0.4, 0.8, 1, 0.65, 0.45, 0.7, 0.5, 0.3, 0.55]
        h.samples = shape.map { $0 * peak }
        return h
    }
}

public enum HUDViewMetrics {
    /// Corner radius of the HUD: half the one-line height (a 20 pt row and 12 pt padding), so a one-line HUD is a capsule
    /// and a taller one a softly rounded rectangle, as before the Pond restyle.
    public static let corner: CGFloat = 22
    /// The HUD never changes width, so it does not jump as words arrive. 472 pt is the full length the capsule grew to
    /// before the Pond restyle (a 440 pt text column), in both modes: 360 pt wrapped a sentence after a few words.
    public static let width: CGFloat = 472
    public static let wordWaveformWidth: CGFloat = 472
    public static let horizontalPadding: CGFloat = ChirpSpacing.s16
    public static let verticalPadding: CGFloat = 12
    /// The transcript viewport shows this many whole lines of plain text, or rows of word cells, and most of the one
    /// before: longer dictation keeps its newest lines in view while the earlier ones fade out past the top edge.
    public static let transcriptLines = 5
    public static let wordWaveformRows = 3
    /// Transparent room around the glass surface, so the live panel (sized to this view) never clips the glass edge.
    public static let glassMargin: CGFloat = 12

    /// How much of the earlier line shows above the whole ones, faded: a line of text from just above its capitals
    /// down (only the line spacing is cut), or the words (not the bars) of a row of word cells.
    public static func transcriptPeek(wordWaveform: Bool) -> CGFloat {
        wordWaveform ? WordWaveformView.textHeight : lineHeight - 3
    }

    /// The viewport's height. The peek is never a whole number of lines, so a transcript fills the viewport exactly only
    /// when it overflows (the cue for the fade), and the faded line says there is more above.
    public static func transcriptMaxHeight(wordWaveform: Bool) -> CGFloat {
        if wordWaveform {
            let row = WordWaveformView.ribbonHeight + WordWaveformView.ribbonGap + WordWaveformView.textHeight
            return CGFloat(wordWaveformRows) * (row + WordWaveformView.lineSpacing) + transcriptPeek(wordWaveform: true)
        }
        return CGFloat(transcriptLines) * lineHeight + transcriptPeek(wordWaveform: false)
    }

    /// SwiftUI's line pitch for the 15 pt transcript (AppKit's default line height says 18); a test measures it.
    public static let lineHeight: CGFloat = 19

    public static func width(wordWaveform: Bool) -> CGFloat { wordWaveform ? wordWaveformWidth : width }
    /// The width of the text column inside the padding.
    public static func contentWidth(wordWaveform: Bool) -> CGFloat { width(wordWaveform: wordWaveform) - 2 * horizontalPadding }
}

public struct HUDView: View {
    /// The widest text column (the word waveform's).
    static let maxTextWidth: CGFloat = HUDViewMetrics.contentWidth(wordWaveform: true)

    let model: HUDModel
    let onSize: (CGSize) -> Void

    public init(model: HUDModel, onSize: @escaping (CGSize) -> Void = { _ in }) {
        self.model = model
        self.onSize = onSize
    }

    private var contentWidth: CGFloat { HUDViewMetrics.contentWidth(wordWaveform: model.wordWaveform) }

    public var body: some View {
        content
            .padding(.horizontal, HUDViewMetrics.horizontalPadding)
            .padding(.vertical, HUDViewMetrics.verticalPadding)
            .frame(width: HUDViewMetrics.width(wordWaveform: model.wordWaveform), alignment: .leading)
            .tint(Color.chirp.koi)
            .modifier(HUDSurface(flat: model.flatSurface || model.increaseContrast, glass: model.usesGlass, contrast: model.increaseContrast))
            .padding(model.usesGlass && !(model.flatSurface || model.increaseContrast) ? HUDViewMetrics.glassMargin : 0)
            .fixedSize()
            .onGeometryChange(for: CGSize.self, of: { $0.size }, action: onSize)
            // The live panel is sized by `onSize`; in a larger frame the HUD stays centred.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The private-session line carries the duration; otherwise it sits at the end of the status row, so an
            // ordinary dictation is not topped by a row that is empty but for the timer.
            if model.privateSession {
                HStack {
                    Label("Private session", systemImage: "lock.fill")
                    Spacer(minLength: 8)
                    durationLabel
                }
                .pondFont(.meta)
                .foregroundStyle(Color.secondary)
            }
            HStack(spacing: 10) {
                indicator
                    .accessibilityHidden(true)
                Text(model.status)
                    .pondFont(13, weight: .medium)
                    .foregroundStyle(model.isError ? HUDColors.error : Color.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let name = model.styleName {
                    HUDChip(name).accessibilityLabel("Style: \(name)")
                }
                if model.keptOriginal { HUDChip("kept original") }
                if model.cleaned { HUDChip(HUDStatus.polished, symbol: "sparkles", tone: .moon) }
                if model.showUseRaw {
                    Button { model.onUseRaw?() } label: { HUDChip("Use raw", tone: .action) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Use raw")
                }
                if model.debugRetention {
                    HUDChip(MenuContent.debugRetention, tone: .alert)
                        .help(MenuContent.debugRetentionHelp)
                }
                if !model.privateSession { durationLabel.pondFont(.meta).foregroundStyle(Color.secondary) }
            }
            let shown = HUDText.tail(stable: model.stable, unstable: model.unstable, limit: HUDText.lineBudget)
            let viewport = TranscriptViewport(maxHeight: HUDViewMetrics.transcriptMaxHeight(wordWaveform: model.showsWordWaveform))
            let fade = TranscriptFade(maxHeight: viewport.maxHeight, length: HUDViewMetrics.transcriptPeek(wordWaveform: model.showsWordWaveform))
            if model.showsWordWaveform {
                viewport {
                    WordWaveformView(cells: model.wordCells, levels: model.utterance, revised: model.revisedWords,
                                     truncated: model.wordsTruncated, polishing: model.polishing, animated: !model.reduceMotion,
                                     contrast: model.increaseContrast, pulsePhase: model.pulsePhase, shimmerPhase: model.shimmerPhase,
                                     maxWidth: contentWidth)
                }
                .modifier(fade)
                .transition(.opacity)
            } else if let diff = model.diff {
                viewport {
                    DiffText(segments: diff, fade: model.diffFade, contrast: model.increaseContrast)
                        .frame(width: contentWidth, alignment: .leading)
                }
                .modifier(fade)
                .transition(.opacity)
            } else if model.polishing, !shown.stable.isEmpty || !shown.unstable.isEmpty {
                viewport {
                    ShimmerText(text: shown.stable + shown.unstable, animated: !model.reduceMotion, phase: model.shimmerPhase)
                        .frame(width: contentWidth, alignment: .leading)
                }
                .modifier(fade)
                .transition(.opacity)
            } else if !shown.stable.isEmpty || !shown.unstable.isEmpty {
                viewport {
                    (Text(shown.stable) + Text(shown.unstable).foregroundStyle(Color.primary.opacity(model.increaseContrast ? 0.72 : 0.5)))
                        .pondFont(15)
                        .frame(width: contentWidth, alignment: .leading)
                }
                .modifier(fade)
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var durationLabel: some View {
        if let duration = model.duration { Text(duration).monospacedDigit().accessibilityLabel("Dictation duration: " + duration) }
    }

    @ViewBuilder private var indicator: some View {
        if let symbol = model.indicator.symbol {
            Image(systemName: symbol.name)
                .pondFont(15)
                .foregroundStyle(model.isError ? HUDColors.error : model.indicator == .success ? Color.chirp.lily : Color.chirp.inkMuted)
                .frame(width: 20, height: 20)
        } else if model.indicator == .waveform {
            Ripple(level: Double(model.levels.samples.last ?? 0), reduceMotion: model.reduceMotion, phase: model.pulsePhase)
        } else if model.indicator == .sparkle {
            Image(systemName: "sparkles")
                .pondFont(15)
                .foregroundStyle(Color.chirp.moon)
                .symbolEffect(.pulse, options: .repeating, isActive: !model.reduceMotion)
                .frame(width: 20, height: 20)
        }
    }
}

/// The transcript's window: as tall as the text up to `maxHeight`, then fixed, with the text anchored at the bottom so
/// the newest line stays in view and earlier lines move up past the top edge. The whole text stays in the view, so
/// VoiceOver still reads all of it.
struct TranscriptViewport: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let text = subviews.first else { return .zero }
        let natural = text.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? natural.width, height: min(natural.height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.minX, y: bounds.maxY), anchor: .bottomLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

/// Clips the viewport and, once the transcript overflows it, fades the partly shown line at the top edge.
struct TranscriptFade: ViewModifier {
    let maxHeight: CGFloat
    let length: CGFloat

    func body(content: Content) -> some View {
        content
            .clipped()
            .mask {
                GeometryReader { g in
                    if g.size.height >= maxHeight - 0.5 {
                        LinearGradient(stops: [.init(color: .clear, location: 0),
                                               .init(color: .black, location: min(1, (length + 2) / max(g.size.height, 1)))],
                                       startPoint: .top, endPoint: .bottom)
                    } else {
                        Color.black
                    }
                }
            }
    }
}

/// The HUD's one chip style: a small capsule of 10 pt semibold text — neutral for the style and "kept original", moon for what the
/// AI did, a koi tonal button for "Use raw", and a solid white-on-red badge for the debug warning.
struct HUDChip: View {
    enum Tone { case neutral, moon, action, alert }

    let text: String
    var symbol: String?
    var tone: Tone = .neutral

    init(_ text: String, symbol: String? = nil, tone: Tone = .neutral) {
        self.text = text; self.symbol = symbol; self.tone = tone
    }

    private var foreground: Color {
        switch tone {
        case .neutral: Color.chirp.inkMuted
        case .moon: Color.chirp.moon
        case .action: Color.chirp.onKoiContainer
        case .alert: .white
        }
    }

    private var background: Color {
        switch tone {
        case .neutral: Color.primary.opacity(0.08)
        case .moon: Color.chirp.moonFill.opacity(0.28)
        case .action: Color.chirp.koiContainer
        case .alert: HUDColors.badge
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).pondFont(9, weight: .semibold) }
            Text(text).lineLimit(1)
        }
        .pondFont(.caption, weight: .semibold)
        .foregroundStyle(foreground)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(background, in: Capsule())
        .fixedSize()
    }
}

/// The HUD's surface: `.glassEffect()` on macOS 26 (the live panel), a hairline panel otherwise (the `NSVisualEffectView`
/// behind the hosting view supplies the blur), and an opaque stand-in for Increase Contrast and the offscreen snapshots.
private struct HUDSurface: ViewModifier {
    let flat: Bool
    let glass: Bool
    let contrast: Bool

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: HUDViewMetrics.corner, style: .continuous) }

    @ViewBuilder func body(content: Content) -> some View {
        if flat {
            content
                .background { shape.fill(HUDColors.surface) }
                .overlay { shape.strokeBorder(Color.primary.opacity(contrast ? 0.55 : 0.12), lineWidth: contrast ? 1.5 : 1) }
                .clipShape(shape)
        } else if glass {
            glassed(content)
        } else {
            hairline(content)
        }
    }

    private func hairline(_ content: Content) -> some View {
        content.overlay { shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1) }.clipShape(shape)
    }

    @ViewBuilder private func glassed(_ content: Content) -> some View {
        #if swift(>=6.2)
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            hairline(content)
        }
        #else
        hairline(content)
        #endif
    }
}

/// The raw transcript as solid text while clean-up runs. A soft highlight sweeps across it (a still sparkle in the
/// header and no sweep when Reduce Motion is on), so the HUD never looks stuck.
struct ShimmerText: View {
    let text: String
    let animated: Bool
    /// Pins the sweep for the snapshots.
    var phase: Double?

    private static let period = 1.5

    var body: some View {
        if animated, phase == nil {
            TimelineView(.animation) { context in
                sweep(at: context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period) / Self.period)
            }
        } else {
            sweep(at: animated ? (phase ?? 0) : nil)
        }
    }

    private var label: some View { Text(text).pondFont(15) }

    @ViewBuilder private func sweep(at position: Double?) -> some View {
        if let position {
            label
                .overlay {
                    // A narrow band travelling from beyond the left edge to beyond the right one.
                    GeometryReader { geo in
                        let band = max(40, geo.size.width * 0.28)
                        let x = -band + (geo.size.width + 2 * band) * position
                        LinearGradient(colors: [.clear, HUDColors.shimmer, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: band)
                            .offset(x: x)
                    }
                    .mask(label)
                    .allowsHitTesting(false)
                }
        } else {
            label
        }
    }
}

/// The brief highlight of what clean-up changed, without red and green: the cleaned text with removed raw words struck
/// through in `inkMuted` (fading out), and added or changed words underlined in moon.
struct DiffText: View {
    let segments: [WordDiff.Segment]
    let fade: Double
    let contrast: Bool
    /// The HUD's 15 pt, uncapped (the HUD's transcript viewport keeps the newest lines in view); the History window
    /// passes its body font.
    var font: Font = .system(size: 15)
    var lineLimit: Int?

    /// The text without the removed words (the width the HUD settles at); removed words add width while visible.
    static func plain(_ segments: [WordDiff.Segment]) -> String { segments.map(\.text).joined(separator: " ") }

    var body: some View {
        segments.enumerated().reduce(Text("")) { acc, item in
            let (i, seg) = item
            let space = i == 0 ? "" : " "
            switch seg.kind {
            case .same:
                return acc + Text(space + seg.text)
            case .changed, .added:
                return acc + Text(space) + Text(seg.text).underline(true, pattern: .solid, color: Color.chirp.moon)
            case .removed:
                // Removed words fade out and, once gone, take no room.
                guard fade < 0.97 else { return acc }
                return acc + Text(space) + Text(seg.text).strikethrough(true, color: Color.chirp.inkMuted)
                    .foregroundStyle(Color.chirp.inkMuted.opacity((contrast ? 1 : 0.9) * (1 - fade)))
            }
        }
        .font(font)
        .lineLimit(lineLimit)
    }
}

/// What the HUD says after an insertion, and for how long. Pure, so it is unit-tested and the snapshots show real wording.
public struct OutcomePresentation: Equatable, Sendable {
    public var status: String
    public var indicator: HUDIndicator = .success
    public var isError = false
    public var showUseRaw = false
    /// The text was rewritten by clean-up: the HUD shows a small "cleaned" badge.
    public var cleaned = false
    /// Clean-up was asked for but did not deliver (timeout, error, rejected answer): the raw text was kept.
    public var keptOriginal = false
    /// Use raw is offered outside the HUD for `RawOffer.duration` (⌃⌥Z and the menu).
    public var offersRawOutsideHUD = false
    /// Seconds the HUD stays up. 0 fades it out at once.
    public var linger: Double

    /// How long the diff highlight plays. It runs alongside the insertion and never delays it.
    public static let highlightDuration = 0.8

    /// The note when clean-up did not deliver and the raw text was kept stays up this long at most.
    public static let keptNoteLinger = 1.0

    /// `offerRaw` is the "Show raw after clean-up" preference: off drops "Use raw" altogether. `showChanges` is "Show
    /// changes after clean-up": on keeps the HUD up with the diff and the Use raw button; off (the default) offers Use
    /// raw outside the HUD. A successful insertion fades the HUD out at once: the text in the field is the outcome.
    /// It stays up only to tell the user something: copied, maybe not inserted, a secure field, clean-up kept the
    /// original, or the changes they asked to see.
    public static func of(_ outcome: InsertionOutcome, final: FinalResult, offerRaw: Bool = true,
                          showChanges: Bool = false) -> OutcomePresentation {
        let useRaw = final.canUseRaw && offerRaw
        let kept = !final.corrected && final.correctionError != nil
        return switch outcome {
        case .inserted where showChanges:
            OutcomePresentation(status: "Inserted", showUseRaw: useRaw, cleaned: final.canUseRaw, keptOriginal: kept,
                                linger: useRaw ? 5 : final.canUseRaw ? 1.8 : kept ? keptNoteLinger : 0)
        case .inserted:
            OutcomePresentation(status: "Inserted", cleaned: final.canUseRaw, keptOriginal: kept,
                                offersRawOutsideHUD: useRaw, linger: kept ? keptNoteLinger : 0)
        case .copied:
            OutcomePresentation(status: "Copied — ⌘V", indicator: .clipboard, cleaned: final.canUseRaw, keptOriginal: kept, linger: 3)
        case .insertedUnverified:
            OutcomePresentation(status: "Inserted? ⌘V if empty", indicator: .clipboard, cleaned: final.canUseRaw, keptOriginal: kept, linger: 4)
        case .refusedSecure:
            OutcomePresentation(status: "Secure field — not inserted", indicator: .warning, isError: true, linger: 3)
        }
    }
}

public enum HUDText {
    /// The most characters of a plain transcript the HUD lays out: only a bound on layout work for very long dictation.
    /// At about 70 characters a line that is nearly thirty lines, far above the six-line viewport, so the cut is never on screen.
    public static let lineBudget = 2000

    /// The width a line of text wants, capped at `max`. SwiftUI proposes no width to a fixed-size capsule, so a Text
    /// would never wrap; giving it this width makes the HUD hug short text and wrap long text at the maximum.
    @MainActor
    public static func fittedWidth(_ text: String, font: NSFont, max limit: CGFloat) -> CGFloat {
        let natural = NSAttributedString(string: text, attributes: [.font: font]).size().width
        return min(limit, ceil(natural) + 2)
    }

    /// Long dictation keeps only the newest words, so the live end of the text is always visible. SwiftUI's own
    /// head truncation would keep the *oldest* lines and cut the last line mid-word.
    /// Drops from the front at a word boundary and marks the cut with "…". The stable/unstable split is kept.
    public static func tail(stable: String, unstable: String, limit: Int = 200) -> (stable: String, unstable: String) {
        let total = stable.count + unstable.count
        guard total > limit else { return (stable, unstable) }
        let combined = stable + unstable
        var cut = combined.index(combined.startIndex, offsetBy: total - limit)
        // Move the cut forward to just after the next space so no word is left half-visible.
        if let space = combined[cut...].firstIndex(of: " ") {
            let after = combined.index(after: space)
            if after < combined.endIndex { cut = after }
        }
        let dropped = combined.distance(from: combined.startIndex, to: cut)
        if dropped >= stable.count {
            return ("", "…" + String(combined[cut...]))
        }
        return ("…" + String(combined[cut...].prefix(stable.count - dropped)), unstable)
    }
}

/// System red fails WCAG contrast on the HUD's translucent material (about 2:1 in light, 2.5:1 in dark),
/// so the HUD uses its own reds, checked against representative material colours in the tests.
public enum HUDColors {
    public typealias RGB = (r: Double, g: Double, b: Double)
    public static let errorLight: RGB = (0.62, 0.04, 0.04)
    public static let errorDark: RGB = (1.0, 0.70, 0.66)
    /// Background of the white "DEBUG: recordings kept" badge.
    public static let badgeRGB: RGB = (0.72, 0.07, 0.07)

    /// The koi accent (revised words, the word waveform's tint); the "Use raw" chip sets its own text on `koiContainer`.
    public static let actionLight: RGB = ChirpColor.Pond.koi.light
    public static let actionDark: RGB = ChirpColor.Pond.koi.dark

    private static func dynamic(light: RGB, dark: RGB) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
        })
    }
    /// The opaque stand-in for the HUD material (Increase Contrast, snapshots), a touch translucent like the material.
    public static let surfaceLight: RGB = (0.97, 0.97, 0.98)
    public static let surfaceDark: RGB = (0.16, 0.16, 0.18)
    public static let surface = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let c = dark ? surfaceDark : surfaceLight
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 0.94)
    })
    public static let error = dynamic(light: errorLight, dark: errorDark)
    public static let action = dynamic(light: actionLight, dark: actionDark)
    public static let badge = Color(red: badgeRGB.r, green: badgeRGB.g, blue: badgeRGB.b)
    /// A word the recogniser just revised, for the brief crossfade.
    public static let change = action
    /// The shimmer's highlight band while clean-up runs: moon, the AI/polish colour.
    public static let shimmer = Color.chirp.moon.opacity(0.9)
}
