import AppKit
import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

/// PR 3 (v2): which overlay a dictation uses, and the Show in Notch switch in
/// Preferences, the menu and Settings.
@Suite struct OverlayRouteTests {
    typealias I = OverlayRoute.Inputs

    @Test func pondAlwaysKeepsTheClassicHUD() {
        for notch in [false, true] {
            for show in [false, true] {
                for pill in [false, true] {
                    for wave in [false, true] {
                        let i = I(designV2: false, showInNotch: show, screenHasNotch: notch, pillOnOtherScreens: pill, wordWaveform: wave)
                        #expect(OverlayRoute.choose(i) == .classic, "\(i)")
                    }
                }
            }
        }
    }

    @Test func v2PutsTheIslandOnANotchedScreenAndThePillElsewhere() {
        #expect(OverlayRoute.choose(I(designV2: true, screenHasNotch: true)) == .island)
        #expect(OverlayRoute.choose(I(designV2: true, screenHasNotch: false)) == .pill)
        // The pill not wanted: a screen without a notch falls back to the classic HUD, a notched one keeps the island.
        #expect(OverlayRoute.choose(I(designV2: true, screenHasNotch: false, pillOnOtherScreens: false)) == .classic)
        #expect(OverlayRoute.choose(I(designV2: true, screenHasNotch: true, pillOnOtherScreens: false)) == .island)
    }

    @Test func showInNotchOffOrTheWordWaveformKeepTheClassicHUD() {
        for notch in [false, true] {
            #expect(OverlayRoute.choose(I(designV2: true, showInNotch: false, screenHasNotch: notch)) == .classic)
            #expect(OverlayRoute.choose(I(designV2: true, screenHasNotch: notch, wordWaveform: true)) == .classic)
        }
    }

    @Test func defaultInputsAreTheClassicHUD() {
        #expect(OverlayRoute.choose(I()) == .classic)
    }

    // MARK: the switch

    @Test func showInNotchDefaultsOnAndPersistsOff() {
        let name = "chirp-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(Preferences(defaults: defaults).showInNotch)
        Preferences(defaults: defaults).showInNotch = false
        #expect(!Preferences(defaults: defaults).showInNotch)
        #expect(defaults.object(forKey: "showInNotch") as? Bool == false)
    }

    private func entries(_ configure: (inout MenuInputs) -> Void) -> [MenuEntry] {
        var m = MenuInputs()
        m.health = Health(engine: "p", ready: true)
        configure(&m)
        return MenuContent.entries(m)
    }

    @Test func theMenuOffersShowInNotchOnlyUnderV2() {
        #expect(!entries { _ in }.contains { $0.action == .toggleShowInNotch })
        #expect(!entries { $0.showInNotch = true }.contains { $0.title == "Show in Notch" })
        let on = entries { $0.notchOffered = true; $0.showInNotch = true }
        let row = try? #require(on.first { $0.action == .toggleShowInNotch })
        #expect(row?.title == "Show in Notch" && row?.mark == .on && row?.value == "On")
        let off = entries { $0.notchOffered = true; $0.showInNotch = false }.first { $0.action == .toggleShowInNotch }
        #expect(off?.mark == .off && off?.value == "Off")
    }

    @Test func showInNotchJoinsThePrivateSessionGroup() {
        let titles = entries { $0.notchOffered = true }.filter { !$0.isSeparator }.map(\.title)
        let i = try? #require(titles.firstIndex(of: "Private session"))
        #expect(i.map { titles[$0 + 1] } == "Show in Notch")
        #expect(i.map { titles[$0 + 2] } == "Clean-up")
    }

    @Test func pondMenuIsUnchanged() {
        let pond = entries { _ in }
        let v2 = entries { $0.notchOffered = true }
        #expect(v2.count == pond.count + 1)
        #expect(v2.filter { $0.action != .toggleShowInNotch } == pond)
    }
}

@MainActor
@Suite struct ShowInNotchSettingsTests {
    @Test func theRowIsHiddenUnlessV2() {
        let form = SettingsForm(SettingsState())
        #expect(form.showInNotch.isHiddenOrHasHiddenAncestor)
        var s = SettingsState()
        s.notchOffered = true
        s.showInNotch = false
        form.apply(s, full: true)
        #expect(!form.showInNotch.superview!.isHidden)
        #expect(form.showInNotch.state == .off)
        s.showInNotch = true
        form.apply(s, full: true)
        #expect(form.showInNotch.state == .on)
        s.notchOffered = false
        form.apply(s, full: true)
        #expect(form.showInNotch.isHiddenOrHasHiddenAncestor)
    }
}
