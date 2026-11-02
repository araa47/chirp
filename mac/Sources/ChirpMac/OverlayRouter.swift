import AppKit
import ChirpUI

/// The overlay `DictationController` talks to. One `HUDModel` feeds both surfaces; each `show()` asks
/// `OverlayRoute.choose` where it goes (classic HUD, notch island or floating pill) for the screen under the mouse,
/// and retires the other surface without clearing the model. With the v2 design off it is the classic HUD, unchanged.
@MainActor
final class OverlayRouter: DictationOverlay {
    let model = HUDModel()
    private lazy var classic = HUDController(model: model)
    private lazy var notch = NotchController(model: model)
    /// The surface the last `show()` used; hides go to it.
    private var active: OverlaySurface?

    /// The surface on screen takes clicks (the classic HUD's Use raw button); the island does not.
    var acceptsClicks: Bool { (active ?? classic).acceptsClicks }

    func show() {
        let target: OverlaySurface
        if ChirpDesign.current == .v2, let screen = Self.screenUnderMouse() {
            // Only v2 looks at the screen at all; Pond goes straight to the classic HUD as before.
            let g = NotchController.geometry(of: screen)
            let route = OverlayRoute.choose(.init(designV2: true, showInNotch: settings.showInNotch, screenHasNotch: g.hasNotch,
                                                  pillOnOtherScreens: NotchWindowPolicy.pillOnOtherScreens,
                                                  wordWaveform: model.wordWaveform))
            if route == .classic {
                target = classic
            } else {
                notch.prepare(g)
                target = notch
            }
        } else {
            target = classic
        }
        if let active, active !== target { active.retire() }
        active = target
        target.show()
    }

    func hide() { (active ?? classic).hide() }
    func hide(after seconds: Double) { (active ?? classic).hide(after: seconds) }
    func cancelHide() { active?.cancelHide() }

    /// The screen the classic HUD also uses: the one under the mouse, else the main screen.
    private static func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }
}
