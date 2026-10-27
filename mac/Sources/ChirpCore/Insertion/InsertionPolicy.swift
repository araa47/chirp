import Foundation

public enum InsertionMethod: String, Sendable, Equatable {
    case ax, paste, copy
}

public enum InsertionOutcome: Sendable, Equatable {
    case inserted(InsertionMethod)
    /// The AX write was accepted but never confirmed (some apps apply it late). Nothing was pasted, to avoid
    /// a duplicate; the text waits on a transient pasteboard for ⌘V.
    case insertedUnverified
    case copied
    case refusedSecure
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
