import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ChirpCore
@testable import ChirpUI

private func timings(_ text: String, pace: Double = 0.3, length: Double = 0.25, stableBefore: Int = 0) -> [WordTiming] {
    text.split(separator: " ").enumerated().map { i, w in
        WordTiming(text: String(w), start: Double(i) * pace, end: Double(i) * pace + length, stable: i < stableBefore)
    }
}

@Suite struct WordTimingProtocolTests {
    @Test func partialCarriesWordsWhenSent() throws {
        let json = #"{"type":"partial","seq":2,"text":"hello world","stable":"","words":[{"text":"hello","start":0.1,"end":0.4,"stable":true},{"text":"world","start":0.5,"end":0.9,"stable":false}]}"#
        let m = try ServerMessage.decode(Data(json.utf8))
        #expect(m == .partial(seq: 2, text: "hello world", stable: "", words: [
            WordTiming(text: "hello", start: 0.1, end: 0.4, stable: true), WordTiming(text: "world", start: 0.5, end: 0.9)]))
    }

    @Test func messagesWithoutWordsDecodeAsBefore() throws {
        #expect(try ServerMessage.decode(Data(#"{"type":"partial","seq":1,"text":"hi","stable":""}"#.utf8)) == .partial(seq: 1, text: "hi", stable: ""))
        guard case .final(let f) = try ServerMessage.decode(Data(#"{"type":"final","text":"hi","raw":"hi"}"#.utf8)) else { Issue.record("not final"); return }
        #expect(f.words == nil)
    }

    @Test func correctingAndFinalCarryTheRawWords() throws {
        let correcting = try ServerMessage.decode(Data(#"{"type":"correcting","seq":3,"raw":"so hi","profile":"chat","words":[{"text":"so","start":0,"end":0.2,"stable":true},{"text":"hi","start":0.3,"end":0.5,"stable":true}]}"#.utf8))
        #expect(correcting == .correcting(seq: 3, raw: "so hi", profile: "chat", words: [
            WordTiming(text: "so", start: 0, end: 0.2, stable: true), WordTiming(text: "hi", start: 0.3, end: 0.5, stable: true)]))
        let json = #"{"type":"final","text":"So, hi.","raw":"so hi","corrected":true,"words":[{"text":"so","start":0,"end":0.2,"stable":true},{"text":"hi","start":0.3,"end":0.5,"stable":true}]}"#
        guard case .final(let f) = try ServerMessage.decode(Data(json.utf8)) else { Issue.record("not final"); return }
        #expect(f.words?.map(\.text) == ["so", "hi"])
        #expect(f.canUseRaw)
    }

    @Test func aWordMissingFieldsStillDecodes() throws {
        let m = try ServerMessage.decode(Data(#"{"type":"partial","seq":1,"text":"x","stable":"","words":[{"text":"x","start":1.5}]}"#.utf8))
        #expect(m == .partial(seq: 1, text: "x", stable: "", words: [WordTiming(text: "x", start: 1.5, end: 1.5, stable: false)]))
    }

    @Test func startAsksForTimingsOnlyWhenTheOverlayIsOn() throws {
        func object(_ s: String) throws -> [String: Any] { try #require(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]) }
        let off = try object(ClientMessage.start(StartOptions()))
        #expect(off["word_timings"] == nil)
        let on = try object(ClientMessage.start(StartOptions(wordTimings: true)))
        #expect(on["word_timings"] as? Bool == true)
    }

    @Test func thePreferenceIsOffByDefaultAndMapsToTheStartMessage() {
        let defaults = UserDefaults(suiteName: "chirp-tests-wordwave-\(UUID().uuidString)")!
        let prefs = Preferences(defaults: defaults)
        #expect(!prefs.wordWaveform)
        #expect(!prefs.startOptions().wordTimings)
        prefs.wordWaveform = true
        #expect(prefs.startOptions().wordTimings)
        #expect(ClientMessage.start(prefs.startOptions()).contains("\"word_timings\":true"))
    }
}

@Suite struct UtteranceLevelsTests {
    @Test func framesMapOntoTimeFromTheFirstSample() {
        var levels = UtteranceLevels()
        for _ in 0..<10 { levels.push(rms: 0.001) }     // 0.0...0.5 s: near silence
        for _ in 0..<10 { levels.push(rms: 0.2) }       // 0.5...1.0 s: speech
        #expect(levels.duration == 1.0)
        let quiet = levels.bars(from: 0, to: 0.5, count: 4)
        let loud = levels.bars(from: 0.5, to: 1.0, count: 4)
        #expect(quiet.allSatisfy { $0 == 0 })
        #expect(loud.allSatisfy { abs($0 - UtteranceLevels.normalize(rms: 0.2)) < 0.0001 })
    }

    @Test func barsKeepThePeakOfTheFramesTheyCover() {
        let levels = UtteranceLevels(samples: [0.1, 0.9, 0.1, 0.1, 0.2, 0.8])
        #expect(levels.bars(from: 0, to: 0.3, count: 2) == [0.9, 0.8])
        #expect(levels.peak(from: 0, to: 0.3) == 0.9)
    }

    @Test func aSpanWithNoAudioYetIsFlatAndATinySpanStillGetsItsFrame() {
        let levels = UtteranceLevels(samples: [0.5, 0.6])
        #expect(levels.bars(from: 3, to: 4, count: 3) == [0, 0, 0])
        #expect(levels.bars(from: 0.06, to: 0.06, count: 2) == [0.6, 0.6])
        #expect(levels.bars(from: 0, to: 1, count: 0).isEmpty)
        #expect(UtteranceLevels().bars(from: 0, to: 1, count: 2) == [0, 0])
    }

    @Test func clearForgetsTheUtterance() {
        var levels = UtteranceLevels(samples: [0.5])
        levels.clear()
        #expect(levels.isEmpty && levels.duration == 0)
    }
}

@Suite struct WordWaveformModelTests {
    @Test func cellsPairEachWordWithItsSpanAndTheSilenceBeforeIt() {
        let words = [WordTiming(text: "so", start: 0.2, end: 0.4, stable: true), WordTiming(text: "hi", start: 1.0, end: 1.3)]
        let cells = WordWaveform.cells(text: "so hi", words: words)
        #expect(cells == [WordCell(id: 0, text: "so", start: 0.2, end: 0.4, stable: true, gapBefore: 0),
                          WordCell(id: 1, text: "hi", start: 1.0, end: 1.3, stable: false, gapBefore: 0.6)])
        #expect(abs(cells[1].duration - 0.3) < 1e-9)
    }

    @Test func withoutTimingsThereIsNothingToDraw() {
        #expect(WordWaveform.cells(text: "so hi", words: nil).isEmpty)
        #expect(WordWaveform.cells(text: "so hi", words: []).isEmpty)
    }

    @Test func theServersWordsWinWhenTheTextSplitsDifferently() {
        let words = timings("a b c")
        #expect(WordWaveform.cells(text: "a  b   c", words: words).map(\.text) == ["a", "b", "c"])
        #expect(WordWaveform.cells(text: "ab c", words: words).map(\.text) == ["a", "b", "c"])
    }

    @Test func badTimesAreClampedAndNeverGoBackwards() {
        let words = [WordTiming(text: "x", start: -1, end: -2), WordTiming(text: "y", start: 0.5, end: 0.2)]
        let cells = WordWaveform.cells(text: "x y", words: words)
        #expect(cells[0].start == 0 && cells[0].end == 0)
        #expect(cells[1].start == 0.5 && cells[1].end == 0.5 && cells[1].gapBefore == 0.5)
    }

    @Test func longDictationKeepsTheNewestWords() {
        // 200 words, well past the 600-character layout bound (the HUD viewport shows only the newest rows of it).
        let text = (1...200).map { "word\($0)" }.joined(separator: " ")
        let cells = WordWaveform.cells(text: text, words: timings(text))
        let (kept, truncated) = WordWaveform.tail(cells)
        #expect(truncated)
        #expect(kept.last?.text == "word200")
        #expect(kept.reduce(0) { $0 + $1.text.count + 1 } <= WordWaveform.characterLimit)
        // Far more than the 120 characters it once kept: about ten rows, so the cut is never inside the viewport.
        #expect(WordWaveform.characterLimit >= 600 && kept.count > 70)
        // What the operator dictates in a long minute (about 80 words) is not cut at all.
        let minute = (1...80).map { "word\($0)" }.joined(separator: " ")
        #expect(!WordWaveform.tail(WordWaveform.cells(text: minute, words: timings(minute))).truncated)
        #expect(kept.first?.gapBefore == 0)
        // Ids are positions in the utterance, so they survive the cut.
        #expect(kept.first?.id == cells.count - kept.count)
        let short = WordWaveform.tail(Array(cells.prefix(5)))
        #expect(!short.truncated && short.cells.count == 5)
    }

    @Test func revisionsAreReportedInPlaceAndNewWordsAreNot() {
        let old = WordWaveform.cells(text: "move the stand", words: timings("move the stand"))
        let new = WordWaveform.cells(text: "move the standup to", words: timings("move the standup to"))
        let (changed, cells) = WordWaveform.revised(old, to: new)
        #expect(changed == [2])
        #expect(cells == new)
        #expect(WordWaveform.revised([], to: new).changed.isEmpty)
    }
}

@Suite @MainActor struct WordWaveformHUDTests {
    private let text = "please move the standup"

    @Test func offByDefaultNothingChanges() {
        let m = HUDModel()
        m.pushLevel(0.2)
        m.showWords(text: text, words: timings(text))
        #expect(!m.showsWordWaveform && m.wordCells.isEmpty && m.utterance.isEmpty)
        #expect(m.levels.samples.last! > 0)
    }

    @Test func onItKeepsEveryLevelAndLaysTheWordsOut() {
        let m = HUDModel()
        m.wordWaveform = true
        for _ in 0..<20 { m.pushLevel(0.1) }
        #expect(m.utterance.duration == 1.0)
        m.showWords(text: text, words: timings(text, stableBefore: 2))
        #expect(m.showsWordWaveform)
        #expect(m.wordCells.map(\.text) == ["please", "move", "the", "standup"])
        #expect(m.wordCells.map(\.stable) == [true, true, false, false])
        m.showWords(text: "please move the standup to", words: timings("please move the standup to", stableBefore: 2))
        #expect(m.wordCells.count == 5 && m.revisedWords.isEmpty)
        m.showWords(text: "please move the stand up to", words: timings("please move the stand up to"))
        #expect(m.revisedWords == [3, 4])
    }

    @Test func aPartialWithoutTimingsFallsBackToPlainText() {
        let m = HUDModel()
        m.wordWaveform = true
        m.showWords(text: text, words: timings(text))
        m.showWords(text: text + " to", words: nil)
        #expect(!m.showsWordWaveform && m.wordCells.isEmpty)
    }

    @Test func polishingKeepsTheRawWordsSettledAndTheCleanedTextDropsThem() async {
        let m = HUDModel()
        m.wordWaveform = true
        m.showWords(text: text, words: timings(text))
        m.beginPolishing(raw: text, style: "Email", words: timings(text, stableBefore: 4))
        #expect(m.polishing && m.showsWordWaveform)
        #expect(m.wordCells.allSatisfy { $0.stable })
        await m.playChangeHighlight(raw: text, cleaned: "Please move the stand-up.")
        #expect(!m.showsWordWaveform && m.wordCells.isEmpty && m.stable == "Please move the stand-up.")
    }

    @Test func polishingWithoutTimingsKeepsMatchingLiveWordsOnly() {
        let m = HUDModel()
        m.wordWaveform = true
        m.showWords(text: text, words: timings(text))
        m.beginPolishing(raw: "um " + text, style: nil, words: nil)     // the live words are the tail of the raw decode
        #expect(m.showsWordWaveform && m.wordCells.allSatisfy { $0.stable })
        m.showWords(text: text, words: timings(text))
        m.beginPolishing(raw: "something else", style: nil, words: nil)
        #expect(!m.showsWordWaveform)
    }

    @Test func anUncorrectedFinalSettlesEveryWordAndResetClearsAll() {
        let m = HUDModel()
        m.wordWaveform = true
        m.pushLevel(0.2)
        m.showWords(text: text, words: timings(text))
        m.finishWords(text: text, words: timings(text))
        #expect(m.showsWordWaveform && m.wordCells.allSatisfy { $0.stable } && m.stable == text && !m.polishing)
        m.settle(on: text)
        #expect(m.wordCells.isEmpty)
        m.showWords(text: text, words: timings(text))
        m.reset()
        #expect(m.wordCells.isEmpty && m.utterance.isEmpty && m.revisedWords.isEmpty && !m.wordsTruncated)
    }

    @Test func truncationIsFlaggedForTheEllipsis() {
        let m = HUDModel()
        m.wordWaveform = true
        let long = (1...200).map { "word\($0)" }.joined(separator: " ")
        m.showWords(text: long, words: timings(long))
        #expect(m.wordsTruncated && m.wordCells.last?.text == "word200")
    }

    @Test func reduceMotionAppliesWithoutAnimation() {
        let m = HUDModel()
        m.wordWaveform = true
        m.reduceMotion = true
        m.showWords(text: text, words: timings(text))
        #expect(m.showsWordWaveform)
    }
}

@Suite @MainActor struct WordWaveformViewTests {
    private func host(_ text: String, polishing: Bool = false, animated: Bool = true) -> NSHostingView<WordWaveformView> {
        let words = timings(text)
        let cells = WordWaveform.cells(text: text, words: words)
        let view = WordWaveformView(cells: cells, levels: Snapshots.demoLevels(for: words), revised: [], truncated: false,
                                    polishing: polishing, animated: animated, contrast: false, pulsePhase: 0.25, shimmerPhase: 0.5,
                                    maxWidth: HUDView.maxTextWidth)
        let host = NSHostingView(rootView: view)
        host.setFrameSize(host.fittingSize)
        return host
    }

    @Test func shortTextIsOneLineAndHugsItsWords() {
        let one = host("so the first")
        let lineHeight = WordWaveformView.ribbonHeight + WordWaveformView.ribbonGap + WordWaveformView.textHeight
        #expect(abs(one.fittingSize.height - lineHeight) < 1)
        let expected = ["so", "the", "first"].map { WordWaveformView.width(of: $0) }.reduce(0, +) + 2 * WordWaveformView.wordSpacing
        #expect(abs(one.fittingSize.width - expected) < 1)
    }

    @Test func longTextWrapsAtTheHUDWidth() {
        let long = host(Array(repeating: "rollout plan review", count: 6).joined(separator: " "))
        #expect(long.fittingSize.width <= HUDView.maxTextWidth + 0.5)
        let lineHeight = WordWaveformView.ribbonHeight + WordWaveformView.ribbonGap + WordWaveformView.textHeight
        #expect(long.fittingSize.height >= 2 * lineHeight + WordWaveformView.lineSpacing - 1)
        // Polishing (the shimmer masks a second copy) and Reduce Motion lay out the same.
        #expect(host(Array(repeating: "rollout plan review", count: 6).joined(separator: " "), polishing: true).fittingSize == long.fittingSize)
        #expect(host(Array(repeating: "rollout plan review", count: 6).joined(separator: " "), animated: false).fittingSize == long.fittingSize)
    }

    @Test func barsFollowTheWordWidthAndAPauseWidensTheGap() {
        #expect(WordWaveformView.barCount(width: 10) == 2)
        #expect(WordWaveformView.barCount(width: 40) == 10)
        #expect(WordWaveformView.gapWidth(seconds: 0.5) == 20)
        #expect(WordWaveformView.gapWidth(seconds: 5) == WordWaveformView.maxSilence)
    }

    @Test func theWordWaveformSnapshotsAreInTheCommittedSet() {
        let names = Snapshots.wordWaveScenarios.map(\.name)
        #expect(names.contains("hud-wordwave-listening") && names.contains("hud-wordwave-long") && names.contains("hud-wordwave-polishing"))
        #expect(names.contains("hud-wordwave-reduce-motion") && names.contains("hud-wordwave-contrast") && names.contains("hud-wordwave-revised"))
        for name in ["hud-wordwave-listening", "hud-wordwave-long", "hud-wordwave-polishing"] {
            #expect(Snapshots.committedNames.contains(name))
        }
        let listening = Snapshots.wordWaveScenarios.first { $0.name == "hud-wordwave-listening" }!
        #expect(Snapshots.png(listening, appearance: .aqua) != nil)
    }
}
