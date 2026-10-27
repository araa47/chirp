#if os(macOS)
import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// The real implementations behind `InsertionEnvironment`.
@MainActor
public enum SystemInsertion {
    public static func environment() -> InsertionEnvironment {
        InsertionEnvironment(
            secureInputEnabled: { IsSecureEventInputEnabled() },
            axTrusted: { AXIsProcessTrusted() },
            frontmostBundleID: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
            axInsert: { await axInsert($0) },
            axReplace: { await axReplace(range: $0, expected: $1, replacement: $2) },
            postPaste: { postCommandKey(CGKeyCode(kVK_ANSI_V)) }
        )
    }

    /// The auto-Return's calls: the Return goes to the frontmost app.
    public static func autoEnterEnvironment() -> AutoEnterEnvironment {
        AutoEnterEnvironment(secureInputEnabled: { IsSecureEventInputEnabled() },
                             frontmostBundleID: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
                             postReturn: { postKey(CGKeyCode(kVK_Return)) })
    }

    // MARK: AX

    fileprivate static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var ref: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success ? ref : nil
    }

    fileprivate static func range(_ element: AXUIElement) -> CFRange? {
        guard let v = copy(element, "AXSelectedTextRange"), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        return AXValueGetValue(v as! AXValue, .cfRange, &r) ? r : nil
    }

    fileprivate static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        guard let focused = copy(system, "AXFocusedUIElement"), CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return (focused as! AXUIElement)
    }

    /// Secure input is on, or the focused field is a password field: history never keeps what goes there.
    public static func focusedFieldIsSecure() -> Bool {
        if IsSecureEventInputEnabled() { return true }
        guard AXIsProcessTrusted(), let element = focusedElement() else { return false }
        let role = copy(element, "AXRole") as? String, subrole = copy(element, "AXSubrole") as? String
        return role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }

    private static func selectedTextSettable(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, "AXSelectedText" as CFString, &settable) == .success && settable.boolValue
    }

    /// Sets `AXSelectedText` on the focused element and checks that the value or caret actually moved.
    /// Some apps apply the write late, so the readback is polled for up to ~150 ms before reporting `.unverified`.
    static func axInsert(_ text: String) async -> AXInsertAttempt {
        guard let element = focusedElement() else { return .notAttempted }
        if let role = copy(element, "AXRole") as? String, role == "AXSecureTextField" { return .notAttempted }
        guard selectedTextSettable(element) else { return .notAttempted }

        let beforeValue = copy(element, "AXValue") as? String
        let beforeRange = range(element)
        // If we can't read the field back we can't verify the write, so let paste handle it.
        guard beforeValue != nil || beforeRange != nil else { return .notAttempted }

        guard AXUIElementSetAttributeValue(element, "AXSelectedText" as CFString, text as CFString) == .success else { return .notAttempted }
        let length = text.utf16.count
        for _ in 0..<6 {
            try? await Task.sleep(for: .milliseconds(25))
            let afterValue = copy(element, "AXValue") as? String
            let afterRange = range(element)
            let changed = (beforeValue != nil && afterValue != nil && beforeValue != afterValue)
                || (beforeRange != nil && afterRange != nil && (beforeRange!.location != afterRange!.location || beforeRange!.length != afterRange!.length))
            guard changed else { continue }
            if let b = beforeRange { return .verified(NSRange(location: b.location, length: length)) }
            if let a = afterRange, a.length == 0, a.location >= length { return .verified(NSRange(location: a.location - length, length: length)) }
            return .verified(nil)
        }
        // The set call succeeded but we never saw the change. The app may still apply it, so do not paste.
        return .unverified
    }

    /// Reselects `range` when it still holds exactly `expected`, then overwrites it with `replacement`.
    static func axReplace(range: NSRange, expected: String, replacement: String) async -> Bool {
        guard let element = focusedElement(), selectedTextSettable(element),
              let value = copy(element, "AXValue") as? String,
              let r = Range(range, in: value), value[r] == expected else { return false }
        var cf = CFRange(location: range.location, length: range.length)
        guard let axRange = AXValueCreate(.cfRange, &cf),
              AXUIElementSetAttributeValue(element, "AXSelectedTextRange" as CFString, axRange) == .success,
              AXUIElementSetAttributeValue(element, "AXSelectedText" as CFString, replacement as CFString) == .success else { return false }
        try? await Task.sleep(for: .milliseconds(60))
        return (copy(element, "AXValue") as? String).map { $0 != value } ?? false
    }

    // MARK: Keystroke

    /// Posts ⌘+key using a private event source so a still-held hotkey modifier (⌥) is not merged in.
    static func postCommandKey(_ key: CGKeyCode) -> Bool {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Posts one key press with no modifiers, on a private source so a still-held hotkey modifier is not merged in.
    static func postKey(_ key: CGKeyCode) -> Bool {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return false }
        down.flags = []
        up.flags = []
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}

/// The focused text field Chirp just inserted into, for Learn from my edits: read only while it stays focused, never
/// when it is a password field or secure input is on.
@MainActor
public final class AXWatchedField: WatchedField {
    private let element: AXUIElement

    private init(_ element: AXUIElement) { self.element = element }

    /// The focused element, when Accessibility is granted and it has a readable text value.
    public static func focused() -> AXWatchedField? {
        guard AXIsProcessTrusted(), let element = SystemInsertion.focusedElement(),
              SystemInsertion.copy(element, "AXValue") is String else { return nil }
        return AXWatchedField(element)
    }

    public func value() -> String? { SystemInsertion.copy(element, "AXValue") as? String }

    public func selection() -> NSRange? {
        SystemInsertion.range(element).map { NSRange(location: $0.location, length: $0.length) }
    }

    private static var requested: Set<pid_t> = []

    /// Chromium and Electron apps build their Accessibility tree only for assistive apps, so a field Chirp pasted into
    /// there cannot be read. Ask for it once per process with `AXManualAccessibility` (never `AXEnhancedUserInterface`,
    /// which upsets window managers); other apps ignore the attribute.
    public static func requestAccessibility(pid: pid_t) {
        guard AXIsProcessTrusted(), requested.insert(pid).inserted else { return }
        let app = AXUIElementCreateApplication(pid)
        let result = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        chirpLog.info("learn AXManualAccessibility result=\(result.rawValue, privacy: .public)")
    }

    public var isFocused: Bool {
        guard let now = SystemInsertion.focusedElement() else { return false }
        return CFEqual(now, element)
    }

    public var isSecure: Bool {
        if IsSecureEventInputEnabled() { return true }
        let role = SystemInsertion.copy(element, "AXRole") as? String, subrole = SystemInsertion.copy(element, "AXSubrole") as? String
        return role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }
}

#endif
