import Foundation
import Testing
@testable import ChirpUI

/// The Pond and Graphite tokens' contrast, computed the WCAG way (as `HUDColorsTests` does for the HUD): every
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

    /// Both tables, Pond and the v2 Graphite one, meet the same bars.
    @Test(arguments: ChirpDesign.allCases)
    func textTokensMeetWCAGAAOnBackgroundAndSurface(design: ChirpDesign) {
        typealias T = ChirpColor.Token
        for surface in [T.background, .surface].map({ $0.pair(in: design) }) {
            for token in [T.ink, .inkMuted, .koi, .moon, .lily].map({ $0.pair(in: design) }) {
                #expect(contrast(token.light, surface.light) >= 4.5, "\(design): \(token.light) on light \(surface.light)")
                #expect(contrast(token.dark, surface.dark) >= 4.5, "\(design): \(token.dark) on dark \(surface.dark)")
            }
        }
    }

    @Test(arguments: ChirpDesign.allCases)
    func koiFillsKeepTheirTextReadable(design: ChirpDesign) {
        let (koi, onKoi) = (ChirpColor.Token.koi.pair(in: design), ChirpColor.Token.onKoi.pair(in: design))
        let (container, onContainer) = (ChirpColor.Token.koiContainer.pair(in: design), ChirpColor.Token.onKoiContainer.pair(in: design))
        #expect(contrast(onKoi.light, koi.light) >= 4.5)
        #expect(contrast(onKoi.dark, koi.dark) >= 4.5)
        #expect(contrast(onContainer.light, container.light) >= 4.5)
        #expect(contrast(onContainer.dark, container.dark) >= 4.5)
    }

    /// The dark sidebar selection uses koiContainer; its ink dims for the snippet and meta lines but
    /// stays readable at body-text contrast (#303: the meta line is text people read, not a 3:1 UI mark). Graphite's
    /// dark pair is derived (not in the prototype), so this is the test that proves it.
    @Test(arguments: ChirpDesign.allCases)
    func sidebarSelectionInkStaysReadableOnTheKoiPill(design: ChirpDesign) {
        func blend(_ a: ChirpColor.RGB, over b: ChirpColor.RGB, alpha: Double) -> ChirpColor.RGB {
            (r: a.r * alpha + b.r * (1 - alpha), g: a.g * alpha + b.g * (1 - alpha), b: a.b * alpha + b.b * (1 - alpha))
        }
        for dark in [false, true] {
            let pill = ChirpColor.Token.koiContainer.pair(in: design), ink = ChirpColor.Token.onKoiContainer.pair(in: design)
            let (koi, on) = dark ? (pill.dark, ink.dark) : (pill.light, ink.light)
            #expect(contrast(on, koi) >= 4.5, "\(design) dark=\(dark)")
            #expect(contrast(blend(on, over: koi, alpha: RowInk.snippetOnPill), koi) >= 4.5, "\(design) dark=\(dark)")
            #expect(contrast(blend(on, over: koi, alpha: RowInk.metaOnPill), koi) >= 4.5, "\(design) dark=\(dark)")
        }
    }

    /// `record` is the record/stop dot, not body text: WCAG AA for UI components is 3:1.
    @Test(arguments: ChirpDesign.allCases)
    func recordDotStandsOutEnough(design: ChirpDesign) {
        let (record, background) = (ChirpColor.Token.record.pair(in: design), ChirpColor.Token.background.pair(in: design))
        #expect(contrast(record.light, background.light) >= 3)
        #expect(contrast(record.dark, background.dark) >= 3)
    }

    /// The numbers the ship plan's section 5 quotes for Graphite, so a hand edit to the table shows up here.
    @Test func graphiteMatchesThePlannedContrast() {
        let g = ChirpColor.Graphite.self
        #expect(abs(contrast(g.ink.light, g.background.light) - 17.05) < 0.01)
        #expect(abs(contrast(g.inkMuted.light, g.background.light) - 6.97) < 0.01)
        #expect(abs(contrast(g.koi.light, g.background.light) - 5.70) < 0.01)
        #expect(abs(contrast(g.koi.dark, g.background.dark) - 6.82) < 0.01)
        #expect(abs(contrast(g.onKoi.light, g.koi.light) - 6.46) < 0.01)
        #expect(abs(contrast(g.onKoi.dark, g.koi.dark) - 6.97) < 0.01)
    }

    /// The PR 5 accent asset (light #2F6FE0, dark #4B86E8): macOS draws white labels on the accent, so white must
    /// read on it (4.5 in light; 3:1 UI-component level in dark). The prototype's #5B9BFF would fail as a fill.
    @Test func theGraphiteAccentFillCarriesWhiteLabels() {
        let white: ChirpColor.RGB = (1, 1, 1)
        #expect(contrast(white, ChirpColor.hex(0x2F6FE0)) >= 4.5)
        #expect(contrast(white, ChirpColor.hex(0x4B86E8)) >= 3)
        #expect(contrast(white, ChirpColor.hex(0x5B9BFF)) < 3)
    }

    /// The HUD's accent (revised words, the word waveform) on its opaque stand-in surface, in either design.
    @Test(arguments: ChirpDesign.allCases)
    func theHUDAccentReadsOnTheHUDSurface(design: ChirpDesign) {
        let (action, surface) = (HUDColors.actionRGB(in: design), HUDColors.surfaceRGB(in: design))
        #expect(contrast(action.light, surface.light) >= 4.5)
        #expect(contrast(action.dark, surface.dark) >= 4.5)
        #expect(contrast(HUDColors.errorDark, surface.dark) >= 4.5)
        #expect(contrast(HUDColors.errorLight, surface.light) >= 4.5)
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
