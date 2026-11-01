import Foundation
import SwiftUI
import Testing
@testable import ChirpCore
@testable import ChirpUI

/// PR 4: the toast countdown that waits while hovered or focused (unflagged), and the Wake hero's pure frame maths.
@MainActor
@Suite struct ToastTimerTests {
    @Test func countsDownWhenNothingHoldsIt() {
        let timer = ToastTimer()
        timer.begin(.seconds(6))
        #expect(timer.tick(.seconds(2)) == false)
        #expect(timer.remaining == .seconds(4))
        #expect(timer.tick(.seconds(4)) == true)
        #expect(timer.remaining == .zero)
    }

    @Test func hoverPausesAndResumesWhereItLeftOff() {
        let timer = ToastTimer()
        timer.begin(.seconds(6))
        timer.tick(.seconds(2))
        timer.setHovered(true)
        #expect(timer.isPaused)
        #expect(timer.tick(.seconds(60)) == false)
        #expect(timer.remaining == .seconds(4))
        timer.setHovered(false)
        #expect(timer.tick(.seconds(3)) == false)
        #expect(timer.remaining == .seconds(1))
        #expect(timer.tick(.seconds(1)) == true)
    }

    @Test func keyboardFocusPausesLikeHover() {
        let timer = ToastTimer()
        timer.begin(.seconds(10))
        timer.setFocused(true)
        timer.tick(.seconds(30))
        #expect(timer.remaining == .seconds(10))
        timer.setFocused(false)
        timer.tick(.seconds(4))
        #expect(timer.remaining == .seconds(6))
    }

    @Test func staysPausedUntilEveryHoldIsReleased() {
        let timer = ToastTimer()
        timer.begin(.seconds(6))
        timer.setHovered(true)
        timer.setFocused(true)
        timer.setHovered(false)
        #expect(timer.isPaused)
        timer.setFocused(false)
        #expect(!timer.isPaused)
        // A stray "focus lost" never goes negative.
        timer.setFocused(false)
        timer.setFocused(true)
        #expect(timer.isPaused)
    }

    @Test func aNewToastStartsFreshAndClear() {
        let timer = ToastTimer()
        timer.begin(.seconds(6))
        timer.setHovered(true)
        timer.setFocused(true)
        timer.tick(.seconds(1))
        timer.begin(.seconds(6))
        #expect(!timer.isPaused)
        #expect(timer.remaining == .seconds(6))
    }

    @Test func theRealTimeDriverDismissesAfterTheDuration() async {
        let timer = ToastTimer()
        let expired = await timer.run(.milliseconds(120), step: .milliseconds(20))
        #expect(expired)
    }

    @Test func theRealTimeDriverWaitsWhilePausedAndStopsWhenCancelled() async {
        let timer = ToastTimer()
        timer.setHovered(true)
        let task = Task { await timer.run(.milliseconds(200), step: .milliseconds(10)) }
        // `run` clears hover as it begins, so hold the pointer over again once it has started.
        try? await Task.sleep(for: .milliseconds(20))
        timer.setHovered(true)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(timer.remaining > .zero)
        task.cancel()
        #expect(await task.value == false)
    }

    @Test func modelsOwnTheirTimers() {
        let history = HistoryModel()
        let library = NotesLibraryModel()
        history.toastTimer.setHovered(true)
        #expect(history.toastTimer.isPaused)
        #expect(!library.toastTimer.isPaused)
    }
}

@Suite struct HeroOrbTests {
    @Test func theCycleVisitsFourStatesAndLoops() {
        #expect(abs(HeroOrbCycle.total - 9.2) < 1e-9)
        #expect(HeroOrbCycle.state(at: 0.5).state == .idle)
        #expect(HeroOrbCycle.state(at: 2.0).state == .listening)
        #expect(HeroOrbCycle.state(at: 6.0).state == .polishing)
        #expect(HeroOrbCycle.state(at: 8.0).state == .done)
        #expect(HeroOrbCycle.state(at: 9.2 + 0.5).state == .idle)
        #expect(abs(HeroOrbCycle.state(at: 2.3).elapsed - 0.5) < 1e-9)
    }

    @Test func listeningScalesWithTheVoiceAndSpreadsThreeRings() {
        let frame = HeroOrbFrame.make(.listening, time: 3.1, elapsed: 1.3)
        #expect(frame.rings.count == 3)
        #expect(frame.scale > 1 && frame.scale <= 1.16)
        #expect(frame.rings.allSatisfy { (0..<1).contains($0) })
    }

    @Test func doneFiresOneRingAndOffIsGreyAndStill() {
        #expect(HeroOrbFrame.make(.done, time: 8, elapsed: 0.2).rings.count == 1)
        #expect(HeroOrbFrame.make(.done, time: 8, elapsed: 2).rings.isEmpty)
        let off = HeroOrbFrame.make(.off, time: 1, elapsed: 0)
        #expect(off.grey && off.opacity < 1 && off.rings.isEmpty && off.glintTurns == 0)
    }

    @Test func aStillFrameHasNoMotionAnywhere() {
        for state in HeroOrbState.allCases {
            let still = HeroOrbFrame.make(state, time: 3, elapsed: 1, moving: false)
            #expect(still.rings.isEmpty && still.sheen == nil && still.glintTurns == 0)
            if state != .listening { #expect(still.scale == 1) }
        }
    }

    @Test func frameMathIsRepeatable() {
        #expect(HeroOrbFrame.make(.polishing, time: 4.2, elapsed: 0.4) == HeroOrbFrame.make(.polishing, time: 4.2, elapsed: 0.4))
    }

    @Test func voiceOverGetsALabelForEveryMode() {
        #expect(WelcomeHero.accessibilityText(reduceMotion: false, state: nil).contains("listening"))
        #expect(WelcomeHero.accessibilityText(reduceMotion: true, state: nil).contains("ready"))
        #expect(WelcomeHero.accessibilityText(reduceMotion: false, state: .off).contains("off"))
    }
}

@MainActor
@Suite struct V2SnapshotTests {
    /// Renders the hero scenarios into a temp directory (or `CHIRP_V2_SNAPSHOT_DIR` to look at them), so a crash or an
    /// empty render is caught. Nothing here touches docs/screenshots.
    @Test func heroScenariosRender() throws {
        let override = ProcessInfo.processInfo.environment["CHIRP_V2_SNAPSHOT_DIR"]
        let dir = override.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("chirp-v2-\(UUID().uuidString)")
        defer { if override == nil { try? FileManager.default.removeItem(at: dir) } }
        let files = try Snapshots.render(to: dir, scenarios: Snapshots.v2Scenarios)
        #expect(files.count == Snapshots.v2Scenarios.count * 2)
        for file in files { #expect(try Data(contentsOf: file).count > 1000) }
    }
}
