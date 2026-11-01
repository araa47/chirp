import AppKit
import SwiftUI
import Observation

/// Which design the app draws: Pond (koi orange, today's look) or v2 (Graphite: neutral greys and one blue accent).
///
/// Read once at launch from `Preferences.designV2` (`ChirpMac/main.swift`, before `NSApplication.shared`); flipping
/// it needs a relaunch. The dynamic colour providers below run nonisolated whenever AppKit resolves a colour, so the
/// value is a plain global written once before any UI exists and only read after that. The snapshot renderer is the
/// one other writer: it swaps the design on the main actor around a render and puts it back.
public enum ChirpDesign: String, Sendable, CaseIterable {
    case pond
    case v2

    nonisolated(unsafe) public static var current: ChirpDesign = .pond

    /// The design a stored `designV2` preference asks for.
    public static func from(designV2: Bool) -> ChirpDesign { designV2 ? .v2 : .pond }

    /// Runs `body` with `design` as the current design, then restores the previous one. For the snapshot renderer
    /// and tests only: the app sets `current` once at launch.
    @MainActor
    public static func with<T>(_ design: ChirpDesign, _ body: () throws -> T) rethrows -> T {
        let previous = current
        current = design
        defer { current = previous }
        return try body()
    }
}

/// The design system's semantic tokens: the Pond table (koi-patterned bird identity) and the v2 Graphite table, with
/// the same keys.
///
/// Colour tokens are dynamic light/dark colours built the way `HUDColors` builds its own (an
/// `NSColor(name:dynamicProvider:)` wrapped in `Color`), so they resolve live with the appearance and the current
/// `ChirpDesign`. Native chrome follows the system; content uses explicit, view-owned text sizing below.
public enum ChirpColor {
    public typealias RGB = (r: Double, g: Double, b: Double)
    public typealias Pair = (light: RGB, dark: RGB)

    static func hex(_ value: UInt32) -> RGB {
        (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    /// A fixed light/dark colour that ignores the design (the HUD's error red, alpha helpers).
    static func dynamic(_ light: RGB, _ dark: RGB) -> NSColor {
        NSColor(name: "ChirpPond") { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
        }
    }

    /// A token that follows the current design as well as the appearance.
    static func dynamic(_ token: Token, alpha: Double = 1) -> NSColor {
        NSColor(name: "ChirpPond") { appearance in
            let pair = token.pair(in: ChirpDesign.current)
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? pair.dark : pair.light
            return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: alpha)
        }
    }

    /// One token's light value beside another's dark value (a tile that inverts between the themes).
    static func dynamic(light: Token, dark: Token) -> NSColor {
        NSColor(name: "ChirpPond") { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark.pair(in: ChirpDesign.current).dark : light.pair(in: ChirpDesign.current).light
            return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
        }
    }

    static func color(_ token: Token) -> Color { Color(nsColor: dynamic(token)) }
    /// A fixed light/dark colour (the speaker hues), the same in both designs.
    static func color(_ light: RGB, _ dark: RGB) -> Color { Color(nsColor: dynamic(light, dark)) }

    /// The token keys, shared by `Pond` and `Graphite`.
    public enum Token: CaseIterable, Sendable {
        case background, surface, surfaceRaised, ink, inkMuted, koi, koiDecor, koiContainer, onKoiContainer, onKoi
        case moon, moonFill, lily, record

        /// This token's light and dark values in `design`.
        public func pair(in design: ChirpDesign) -> Pair {
            switch design {
            case .pond: pond
            case .v2: graphite
            }
        }

        private var pond: Pair {
            switch self {
            case .background: Pond.background
            case .surface: Pond.surface
            case .surfaceRaised: Pond.surfaceRaised
            case .ink: Pond.ink
            case .inkMuted: Pond.inkMuted
            case .koi: Pond.koi
            case .koiDecor: Pond.koiDecor
            case .koiContainer: Pond.koiContainer
            case .onKoiContainer: Pond.onKoiContainer
            case .onKoi: Pond.onKoi
            case .moon: Pond.moon
            case .moonFill: Pond.moonFill
            case .lily: Pond.lily
            case .record: Pond.record
            }
        }

        private var graphite: Pair {
            switch self {
            case .background: Graphite.background
            case .surface: Graphite.surface
            case .surfaceRaised: Graphite.surfaceRaised
            case .ink: Graphite.ink
            case .inkMuted: Graphite.inkMuted
            case .koi: Graphite.koi
            case .koiDecor: Graphite.koiDecor
            case .koiContainer: Graphite.koiContainer
            case .onKoiContainer: Graphite.onKoiContainer
            case .onKoi: Graphite.onKoi
            case .moon: Graphite.moon
            case .moonFill: Graphite.moonFill
            case .lily: Graphite.lily
            case .record: Graphite.record
            }
        }
    }

    /// The Pond table: every token's light and dark values, so the tests can check contrast against them.
    public enum Pond {
        /// Window and app background.
        public static let background = (light: ChirpColor.hex(0xF6F7FA), dark: ChirpColor.hex(0x0D1526))
        /// The editor and cards.
        public static let surface = (light: ChirpColor.hex(0xFFFFFF), dark: ChirpColor.hex(0x121C30))
        /// Sidebars and list containers.
        public static let surfaceRaised = (light: ChirpColor.hex(0xECEFF5), dark: ChirpColor.hex(0x1A2640))
        /// Primary text.
        public static let ink = (light: ChirpColor.hex(0x1A2333), dark: ChirpColor.hex(0xE8ECF3))
        /// Snippets and meta text.
        public static let inkMuted = (light: ChirpColor.hex(0x5B6577), dark: ChirpColor.hex(0xA3ADBF))
        /// The brand accent: primary buttons, selection, links, focus. Also the app accent.
        public static let koi = (light: ChirpColor.hex(0xC2410C), dark: ChirpColor.hex(0xFF8A4C))
        /// Ripple rings and large shapes only, never body text.
        public static let koiDecor = (light: ChirpColor.hex(0xF26A1B), dark: ChirpColor.hex(0xFF8A4C))
        /// Selected rows and tonal buttons.
        public static let koiContainer = (light: ChirpColor.hex(0xFFE4D4), dark: ChirpColor.hex(0x5C2207))
        public static let onKoiContainer = (light: ChirpColor.hex(0x7A2A08), dark: ChirpColor.hex(0xFFD9C2))
        /// The koi fill is dark in light mode (white text on it) and light in dark mode (pond ink on it).
        public static let onKoi = (light: ChirpColor.hex(0xFFFFFF), dark: ChirpColor.hex(0x0D1526))
        /// AI/polish text colour (Organize, Polished, changed words)…
        public static let moon = (light: ChirpColor.hex(0x8A5A00), dark: ChirpColor.hex(0xF5C566))
        /// …and the golden fill those come on.
        public static let moonFill = (light: ChirpColor.hex(0xF5C566), dark: ChirpColor.hex(0xF5C566))
        /// Success and decisions (Connected, Decision callouts).
        public static let lily = (light: ChirpColor.hex(0x2F7A4F), dark: ChirpColor.hex(0x7CCB9B))
        /// The record/stop dot and errors only.
        public static let record = (light: ChirpColor.hex(0xD93636), dark: ChirpColor.hex(0xFF6B6B))
    }

    /// The v2 Graphite table: the same keys as `Pond`. Hand-ported from the `graphite` entry in the v2 prototype
    /// (`prototype/src/palettes.ts`: ice, powder, sky, deep, ink, inkMuted, accent, accentInk, and the dark bg, popover
    /// and muted), as mapped in the ship plan's section 5. The keys keep their `koi` names until Pond is removed;
    /// under Graphite "koi" is the blue accent. `ChirpThemeTests` checks every pair the way it checks Pond.
    public enum Graphite {
        /// Ice / the dark page.
        public static let background = (light: ChirpColor.hex(0xEEF1F5), dark: ChirpColor.hex(0x0C111B))
        /// White / the dark popover.
        public static let surface = (light: ChirpColor.hex(0xFFFFFF), dark: ChirpColor.hex(0x151B28))
        /// Powder / the top of the dark page gradient.
        public static let surfaceRaised = (light: ChirpColor.hex(0xE3E7ED), dark: ChirpColor.hex(0x1A2233))
        public static let ink = (light: ChirpColor.hex(0x0A0E16), dark: ChirpColor.hex(0xEEF1F5))
        public static let inkMuted = (light: ChirpColor.hex(0x475264), dark: ChirpColor.hex(0xA9B3C2))
        /// Accent text, links and focus: accentInk in light, the accent in dark.
        public static let koi = (light: ChirpColor.hex(0x1F58C4), dark: ChirpColor.hex(0x5B9BFF))
        /// Rings and glow only, never body text.
        public static let koiDecor = (light: ChirpColor.hex(0x5B9BFF), dark: ChirpColor.hex(0x5B9BFF))
        /// Selected rows and tonal buttons: sky / deep in light. The dark pair is not in the prototype: a blue-tinted
        /// slate (#1E3A66) that reads as the accent's container beside `surfaceRaised`, with a pale ink that keeps the
        /// sidebar's dimmed snippet and meta lines readable (`sidebarSelectionInk…` tests).
        public static let koiContainer = (light: ChirpColor.hex(0xD3D9E2), dark: ChirpColor.hex(0x1E3A66))
        public static let onKoiContainer = (light: ChirpColor.hex(0x1B2436), dark: ChirpColor.hex(0xDCE6F7))
        /// White on accentInk in light, Graphite ink on the accent in dark.
        public static let onKoi = (light: ChirpColor.hex(0xFFFFFF), dark: ChirpColor.hex(0x0A0E16))
        /// The AI/polish and success colours stay warm and green; the light values darken a step to read on ice.
        public static let moon = (light: ChirpColor.hex(0x7A5200), dark: ChirpColor.hex(0xF5C566))
        public static let moonFill = (light: ChirpColor.hex(0xF5C566), dark: ChirpColor.hex(0xF5C566))
        public static let lily = (light: ChirpColor.hex(0x1F6B45), dark: ChirpColor.hex(0x7CCB9B))
        /// The record/stop dot and errors: Pond's red.
        public static let record = Pond.record
    }

    /// The current design's table, for code that needs raw values (alpha blends, CGColors).
    public static func table(_ token: Token) -> Pair { token.pair(in: ChirpDesign.current) }

    public static let background = color(.background)
    public static let surface = color(.surface)
    public static let surfaceRaised = color(.surfaceRaised)
    public static let ink = color(.ink)
    public static let inkMuted = color(.inkMuted)
    public static let koi = color(.koi)
    public static let koiDecor = color(.koiDecor)
    public static let koiContainer = color(.koiContainer)
    public static let onKoiContainer = color(.onKoiContainer)
    public static let onKoi = color(.onKoi)
    public static let moon = color(.moon)
    public static let moonFill = color(.moonFill)
    public static let lily = color(.lily)
    public static let record = color(.record)

    /// The accent for AppKit's custom-drawn accents (the same dynamic colour as `koi`);
    /// system controls pick the accent up from the bundle's AccentColor asset instead.
    public static let koiAccent = dynamic(.koi)
}

public extension Color {
    /// The Pond tokens: `Color.chirp.koi`, `Color.chirp.inkMuted`, …
    static var chirp: ChirpColor.Type { ChirpColor.self }
}

public extension NSColor {
    /// The koi accent for custom-drawn AppKit accents (dots, discs, tints).
    static var chirpKoi: NSColor { ChirpColor.koiAccent }
}

/// The Pond spacing grid (4-point: 4, 8, 12, 16, 24, 32, 48) and the Mac content gutter.
public enum ChirpSpacing {
    public static let s4: CGFloat = 4
    public static let s8: CGFloat = 8
    public static let s12: CGFloat = 12
    public static let s16: CGFloat = 16
    public static let s24: CGFloat = 24
    public static let s32: CGFloat = 32
    public static let s48: CGFloat = 48
    /// The window-content gutter.
    public static let gutter: CGFloat = 20
}

/// The corner radii. Pond and v2 share control, row and sheet radii; v2 rounds custom-drawn cards to 18 and panels to
/// 24 (the v2 proposal's "controls 10 · cards 18 · panels 24"; native controls keep drawing their own corners, so
/// `control` stays 6).
public enum ChirpRadius {
    /// Controls and keycaps.
    public static let control: CGFloat = 6
    /// Rows and callouts.
    public static let row: CGFloat = 10
    /// Custom-drawn cards (Settings cards, callout blocks): 16 in Pond, 18 in v2.
    public static var card: CGFloat { card(in: ChirpDesign.current) }
    /// The HUD and panels: 16 in Pond, 24 in v2.
    public static var panel: CGFloat { panel(in: ChirpDesign.current) }
    /// Sheets.
    public static let sheet: CGFloat = 28

    public static func card(in design: ChirpDesign) -> CGFloat { design == .v2 ? 18 : 16 }
    public static func panel(in design: ChirpDesign) -> CGFloat { design == .v2 ? 24 : 16 }
}

/// The type helpers. Chrome stays native (SF Pro) in both designs; note titles and library section headers
/// use the New York serif, and timers use tabular digits so they don't jitter as they tick.
public enum ChirpType {
    /// The note title's font design. Both designs keep the New York serif for v1 (the v2 plan's typography decision);
    /// change the v2 case here to move v2 note titles to SF Pro.
    public static func noteTitleDesign(in design: ChirpDesign) -> Font.Design {
        switch design {
        case .pond: .serif
        case .v2: .serif
        }
    }
    /// A note title: New York serif, 26 semibold by default.
    public static func noteTitle(_ size: CGFloat = 26) -> Font {
        .system(size: size, weight: .semibold, design: noteTitleDesign(in: ChirpDesign.current))
    }
    /// A section header inside a note.
    public static let h2: Font = .system(size: 19, weight: .semibold)
    /// A library list title.
    public static let listTitle: Font = .system(size: 13, weight: .semibold)
    /// A library meta line.
    public static let meta: Font = .system(size: 12)
    /// Body text; pair with `bodyLineSpacing` for the 1.5 line height.
    public static let body: Font = .system(size: 15)
    public static let bodyLineSpacing: CGFloat = 7.5
    /// Timer text with tabular digits (SwiftUI).
    public static func timer(_ size: CGFloat = 15, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
    /// Timer text with tabular digits (AppKit).
    public static func timerFont(_ size: CGFloat = 13, weight: NSFont.Weight = .medium) -> NSFont {
        .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }
}

/// The round-bird brand glyph: the operator-approved pixels (`Assets/ChirpGlyph.png`, copied from
/// `android/artwork/chirp-icons/approved-glyph.png` verbatim), shipped as a template image so the
/// system or a koi tint colours it. No redrawn or cut-out version of the bird ships.
public enum ChirpBrand {
    /// The glyph as a template image: tint it with `contentTintColor` (AppKit) or `tinted(_:size:)`.
    @MainActor
    public static func glyph() -> NSImage? {
        let image = Bundle.main.image(forResource: "ChirpGlyph")
            ?? NSImage(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Assets/ChirpGlyph.png"))
        image?.isTemplate = true
        return image
    }

    /// The app icon's pond artwork (the koi-patterned bird on a lily pad under the moon): the welcome hero. From the
    /// bundle's icon when installed, else `Assets/AppIcon.png` (unbundled runs and the snapshots).
    @MainActor
    public static func pond() -> NSImage? {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Assets/AppIcon.png")
        return NSImage(contentsOf: file) ?? NSApp?.applicationIconImage
    }

    /// The glyph pre-tinted for SwiftUI, rendered at 2× so it stays crisp.
    @MainActor
    public static func tinted(_ tint: Color, size: CGFloat) -> NSImage? {
        guard let glyph = glyph(), let cg = glyph.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let tintNS = NSColor(tint).usingColorSpace(.sRGB) else { return nil }
        let scale: CGFloat = 2
        let pixels = Int(size * scale)
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        context.setBlendMode(.sourceIn)
        context.setFillColor(tintNS.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let tinted = context.makeImage() else { return nil }
        return NSImage(cgImage: tinted, size: NSSize(width: size, height: size))
    }
}

/// Explicit content sizing. Each window/model owns its instance; no shared mutable font state.
@MainActor @Observable
public final class ChirpTextSize {
    public static let steps: [CGFloat] = [1, 1.15, 1.3, 1.5, 1.75, 2]
    public private(set) var factor: CGFloat
    /// Called with the new factor after each change the user makes (never for `restore`): the owner stores it.
    @ObservationIgnored public var onChange: ((CGFloat) -> Void)?
    public init(factor: CGFloat = 1) { self.factor = Self.nearestStep(factor) }
    private static func nearestStep(_ factor: CGFloat) -> CGFloat {
        guard factor.isFinite else { return 1 }
        return steps.min(by: { abs($0 - factor) < abs($1 - factor) }) ?? 1
    }
    public var percent: String { "\(Int((factor * 100).rounded()))%" }
    public var canIncrease: Bool { factor < 2 }
    public var canDecrease: Bool { factor > 1 }
    public func increase() { change(Self.steps.first(where: { $0 > factor }) ?? 2) }
    public func decrease() { change(Self.steps.last(where: { $0 < factor }) ?? 1) }
    public func reset() { change(1) }
    /// Opens at a remembered size without reporting it back as a change.
    public func restore(_ factor: CGFloat) { self.factor = Self.nearestStep(factor) }
    private func change(_ new: CGFloat) {
        guard new != factor else { return }
        factor = new
        onChange?(new)
    }
}

private struct ChirpTextScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
extension EnvironmentValues {
    var chirpTextScale: CGFloat {
        get { self[ChirpTextScaleKey.self] }
        set { self[ChirpTextScaleKey.self] = newValue }
    }
}

/// Content roles retain their hierarchy at every size. Native menu/toolbar control chrome remains native.
enum ChirpTextRole {
    case title, section, body, callout, meta, keycap, caption
    var points: CGFloat {
        switch self { case .title: 26; case .section: 19; case .body: 15; case .callout: 13; case .meta, .keycap, .caption: 12 }
    }
}
private struct PondFont: ViewModifier {
    @Environment(\.chirpTextScale) private var scale
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    let digits: Bool
    func body(content: Content) -> some View {
        let font = Font.system(size: size * scale, weight: weight, design: design)
        content.font(digits ? font.monospacedDigit() : font)
    }
}
extension View {
    func pondFont(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default, digits: Bool = false) -> some View {
        modifier(PondFont(size: size, weight: weight, design: design, digits: digits))
    }
    func pondFont(_ role: ChirpTextRole, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        pondFont(role.points, weight: weight, design: design)
    }
}

/// The History window's text size (Notes has View ▸ Bigger/Smaller Text): a toolbar menu with the same steps.
struct TextSizeControl: View {
    let size: ChirpTextSize
    var body: some View {
        Menu {
            Text("Text size: " + size.percent)
            Button("Bigger Text", action: size.increase).keyboardShortcut("+", modifiers: .command).disabled(!size.canIncrease)
            Button("Smaller Text", action: size.decrease).keyboardShortcut("-", modifiers: .command).disabled(!size.canDecrease)
            Button("Actual Size", action: size.reset).keyboardShortcut("0", modifiers: .command).disabled(size.factor == 1)
        } label: {
            Label("Text Size", systemImage: "textformat.size")
        }
        .help("Text size: " + size.percent + " (up to 200%)")
        .accessibilityLabel("Text Size")
        .accessibilityValue(size.percent)
    }
}
