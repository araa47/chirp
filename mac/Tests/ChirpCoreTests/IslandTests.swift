import AppKit
import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

/// The v2 island: every HUD state lands somewhere visible, the debug-retention marker is never lost, and the geometry
/// places the island on notched and plain screens.
@MainActor
@Suite struct IslandPresentationTests {
    private static let statuses = [
        "", HUDStatus.connecting, HUDStatus.listening, HUDStatus.finishing, HUDStatus.polishing, HUDStatus.polished,
        HUDStatus.inserting, HUDStatus.noSpeech, "Inserted", "Inserted" + HUDStatus.returnSent, "Copied — ⌘V",
        "Inserted? ⌘V if empty", "Secure field — not inserted", "Inserted raw", "Copied raw — ⌘V", "Secure field — unchanged",
        "Notes is recording — stop it to dictate", "Learned: Kubernetes", "No microphone signal",
        "Server rejected the token (check ~/.config/chirp/token)", "This dictation segment was too long — try again",
    ]
    private static let indicators: [HUDIndicator] = [.waveform, .success, .clipboard, .warning, .none, .sparkle]
    /// Statuses the island shows as a shorter wing title rather than word for word.
    private static let titled: [String: String] = [
        HUDStatus.listening: "Listening", HUDStatus.finishing: HUDStatus.finishing, HUDStatus.connecting: HUDStatus.connecting,
        HUDStatus.polishing: HUDStatus.polishing, HUDStatus.polished: HUDStatus.polished, HUDStatus.inserting: HUDStatus.inserting,
    ]

    private struct Flags {
        var error = false, privateSession = false, debug = false, kept = false, cleaned = false, useRaw = false
        var style: String?, duration: String?, polishing = false, diff = false, text = false, wordWaveform = false
    }

    /// Every combination worth distinguishing, small enough to run in a moment.
    private static var flagSets: [Flags] {
        var all: [Flags] = []
        for bits in 0..<(1 << 9) {
            func on(_ i: Int) -> Bool { bits & (1 << i) != 0 }
            all.append(Flags(error: on(0), privateSession: on(1), debug: on(2), kept: on(3), cleaned: on(4), useRaw: on(5),
                             style: on(6) ? "Email" : nil, duration: on(7) ? (on(4) ? "10:00 / 10:00" : "0:24 / 10:00") : nil,
                             polishing: on(8) && on(3), diff: on(8) && !on(3), text: on(6) != on(1), wordWaveform: on(5) && on(2)))
        }
        return all
    }

    private func model(status: String, indicator: HUDIndicator, _ f: Flags) -> HUDModel {
        let m = HUDModel()
        m.status = status; m.indicator = indicator
        m.isError = f.error; m.privateSession = f.privateSession; m.debugRetention = f.debug
        m.keptOriginal = f.kept; m.cleaned = f.cleaned; m.showUseRaw = f.useRaw; m.styleName = f.style
        m.duration = f.duration; m.polishing = f.polishing; m.wordWaveform = f.wordWaveform
        if f.diff { m.diff = WordDiff.segments(raw: "move it to three", cleaned: "Move it to 3.") }
        if f.text { m.stable = "Please move the standup"; m.unstable = " to three" }
        return m
    }

    @Test func noHUDStateIsEverDropped() {
        var seen = Set<IslandState>()
        for status in Self.statuses {
            for indicator in Self.indicators {
                for f in Self.flagSets {
                    let m = model(status: status, indicator: indicator, f)
                    let p = IslandPresentation.of(m)
                    seen.insert(p.state)
                    let context = "\(status) \(indicator) \(f)"
                    // Privacy invariant: the debug-retention marker survives every state.
                    #expect(p.debugRetention == f.debug, "\(context)")
                    #expect(p.privateSession == f.privateSession, "\(context)")
                    #expect(p.duration == f.duration, "\(context)")
                    if f.debug { #expect(p.accessibilityLabel.contains(MenuContent.debugRetention), "\(context)") }
                    // A problem is a notice that says what happened, in the record colour when it is an error.
                    if f.error || indicator == .warning {
                        #expect(p.state == .notice && p.body == .message(status), "\(context)")
                        #expect(p.glyph == (f.error ? .error : .warning), "\(context)")
                    }
                    // The status is on screen: as the wing title, its short form, or the body.
                    if !status.isEmpty {
                        let visible = p.title == status || p.body == .message(status) || Self.titled[status] == p.title
                            || (status.hasPrefix(p.title) && !p.title.isEmpty)
                        #expect(visible, "status lost: \(context) → \(p)")
                        #expect(p.accessibilityLabel.contains(status), "\(context)")
                    }
                    // A done state's title and body together say the whole status.
                    if p.state == .done, p.title != status {
                        guard case .message(let rest) = p.body else { Issue.record("no rest: \(context)"); continue }
                        #expect(status.hasPrefix(p.title) && (status.hasSuffix(rest)), "\(context)")
                    }
                    // A done state carries every outcome note.
                    if p.state == .done {
                        #expect(p.chips.contains(.polished) == f.cleaned, "\(context)")
                        #expect(p.chips.contains(.keptOriginal) == f.kept, "\(context)")
                        #expect(p.chips.contains(.useRaw(key: "⌃⌥Z")) == f.useRaw, "\(context)")
                    }
                    if p.state == .polishing, let style = f.style { #expect(p.style == style, "\(context)") }
                    if f.diff, !f.error, indicator != .warning { #expect(p.state == .polishing, "\(context)") }
                    // Text never disappears while listening.
                    if f.text, [.listening, .live].contains(p.state) { #expect(p.state == .live, "\(context)") }
                    if let d = f.duration {
                        #expect(p.timer == d.components(separatedBy: " / ")[0])
                        #expect(p.atLimit == d.hasPrefix("10:00"))
                    }
                    // The island is never empty unless the HUD is.
                    if p.state == .idle { #expect(status.isEmpty && !f.text, "\(context)") }
                }
            }
        }
        #expect(seen == Set(IslandState.allCases))
    }

    @Test func eachOutcomeMapsToADoneOrNoticeState() {
        let plain = FinalResult(text: "Move it.")
        let corrected = FinalResult(text: "Move it.", raw: "move it", corrected: true)
        let kept = FinalResult(text: "move it", corrected: false, correctionError: "timeout")
        let outcomes: [InsertionOutcome] = [.inserted(.ax), .inserted(.paste), .copied, .insertedUnverified, .refusedSecure]
        for outcome in outcomes {
            for final in [plain, corrected, kept] {
                for showChanges in [false, true] {
                    let o = OutcomePresentation.of(outcome, final: final, showChanges: showChanges)
                    let m = HUDModel()
                    m.status = o.status; m.indicator = o.indicator; m.isError = o.isError; m.showUseRaw = o.showUseRaw
                    m.cleaned = o.cleaned; m.keptOriginal = o.keptOriginal
                    let p = IslandPresentation.of(m, useRawKey: "⌃⌥R")
                    #expect(p.state == (o.isError ? .notice : .done))
                    #expect(p.chips.contains(.useRaw(key: "⌃⌥R")) == o.showUseRaw)
                    #expect(p.expanded == (p.state == .notice || o.cleaned || o.keptOriginal || o.showUseRaw || !["Inserted", "Inserted raw"].contains(o.status)))
                }
            }
        }
    }

    @Test func theUseRawHintNamesTheHotkeyBecauseTheIslandTakesNoClicks() {
        let m = HUDModel()
        m.status = "Inserted"; m.indicator = .success; m.showUseRaw = true; m.cleaned = true; m.onUseRaw = {}
        let p = IslandPresentation.of(m)
        #expect(p.chips == [.polished, .useRaw(key: "⌃⌥Z")])
        #expect(IslandPresentation.Chip.useRaw(key: "⌃⌥Z").text == "⌃⌥Z Use raw")
    }

    @Test func liveStatesFollowTheModel() {
        let m = HUDModel()
        #expect(IslandPresentation.of(m).state == .idle)
        m.status = HUDStatus.connecting
        #expect(IslandPresentation.of(m).state == .listening && IslandPresentation.of(m).glyph == .connecting)
        m.status = HUDStatus.listening
        #expect(IslandPresentation.of(m).state == .listening && IslandPresentation.of(m).glyph == .ripple)
        m.stable = "hello there"
        #expect(IslandPresentation.of(m).body == .transcript(stable: "hello there", unstable: ""))
        m.beginPolishing(raw: "hello there", style: "Chat")
        let polishing = IslandPresentation.of(m)
        #expect(polishing.state == .polishing && polishing.body == .polishing("hello there") && polishing.style == "Chat")
    }

    @Test func rollingDictationKeepsTheNewestWords() {
        let m = HUDModel()
        m.status = HUDStatus.listening
        m.stable = Array(repeating: "and then we check the rollout plan", count: 8).joined(separator: " ") + " finally"
        guard case .transcript(let stable, _) = IslandPresentation.of(m).body else { Issue.record("no transcript"); return }
        #expect(stable.hasPrefix("…") && stable.hasSuffix("finally") && stable.count <= IslandPresentation.transcriptBudget + 1)
    }

    @Test func shortTitlesCutAtTheSeparator() {
        #expect(IslandPresentation.shortTitle("Copied — ⌘V") == "Copied")
        #expect(IslandPresentation.shortTitle("Inserted · ↵ sent") == "Inserted")
        #expect(IslandPresentation.shortTitle("Inserted raw") == "Inserted raw")
        #expect(IslandPresentation.shortTitle("Copied raw — ⌘V") == "Copied raw")
        #expect(IslandPresentation.rest(of: "Copied — ⌘V", after: "Copied") == "⌘V")
        #expect(IslandPresentation.rest(of: "Inserted? ⌘V if empty", after: "Inserted?") == "⌘V if empty")
        #expect(IslandPresentation.rest(of: "Inserted · ↵ sent", after: "Inserted") == "↵ sent")
        #expect(IslandPresentation.rest(of: "Inserted", after: "Inserted") == nil)
        #expect(IslandPresentation.shortTitle("Inserted? ⌘V if empty") == "Inserted?")
        #expect(IslandPresentation.shortTitle("Inserted") == "Inserted")
    }
}

@Suite struct IslandMetricsTests {
    @Test func theDefaultNotchUsesThePrototypeSizes() {
        let n = IslandMetrics.defaultNotch
        func s(_ st: IslandState, _ e: Bool = false) -> IslandMetrics.Size { IslandMetrics.size(st, expanded: e, mode: .notch, notch: n) }
        #expect(s(.listening) == .init(width: 380, height: 34, radius: 20))
        #expect(s(.done) == .init(width: 360, height: 34, radius: 20))
        #expect(s(.live).height == 84 && s(.live).radius == 26 && s(.polishing).height == 84)
        #expect(s(.done).height == 34 && s(.done, true).height == 84 && s(.notice).height == 84)
        #expect(s(.idle).width == n.width + 2 * IslandMetrics.flare)
        let floating = IslandMetrics.size(.listening, expanded: false, mode: .floating)
        #expect(floating == .init(width: 380, height: 40, radius: 20))
        #expect(IslandMetrics.size(.live, expanded: true, mode: .floating) == .init(width: 430, height: 90, radius: 26))
    }

    @Test func wingsNeverSitUnderAWiderNotch() {
        for notch in [CGSize(width: 180, height: 32), CGSize(width: 200, height: 34), CGSize(width: 250, height: 38)] {
            for state in IslandState.allCases where state != .idle {
                for e in [false, true] {
                    let s = IslandMetrics.size(state, expanded: e, mode: .notch, notch: notch)
                    let wing = (s.width - 2 * IslandMetrics.flare - notch.width) / 2
                    #expect(wing >= IslandMetrics.minimumWing, "\(state) \(notch)")
                    #expect(s.height >= notch.height)
                }
            }
            let panel = IslandMetrics.panelSize(mode: .notch, notch: notch)
            #expect(panel.width >= 430 + 2 * IslandMetrics.shadowMargin && panel.height >= 84 - 34 + notch.height)
        }
    }

    @Test func aDebugMarkerWidensTheIdleNotchSoTheDotIsNotUnderTheCutout() {
        let p = IslandPresentation(state: .idle, glyph: .none, title: "", status: "", debugRetention: true)
        let s = IslandMetrics.size(for: p, mode: .notch)
        #expect(s.width >= IslandMetrics.defaultNotch.width + 2 * IslandMetrics.minimumWing)
    }
}

@Suite struct NotchGeometryTests {
    /// A 14" MacBook Pro at its default resolution: the cutout between the two auxiliary areas.
    static let fourteen = NotchGeometry.of(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 32,
                                           auxiliaryTopLeftWidth: 655, auxiliaryTopRightWidth: 655)
    /// A 16" MacBook Pro, with a slightly taller inset.
    static let sixteen = NotchGeometry.of(screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117), safeAreaTop: 37,
                                          auxiliaryTopLeftWidth: 764, auxiliaryTopRightWidth: 762)
    /// An external display to the right of the laptop: no safe area, no auxiliary areas.
    static let external = NotchGeometry.of(screenFrame: CGRect(x: 1512, y: -200, width: 2560, height: 1440), safeAreaTop: 0,
                                           auxiliaryTopLeftWidth: nil, auxiliaryTopRightWidth: nil, menuBarHeight: 25)

    @Test func notchedScreensFindTheirCutout() throws {
        let n14 = try #require(Self.fourteen.notch)
        #expect(n14 == CGRect(x: 655, y: 950, width: 202, height: 32))
        #expect(Self.fourteen.mode == .notch && Self.fourteen.menuBarHeight == 32)
        let n16 = try #require(Self.sixteen.notch)
        #expect(n16 == CGRect(x: 764, y: 1080, width: 202, height: 37))
        #expect(Self.sixteen.notchSize == CGSize(width: 202, height: 37))
    }

    @Test func plainScreensFloat() {
        #expect(Self.external.notch == nil && Self.external.mode == .floating)
        #expect(Self.external.notchSize == IslandMetrics.defaultNotch)
        // A safe area without auxiliary areas, or an implausible cutout, is not a notch.
        let noAux = NotchGeometry.of(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 32,
                                     auxiliaryTopLeftWidth: nil, auxiliaryTopRightWidth: 655)
        let tiny = NotchGeometry.of(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 32,
                                    auxiliaryTopLeftWidth: 740, auxiliaryTopRightWidth: 740)
        let huge = NotchGeometry.of(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 32,
                                    auxiliaryTopLeftWidth: 100, auxiliaryTopRightWidth: 100)
        #expect(!noAux.hasNotch && !tiny.hasNotch && !huge.hasNotch)
    }

    @Test func theIslandSitsFlushOnTheNotchOrUnderTheMenuBar() throws {
        let size = CGSize(width: 430, height: 84)
        let f14 = Self.fourteen.islandFrame(size: size)
        let n14 = try #require(Self.fourteen.notch)
        #expect(f14.maxY == 982 && f14.midX == n14.midX)
        let f16 = Self.sixteen.islandFrame(size: size)
        #expect(f16.maxY == 1117 && f16.midX == 865)
        let ext = Self.external.islandFrame(size: size)
        #expect(ext.maxY == 1240 - 25 - NotchGeometry.floatingGap && ext.midX == 1512 + 1280)
    }

    @Test func theFixedPanelHoldsEveryStateAndItsShadow() {
        for g in [Self.fourteen, Self.sixteen, Self.external] {
            let panel = g.panelFrame
            for state in IslandState.allCases {
                for e in [false, true] {
                    let s = IslandMetrics.size(state, expanded: e, mode: g.mode, notch: g.notchSize)
                    let island = g.islandFrame(size: CGSize(width: s.width, height: s.height))
                    #expect(panel.contains(island), "\(state) \(g.mode)")
                    #expect(island.maxY == panel.maxY, "the island is drawn top-aligned in the panel")
                }
            }
            #expect(panel.minX >= g.screenFrame.minX - IslandMetrics.shadowMargin)
        }
    }
}

@MainActor
@Suite struct IslandSnapshotTests {
    /// `CHIRP_ISLAND_SNAPSHOTS=<dir>` keeps the PNGs there for review (the committed set never includes them).
    @Test func everyIslandScenarioRendersInLightAndDark() throws {
        let keep = ProcessInfo.processInfo.environment["CHIRP_ISLAND_SNAPSHOTS"]
        let dir = keep.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("chirp-island-\(UUID().uuidString)")
        defer { if keep == nil { try? FileManager.default.removeItem(at: dir) } }
        // The island is drawn in both designs: Pond (today) and v2 (Graphite, behind the flag).
        let files = try Snapshots.render(to: dir.appendingPathComponent("pond"), scenarios: Snapshots.islandScenarios, design: .pond)
            + Snapshots.render(to: dir.appendingPathComponent("v2"), scenarios: Snapshots.islandScenarios, design: .v2)
        #expect(files.count == Snapshots.islandScenarios.count * 4)
        #expect(Set(Snapshots.islandScenarios.map(\.name)).count == Snapshots.islandScenarios.count)
        for url in files {
            let data = try Data(contentsOf: url)
            #expect(data.count < 300_000, "\(url.lastPathComponent)")
            let rep = try #require(NSBitmapImageRep(data: data))
            #expect(rep.pixelsWide > 400 && rep.pixelsHigh > 100)
        }
        // Not in the committed set until the flip (PR 5).
        #expect(!Snapshots.committedNames.contains { $0.hasPrefix("island-") })
    }
}
