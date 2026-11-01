import AppKit
import ChirpCore
import SwiftUI

// The v2 dictation island: one black shape that merges with the notch (or floats under the menu bar on a screen
// without one) and morphs between states. Ported from the prototype's kit/DynamicIsland.tsx (sizes and spring); it
// reads the same `HUDModel` the classic HUD does, so the controller drives both. v1's island takes no mouse input,
// so Use raw is a hotkey hint, and it has no word waveform (the router keeps the classic HUD for that).

/// The island's shapes. `notice` covers what the prototype had no state for: errors, warnings, no speech, toasts.
public enum IslandState: String, CaseIterable, Sendable {
    case idle, listening, live, polishing, done, notice
}

/// `notch` merges with the hardware cutout; `floating` is a detached pill for screens without one.
public enum IslandMode: String, CaseIterable, Sendable {
    case notch, floating
}

/// Sizes, radii and timing of the island, in points.
public enum IslandMetrics {
    public struct Size: Equatable, Sendable {
        public var width: CGFloat
        public var height: CGFloat
        public var radius: CGFloat
    }

    /// The prototype's `ISLAND_SIZES` (a 14" MacBook Pro notch is about 200 × 34). Expanded done and notice states
    /// take the live size so their message has two lines.
    public static let compact: [IslandState: Size] = [
        .idle: Size(width: 200, height: 34, radius: 18),
        .listening: Size(width: 380, height: 34, radius: 20),
        .live: Size(width: 430, height: 84, radius: 26),
        .polishing: Size(width: 430, height: 84, radius: 26),
        .done: Size(width: 360, height: 34, radius: 20),
        .notice: Size(width: 430, height: 84, radius: 26),
    ]
    public static let expanded = Size(width: 430, height: 84, radius: 26)

    /// The stand-in notch when the real one is not known.
    public static let defaultNotch = CGSize(width: 200, height: 34)
    /// The floating pill's header row (taller than the notch's, as in the prototype).
    public static let floatingBar: CGFloat = 40
    /// The narrowest a wing either side of the notch may be.
    public static let minimumWing: CGFloat = 72
    /// Clear space kept between a wing's content and the hardware cutout, each side.
    public static let notchClearance: CGFloat = 4
    /// The concave "ears" where the island meets the top of the screen in notch mode.
    public static let flare: CGFloat = 8
    /// Room for the shadow around the island inside the fixed panel.
    public static let shadowMargin: CGFloat = 24
    public static let wingPadding: CGFloat = 12
    public static let bodyInset: CGFloat = 18

    /// The prototype's spring (stiffness 240, damping 21, mass 0.9).
    public static let spring = Animation.interpolatingSpring(mass: 0.9, stiffness: 240, damping: 21)
    /// Reduce Motion: a short cross-fade instead of the morph.
    public static let crossFade = Animation.easeInOut(duration: 0.2)

    /// The island's size for a state. In notch mode the header row is the notch's height and the wings are never
    /// narrower than `minimumWing`, so nothing sits under the cutout on a wider notch; idle is the notch itself.
    public static func size(_ state: IslandState, expanded isExpanded: Bool, mode: IslandMode,
                            notch: CGSize = defaultNotch) -> Size {
        var s = isExpanded && state != .idle ? expanded : compact[state]!
        switch mode {
        case .notch:
            let bar = notch.height
            s.height = s.height - defaultNotch.height + bar
            if state == .idle {
                s.width = notch.width + 2 * flare
            } else {
                s.width = max(s.width, notch.width + 2 * (minimumWing + flare))
            }
        case .floating:
            s.height = s.height - defaultNotch.height + floatingBar
        }
        return s
    }

    /// The island's size for what it shows. An idle island with the debug-retention marker opens to the listening width,
    /// so the dot sits beside the cutout instead of under it.
    public static func size(for p: IslandPresentation, mode: IslandMode, notch: CGSize = defaultNotch) -> Size {
        let state = p.state == .idle && p.debugRetention ? .listening : p.state
        return size(state, expanded: p.expanded, mode: mode, notch: notch)
    }

    /// The largest island in a mode: the fixed panel is this plus the shadow margin (sides and bottom).
    public static func panelSize(mode: IslandMode, notch: CGSize = defaultNotch) -> CGSize {
        let all = IslandState.allCases.flatMap { [size($0, expanded: false, mode: mode, notch: notch),
                                                  size($0, expanded: true, mode: mode, notch: notch)] }
        let w = all.map(\.width).max() ?? expanded.width, h = all.map(\.height).max() ?? expanded.height
        return CGSize(width: w + 2 * shadowMargin, height: h + shadowMargin)
    }

    /// The header row's height.
    public static func barHeight(mode: IslandMode, notch: CGSize = defaultNotch) -> CGFloat {
        mode == .notch ? notch.height : floatingBar
    }
}

/// What the island shows for a `HUDModel`: pure, so every HUD state is unit-tested to land somewhere visible.
public struct IslandPresentation: Equatable, Sendable {
    /// The leading symbol in the left wing.
    public enum Glyph: String, Equatable, Sendable {
        case none, ripple, connecting, sparkle, success, clipboard, warning, error, info, working
    }

    public enum Body: Equatable, Sendable {
        case none
        /// The live transcript, its unsettled tail dimmed.
        case transcript(stable: String, unstable: String)
        /// The raw transcript while clean-up runs (a shimmer sweeps across it).
        case polishing(String)
        /// What clean-up changed (`DiffText`).
        case diff([WordDiff.Segment], fade: Double)
        /// A sentence: an error, a warning, an outcome too long for the wing.
        case message(String)
    }

    public enum Chip: Equatable, Sendable {
        case polished, keptOriginal
        /// "⌃⌥Z Use raw": the island takes no clicks, so it names the hotkey instead of offering a button.
        case useRaw(key: String)

        public var text: String {
            switch self {
            case .polished: HUDStatus.polished
            case .keptOriginal: "kept original"
            case .useRaw(let key): "\(key) Use raw"
            }
        }
    }

    public var state: IslandState
    public var glyph: Glyph
    /// A word or two for the left wing ("Listening", "Inserted"); empty for notices, whose message is the body.
    public var title: String
    /// The HUD's full status, for VoiceOver.
    public var status: String
    public var body: Body = .none
    public var chips: [Chip] = []
    /// The elapsed part of the HUD's duration ("0:24" of "0:24 / 10:00").
    public var timer: String?
    /// The HUD's full duration text, for VoiceOver.
    public var duration: String?
    /// The dictation reached its length limit: the timer turns the record colour.
    public var atLimit = false
    /// The clean-up style, a badge while polishing.
    public var style: String?
    public var privateSession = false
    /// The server keeps recordings: a red dot that every state shows, idle included. Never hidden.
    public var debugRetention = false
    public var isError = false

    /// The island needs its body row.
    public var expanded: Bool { body != .none || !chips.isEmpty }

    /// The most characters of live transcript the island keeps (two lines at 430 pt); older words give way at the front.
    public static let transcriptBudget = 96
    /// A wing title longer than this is cut to its first words (the whole status goes to the body).
    public static let titleBudget = 12

    /// The default Use raw hotkey (`Preferences.useRawHotkey`).
    public static let defaultUseRawKey = "⌃⌥Z"

    @MainActor
    public static func of(_ model: HUDModel, useRawKey: String = defaultUseRawKey) -> IslandPresentation {
        var p = classify(model, useRawKey: useRawKey)
        p.privateSession = model.privateSession
        p.debugRetention = model.debugRetention
        p.isError = model.isError
        p.duration = model.duration
        if let duration = model.duration {
            let parts = duration.components(separatedBy: " / ")
            p.timer = parts.first
            p.atLimit = parts.count == 2 && parts[0] == parts[1]
        }
        return p
    }

    @MainActor
    private static func classify(_ m: HUDModel, useRawKey: String) -> IslandPresentation {
        let status = m.status
        let shown = HUDText.tail(stable: m.stable, unstable: m.unstable, limit: transcriptBudget)
        let hasText = !(shown.stable + shown.unstable).trimmingCharacters(in: .whitespaces).isEmpty
        let transcript: Body = hasText ? .transcript(stable: shown.stable, unstable: shown.unstable) : .none

        // Errors and warnings first: a problem is never shown as progress.
        if m.isError || m.indicator == .warning {
            return IslandPresentation(state: .notice, glyph: m.isError ? .error : .warning, title: "", status: status,
                                      body: .message(status))
        }
        if let diff = m.diff {
            return IslandPresentation(state: .polishing, glyph: .sparkle, title: wing(status, or: HUDStatus.polished), status: status,
                                      body: .diff(diff, fade: m.diffFade), style: m.styleName)
        }
        if m.polishing || status == HUDStatus.polishing {
            let raw = shown.stable + shown.unstable
            return IslandPresentation(state: .polishing, glyph: .sparkle, title: wing(status, or: HUDStatus.polishing), status: status,
                                      body: hasText ? .polishing(raw) : .none, style: m.styleName)
        }
        if status == HUDStatus.polished {
            return IslandPresentation(state: .polishing, glyph: .sparkle, title: HUDStatus.polished, status: status,
                                      body: transcript, style: m.styleName)
        }
        switch m.indicator {
        case .success, .clipboard:
            var chips: [Chip] = []
            if m.cleaned { chips.append(.polished) }
            if m.keptOriginal { chips.append(.keptOriginal) }
            if m.showUseRaw { chips.append(.useRaw(key: useRawKey)) }
            let title = shortTitle(status)
            return IslandPresentation(state: .done, glyph: m.indicator == .success ? .success : .clipboard, title: title,
                                      status: status, body: rest(of: status, after: title).map(Body.message) ?? .none, chips: chips)
        case .sparkle:
            // A sparkle that is not clean-up: the "Learned: Kubernetes" toast.
            return IslandPresentation(state: .notice, glyph: .sparkle, title: "", status: status, body: .message(status))
        case .none:
            if status.isEmpty, !hasText { return IslandPresentation(state: .idle, glyph: .none, title: "", status: status) }
            return IslandPresentation(state: .notice, glyph: .info, title: "", status: status,
                                      body: .message(status.isEmpty ? shown.stable + shown.unstable : status))
        case .waveform, .warning:
            break
        }
        switch status {
        case "":
            return hasText ? IslandPresentation(state: .live, glyph: .ripple, title: "", status: status, body: transcript)
                           : IslandPresentation(state: .idle, glyph: .none, title: "", status: status)
        case HUDStatus.connecting:
            return IslandPresentation(state: hasText ? .live : .listening, glyph: .connecting, title: HUDStatus.connecting,
                                      status: status, body: transcript)
        case HUDStatus.listening, HUDStatus.finishing:
            let title = wing(status, or: "")
            return IslandPresentation(state: hasText ? .live : .listening, glyph: .ripple, title: title, status: status,
                                      body: transcript)
        case HUDStatus.inserting:
            return IslandPresentation(state: hasText ? .live : .listening, glyph: .working, title: HUDStatus.inserting,
                                      status: status, body: transcript)
        default:
            // Any other wording the controller sets: shown whole rather than dropped.
            return IslandPresentation(state: .notice, glyph: .info, title: "", status: status, body: .message(status))
        }
    }

    /// The wing title for a status: "Listening" for "Listening…", else its first words; `fallback` when it is empty.
    static func wing(_ status: String, or fallback: String) -> String {
        if status.isEmpty { return fallback }
        return status == HUDStatus.listening ? "Listening" : shortTitle(status)
    }

    /// What the body adds to a wing title: the part after " — " or " · " ("⌘V" of "Copied — ⌘V"), the words after a
    /// question ("⌘V if empty" of "Inserted? ⌘V if empty"), or the whole status when the title cut it elsewhere.
    static func rest(of status: String, after title: String) -> String? {
        guard title != status else { return nil }
        guard status.hasPrefix(title) else { return status }
        let tail = status.dropFirst(title.count)
        for sep in [" — ", " · "] where tail.hasPrefix(sep) { return String(tail.dropFirst(sep.count)) }
        if title.hasSuffix("?"), tail.hasPrefix(" ") { return String(tail.dropFirst()) }
        return status
    }

    /// The first words of `status` that fit the wing ("Copied" of "Copied — ⌘V", "Inserted" of "Inserted raw").
    static func shortTitle(_ status: String) -> String {
        let head = status.components(separatedBy: " — ").first!.components(separatedBy: " · ").first!
        guard head.count > titleBudget || head.dropLast().contains("?") else { return head }
        var title = ""
        for word in head.split(separator: " ") {
            let next = title.isEmpty ? String(word) : title + " " + word
            if next.count > titleBudget { break }
            title = next
            if word.hasSuffix("?") { break }
        }
        return title.isEmpty ? String(head.prefix(titleBudget)) : title
    }

    /// One sentence for VoiceOver: the status, the body, then the markers.
    public var accessibilityLabel: String {
        var parts = ["Chirp"]
        if !status.isEmpty { parts.append(status) }
        switch body {
        case .transcript(let s, let u): parts.append(s + u)
        case .polishing(let t): parts.append(t)
        case .diff(let segments, _): parts.append(segments.filter { $0.kind != .removed }.map(\.text).joined(separator: " "))
        case .message(let t) where t != status: parts.append(t)
        default: break
        }
        parts += chips.map(\.text)
        if let style, state == .polishing { parts.append("Style: \(style)") }
        if privateSession { parts.append("Private session") }
        if let duration { parts.append("Dictation duration: " + duration) }
        if debugRetention { parts.append(MenuContent.debugRetention) }
        return parts.joined(separator: ", ")
    }
}

/// The island's outline: flat along the top of the screen with concave ears in notch mode (`flare`), every corner
/// rounded when floating. Its radii animate with the size, so the morph between states is one continuous shape.
public struct NotchShape: Shape {
    public var topRadius: CGFloat
    public var bottomRadius: CGFloat
    public var flare: CGFloat

    public init(topRadius: CGFloat, bottomRadius: CGFloat, flare: CGFloat) {
        self.topRadius = topRadius
        self.bottomRadius = bottomRadius
        self.flare = flare
    }

    public var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(topRadius, bottomRadius), flare) }
        set { topRadius = newValue.first.first; bottomRadius = newValue.first.second; flare = newValue.second }
    }

    public func path(in rect: CGRect) -> Path {
        let f = max(0, min(flare, rect.width / 4, rect.height / 2))
        let body = CGRect(x: rect.minX + f, y: rect.minY, width: rect.width - 2 * f, height: rect.height)
        let rb = max(0, min(bottomRadius, body.width / 2, body.height / 2))
        let rt = max(0, min(topRadius, body.width / 2, body.height / 2 - 0.01))
        var p = Path()
        // SwiftUI's y grows downwards: minY is the top edge.
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        if f > 0 {
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addQuadCurve(to: CGPoint(x: body.maxX, y: rect.minY + f), control: CGPoint(x: body.maxX, y: rect.minY))
        } else {
            p.move(to: CGPoint(x: body.minX + rt, y: body.minY))
            p.addLine(to: CGPoint(x: body.maxX - rt, y: body.minY))
            p.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.minY + rt), radius: rt)
        }
        p.addLine(to: CGPoint(x: body.maxX, y: body.maxY - rb))
        p.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY), tangent2End: CGPoint(x: body.maxX - rb, y: body.maxY), radius: rb)
        p.addLine(to: CGPoint(x: body.minX + rb, y: body.maxY))
        p.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.maxY - rb), radius: rb)
        if f > 0 {
            p.addLine(to: CGPoint(x: body.minX, y: rect.minY + f))
            p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY), control: CGPoint(x: body.minX, y: rect.minY))
        } else {
            p.addLine(to: CGPoint(x: body.minX, y: body.minY + rt))
            p.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY), tangent2End: CGPoint(x: body.minX + rt, y: body.minY), radius: rt)
        }
        p.closeSubpath()
        return p
    }
}

/// The island. It fills its container (the fixed panel) and draws itself top-centred, so the panel never resizes.
/// All state comes from the `HUDModel` (no view-local state: the Command Line Tools build has no `@State`).
public struct IslandView: View {
    let model: HUDModel
    let mode: IslandMode
    let notch: CGSize
    let useRawKey: String

    public init(model: HUDModel, mode: IslandMode, notch: CGSize = IslandMetrics.defaultNotch,
                useRawKey: String = IslandPresentation.defaultUseRawKey) {
        self.model = model
        self.mode = mode
        self.notch = notch
        self.useRawKey = useRawKey
    }

    public var body: some View {
        let p = IslandPresentation.of(model, useRawKey: useRawKey)
        let size = IslandMetrics.size(for: p, mode: mode, notch: notch)
        let hidden = mode == .floating && p.state == .idle && !p.debugRetention
        let key = "\(p.state.rawValue)-\(p.expanded)"
        Group {
            if model.reduceMotion {
                // No morph: the old shape fades out as the new one fades in.
                island(p, size: size).id(key).transition(.opacity)
            } else {
                island(p, size: size)
            }
        }
        .opacity(hidden ? 0 : 1)
        .offset(y: hidden && !model.reduceMotion ? -16 : 0)
        .animation(model.reduceMotion ? IslandMetrics.crossFade : IslandMetrics.spring, value: key)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The island is always black, so its tokens resolve as they do in dark mode whatever the system appearance.
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(p.accessibilityLabel)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var flare: CGFloat { mode == .notch ? IslandMetrics.flare : 0 }
    private var bar: CGFloat { IslandMetrics.barHeight(mode: mode, notch: notch) }

    private func island(_ p: IslandPresentation, size: IslandMetrics.Size) -> some View {
        let shape = NotchShape(topRadius: mode == .floating ? size.radius : 0, bottomRadius: size.radius, flare: flare)
        return ZStack(alignment: .top) {
            // The glow is an overlay so it never makes a compact island taller than its shape.
            shape.fill(Color.black).overlay(alignment: .top) { glow(p) }
            VStack(alignment: .leading, spacing: 0) {
                header(p, width: size.width)
                if p.expanded {
                    bodyRow(p)
                        .padding(.horizontal, IslandMetrics.bodyInset)
                        .padding(.top, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, flare)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(shape)
        .overlay {
            if model.increaseContrast { shape.stroke(Color.white.opacity(0.6), lineWidth: 1) }
        }
        .foregroundStyle(Color.white)
        .shadow(color: .black.opacity(0.45), radius: 14, y: 8)
    }

    /// A soft record-colour glow from below while the microphone is open.
    @ViewBuilder private func glow(_ p: IslandPresentation) -> some View {
        if p.glyph == .ripple, !model.increaseContrast {
            Ellipse()
                .fill(RadialGradient(colors: [Color.chirp.koiDecor.opacity(0.22), .clear], center: .center, startRadius: 0, endRadius: 140))
                .frame(height: 90)
                .offset(y: 50)
                .allowsHitTesting(false)
        }
    }

    // MARK: header

    private func header(_ p: IslandPresentation, width: CGFloat) -> some View {
        let inner = width - 2 * flare - 2 * IslandMetrics.wingPadding
        let gap = mode == .notch ? notch.width + 2 * IslandMetrics.notchClearance : 12
        let wing = max(0, (inner - gap) / 2)
        return HStack(spacing: 0) {
            leadingWing(p)
                .frame(width: mode == .notch ? wing : nil, alignment: .leading)
            if mode == .notch { Spacer(minLength: gap) } else { Spacer(minLength: 12) }
            trailingWing(p)
                .frame(width: mode == .notch ? wing : nil, alignment: .trailing)
        }
        .padding(.horizontal, IslandMetrics.wingPadding)
        .frame(height: bar)
        .font(.system(size: 12, weight: .medium))
    }

    @ViewBuilder private func leadingWing(_ p: IslandPresentation) -> some View {
        // The title shows when it fits beside the glyph; VoiceOver always has the whole status.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 7) {
                glyph(p)
                if !p.title.isEmpty { Text(p.title).lineLimit(1).fixedSize() }
            }
            glyph(p)
        }
    }

    @ViewBuilder private func trailingWing(_ p: IslandPresentation) -> some View {
        HStack(spacing: 6) {
            if p.state == .polishing, let style = p.style {
                Text(style)
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.white.opacity(0.15), in: Capsule())
                    .fixedSize()
            }
            if p.privateSession {
                Image(systemName: "lock.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.white.opacity(0.8))
            }
            if let timer = p.timer, [.listening, .live, .notice].contains(p.state) {
                Text(timer)
                    .font(ChirpType.timer(12))
                    .foregroundStyle(p.atLimit ? Color.chirp.record : Color.white.opacity(0.85))
                    .fixedSize()
            }
            if p.debugRetention { DebugDot(contrast: model.increaseContrast) }
        }
    }

    @ViewBuilder private func glyph(_ p: IslandPresentation) -> some View {
        switch p.glyph {
        case .none:
            EmptyView()
        case .ripple:
            Ripple(level: Double(model.levels.samples.last ?? 0), reduceMotion: model.reduceMotion, phase: model.pulsePhase,
                   color: Color.chirp.koiDecor, staticColor: Color.chirp.koiDecor, side: 18)
        case .connecting:
            Ripple(level: 0, reduceMotion: model.reduceMotion, phase: model.pulsePhase,
                   color: Color.white.opacity(0.55), staticColor: Color.white.opacity(0.55), side: 18)
        case .sparkle:
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.chirp.moon)
                .symbolEffect(.pulse, options: .repeating, isActive: !model.reduceMotion && p.state == .polishing)
                .frame(width: 18, height: 18)
        case .success:
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(Color.black)
                .frame(width: 18, height: 18)
                .background(Color.chirp.lily, in: Circle())
        case .clipboard:
            symbol("doc.on.clipboard.fill", Color.white)
        case .warning:
            symbol("exclamationmark.triangle.fill", Color.chirp.moon)
        case .error:
            symbol("exclamationmark.triangle.fill", Color.chirp.record)
        case .info:
            symbol("info.circle.fill", Color.white.opacity(0.8))
        case .working:
            symbol("text.insert", Color.white.opacity(0.85))
        }
    }

    private func symbol(_ name: String, _ color: Color) -> some View {
        Image(systemName: name).font(.system(size: 13, weight: .semibold)).foregroundStyle(color).frame(width: 18, height: 18)
    }

    // MARK: body

    private var dim: Double { model.increaseContrast ? 0.75 : 0.55 }

    @ViewBuilder private func bodyRow(_ p: IslandPresentation) -> some View {
        let font = Font.system(size: 13.5)
        VStack(alignment: .leading, spacing: 5) {
            switch p.body {
            case .none:
                EmptyView()
            case .transcript(let stable, let unstable):
                (Text(stable) + Text(unstable).foregroundStyle(Color.white.opacity(dim)))
                    .font(font).lineLimit(2)
            case .polishing(let text):
                IslandShimmer(text: text, animated: !model.reduceMotion, phase: model.shimmerPhase, font: font)
            case .diff(let segments, let fade):
                DiffText(segments: segments, fade: fade, contrast: model.increaseContrast, font: font, lineLimit: 2)
            case .message(let text):
                Text(text).font(font).lineLimit(p.chips.isEmpty ? 2 : 1)
                    .foregroundStyle(p.isError ? Color.chirp.record : Color.white)
            }
            if !p.chips.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(p.chips.enumerated()), id: \.offset) { _, chip in IslandChip(chip: chip) }
                }
            }
        }
        .transition(.opacity)
    }
}

/// A small capsule under a done state: "Polished" in moon, "kept original" neutral, the Use raw hotkey as a keycap hint.
private struct IslandChip: View {
    let chip: IslandPresentation.Chip

    var body: some View {
        HStack(spacing: 3) {
            if chip == .polished { Image(systemName: "sparkles").font(.system(size: 9, weight: .semibold)) }
            Text(chip.text).lineLimit(1)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(chip == .polished ? Color.chirp.moon : Color.white.opacity(0.85))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Color.white.opacity(chip == .polished ? 0.1 : 0.15), in: Capsule())
        .fixedSize()
    }
}

/// The debug-retention marker: a red dot with a white ring, drawn in every state. It is the island's form of the
/// HUD's "DEBUG: recordings kept" badge and must never be hidden.
private struct DebugDot: View {
    let contrast: Bool

    var body: some View {
        Circle()
            .fill(Color.chirp.record)
            .overlay { Circle().strokeBorder(Color.white.opacity(contrast ? 1 : 0.8), lineWidth: contrast ? 1.5 : 1) }
            .frame(width: 9, height: 9)
            .help(MenuContent.debugRetentionHelp)
    }
}

/// The raw transcript while clean-up runs, with a soft band sweeping across it (still under Reduce Motion).
/// The island's own version of the HUD's `ShimmerText`, at the island's font and two lines.
private struct IslandShimmer: View {
    let text: String
    let animated: Bool
    var phase: Double?
    let font: Font

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

    private var label: some View { Text(text).font(font).lineLimit(2).foregroundStyle(Color.white.opacity(0.75)) }

    @ViewBuilder private func sweep(at position: Double?) -> some View {
        if let position {
            label.overlay {
                GeometryReader { geo in
                    let band = max(40, geo.size.width * 0.28)
                    LinearGradient(colors: [.clear, Color.chirp.moon.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: band)
                        .offset(x: -band + (geo.size.width + 2 * band) * position)
                }
                .mask(label)
                .allowsHitTesting(false)
            }
        } else {
            label
        }
    }
}
