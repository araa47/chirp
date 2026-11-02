import CoreGraphics

/// Where the dictation island goes on one screen, from the numbers `NSScreen` reports: pure maths so it is unit-tested
/// with made-up screens (the app passes `safeAreaInsets.top` and the widths of `auxiliaryTopLeftArea` and
/// `auxiliaryTopRightArea`). Coordinates are AppKit screen coordinates: y grows upwards and `screenFrame.maxY` is the top.
public struct NotchGeometry: Equatable, Sendable {
    public var screenFrame: CGRect
    /// The hardware cutout in screen coordinates, or nil on a screen without one (external displays, older Macs).
    public var notch: CGRect?
    /// The menu bar's height, which the floating pill sits below.
    public var menuBarHeight: CGFloat

    /// The gap between the menu bar and the floating pill (the prototype's 10 pt).
    public static let floatingGap: CGFloat = 10

    public init(screenFrame: CGRect, notch: CGRect?, menuBarHeight: CGFloat) {
        self.screenFrame = screenFrame
        self.notch = notch
        self.menuBarHeight = menuBarHeight
    }

    /// A screen as `NSScreen` describes it. A notch exists only when the top safe-area inset is positive and both
    /// auxiliary areas are reported with a believable cutout between them (wider than 40 pt, narrower than half the screen);
    /// anything else is treated as a plain screen. `menuBarHeight` defaults to the safe-area inset on a notched screen.
    public static func of(screenFrame: CGRect, safeAreaTop: CGFloat, auxiliaryTopLeftWidth: CGFloat?,
                          auxiliaryTopRightWidth: CGFloat?, menuBarHeight: CGFloat? = nil) -> NotchGeometry {
        let bar = menuBarHeight ?? (safeAreaTop > 0 ? safeAreaTop : 24)
        guard safeAreaTop > 0, let left = auxiliaryTopLeftWidth, let right = auxiliaryTopRightWidth,
              left > 0, right > 0 else {
            return NotchGeometry(screenFrame: screenFrame, notch: nil, menuBarHeight: bar)
        }
        let width = screenFrame.width - left - right
        guard width > 40, width < screenFrame.width / 2 else {
            return NotchGeometry(screenFrame: screenFrame, notch: nil, menuBarHeight: bar)
        }
        let notch = CGRect(x: screenFrame.minX + left, y: screenFrame.maxY - safeAreaTop, width: width, height: safeAreaTop)
        return NotchGeometry(screenFrame: screenFrame, notch: notch, menuBarHeight: bar)
    }

    public var hasNotch: Bool { notch != nil }

    /// Notch mode on a notched screen, the floating pill elsewhere.
    public var mode: IslandMode { hasNotch ? .notch : .floating }

    /// The cutout's size for `IslandView` (the default stand-in on a screen without one).
    public var notchSize: CGSize { notch?.size ?? IslandMetrics.defaultNotch }

    /// The island's frame for a given island size: flush with the top of the screen and centred on the notch, or
    /// centred under the menu bar when floating. Always kept inside the screen horizontally.
    public func islandFrame(size: CGSize) -> CGRect {
        let midX = notch?.midX ?? screenFrame.midX
        let top = hasNotch ? screenFrame.maxY : screenFrame.maxY - menuBarHeight - Self.floatingGap
        var x = midX - size.width / 2
        x = min(max(x, screenFrame.minX), screenFrame.maxX - size.width)
        return CGRect(x: x, y: top - size.height, width: size.width, height: size.height)
    }

    /// The fixed-size panel that hosts `IslandView`: the largest island plus room for its shadow at the sides and bottom.
    /// The view draws the island top-centred inside it, so the panel never resizes while the island morphs.
    public var panelFrame: CGRect {
        let size = IslandMetrics.panelSize(mode: mode, notch: notchSize)
        let island = islandFrame(size: CGSize(width: size.width - 2 * IslandMetrics.shadowMargin,
                                              height: size.height - IslandMetrics.shadowMargin))
        return CGRect(x: island.minX - IslandMetrics.shadowMargin, y: island.minY - IslandMetrics.shadowMargin,
                      width: size.width, height: size.height)
    }
}
