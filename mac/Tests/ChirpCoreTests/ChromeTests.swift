import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ChirpCore
@testable import ChirpUI

/// The Pond chrome: the onboarding step rail and welcome, the HUD's fixed-width panel and the export-folder preference.
@MainActor
@Suite struct ChromeTests {
    private func checks(mic: MicrophoneAccess = .granted, ax: Bool = true, server: ServerCheck = .ready(engine: nil)) -> OnboardingChecks {
        var c = OnboardingChecks()
        c.microphone = mic; c.accessibility = ax; c.server = server
        return c
    }

    // MARK: onboarding rail

    @Test func railMarksTheCurrentStepAndWhatIsAheadLive() {
        let welcome = OnboardingRail.marks(OnboardingFlow(), checks())
        #expect(welcome == [.current, .done, .done, .done, .upcoming])   // checks that already pass show ✓ ahead of time
        let blocked = OnboardingRail.marks(OnboardingFlow(), checks(mic: .denied, ax: false, server: .unreachable(host: "h")))
        #expect(blocked == [.current, .upcoming, .upcoming, .upcoming, .upcoming])
    }

    @Test func railTurnsAPassedStepWarningWhenItIsNotInOrder() {
        let flow = OnboardingState(step: .server).flow
        let ok = OnboardingRail.marks(flow, checks())
        #expect(ok == [.done, .done, .done, .current, .upcoming])
        let revoked = OnboardingRail.marks(flow, checks(mic: .denied, ax: false))
        #expect(revoked == [.done, .warning, .warning, .current, .upcoming])
        let last = OnboardingState(step: .tryIt, heardHotkey: true).flow
        #expect(OnboardingRail.marks(last, checks()) == [.done, .done, .done, .done, .current])
    }

    @Test func railRowsAreLabelledForVoiceOver() {
        #expect(OnboardingRail.label(.microphone, .done) == "Microphone, done")
        #expect(OnboardingRail.label(.accessibility, .warning) == "Accessibility, needs attention")
        #expect(OnboardingRail.label(.tryIt, .current) == "Try it, current step")
        #expect(OnboardingRail.label(.server, .upcoming) == "Chirp server")
    }

    @Test func keycapsSplitAShortcutIntoItsKeys() {
        #expect(OnboardingView.keySymbols("⌃⌥Space") == ["⌃", "⌥", "Space"])
        #expect(OnboardingView.keySymbols("⌃⌥⇧N") == ["⌃", "⌥", "⇧", "N"])
        #expect(OnboardingView.keySymbols("⌥") == ["⌥"])
        // A modifier on its own is one keycap, named for its side.
        #expect(OnboardingView.keySymbols("Right ⌥ Option") == ["Right ⌥ Option"])
        #expect(OnboardingView.keySymbols("⌥ Option") == ["⌥ Option"])
    }

    @Test func theWelcomeIntroducesDictationAndNotesAndTheLastStepOffersOpenNotes() {
        let view = OnboardingView(icon: nil, pond: nil)
        view.apply(OnboardingState(step: .welcome))
        func texts(_ v: NSView) -> [String] {
            ((v as? NSTextField).map { [$0.stringValue] } ?? []) + v.subviews.flatMap(texts)
        }
        let welcome = texts(view)
        #expect(welcome.contains("Dictate into any app"))
        #expect(welcome.contains("Keep conversations in Notes"))
        #expect(view.primary.title == "Get Started" && view.openNotes.isHidden)
        view.apply(OnboardingState(step: .tryIt, heardHotkey: true))
        #expect(!view.openNotes.isHidden && view.openNotes.title == "Open Notes")
        #expect(view.primary.title == "Done")
        #expect(OnboardingView.size == NSSize(width: 720, height: 460))
    }

    // MARK: HUD

    @Test func hudPanelWidthIsFixedPerMode() {
        let model = HUDModel()
        for words in [false, true] {
            model.wordWaveform = words
            let view = NSHostingViewForTests.host(HUDView(model: model))
            for text in ["", "short", String(repeating: "a long dictation goes on ", count: 12)] {
                model.stable = text
                view.layoutSubtreeIfNeeded()
                #expect(abs(view.fittingSize.width - HUDViewMetrics.width(wordWaveform: words)) < 0.5, "\(words) \(text.count)")
            }
        }
    }

    @Test func hudTranscriptViewportCapsTheHeightButKeepsTheText() {
        let model = HUDModel()
        model.flatSurface = true
        model.stable = String(repeating: "word ", count: 160)
        let view = NSHostingViewForTests.host(HUDView(model: model))
        view.layoutSubtreeIfNeeded()
        // The viewport (five lines and a faded one) plus the status row and the padding, however long the dictation.
        let cap = HUDViewMetrics.transcriptMaxHeight(wordWaveform: false) + 20 + 8 + 2 * HUDViewMetrics.verticalPadding
        #expect(abs(view.fittingSize.height - cap) < 1)
        // A long minute of speech (about 600 characters) reaches the view whole: the old 120-character cut dropped the
        // start of it, which read as missing text. The budget only bounds layout work far above the viewport.
        let minute = String(repeating: "and then we check the rollout plan with the team ", count: 12)
        #expect(HUDText.tail(stable: minute, unstable: " and so", limit: HUDText.lineBudget) == (minute, " and so"))
        #expect(HUDText.lineBudget >= 2000)
    }

    @Test func hudViewportFadesOnlyWhenTheTranscriptOverflows() {
        func height(lines n: Int) -> CGFloat {
            let text = (1...n).map { _ in "line" }.joined(separator: "\n")
            return NSHostingView(rootView: Text(text).font(.system(size: 15)).frame(width: 440, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)).fittingSize.height
        }
        // The viewport's line pitch is SwiftUI's own for 15 pt text.
        #expect(abs((height(lines: 6) - height(lines: 1)) / 5 - HUDViewMetrics.lineHeight) < 0.01)
        // Five lines fit whole (no fade); a sixth fills the viewport, the cue for the top-edge fade, with most of the
        // earliest visible line still showing above the five.
        let viewport = HUDViewMetrics.transcriptMaxHeight(wordWaveform: false)
        #expect(height(lines: 5) < viewport - 0.5 && height(lines: 6) > viewport)
        #expect(viewport - height(lines: 5) >= 0.75 * HUDViewMetrics.lineHeight)
        // Word cells: three rows whole, a fourth fills it.
        let row = WordWaveformView.ribbonHeight + WordWaveformView.ribbonGap + WordWaveformView.textHeight
        let rows = { (n: CGFloat) in n * row + (n - 1) * WordWaveformView.lineSpacing }
        let words = HUDViewMetrics.transcriptMaxHeight(wordWaveform: true)
        #expect(rows(3) < words - 0.5 && rows(4) > words)
    }

    @Test func theDurationJoinsTheStatusRowUnlessPrivate() {
        func height(_ configure: (HUDModel) -> Void) -> CGFloat {
            let m = HUDModel()
            m.flatSurface = true
            m.status = HUDStatus.listening
            configure(m)
            return NSHostingViewForTests.host(HUDView(model: m)).fittingSize.height
        }
        // An ordinary dictation is one 44 pt capsule with its timer; Private adds the lock line above.
        let plain = height { _ in }
        #expect(height { $0.duration = "0:24 / 10:00" } == plain && plain <= 44.5)
        #expect(height { $0.duration = "0:24 / 10:00"; $0.privateSession = true } > plain + 10)
    }

    // MARK: export folder

    @Test func exportFolderIsAPathThatClearsBackToNone() {
        let name = "chirp-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = Preferences(defaults: defaults)
        #expect(prefs.notesExportFolder == nil)
        prefs.notesExportFolder = "/tmp/notes"
        #expect(Preferences(defaults: defaults).notesExportFolder == "/tmp/notes")
        prefs.notesExportFolder = nil
        #expect(Preferences(defaults: defaults).notesExportFolder == nil)
    }
}

@MainActor
private enum NSHostingViewForTests {
    static func host<V: SwiftUI.View>(_ view: V) -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        host.setFrameSize(host.fittingSize)
        return host
    }
}
