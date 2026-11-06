import Foundation

public enum InsertionMethod: String, Sendable, Equatable {
    case ax, paste, copy
}

public enum InsertionOutcome: Sendable, Equatable {
    case inserted(InsertionMethod)
    /// The AX write was accepted but never confirmed (some apps apply it late). Nothing was pasted, to avoid
    /// a duplicate; the text waits on a transient pasteboard for ⌘V.
    case insertedUnverified
    /// ⌘V reached the app but Chirp could not confirm the text arrived. The text stays on the clipboard as a normal copy
    /// (when nobody copied something else meanwhile), so ⌘V gets it; history and Paste Again have it too.
    case pasteUnconfirmed(PasteDoubt)
    case copied
    case refusedSecure

    /// A short name for the diagnostics log.
    public var logName: String {
        switch self {
        case .inserted(let method): method.rawValue
        case .insertedUnverified: "unverified"
        case .pasteUnconfirmed(let doubt): "paste_unconfirmed_\(doubt.rawValue)"
        case .copied: "copied"
        case .refusedSecure: "secure"
        }
    }

    /// The text was handed to the app and probably arrived: a confirmed insertion, or a paste the app read into a field
    /// Chirp cannot read back (Chromium, Electron). The Return after inserting and Use raw follow these.
    public var probablyInserted: Bool {
        switch self {
        case .inserted, .pasteUnconfirmed(.unreadable): true
        default: false
        }
    }

    /// The text may not be in the field: the HUD says where it is (the clipboard) and how to get it.
    public var leftOnClipboard: Bool {
        switch self {
        case .insertedUnverified, .pasteUnconfirmed, .copied: true
        case .inserted, .refusedSecure: false
        }
    }
}

/// Why a paste could not be confirmed.
public enum PasteDoubt: String, Sendable, Equatable {
    /// The app read the clipboard, but its field cannot be read back (Chromium and Electron web fields): probably in, but
    /// a web page whose field lost focus drops it silently.
    case unreadable
    /// No app asked for the text after ⌘V: it went nowhere.
    case notRead
    /// The field can be read and did not change.
    case unchanged

    /// The paste most likely failed: the HUD warns instead of fading.
    public var likelyFailed: Bool { self != .unreadable }
}

/// Chooses which insertion methods to try, in order. Pure, so it is unit-tested.
public enum InsertionPolicy {
    /// Apps where the AX write is unreliable, so we go straight to paste. Terminals have no AX text field.
    /// Chromium and Electron apps can apply an AX write late or not at all, and a late write plus a paste fallback
    /// would insert the text twice.
    public static let pasteFirstBundleIDs: Set<String> = [
        // terminals
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "org.alacritty", "co.zeit.hyper", "com.github.wez.wezterm",
        // Chromium browsers
        "com.google.Chrome", "com.google.Chrome.canary", "org.chromium.Chromium", "com.brave.Browser",
        "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
        "com.citrolabs.ego.lite", // ego Lite's web text fields
        // ChatGPT/Codex also needs paste for its web-backed composer.
        "com.openai.codex",
        // Electron apps
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92" /* Cursor */, "com.tinyspeck.slackmacgap",
        "com.hnc.Discord", "notion.id", "com.microsoft.teams2", "md.obsidian",
    ]

    public enum Plan: Sendable, Equatable {
        case refuseSecure
        case try_([InsertionMethod])
    }

    public static func plan(secureInput: Bool, axTrusted: Bool, bundleID: String?) -> Plan {
        if secureInput { return .refuseSecure }
        // Without Accessibility trust we can neither set AX text nor post ⌘V.
        if !axTrusted { return .try_([.copy]) }
        if let bundleID, pasteFirstBundleIDs.contains(bundleID) { return .try_([.paste, .copy]) }
        return .try_([.ax, .paste, .copy])
    }
}
