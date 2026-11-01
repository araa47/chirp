import Foundation

/// What a process invocation asks for. A bare launch or --models starts the UI, which onboards and requests TCC grants.
public enum LaunchMode: Equatable, Sendable {
    case app
    case selftest
    /// A WAV through the real Live Notes session (no microphone, window or TCC).
    case notesSelftest
    /// Live Notes with call audio: a microphone file and a "remote" file through a file-backed tap (#211).
    case callSelftest
    /// Learn from my edits end to end on a test text field: dictate, edit, learn, and the next dictation applies it (#220).
    case learnSelftest
    /// Draw the UI to PNGs in a directory and exit, without starting the app (no onboarding, no TCC prompt).
    /// `curated` draws only the set committed under `docs/screenshots/mac`; `designV2` (`--design v2`) draws the v2
    /// design instead of Pond, whatever the stored preference says.
    case renderSnapshots(directory: String, curated: Bool = false, designV2: Bool = false)
    case usage(exitCode: Int32)

    public static let usageText = """
        usage: ChirpMac                         launch the menu-bar app
               ChirpMac --models                open local model setup
               ChirpMac --selftest <audio> [--url URL] [--token-file PATH] [--expect WORD] [--fast]
               ChirpMac --notes-selftest <audio> [--url URL] [--token-file PATH] [--expect WORD] [--fault drop@30,down@60-90] [--fast]
               ChirpMac --call-selftest --mic <audio> --remote <audio> [--url URL] [--token-file PATH] [--fast] [--live]
               ChirpMac --learn-selftest [--url URL] [--token-file PATH]
               ChirpMac --render-snapshots <dir> [--curated] [--design pond|v2]   draw the HUD, Settings and menu to PNGs (light and dark)
        """

    /// `arguments` excludes the executable path. Launch Services may pass `-psn_*`; it is not a CLI flag.
    public static func parse(_ arguments: [String]) -> LaunchMode {
        if arguments.contains("--notes-selftest") { return .notesSelftest }
        if arguments.contains("--call-selftest") { return .callSelftest }
        if arguments.contains("--learn-selftest") { return .learnSelftest }
        if arguments.contains("--selftest") { return .selftest }
        if let i = arguments.firstIndex(of: "--render-snapshots") {
            guard i + 1 < arguments.count, !arguments[i + 1].hasPrefix("-") else { return .usage(exitCode: 64) }
            var designV2 = false
            if let d = arguments.firstIndex(of: "--design") {
                guard d + 1 < arguments.count, ["pond", "v2"].contains(arguments[d + 1]) else { return .usage(exitCode: 64) }
                designV2 = arguments[d + 1] == "v2"
            }
            return .renderSnapshots(directory: arguments[i + 1], curated: arguments.contains("--curated"), designV2: designV2)
        }
        if arguments.filter({ !$0.hasPrefix("-psn_") }) == ["--models"] { return .app }
        guard let flag = arguments.first(where: { $0.hasPrefix("-") && !$0.hasPrefix("-psn_") }) else {
            return arguments.isEmpty || arguments.allSatisfy({ $0.hasPrefix("-psn_") }) ? .app : .usage(exitCode: 64)
        }
        return .usage(exitCode: flag == "--help" || flag == "-h" ? 0 : 64)
    }
}
