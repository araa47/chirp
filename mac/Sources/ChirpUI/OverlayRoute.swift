import Foundation

/// Where one dictation's overlay appears. The Mac app's `OverlayRouter` asks `choose` on every show; this is the
/// pure half so it can be tested (ChirpMac has no test target).
public enum OverlayRoute: Equatable, Sendable {
    /// The classic HUD: the bottom-centre panel (`HUDView`).
    case classic
    /// The island drawn around the notch of the screen under the mouse.
    case island
    /// The same island as a floating pill at the top centre of a screen without a notch.
    case pill

    public struct Inputs: Equatable, Sendable {
        /// The v2 design is on for this launch (`ChirpDesign.current == .v2`).
        public var designV2 = false
        /// Settings › Dictation "Show in the notch" and the menu's "Show in Notch".
        public var showInNotch = true
        /// The screen under the mouse has a notch the island can wrap (a top safe-area inset and both auxiliary areas).
        public var screenHasNotch = false
        /// Screens without a notch get the floating pill; false keeps the classic HUD there.
        public var pillOnOtherScreens = true
        /// The word waveform is on: it needs the classic HUD's width, so the island steps aside.
        public var wordWaveform = false

        public init(designV2: Bool = false, showInNotch: Bool = true, screenHasNotch: Bool = false,
                    pillOnOtherScreens: Bool = true, wordWaveform: Bool = false) {
            self.designV2 = designV2
            self.showInNotch = showInNotch
            self.screenHasNotch = screenHasNotch
            self.pillOnOtherScreens = pillOnOtherScreens
            self.wordWaveform = wordWaveform
        }
    }

    /// The classic HUD unless v2 is on and Show in Notch is on; then the island on a notched screen, the pill
    /// elsewhere (or the classic HUD when the pill is not wanted). The word waveform always keeps the classic HUD.
    public static func choose(_ i: Inputs) -> OverlayRoute {
        guard i.designV2, i.showInNotch, !i.wordWaveform else { return .classic }
        if i.screenHasNotch { return .island }
        return i.pillOnOtherScreens ? .pill : .classic
    }
}
