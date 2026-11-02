import AppKit
import ChirpUI
import SwiftUI

/// What `DictationController` drives while dictating: one shared `HUDModel` and when it is on screen. The classic HUD
/// (`HUDController`) and the v2 notch island (`NotchController`) both conform; `OverlayRouter` picks one per show.
@MainActor
protocol DictationOverlay: AnyObject {
    var model: HUDModel { get }
    func show()
    /// Fades out, then orders out and clears the model.
    func hide()
    /// Hide after a delay unless something else is shown first.
    func hide(after seconds: Double)
    /// Keeps it on screen: cancels a scheduled or running hide.
    func cancelHide()
    /// Has VoiceOver speak a status change.
    func announce(_ text: String)
    /// What is on screen takes clicks: false for the island, so a shown Use raw also needs the ⌃⌥Z offer.
    var acceptsClicks: Bool { get }
}

extension DictationOverlay {
    /// Every overlay never takes focus, so it would otherwise stay silent: post the announcement app-wide.
    func announce(_ text: String) {
        guard !text.isEmpty else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

/// An overlay the router can swap out mid-dictation without clearing the model the other one now shows.
@MainActor
protocol OverlaySurface: DictationOverlay {
    /// Orders out at once and cancels any pending hide, leaving the shared model as it is.
    func retire()
}

private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A non-activating floating panel: it shows partial text without ever taking focus from the target app.
/// The surface is `.glassEffect()` on macOS 26 and otherwise a real `NSVisualEffectView` (HUD material, so it follows
/// light and dark), masked to a rounded rectangle; the SwiftUI content sits on top and the panel follows the content's size with a short animation.
@MainActor
final class HUDController: OverlaySurface {
    let model: HUDModel
    private var panel: HUDPanel?
    private var hideTask: Task<Void, Never>?
    private var size = CGSize(width: HUDViewMetrics.width, height: 44)
    /// Bumped by every show/hide so a fade-out that was overtaken never orders the panel out.
    private var generation = 0

    private static let appearDuration = 0.18
    private static let disappearDuration = 0.15
    private static let appearScale: CGFloat = 0.94

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// The Use raw button is clickable.
    let acceptsClicks = true

    init(model: HUDModel = HUDModel()) { self.model = model }

    private func makePanel() -> HUDPanel {
        let p = HUDPanel(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let host = NSHostingView(rootView: HUDView(model: model) { [weak self] s in self?.resize(to: s) })
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        if Self.hasGlass {
            // macOS 26: the SwiftUI view draws its own `.glassEffect()`, so the panel is just a clear window around it.
            model.usesGlass = true
            p.contentView = host
        } else {
            let effect = NSVisualEffectView(frame: host.frame)
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.maskImage = Self.roundedMask(radius: HUDViewMetrics.corner)
            effect.addSubview(host)
            p.contentView = effect
        }
        return p
    }

    /// The system draws Liquid Glass (macOS 26 and later); earlier systems keep the `.hudWindow` blur.
    private static var hasGlass: Bool {
        #if swift(>=6.2)
        if #available(macOS 26, *) { return true }
        #endif
        return false
    }

    /// A stretchable rounded-rect mask: the corners stay round at any size, so the blur is a capsule when the HUD is
    /// one line and a rounded rectangle when the text wraps.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    func show() {
        hideTask?.cancel()
        generation += 1
        model.reduceMotion = reduceMotion
        model.increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let p = panel ?? makePanel()
        panel = p
        let target = frame(for: size)
        if p.isVisible, p.alphaValue > 0.05 {
            // Already on screen (possibly mid fade-out): keep it and bring it back to full opacity.
            p.alphaValue = 1
            p.setFrame(target, display: true)
            return
        }
        if reduceMotion {
            // Reduce Motion keeps a plain cross-fade and drops the scale.
            p.setFrame(target, display: true)
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                p.animator().alphaValue = 1
            }
        } else {
            p.setFrame(Self.scaled(target, by: Self.appearScale), display: true)
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.appearDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                p.animator().alphaValue = 1
                p.animator().setFrame(target, display: true)
            } completionHandler: { p.invalidateShadow() }
        }
    }

    /// Keeps the HUD on screen: cancels a scheduled or running hide (a new dictation starts while the last outcome lingers).
    func cancelHide() {
        hideTask?.cancel()
        generation += 1
        if let p = panel, p.isVisible { p.alphaValue = 1 }
    }

    func hide() { hide(animated: true) }

    /// Fades the HUD out (and shrinks it a little unless Reduce Motion is on), then orders it out and clears the model.
    func hide(animated: Bool) {
        hideTask?.cancel()
        generation += 1
        let token = generation
        guard let p = panel, p.isVisible else { model.reset(); return }
        let finish = { [weak self] in
            guard let self, self.generation == token else { return }
            p.orderOut(nil)
            p.alphaValue = 1
            self.model.reset()
        }
        guard animated else { finish(); return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduceMotion ? 0.1 : Self.disappearDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().alphaValue = 0
            if !reduceMotion { p.animator().setFrame(Self.scaled(p.frame, by: Self.appearScale), display: true) }
        } completionHandler: { finish() }
    }

    /// Hide after a delay unless something else is shown first.
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

    /// The content changed size (text grew, a badge appeared): follow it, animated unless Reduce Motion is on.
    private func resize(to s: CGSize) {
        size = s
        guard let p = panel, p.isVisible, p.alphaValue > 0.95 else { return }
        let target = frame(for: s)
        if reduceMotion {
            p.setFrame(target, display: true)
            p.invalidateShadow()
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                p.animator().setFrame(target, display: true)
            } completionHandler: { p.invalidateShadow() }
        }
    }

    /// Bottom centre of the screen under the mouse, just above the Dock (visibleFrame excludes it); the HUD grows upward.
    private func frame(for s: CGSize) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return NSRect(origin: .zero, size: s) }
        return NSRect(x: (visible.midX - s.width / 2).rounded(), y: visible.minY + 28, width: s.width, height: s.height)
    }

    private static func scaled(_ r: NSRect, by k: CGFloat) -> NSRect {
        NSRect(x: r.midX - r.width * k / 2, y: r.minY, width: r.width * k, height: r.height * k)
    }
}
