import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

/// The Notes and History text sizes survive a relaunch (#331): one stored factor per surface in `Preferences`.
@MainActor
@Suite struct TextSizePreferenceTests {
    private func suite() -> UserDefaults { UserDefaults(suiteName: "chirp-textsize-\(UUID())")! }

    @Test func missingValueMeansActualSize() {
        let prefs = Preferences(defaults: suite())
        #expect(prefs.notesTextSize == 1 && prefs.historyTextSize == 1)
    }

    @Test func sizesRoundTripPerSurface() {
        let defaults = suite()
        let prefs = Preferences(defaults: defaults)
        prefs.notesTextSize = 1.5
        prefs.historyTextSize = 1.15
        let relaunched = Preferences(defaults: defaults)
        #expect(relaunched.notesTextSize == 1.5 && relaunched.historyTextSize == 1.15)
    }

    @Test func outOfRangeValuesClampToOneHundredThroughTwoHundredPercent() {
        let defaults = suite()
        for (stored, expected) in [(0.2, 1.0), (-3.0, 1.0), (2.5, 2.0), (40.0, 2.0), (Double.nan, 1.0), (.infinity, 1.0)] {
            defaults.set(stored, forKey: "notesTextSize")
            defaults.set(stored, forKey: "historyTextSize")
            let prefs = Preferences(defaults: defaults)
            #expect(prefs.notesTextSize == expected && prefs.historyTextSize == expected)
        }
        defaults.set("big", forKey: "notesTextSize")
        #expect(Preferences(defaults: defaults).notesTextSize == 1)
        let prefs = Preferences(defaults: defaults)
        prefs.notesTextSize = 9
        #expect(defaults.double(forKey: "notesTextSize") == 2)
    }

    @Test func restoreOpensAtTheStoredSizeWithoutReportingAChange() {
        let size = ChirpTextSize()
        var reported: [CGFloat] = []
        size.onChange = { reported.append($0) }
        size.restore(1.75)
        #expect(size.factor == 1.75 && reported.isEmpty)
        size.restore(9)
        #expect(size.factor == 2)
        size.restore(.nan)
        #expect(size.factor == 1)
        size.increase(); size.increase(); size.decrease(); size.reset()
        #expect(reported == [1.15, 1.3, 1.15, 1])
        size.reset()                                  // already 100%: nothing to store
        #expect(reported.count == 4)
    }

    @Test func notesWindowOpensAtTheStoredSizeAndStoresChanges() {
        let h = NotesHarness(storedTextSize: 1.5)
        let size = h.session.window.textSize
        #expect(size.factor == 1.5)
        size.increase()
        #expect(h.prefs.notesTextSize == 1.75)
        size.reset()
        #expect(h.prefs.notesTextSize == 1 && h.prefs.historyTextSize == 1)
        // A window opened with an out-of-range stored value starts at the nearest step.
        #expect(NotesHarness(storedTextSize: 5).session.window.textSize.factor == 2)
        // Without a stored value, 100%.
        #expect(NotesHarness().session.window.textSize.factor == 1)
    }
}
