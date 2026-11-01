import SwiftUI

/// How long a toast stays, and when it waits. The HIG says transient messages must not vanish while the person is
/// reading or reaching for them, so the countdown stops while the pointer is over the toast or one of its buttons has
/// keyboard focus, and picks up where it left off afterwards.
///
/// The countdown is plain arithmetic (`tick`), so a test can drive it without a clock; `run()` is the real-time driver
/// the toast views use (`.task(id: toast.serial)`).
@MainActor @Observable
public final class ToastTimer {
    /// Time left before the toast goes.
    public private(set) var remaining: Duration = .zero
    public private(set) var isHovered = false
    public private(set) var focusedCount = 0

    public init() {}

    /// The countdown is stopped: the pointer is over the toast, or a button in it has keyboard focus.
    public var isPaused: Bool { isHovered || focusedCount > 0 }

    /// Starts a fresh countdown for a new toast. Hover and focus start clear: the old toast's views are gone, and a
    /// removed view sends no "pointer left" or "focus lost" to say so.
    public func begin(_ duration: Duration) {
        remaining = duration
        isHovered = false
        focusedCount = 0
    }

    public func setHovered(_ hovered: Bool) { isHovered = hovered }

    /// One toast button gained or lost keyboard focus.
    public func setFocused(_ focused: Bool) { focusedCount = max(0, focusedCount + (focused ? 1 : -1)) }

    /// Lets `elapsed` pass. Nothing is spent while paused. Returns true once the toast is due to go.
    @discardableResult
    public func tick(_ elapsed: Duration) -> Bool {
        if !isPaused { remaining = max(.zero, remaining - elapsed) }
        return remaining <= .zero
    }

    /// Counts down in real time and returns true when the time ran out (false if the task was cancelled first).
    public func run(_ duration: Duration, step: Duration = .milliseconds(100)) async -> Bool {
        begin(duration)
        var last = ContinuousClock.now
        while !Task.isCancelled {
            try? await Task.sleep(for: step)
            let now = ContinuousClock.now
            let expired = tick(now - last)
            last = now
            if expired { return !Task.isCancelled }
        }
        return false
    }
}

/// A toast's countdown wiring: hover pauses it. Buttons inside add `.toastFocus(timer)`.
struct ToastHoverModifier: ViewModifier {
    let timer: ToastTimer
    func body(content: Content) -> some View { content.onHover { timer.setHovered($0) } }
}

/// Reports a toast button's keyboard focus to the countdown.
private struct ToastFocusModifier: ViewModifier {
    let timer: ToastTimer
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content.onChange(of: isFocused) { _, focused in timer.setFocused(focused) }
    }
}

extension View {
    /// Pauses the toast countdown while the pointer is over this view.
    func toastHover(_ timer: ToastTimer) -> some View { modifier(ToastHoverModifier(timer: timer)) }
    /// Pauses the toast countdown while this control has keyboard focus.
    func toastFocus(_ timer: ToastTimer) -> some View { modifier(ToastFocusModifier(timer: timer)) }
}
