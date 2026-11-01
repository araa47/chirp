import AppKit
import ChirpUI
import SwiftUI

/// Every window-server choice for the notch panel, in one place. **None of these is verified on notched hardware**
/// (the PR 0 spike has not run; see `spikes/notch` on `v2/pr0-notch-spike` for the harness that answers them).
/// Change them here and nowhere else.
enum NotchWindowPolicy {
    /// UNVERIFIED. `.statusBar` (25) is one above the menu bar (`.mainMenu`, 24), so the island can draw over the bar
    /// around the notch, and below open menus (`.popUpMenu`, 101), so a menu the user opens still covers it. It is
    /// the level the classic HUD already uses. Unknown: whether macOS 14/15/26 composite it over the menu bar in a
    /// full-screen app, and whether it covers status items next to the notch.
    static let level: NSWindow.Level = .statusBar
    /// UNVERIFIED. The classic HUD's behaviour: on every Space, alongside full-screen apps, not moved by Exposé or
    /// Mission Control, and out of ⌘` cycling. Unknown under Stage Manager and in clamshell.
    static let collectionBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    /// Screens without a notch get the floating pill; false keeps the classic HUD there (`OverlayRoute.choose`).
    static let pillOnOtherScreens = true
}

private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    /// UNVERIFIED (spike harness note): AppKit may move a window off the menu bar; the island must sit exactly where
    /// `OverlayPlacement` put it, over the bar around the notch.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The v2 island: a fixed-size, click-through, non-activating panel at the top of the screen under the mouse, wrapped
/// around the notch (or a floating pill under the menu bar on a screen without one). It never takes focus or the
/// mouse, so Use raw stays on ⌃⌥Z and the menu. The island's own shape and state animation live in `IslandView`;
/// this only orders the panel in and out with a fade.
@MainActor
final class NotchController: OverlaySurface {
    let model: HUDModel
    private var panel: NotchPanel?
    private var host: NSHostingView<IslandView>?
    private var hideTask: Task<Void, Never>?
    /// Bumped by every show/hide so a fade-out that was overtaken never orders the panel out.
    private var generation = 0
    /// Where the next `show()` puts the island: set by `OverlayRouter` with the screen it chose.
    private var geometry: NotchGeometry?
    /// The island takes no clicks: Use raw is the hotkey and the menu (`DictationController` opens the offer).
    let acceptsClicks = false

    init(model: HUDModel) { self.model = model }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// The island's geometry on `screen`: its notch from the safe-area inset and the two auxiliary top areas, and the
    /// menu bar's height (for the floating pill) from what `visibleFrame` leaves out at the top.
    static func geometry(of screen: NSScreen) -> NotchGeometry {
        NotchGeometry.of(screenFrame: screen.frame, safeAreaTop: screen.safeAreaInsets.top,
                         auxiliaryTopLeftWidth: screen.auxiliaryTopLeftArea?.width,
                         auxiliaryTopRightWidth: screen.auxiliaryTopRightArea?.width,
                         menuBarHeight: max(0, screen.frame.maxY - screen.visibleFrame.maxY))
    }

    func prepare(_ geometry: NotchGeometry) { self.geometry = geometry }

    private func makePanel() -> NotchPanel {
        let p = NotchPanel(contentRect: NSRect(origin: .zero, size: IslandMetrics.panelSize(mode: .notch)),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = NotchWindowPolicy.level
        p.collectionBehavior = NotchWindowPolicy.collectionBehavior
        p.backgroundColor = .clear
        p.isOpaque = false
        // The view draws its own shadow inside the transparent margin; a window shadow would outline the whole panel.
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.ignoresMouseEvents = true
        p.isMovable = false
        p.animationBehavior = .none
        return p
    }

    private func hostedView(_ g: NotchGeometry) -> NSHostingView<IslandView> {
        let view = IslandView(model: model, mode: g.mode, notch: g.notchSize, useRawKey: settings.useRawHotkey.title)
        if let host {
            host.rootView = view
            return host
        }
        let h = NSHostingView(rootView: view)
        // Fixed size: the panel never follows the view; the island morphs inside it.
        h.sizingOptions = []
        h.autoresizingMask = [.width, .height]
        host = h
        return h
    }

    func show() {
        hideTask?.cancel()
        generation += 1
        model.reduceMotion = reduceMotion
        model.increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        // The router always prepares a geometry; the main screen is only a fallback.
        guard let g = geometry ?? NSScreen.main.map(Self.geometry(of:)) else { return }
        let p = panel ?? makePanel()
        panel = p
        let content = hostedView(g)
        if p.contentView !== content { p.contentView = content }
        p.setFrame(g.panelFrame, display: true)
        if p.isVisible, p.alphaValue > 0.05 {
            // Already on screen (possibly mid fade-out): keep it and bring it back to full opacity.
            p.alphaValue = 1
            return
        }
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduceMotion ? 0.12 : 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
        }
    }

    func cancelHide() {
        hideTask?.cancel()
        generation += 1
        if let p = panel, p.isVisible { p.alphaValue = 1 }
    }

    func hide() {
        hideTask?.cancel()
        generation += 1
        let token = generation
        guard let p = panel, p.isVisible else { model.reset(); return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduceMotion ? 0.1 : 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.generation == token else { return }
            p.orderOut(nil)
            p.alphaValue = 1
            self.model.reset()
        }
    }

    func hide(after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func retire() {
        hideTask?.cancel()
        generation += 1
        guard let p = panel, p.isVisible else { return }
        p.orderOut(nil)
        p.alphaValue = 1
    }
}
