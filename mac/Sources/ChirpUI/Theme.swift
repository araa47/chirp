import AppKit
import SwiftUI
import Observation

/// The Pond design system: the koi-patterned bird identity as semantic tokens.
///
/// Colour tokens are dynamic light/dark colours built the way `HUDColors` builds its own (an
/// `NSColor(name:dynamicProvider:)` wrapped in `Color`), so they resolve live with the appearance.
/// Native chrome follows the system; content uses explicit, view-owned text sizing below.
public enum ChirpColor {
    public typealias RGB = (r: Double, g: Double, b: Double)

    static func hex(_ value: UInt32) -> RGB {
        (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    static func dynamic(_ light: RGB, _ dark: RGB) -> NSColor {
        NSColor(name: "ChirpPond") { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
        }
    }

    static func color(_ light: RGB, _ dark: RGB) -> Color { Color(nsColor: dynamic(light, dark)) }

    /// Every token's light and dark values, so the tests can check contrast against them.
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

    public static let background = color(Pond.background.light, Pond.background.dark)
    public static let surface = color(Pond.surface.light, Pond.surface.dark)
    public static let surfaceRaised = color(Pond.surfaceRaised.light, Pond.surfaceRaised.dark)
    public static let ink = color(Pond.ink.light, Pond.ink.dark)
    public static let inkMuted = color(Pond.inkMuted.light, Pond.inkMuted.dark)
    public static let koi = color(Pond.koi.light, Pond.koi.dark)
    public static let koiDecor = color(Pond.koiDecor.light, Pond.koiDecor.dark)
    public static let koiContainer = color(Pond.koiContainer.light, Pond.koiContainer.dark)
    public static let onKoiContainer = color(Pond.onKoiContainer.light, Pond.onKoiContainer.dark)
    public static let onKoi = color(Pond.onKoi.light, Pond.onKoi.dark)
    public static let moon = color(Pond.moon.light, Pond.moon.dark)
    public static let moonFill = color(Pond.moonFill.light, Pond.moonFill.dark)
    public static let lily = color(Pond.lily.light, Pond.lily.dark)
    public static let record = color(Pond.record.light, Pond.record.dark)

    /// The koi accent for AppKit's custom-drawn accents (the same dynamic colour as `koi`);
    /// system controls pick the accent up from the bundle's AccentColor asset instead.
    public static let koiAccent = dynamic(Pond.koi.light, Pond.koi.dark)
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

/// The Pond corner radii.
public enum ChirpRadius {
    /// Controls and keycaps.
    public static let control: CGFloat = 6
    /// Rows and callouts.
    public static let row: CGFloat = 10
    /// The HUD, panels and cards.
    public static let panel: CGFloat = 16
    /// Sheets.
    public static let sheet: CGFloat = 28
}

/// The Pond type helpers. Chrome stays native (SF Pro); note titles and library section headers
/// use the New York serif, and timers use tabular digits so they don't jitter as they tick.
public enum ChirpType {
    /// A note title: New York serif, 26 semibold by default.
    public static func noteTitle(_ size: CGFloat = 26) -> Font { .system(size: size, weight: .semibold, design: .serif) }
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
    public init(factor: CGFloat = 1) { self.factor = Self.steps.min(by: { abs($0 - factor) < abs($1 - factor) }) ?? 1 }
    public var percent: String { "\(Int((factor * 100).rounded()))%" }
    public var canIncrease: Bool { factor < 2 }
    public var canDecrease: Bool { factor > 1 }
    public func increase() { factor = Self.steps.first(where: { $0 > factor }) ?? 2 }
    public func decrease() { factor = Self.steps.last(where: { $0 < factor }) ?? 1 }
    public func reset() { factor = 1 }
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
