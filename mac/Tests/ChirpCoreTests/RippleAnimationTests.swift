import AppKit
import QuartzCore
import Testing
@testable import ChirpUI

@Suite @MainActor struct RippleAnimationTests {
    @Test func nativeRingsKeepTheirAnimationWhenLevelChanges() throws {
        let view = RippleLayerView(frame: NSRect(x: 0, y: 0, width: 120, height: 120))
        view.configure(period: Ripple.periodAtSilence, color: .orange)
        view.layout()
        #expect(view.rings.count == 3)
        for (index, ring) in view.rings.enumerated() {
            let animation = try #require(ring.animation(forKey: "chirp.ripple") as? CAAnimationGroup)
            #expect(animation.repeatCount == .infinity)
            #expect(animation.timeOffset == Double(index) * Ripple.periodAtSilence / 3)
            #expect(ring.path != nil && ring.strokeColor != nil)
            #expect(ring.speed == 1)
        }
        view.configure(period: Ripple.periodAtPeak, color: .blue)
        for ring in view.rings {
            #expect(abs(ring.speed - Float(Ripple.periodAtSilence / Ripple.periodAtPeak)) < 0.0001)
            #expect(ring.animation(forKey: "chirp.ripple") != nil)
        }
    }
}
