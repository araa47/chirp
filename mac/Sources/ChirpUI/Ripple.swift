import AppKit
import QuartzCore
import SwiftUI

/// The Pond motif: three concentric koi rings expanding out of the mic — *the* "Chirp is listening"
/// sign (HUD glyph, record button, recording rows, keyboard strip, voice panel).
///
/// The input level drives the tempo: each ring scales 1 → 1.8 while its opacity goes 0.5 → 0,
/// staggered by a third, and the period shortens from 1.6 s at silence to 0.6 s at peak level —
/// speech makes the water ripple faster. Reduce Motion shows one static koi ring whose stroke
/// weight follows the level instead.
public struct Ripple: View {
    /// The normalized input level, 0...1 (the same meter the waveform bars use).
    var level: Double
    var reduceMotion = false
    /// A fixed phase (0...1) for the snapshots; nil runs on the clock.
    var phase: Double?
    /// The rings' colour: koiDecor, a large-shape-only token.
    var color = Color.chirp.koiDecor
    /// The static ring's colour (Reduce Motion).
    var staticColor = Color.chirp.koi
    /// The side the rings are laid out in; the HUD glyph is 20 pt.
    var side: CGFloat = 20

    /// Seconds per ring cycle at silence, and at peak level.
    public static let periodAtSilence: Double = 1.6
    public static let periodAtPeak: Double = 0.6

    /// The cycle length for a level: 1.6 s at silence, 0.6 s at peak, linear in between.
    public static func period(level: Double) -> Double {
        periodAtSilence + (periodAtPeak - periodAtSilence) * min(max(level, 0), 1)
    }

    public var body: some View {
        Group {
            if reduceMotion {
                staticRing
            } else if let phase {
                rings(phase: phase)
            } else {
                AnimatedRipple(period: Self.period(level: level), color: color)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: side, height: side)
    }

    /// Where the ring cycle stands (0...1) at a moment in time.
    static func clockPhase(at date: Date, level: Double) -> Double {
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period(level: level))
        return t / period(level: level)
    }

    private func rings(phase: Double) -> some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            // The outermost ring (scale 1.8) just fits the box; strokes thin slightly as they expand.
            let base = min(size.width, size.height) / 1.8
            let line = max(size.width / 12, 1.2)
            for index in 0..<3 {
                let progress = (phase + Double(index) / 3).truncatingRemainder(dividingBy: 1)
                let diameter = base * (1 + 0.8 * progress)
                let opacity = 0.5 * (1 - progress)
                let rect = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
                context.stroke(Path(ellipseIn: rect), with: .color(color.opacity(opacity)),
                               style: StrokeStyle(lineWidth: line * (1 - 0.35 * progress)))
            }
        }
        .accessibilityHidden(true)
    }

    /// Reduce Motion: one steady koi ring whose stroke weight follows the level.
    private var staticRing: some View {
        Circle()
            .strokeBorder(staticColor, lineWidth: max(side / 14, 1.2) + side / 8 * min(max(level, 0), 1))
            .padding(side * 0.14)
            .accessibilityHidden(true)
    }
}

/// Core Animation owns the live clock. Avoid an escaping TimelineView content
/// callback, which appears in repeated-HUD EXC_BAD_ACCESS crash reports.
private struct AnimatedRipple: NSViewRepresentable {
    let period: Double
    let color: Color

    func makeNSView(context: Context) -> RippleLayerView {
        let view = RippleLayerView(frame: .zero)
        view.configure(period: period, color: NSColor(color))
        return view
    }

    func updateNSView(_ view: RippleLayerView, context: Context) {
        view.configure(period: period, color: NSColor(color))
    }
}

/// No SwiftUI state wrappers or per-frame main-actor callbacks. Geometry, colour
/// and playback speed update in place, without restarting the rings on every level.
final class RippleLayerView: NSView {
    private(set) var rings: [CAShapeLayer] = []
    private var period: Double?
    private var ringColor = NSColor.clear
    private var strokeWidth: CGFloat?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for index in 0..<3 {
            let ring = CAShapeLayer()
            ring.fillColor = nil
            ring.opacity = 0
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1
            scale.toValue = 1.8
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.5
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = Ripple.periodAtSilence
            group.repeatCount = .infinity
            group.timeOffset = Double(index) * group.duration / 3
            group.timingFunction = CAMediaTimingFunction(name: .linear)
            layer?.addSublayer(ring)
            ring.add(group, forKey: "chirp.ripple")
            rings.append(ring)
        }
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(period: Double, color: NSColor) {
        ringColor = color
        updateColors()
        guard self.period != period else { return }
        self.period = period
        let now = CACurrentMediaTime()
        for ring in rings {
            let current = ring.convertTime(now, from: nil)
            ring.speed = Float(Ripple.periodAtSilence / period)
            ring.beginTime = now
            ring.timeOffset = current
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let side = min(bounds.width, bounds.height)
        let diameter = side / 1.8
        let rect = CGRect(x: -diameter / 2, y: -diameter / 2, width: diameter, height: diameter)
        let width = max(side / 12, 1.2)
        let strokeChanged = strokeWidth != width
        strokeWidth = width
        for ring in rings {
            ring.position = CGPoint(x: bounds.midX, y: bounds.midY)
            ring.path = CGPath(ellipseIn: rect, transform: nil)
            ring.lineWidth = width
            if strokeChanged, let group = ring.animation(forKey: "chirp.ripple")?.copy() as? CAAnimationGroup {
                let stroke = CABasicAnimation(keyPath: "lineWidth")
                stroke.fromValue = width
                stroke.toValue = width * 0.65 / 1.8
                group.animations = (group.animations ?? []).filter { ($0 as? CABasicAnimation)?.keyPath != "lineWidth" } + [stroke]
                group.beginTime = ring.convertTime(CACurrentMediaTime(), from: nil)
                ring.add(group, forKey: "chirp.ripple")
            }
        }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for ring in rings { ring.strokeColor = ringColor.cgColor }
        }
    }
}
