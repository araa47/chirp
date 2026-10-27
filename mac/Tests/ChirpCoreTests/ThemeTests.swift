import Foundation
import Testing
@testable import ChirpUI

/// The Pond tokens' contrast, computed the WCAG way (as `HUDColorsTests` does for the HUD): every
/// text-capable token must read on the surfaces it lands on, in both light and dark.
@Suite struct ChirpThemeTests {
    private func luminance(_ c: ChirpColor.RGB) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }
    private func contrast(_ a: ChirpColor.RGB, _ b: ChirpColor.RGB) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    @Test func textTokensMeetWCAGAAOnBackgroundAndSurface() {
        let surfaces = [(ChirpColor.Pond.background.light, ChirpColor.Pond.background.dark),
                        (ChirpColor.Pond.surface.light, ChirpColor.Pond.surface.dark)]
        let textTokens = [(ChirpColor.Pond.ink.light, ChirpColor.Pond.ink.dark),
                          (ChirpColor.Pond.inkMuted.light, ChirpColor.Pond.inkMuted.dark),
                          (ChirpColor.Pond.koi.light, ChirpColor.Pond.koi.dark),
                          (ChirpColor.Pond.moon.light, ChirpColor.Pond.moon.dark),
                          (ChirpColor.Pond.lily.light, ChirpColor.Pond.lily.dark)]
        for surface in surfaces {
            for token in textTokens {
                #expect(contrast(token.0, surface.0) >= 4.5, "\(token.0) on light \(surface.0)")
                #expect(contrast(token.1, surface.1) >= 4.5, "\(token.1) on dark \(surface.1)")
            }
        }
    }

    @Test func koiFillsKeepTheirTextReadable() {
        #expect(contrast(ChirpColor.Pond.onKoi.light, ChirpColor.Pond.koi.light) >= 4.5)
        #expect(contrast(ChirpColor.Pond.onKoi.dark, ChirpColor.Pond.koi.dark) >= 4.5)
        #expect(contrast(ChirpColor.Pond.onKoiContainer.light, ChirpColor.Pond.koiContainer.light) >= 4.5)
        #expect(contrast(ChirpColor.Pond.onKoiContainer.dark, ChirpColor.Pond.koiContainer.dark) >= 4.5)
    }

    /// The dark sidebar selection uses koiContainer; its warm ink dims for the snippet and meta lines but
    /// stays readable at body-text contrast (#303: the meta line is text people read, not a 3:1 UI mark).
    @Test func sidebarSelectionInkStaysReadableOnTheKoiPill() {
        func blend(_ a: ChirpColor.RGB, over b: ChirpColor.RGB, alpha: Double) -> ChirpColor.RGB {
            (r: a.r * alpha + b.r * (1 - alpha), g: a.g * alpha + b.g * (1 - alpha), b: a.b * alpha + b.b * (1 - alpha))
        }
        let koi = ChirpColor.Pond.koiContainer.dark
        #expect(contrast(ChirpColor.Pond.onKoiContainer.dark, koi) >= 4.5)
        #expect(contrast(blend(ChirpColor.Pond.onKoiContainer.dark, over: koi, alpha: RowInk.snippetOnPill), koi) >= 4.5)
        #expect(contrast(blend(ChirpColor.Pond.onKoiContainer.dark, over: koi, alpha: RowInk.metaOnPill), koi) >= 4.5)
    }

    /// `record` is the record/stop dot, not body text: WCAG AA for UI components is 3:1.
    @Test func recordDotStandsOutEnough() {
        #expect(contrast(ChirpColor.Pond.record.light, ChirpColor.Pond.background.light) >= 3)
        #expect(contrast(ChirpColor.Pond.record.dark, ChirpColor.Pond.background.dark) >= 3)
    }

    @Test func ripplePeriodShrinksAsSpeechPeaks() {
        #expect(Ripple.period(level: 0) == Ripple.periodAtSilence)
        #expect(abs(Ripple.period(level: 1) - Ripple.periodAtPeak) < 1e-9)
        #expect(abs(Ripple.period(level: 0.5) - 1.1) < 1e-9)
        #expect(Ripple.period(level: 0.8) < Ripple.period(level: 0.2))
        #expect(abs(Ripple.period(level: 2) - Ripple.periodAtPeak) < 1e-9, "levels clamp")
    }

    @Test func rippleClockPhaseAdvancesWithinOneCycle() {
        let base = Date(timeIntervalSinceReferenceDate: 100)
        #expect((0..<1).contains(Ripple.clockPhase(at: base, level: 0)))
        // Half a period later the phase is half a cycle on, whatever the level's period is.
        for level in [0.0, 0.35, 1.0] {
            let period = Ripple.period(level: level)
            let before = Ripple.clockPhase(at: base, level: level)
            let after = Ripple.clockPhase(at: base.addingTimeInterval(period / 2), level: level)
            #expect(abs(abs(after - before) - 0.5) < 1e-6, "level \(level)")  // half a cycle on, wrapping either way
        }
    }
}
