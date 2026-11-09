import Foundation
import Testing
@testable import ChirpCore

/// "Keep listening until I stop" (#381): only the user ends a dictation. The capture sink's clock is the audio itself,
/// so these feed 50 ms frames and never wait.
@Suite struct ContinuousListeningTests {
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [(String, TimeInterval)] = []
        private var clock: TimeInterval = 0
        private(set) var sentBytes = 0
        func level(_ at: TimeInterval) { lock.withLock { clock = at } }
        func add(_ name: String) { lock.withLock { log.append((name, clock)) } }
        func sent(_ data: Data) { lock.withLock { sentBytes += data.count } }
        func times(_ name: String) -> [TimeInterval] { lock.withLock { log.filter { $0.0 == name }.map(\.1) } }
    }

    /// A 50 ms PCM16 frame: a 220 Hz tone at `amplitude` (0 is digital silence).
    static func frame(_ amplitude: Int16) -> Data {
        (0..<800).map { Int16(Double(amplitude) * sin(2 * .pi * 220 * Double($0) / 16_000)).littleEndian }
            .withUnsafeBytes { Data($0) }
    }
    static let speech = frame(8_000), room = frame(30), zero = frame(0)

    func sink(_ mode: ActivationMode = .autoStop, continuous: Bool, calls: Calls) -> DictationCaptureSink {
        DictationCaptureSink(mode: mode, continuous: continuous, autoStopSilence: 1, send: { calls.sent($0) },
                             onLevel: { _, t in calls.level(t) }, onSilence: { calls.add("silence") },
                             onAutoStop: { calls.add("autoStop") }, onLimit: { calls.add("limit") })
    }
    func feed(_ sink: DictationCaptureSink, _ frame: Data, seconds: TimeInterval) {
        for _ in 0..<Int((seconds * 20).rounded()) { sink.handle(frame) }
    }

    @Test(arguments: [ActivationMode.autoStop, .holdToTalk])
    func onlyTheUserEndsIt(mode: ActivationMode) {
        let calls = Calls(), sink = sink(mode, continuous: true, calls: calls)
        feed(sink, Self.room, seconds: 12)       // past the no-speech timeout, nothing said
        feed(sink, Self.speech, seconds: 2)
        feed(sink, Self.room, seconds: 30)       // a long pause
        feed(sink, Self.zero, seconds: 60)       // a muted or gated microphone after it worked: a pause
        feed(sink, Self.speech, seconds: 1)
        feed(sink, Self.room, seconds: 600)      // past the ten-minute ceiling
        #expect(calls.times("autoStop").isEmpty && calls.times("silence").isEmpty && calls.times("limit").isEmpty)
        #expect(calls.sentBytes == Int(705 * 32_000))
    }

    @Test func aSilentMicrophoneBeforeAnySignalStillFails() {
        let calls = Calls(), sink = sink(continuous: true, calls: calls)
        feed(sink, Self.zero, seconds: 3)
        #expect(calls.times("silence").count == 1 && abs(calls.times("silence")[0] - 1.5) < 0.06)
    }

    @Test func theStartCueWindowIsNotASignal() {
        let calls = Calls(), sink = sink(continuous: true, calls: calls)
        for _ in 0..<4 { sink.handle(Self.speech, muted: true) }   // zeroed for the cue, never heard
        feed(sink, Self.zero, seconds: 2)
        #expect(calls.times("silence").count == 1)
    }

    @Test func offIsUnchanged() {
        var calls = Calls(), off = sink(continuous: false, calls: calls)
        feed(off, Self.room, seconds: 1)                            // the detector learns the room first
        feed(off, Self.speech, seconds: 2)
        feed(off, Self.room, seconds: 2)
        #expect(calls.times("autoStop").count == 1 && abs(calls.times("autoStop")[0] - 4) < 0.06)
        feed(off, Self.zero, seconds: 2)
        #expect(calls.times("silence").count == 1)
        feed(off, Self.room, seconds: 600)
        #expect(calls.times("limit").count == 1 && abs(calls.times("limit")[0] - DictationCaptureSink.limitSeconds) < 0.06)
        calls = Calls(); off = sink(.holdToTalk, continuous: false, calls: calls)
        feed(off, Self.room, seconds: 12)
        #expect(calls.times("autoStop").isEmpty)                    // hold to talk never stops on a pause
        feed(off, Self.zero, seconds: 2)
        #expect(calls.times("silence").count == 1)
    }

    @Test func theSilenceGuardOnlyBeforeASignal() {
        var g = SilenceGuard(onlyBeforeSignal: true)
        var t = 0.0, fired = false
        fired = g.feed(Level(peak: 0.01, rms: 0.01), at: t)
        for _ in 0..<200 { t += 0.05; fired = g.feed(.zero, at: t) || fired }
        #expect(!fired)
        var before = SilenceGuard(onlyBeforeSignal: true)
        #expect((0..<40).contains { before.feed(.zero, at: Double($0) * 0.05) })
    }

    @Test func theMachineIgnoresAPauseButEveryStopStillWorks() {
        var m = DictationMachine(mode: .autoStop)
        m.continuous = true
        m.handle(.hotkeyDown(at: 0)); m.handle(.hotkeyUp(at: 0.1)); m.handle(.serverReady)
        #expect(m.handle(.silence) == [] && m.state == .listening)
        #expect(m.handle(.hotkeyDown(at: 900)) == [.finalize])              // the shortcut again
        m = DictationMachine(mode: .autoStop); m.continuous = true
        m.handle(.toggle); m.handle(.serverReady)
        #expect(m.handle(.toggle) == [.finalize])                          // the menu's Stop
        m = DictationMachine(mode: .holdToTalk); m.continuous = true
        m.handle(.hotkeyDown(at: 0)); m.handle(.serverReady)
        #expect(m.handle(.silence) == [])
        #expect(m.handle(.hotkeyUp(at: 700)) == [.finalize])               // letting go
        m = DictationMachine(mode: .autoStop); m.continuous = true
        m.handle(.toggle); m.handle(.serverReady)
        #expect(m.handle(.escape) == [.cancel])                            // Esc
        m = DictationMachine(mode: .autoStop)
        m.handle(.toggle); m.handle(.serverReady)
        #expect(m.handle(.silence) == [.finalize])                         // off: a pause stops it
    }

    @Test func theClockHasNoCeiling() {
        #expect(DictationCaptureSink.durationLabel(121, continuous: false) == "2:01 / 10:00")
        #expect(DictationCaptureSink.durationLabel(700, continuous: false) == "10:00 / 10:00")
        #expect(DictationCaptureSink.durationLabel(0, continuous: true) == "0:00")
        #expect(DictationCaptureSink.durationLabel(700, continuous: true) == "11:40")
        #expect(DictationCaptureSink.durationLabel(3723, continuous: true) == "1:02:03")
    }
}
