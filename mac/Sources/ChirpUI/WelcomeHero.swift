import SwiftUI

// The v2 welcome hero, variant A "Wake": a glass ribbon fills the banner and Chirp's classic orb sits on the right.
// Ported from the prototype's kit/WelcomeHero.tsx and kit/Orb.tsx (ClassicOrb). The orb states are driven by a
// looping demo cycle (idle, listening, polishing, done), not by real dictation. The WebGL "Aura" orb is deferred.
//
// Everything is drawn with `Canvas` inside one `TimelineView`, like `Ripple`, and every frame is a pure function of
// (state, seconds), so the snapshots can pin a frame and Reduce Motion shows a still one.

/// The orb's five states, in the order the demo cycle visits them (off is only ever shown on request).
public enum HeroOrbState: String, CaseIterable, Sendable {
    case idle, listening, polishing, done, off

    /// What the orb says, for VoiceOver and the snapshot names.
    public var meaning: String {
        switch self {
        case .idle: "ready"
        case .listening: "listening"
        case .polishing: "polishing"
        case .done: "done"
        case .off: "off"
        }
    }
}

/// The demo cycle behind the hero: idle 1.8 s, listening 3.6 s, polishing 2.0 s, done 1.8 s, then again.
public enum HeroOrbCycle {
    public static let steps: [(state: HeroOrbState, seconds: Double)] = [(.idle, 1.8), (.listening, 3.6), (.polishing, 2.0), (.done, 1.8)]
    public static let total: Double = steps.reduce(0) { $0 + $1.seconds }

    /// The state at `time`, and how long the orb has been in it.
    public static func state(at time: Double) -> (state: HeroOrbState, elapsed: Double) {
        var rest = time.truncatingRemainder(dividingBy: total)
        if rest < 0 { rest += total }
        for step in steps {
            if rest < step.seconds { return (step.state, rest) }
            rest -= step.seconds
        }
        return (.idle, 0)
    }
}

/// One frame of the classic orb: every number the drawing needs, from the state and the time alone.
public struct HeroOrbFrame: Equatable, Sendable {
    /// Body scale: breathes while idle, follows the voice while listening, pops once on done.
    public var scale: Double
    /// How bright the glint is (0...1) and how far it has orbited, in turns.
    public var glintOpacity: Double
    public var glintTurns: Double
    /// Whole-orb opacity (greyed when off) and desaturation.
    public var opacity: Double
    public var grey: Bool
    /// Expanding rings, each (progress 0...1): three while listening, one on done.
    public var rings: [Double]
    /// Where the polishing sheen is across the orb (0...1), nil when it is not shown.
    public var sheen: Double?
    /// The voice level that drives the listening scale (0...1).
    public var level: Double

    /// A smooth stand-in voice level (the prototype uses random numbers; snapshots need a repeatable one).
    public static func level(at time: Double) -> Double {
        let v = 0.5 + 0.22 * sin(time * 7.3) + 0.14 * sin(time * 12.9 + 1.1) + 0.08 * sin(time * 3.1 + 2.0)
        return min(1, max(0.1, v))
    }

    /// `time` is the clock; `elapsed` is the time since the orb entered `state` (it drives the done pop and ring).
    public static func make(_ state: HeroOrbState, time: Double, elapsed: Double, moving: Bool = true) -> HeroOrbFrame {
        let level = state == .listening ? level(at: time) : 0
        var frame = HeroOrbFrame(scale: 1, glintOpacity: 1, glintTurns: 0, opacity: 1, grey: false, rings: [], sheen: nil, level: level)
        switch state {
        case .idle:
            frame.glintOpacity = 0.55
            // 5.5 s breathing between 1 and 1.035.
            if moving { frame.scale = 1 + 0.035 * (0.5 - 0.5 * cos(2 * .pi * time / 5.5)) }
        case .listening:
            frame.scale = 1 + level * 0.16
            if moving { frame.rings = (0..<3).map { i in ((time / 2.1) + Double(i) / 3).truncatingRemainder(dividingBy: 1) } }
        case .polishing:
            if moving {
                frame.glintTurns = (time / 2.6).truncatingRemainder(dividingBy: 1)
                frame.sheen = (time / 1.4).truncatingRemainder(dividingBy: 1)
            }
        case .done:
            if moving {
                // A pop from 1.16 that settles (damped), and one ring over 1.1 s.
                let t = max(0, elapsed)
                frame.scale = 1 + 0.16 * exp(-t * 5.5) * cos(t * 11)
                if t < 1.1 { frame.rings = [t / 1.1] }
            }
        case .off:
            frame.glintOpacity = 0.35
            frame.opacity = 0.62
            frame.grey = true
        }
        return frame
    }
}

/// The Wake hero as a SwiftUI view. `time` pins a frame (snapshots); nil runs on the clock; `reduceMotion` shows one
/// still frame of `state` (idle unless told otherwise).
public struct WelcomeHero: View {
    /// Pin the orb to one state instead of running the demo cycle.
    var state: HeroOrbState?
    /// A fixed time in seconds for the snapshots; nil follows the clock.
    var time: Double?
    var reduceMotion: Bool

    public init(state: HeroOrbState? = nil, time: Double? = nil, reduceMotion: Bool = false) {
        self.state = state
        self.time = time
        self.reduceMotion = reduceMotion
    }

    public static let height: CGFloat = 150

    /// What VoiceOver reads: the hero is a picture of the orb, so it says what the orb is.
    public static func accessibilityText(reduceMotion: Bool, state: HeroOrbState?) -> String {
        if let state { return "Chirp’s orb, \(state.meaning), on a glass ribbon" }
        return reduceMotion
            ? "Chirp’s orb, ready, on a glass ribbon"
            : "Chirp’s orb on a glass ribbon, showing ready, listening, polishing and done in turn"
    }

    public var body: some View {
        Group {
            if reduceMotion {
                frame(at: 0, fixed: true)
            } else if let time {
                frame(at: time, fixed: true)
            } else {
                TimelineView(.animation) { context in
                    frame(at: context.date.timeIntervalSinceReferenceDate, fixed: false)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: ChirpRadius.panel, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityText(reduceMotion: reduceMotion, state: state))
        .accessibilityAddTraits(.isImage)
    }

    private func frame(at time: Double, fixed: Bool) -> some View {
        let (cycled, elapsed) = HeroOrbCycle.state(at: time)
        // Reduce Motion: a still frame; a pinned state shows as that state, otherwise Ready.
        let shown = state ?? (reduceMotion ? .idle : cycled)
        let moving = !reduceMotion
        let since = state == nil ? elapsed : (time.truncatingRemainder(dividingBy: 1.8))
        return HeroCanvas(state: shown, time: time, elapsed: since, moving: moving)
    }
}

/// The ribbon and the orb on one canvas, plus the glyph that sits on the orb (check or slashed mic).
private struct HeroCanvas: View {
    let state: HeroOrbState
    let time: Double
    let elapsed: Double
    let moving: Bool

    var body: some View {
        let orb = HeroOrbFrame.make(state, time: time, elapsed: elapsed, moving: moving)
        GeometryReader { geo in
            let side = geo.size.height * 0.83
            let x = geo.size.width * (1 - 0.09) - side
            let y = geo.size.height * 0.13
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    HeroPaint.background(&context, size)
                    HeroPaint.ribbon(&context, size, state: state, time: time, moving: moving)
                    HeroPaint.orb(&context, CGRect(x: x, y: y, width: side, height: side), state: state, frame: orb)
                }
                glyph(side: side, scale: orb.scale)
                    .frame(width: side, height: side)
                    .offset(x: x, y: y)
            }
        }
        .frame(height: WelcomeHero.height)
    }

    @ViewBuilder private func glyph(side: CGFloat, scale: Double) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: side * 0.34, weight: .heavy))
                .foregroundStyle(.white)
                .scaleEffect(moving ? min(1, 0.3 + elapsed * 6) : 1)
        case .off:
            Image(systemName: "mic.slash")
                .font(.system(size: side * 0.3, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
        default:
            Color.clear
        }
    }
}

/// The drawing. The hero is a brand image like the pond art was, so it keeps its own fixed Graphite colours in both
/// appearances; these are not theme tokens (hand-ported from the prototype's `graphite` palette).
private enum HeroPaint {
    static func rgb(_ hex: UInt32, _ alpha: Double = 1) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
    static let ice = 0xEEF1F5 as UInt32, sky = 0xD3D9E2 as UInt32, mist = 0xB4BDCB as UInt32, cobalt = 0x26324A as UInt32
    static let deep = 0x1B2436 as UInt32, navy = 0x121826 as UInt32, mauve = 0x5A6B8C as UInt32
    static let petal = 0xC9DBFA as UInt32, rose = 0x8FB7F5 as UInt32, accent = 0x5B9BFF as UInt32, accentDeep = 0x2F6FE0 as UInt32

    /// Strip widths (the prototype's flex values).
    static let flex: [Double] = [0.9, 1.5, 0.8, 1.2, 0.7, 1.1, 0.9, 1.3]

    static func background(_ context: inout GraphicsContext, _ size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        // ice 70% over white, mist at 55%, deep at the bottom.
        let top = mix(ice, 0xFFFFFF, 0.3)
        context.fill(Path(rect), with: .linearGradient(
            Gradient(stops: [.init(color: top, location: 0), .init(color: rgb(mist), location: 0.55), .init(color: rgb(deep), location: 1)]),
            startPoint: CGPoint(x: size.width / 2, y: 0), endPoint: CGPoint(x: size.width / 2, y: size.height)))
    }

    static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> Color {
        func c(_ v: UInt32, _ s: UInt32) -> Double { Double((v >> s) & 0xFF) }
        return Color(.sRGB, red: (c(a, 16) + (c(b, 16) - c(a, 16)) * t) / 255, green: (c(a, 8) + (c(b, 8) - c(a, 8)) * t) / 255,
                     blue: (c(a, 0) + (c(b, 0) - c(a, 0)) * t) / 255)
    }

    /// Eight glass strips. At rest each breathes slowly; while listening a bright pulse travels right to left.
    static func ribbon(_ context: inout GraphicsContext, _ size: CGSize, state: HeroOrbState, time: Double, moving: Bool) {
        let n = flex.count
        let total = flex.reduce(0, +)
        var x = 0.0
        for i in 0..<n {
            let w = size.width * flex[i] / total
            let rect = CGRect(x: x, y: 0, width: w, height: size.height)
            x += w
            var boost = 0.0
            if moving {
                if state == .listening {
                    // strip-wake: brightens at 18% of 1.8 s, back to normal by 60%, delayed per strip (right first).
                    let delay = Double(n - 1 - i) * 0.17
                    let p = (((time - delay) / 1.8).truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
                    boost = p < 0.18 ? p / 0.18 : p < 0.6 ? 1 - (p - 0.18) / 0.42 : 0
                } else {
                    boost = 0.12 * (0.5 + 0.5 * sin(2 * .pi * (time / 9 - Double(i) * 1.7 / 9)))
                }
            }
            let fade = Gradient(stops: [
                .init(color: rgb(sky, 0.78), location: 0), .init(color: rgb(petal, 0.85), location: 0.28),
                .init(color: rgb(navy, 0.85), location: 0.58), .init(color: rgb(mauve, 0.70), location: 0.82),
                .init(color: rgb(deep, 0.90), location: 1)])
            context.drawLayer { layer in
                // Mask the strip to fade out at the top and bottom (transparent 0, opaque 14% to 76%, transparent 100%).
                layer.clip(to: Path(rect))
                layer.fill(Path(rect), with: .linearGradient(fade, startPoint: CGPoint(x: rect.midX, y: 0), endPoint: CGPoint(x: rect.midX, y: size.height)))
                if boost > 0 {
                    layer.fill(Path(rect), with: .linearGradient(
                        Gradient(colors: [.white.opacity(0.0), .white.opacity(0.32 * boost), .white.opacity(0.0)]),
                        startPoint: CGPoint(x: rect.midX, y: 0), endPoint: CGPoint(x: rect.midX, y: size.height)))
                }
                var edge = Path()
                edge.move(to: CGPoint(x: rect.minX + 0.5, y: 0)); edge.addLine(to: CGPoint(x: rect.minX + 0.5, y: size.height))
                edge.move(to: CGPoint(x: rect.maxX - 0.5, y: 0)); edge.addLine(to: CGPoint(x: rect.maxX - 0.5, y: size.height))
                layer.stroke(edge, with: .color(.white.opacity(0.35)), lineWidth: 1)
                // Soften the top and bottom: paint the backdrop's own gradient back over the strip's ends.
                layer.blendMode = .normal
            }
        }
        // The fade mask: wash the top and bottom bands with the background so strips dissolve into it.
        let wash = Gradient(stops: [
            .init(color: .white.opacity(0), location: 0), .init(color: .clear, location: 0.14),
            .init(color: .clear, location: 0.76), .init(color: rgb(deep, 0.5), location: 1)])
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
            wash, startPoint: CGPoint(x: size.width / 2, y: 0), endPoint: CGPoint(x: size.width / 2, y: size.height)))
    }

    /// The classic orb: a deep-blue sphere, a glint at the top right, expanding rings while it listens.
    static func orb(_ context: inout GraphicsContext, _ rect: CGRect, state: HeroOrbState, frame f: HeroOrbFrame) {
        let side = rect.width
        let center = CGPoint(x: rect.midX, y: rect.midY)
        // Rings sit behind the body.
        for p in f.rings {
            let d = side * (1 + 1.1 * p)
            let r = CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)
            context.stroke(Path(ellipseIn: r), with: .color(rgb(accent, 0.65 * (1 - p))), lineWidth: 2)
        }
        let d = side * f.scale
        let body = CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)
        context.drawLayer { layer in
            layer.opacity = f.opacity
            if f.grey { layer.addFilter(.grayscale(1)); layer.addFilter(.brightness(-0.1)) }
            // Drop shadow under the sphere (and the listening glow).
            layer.drawLayer { shadow in
                shadow.addFilter(.shadow(color: rgb(deep, 0.75), radius: side * 0.21, x: 0, y: side * 0.2))
                if state == .listening { shadow.addFilter(.shadow(color: rgb(accent, 0.38), radius: side * 0.25, x: 0, y: 0)) }
                shadow.fill(Path(ellipseIn: body), with: .color(rgb(navy)))
            }
            layer.clip(to: Path(ellipseIn: body))
            layer.fill(Path(ellipseIn: body), with: .radialGradient(
                Gradient(stops: [.init(color: rgb(cobalt), location: 0), .init(color: rgb(deep), location: 0.42), .init(color: rgb(navy), location: 0.78)]),
                center: CGPoint(x: body.minX + d * 0.30, y: body.minY + d * 0.40), startRadius: 0, endRadius: d * 0.78))
            // Inner shade at the bottom right, inner light at the top left.
            layer.fill(Path(ellipseIn: body), with: .radialGradient(
                Gradient(colors: [.clear, Color(.sRGB, red: 2 / 255, green: 8 / 255, blue: 24 / 255, opacity: 0.55)]),
                center: CGPoint(x: body.midX - d * 0.09, y: body.midY - d * 0.13), startRadius: d * 0.3, endRadius: d * 0.72))
            layer.fill(Path(ellipseIn: body), with: .radialGradient(
                Gradient(colors: [rgb(mist, 0.22), .clear]),
                center: CGPoint(x: body.minX + d * 0.12, y: body.minY + d * 0.12), startRadius: 0, endRadius: d * 0.4))
            // The glint: top right, orbiting while polishing.
            let gd = d * 0.62
            let home = CGPoint(x: body.maxX + d * 0.04 - gd / 2, y: body.minY - d * 0.06 + gd / 2)
            let angle = Angle.degrees(f.glintTurns * 360)
            let dx = home.x - body.midX, dy = home.y - body.midY
            let gc = CGPoint(x: body.midX + dx * cos(angle.radians) - dy * sin(angle.radians),
                             y: body.midY + dx * sin(angle.radians) + dy * cos(angle.radians))
            layer.opacity = f.glintOpacity
            layer.fill(Path(ellipseIn: CGRect(x: gc.x - gd / 2, y: gc.y - gd / 2, width: gd, height: gd)), with: .radialGradient(
                Gradient(stops: [.init(color: mix(petal, 0xFFFFFF, 0.38), location: 0), .init(color: rgb(rose), location: 0.3),
                                 .init(color: rgb(accentDeep, 0.5), location: 0.62), .init(color: .clear, location: 1)]),
                center: gc, startRadius: 0, endRadius: gd / 2))
        }
        if let sheen = f.sheen {
            context.drawLayer { layer in
                layer.clip(to: Path(ellipseIn: body))
                let span = d * 2.6
                let start = body.minX - span * 0.5 + (span + d) * sheen
                layer.fill(Path(body), with: .linearGradient(
                    Gradient(stops: [.init(color: .clear, location: 0.38), .init(color: .white.opacity(0.22), location: 0.5), .init(color: .clear, location: 0.62)]),
                    startPoint: CGPoint(x: start - d * 0.5, y: body.minY), endPoint: CGPoint(x: start + d * 0.5, y: body.maxY)))
            }
        }
    }
}
