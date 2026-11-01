import AppKit
import ChirpCore
import Foundation
import Testing
@testable import ChirpUI

/// The hidden v2 design flag: it is off by default, the launch flag and preference map onto `ChirpDesign`, and with
/// the flag off every token, radius and helper is exactly Pond (so nothing a user sees changes).
@Suite struct DesignFlagTests {
    @Test func designV2IsOffByDefaultAndPersists() {
        let suite = "chirp-design-\(UUID().uuidString)"
        defer { removeTestDefaults(suite) }
        let prefs = Preferences(defaults: UserDefaults(suiteName: suite)!)
        #expect(!prefs.designV2)
        prefs.designV2 = true
        #expect(Preferences(defaults: UserDefaults(suiteName: suite)!).designV2)
        #expect(ChirpDesign.from(designV2: false) == .pond)
        #expect(ChirpDesign.from(designV2: true) == .v2)
    }

    @Test func renderSnapshotsTakesADesign() {
        #expect(LaunchMode.parse(["--render-snapshots", "/tmp/out"]) == .renderSnapshots(directory: "/tmp/out", designV2: false))
        #expect(LaunchMode.parse(["--render-snapshots", "/tmp/out", "--design", "v2"]) == .renderSnapshots(directory: "/tmp/out", designV2: true))
        #expect(LaunchMode.parse(["--render-snapshots", "/tmp/out", "--design", "pond"]) == .renderSnapshots(directory: "/tmp/out"))
        #expect(LaunchMode.parse(["--render-snapshots", "out", "--curated", "--design", "v2"])
                == .renderSnapshots(directory: "out", curated: true, designV2: true))
        #expect(LaunchMode.parse(["--render-snapshots", "out", "--design"]) == .usage(exitCode: 64))
        #expect(LaunchMode.parse(["--render-snapshots", "out", "--design", "graphite"]) == .usage(exitCode: 64))
        #expect(LaunchMode.usageText.contains("--design pond|v2"))
    }

    /// With the flag off the tokens resolve to the Pond table unchanged.
    @Test func pondTokensAreThePondTable() {
        func same(_ a: ChirpColor.Pair, _ b: ChirpColor.Pair) -> Bool {
            a.light == b.light && a.dark == b.dark
        }
        let pond = ChirpColor.Pond.self
        let expected: [(ChirpColor.Token, ChirpColor.Pair)] = [
            (.background, pond.background), (.surface, pond.surface), (.surfaceRaised, pond.surfaceRaised), (.ink, pond.ink),
            (.inkMuted, pond.inkMuted), (.koi, pond.koi), (.koiDecor, pond.koiDecor), (.koiContainer, pond.koiContainer),
            (.onKoiContainer, pond.onKoiContainer), (.onKoi, pond.onKoi), (.moon, pond.moon), (.moonFill, pond.moonFill),
            (.lily, pond.lily), (.record, pond.record),
        ]
        #expect(expected.count == ChirpColor.Token.allCases.count)
        for (token, pair) in expected { #expect(same(token.pair(in: .pond), pair), "\(token)") }
        #expect(same(HUDColors.actionRGB(in: .pond), (light: HUDColors.actionLight, dark: HUDColors.actionDark)))
        #expect(same(HUDColors.surfaceRGB(in: .pond), (light: HUDColors.surfaceLight, dark: HUDColors.surfaceDark)))
    }

    /// Graphite is a real second table: the brand tokens move, the record red stays.
    @Test func graphiteChangesTheBrandTokens() {
        for token in [ChirpColor.Token.background, .surfaceRaised, .ink, .koi, .koiDecor, .koiContainer, .onKoiContainer] {
            #expect(token.pair(in: .v2).light != token.pair(in: .pond).light, "\(token)")
        }
        #expect(ChirpColor.Token.record.pair(in: .v2).light == ChirpColor.Pond.record.light)
        #expect(ChirpColor.Graphite.koi.light == ChirpColor.hex(0x1F58C4))
    }

    @Test func radiiAndTypeFollowTheDesign() {
        #expect(ChirpRadius.card(in: .pond) == 16 && ChirpRadius.panel(in: .pond) == 16)
        #expect(ChirpRadius.card(in: .v2) == 18 && ChirpRadius.panel(in: .v2) == 24)
        #expect(ChirpRadius.control == 6 && ChirpRadius.row == 10 && ChirpRadius.sheet == 28)
        #expect(ChirpType.noteTitleDesign(in: .pond) == .serif)
        #expect(ChirpType.noteTitleDesign(in: .v2) == .serif)   // decision 4: keep the serif in v1
    }

    @Test func theTonalTileFollowsTheDesign() {
        let pondLight = SettingsLayout.tonalRGBA(dark: false, in: .pond)
        #expect(pondLight.0 == ChirpColor.Pond.koiContainer.light.r && pondLight.3 == 1)
        let pondDark = SettingsLayout.tonalRGBA(dark: true, in: .pond)
        #expect(pondDark.0 == ChirpColor.Pond.koi.dark.r && pondDark.3 == 0.28)
        let v2Dark = SettingsLayout.tonalRGBA(dark: true, in: .v2)
        #expect(v2Dark.2 == ChirpColor.Graphite.koi.dark.b && v2Dark.3 == 0.28)
    }

    /// The dynamic colours read the design when AppKit resolves them, and `with` puts the previous design back.
    @MainActor @Test func dynamicColoursResolveTheCurrentDesign() throws {
        func resolved(_ color: NSColor, _ name: NSAppearance.Name) -> ChirpColor.RGB {
            var c = NSColor.clear
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance { c = color.usingColorSpace(.sRGB)! }
            return (c.redComponent, c.greenComponent, c.blueComponent)
        }
        func close(_ a: ChirpColor.RGB, _ b: ChirpColor.RGB) -> Bool {
            abs(a.r - b.r) < 0.002 && abs(a.g - b.g) < 0.002 && abs(a.b - b.b) < 0.002
        }
        #expect(ChirpDesign.current == .pond)
        #expect(close(resolved(.chirpKoi, .aqua), ChirpColor.Pond.koi.light))
        ChirpDesign.with(.v2) {
            #expect(ChirpDesign.current == .v2)
            #expect(close(resolved(.chirpKoi, .aqua), ChirpColor.Graphite.koi.light))
            #expect(close(resolved(.chirpKoi, .darkAqua), ChirpColor.Graphite.koi.dark))
            #expect(close(resolved(SettingsLayout.pageBackground, .aqua), ChirpColor.Graphite.background.light))
            #expect(close(resolved(NotesEditorDecorations.moon, .aqua), ChirpColor.Graphite.moon.light))
            #expect(ChirpRadius.panel == 24 && HUDViewMetrics.corner == 22)
        }
        #expect(ChirpDesign.current == .pond)
        #expect(close(resolved(SettingsLayout.pageBackground, .aqua), ChirpColor.Pond.background.light))
        #expect(ChirpRadius.panel == 16 && HUDViewMetrics.corner == 22)
    }
}

/// Renders the curated set in the v2 design to a temp directory: it must not crash, must stay inside the committed
/// set's size cap, must really draw differently, and must leave Pond current afterwards. Named `…SnapshotTests` so CI
/// skips it with the other snapshot suites (the runner's fonts change PNG sizes); it runs in `scripts/test.sh`.
@MainActor @Suite struct DesignV2SnapshotTests {
    @Test func theCuratedSetRendersInV2() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-v2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let scenarios = Snapshots.committedScenarios
        let v2 = try Snapshots.render(to: root.appendingPathComponent("v2"), scenarios: scenarios, design: .v2)
        #expect(ChirpDesign.current == .pond)
        #expect(Set(v2.map(\.lastPathComponent)) == Set(Snapshots.committedNames.flatMap { ["\($0)-dark.png", "\($0)-light.png"] }))
        let total = try v2.reduce(0) { $0 + (try FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? Int ?? 0) }
        #expect(total < 20_000_000, "\(total) bytes")
        let sample = scenarios.filter { ["settings-general-ready", "notes-library"].contains($0.name) }
        #expect(sample.count == 2)
        let pond = try Snapshots.render(to: root.appendingPathComponent("pond"), scenarios: sample, design: .pond)
        for file in pond {
            let other = root.appendingPathComponent("v2").appendingPathComponent(file.lastPathComponent)
            #expect(try Data(contentsOf: file) != Data(contentsOf: other), "\(file.lastPathComponent) looks the same in v2")
        }
    }
}
