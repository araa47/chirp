import AVFoundation
import Foundation
import Testing
@testable import ChirpCore

/// Scriptable engine: counts installs and removals so a leaked tap shows up as an imbalance. No hardware.
final class FakeEngine: CaptureEngine, @unchecked Sendable {
    var format: AVAudioFormat? = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    var resumeSucceeds = false
    var resumeAttempts = 0
    var onReset: (() -> Void)?
    /// Runs as a resume is tried (the real engine refreshes `inputName` there).
    var onResume: (() -> Void)?
    func resetForCapture() { onReset?() }
    func resumeAfterConfigurationChange() -> Bool {
        resumeAttempts += 1
        onResume?()
        return resumeSucceeds
    }
    var startError: Error?
    var taps = 0                // currently installed
    var installs = 0, removes = 0, stops = 0
    private var block: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var onChange: (@Sendable () -> Void)?

    var inputFormat: AVAudioFormat? { format }
    func installTap(_ block: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        // A real engine throws on a second tap on the same bus; model that.
        precondition(taps == 0, "duplicate tap")
        taps += 1; installs += 1
        self.block = block
    }
    func removeTap() { taps = max(0, taps - 1); removes += 1; block = nil }
    func prepare() {}
    /// Runs as the input starts (a test clock can charge the engine's start-up time here).
    var onStart: (() -> Void)?
    func start() throws {
        if let startError { throw startError }
        onStart?()
    }
    func stop() { stops += 1 }
    func setConfigurationChangeHandler(_ handler: (@Sendable () -> Void)?) { onChange = handler }

    /// Delivers `seconds` of a synthetic tone through the installed tap.
    func deliver(seconds: Double) {
        let format = format!
        let n = AVAudioFrameCount(format.sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
        buffer.frameLength = n
        for i in 0..<Int(n) { buffer.floatChannelData![0][i] = 0.3 * sinf(Float(i) * 0.05) }
        block?(buffer)
    }
    func changeConfiguration() { onChange?() }
    var hasChangeHandler: Bool { onChange != nil }
    /// What `fallBack` moves to, in order: an input's name, or nil for one that fails to start too.
    var fallbacks: [String?] = []
    var inputName: String? = "USB Microphone"
    func fallBack() -> Bool {
        guard !fallbacks.isEmpty else { return false }
        let next = fallbacks.removeFirst()
        inputName = next
        startError = next == nil ? Boom() : nil
        format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        return true
    }
    struct Boom: Error {}
}

final class InputEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [CaptureInputEvent] = []
    var events: [CaptureInputEvent] { lock.withLock { _events } }
    func add(_ e: CaptureInputEvent) { lock.withLock { _events.append(e) } }
}

final class FrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Data] = []
    var count: Int { lock.withLock { frames.count } }
    var bytes: Int { lock.withLock { frames.reduce(0) { $0 + $1.count } } }
    func add(_ d: Data) { lock.withLock { frames.append(d) } }
}

@Suite struct AudioCaptureTests {
    struct Boom: Error {}

    @Test func failedStartAfterTheTapWasInstalledUnwindsEverything() throws {
        let engine = FakeEngine()
        engine.startError = Boom()
        let capture = AudioCapture(engine: engine)
        #expect(throws: Boom.self) { try capture.start { _ in } }
        #expect(engine.taps == 0)                       // the tap did not leak
        #expect(engine.stops == 1)
        #expect(!capture.isRunning)
        #expect(!engine.hasChangeHandler)
    }

    @Test func retryAfterAFailedStartInstallsOneCleanTap() throws {
        let engine = FakeEngine()
        let box = FrameBox()
        let capture = AudioCapture(engine: engine)
        engine.startError = Boom()
        #expect(throws: Boom.self) { try capture.start { _ in } }
        engine.startError = nil
        try capture.start { box.add($0) }               // would trap on a duplicate tap if the first leaked
        #expect(capture.isRunning && engine.taps == 1)
        engine.deliver(seconds: 0.2)
        #expect(box.count > 0)
        capture.stop()
        #expect(engine.taps == 0)
    }

    @Test func stopIsIdempotentAndHarmlessWhenNeverStarted() throws {
        let engine = FakeEngine()
        let capture = AudioCapture(engine: engine)
        capture.stop()
        #expect(engine.stops == 0 && engine.removes == 0)
        let box = FrameBox()
        try capture.start { box.add($0) }
        engine.deliver(seconds: 0.11)
        capture.stop()
        let afterFirst = (engine.removes, engine.stops, box.bytes)
        capture.stop()
        capture.stop()
        #expect(engine.removes == afterFirst.0 && engine.stops == afterFirst.1 && box.bytes == afterFirst.2)
        #expect(!capture.isRunning)
    }

    @Test func stopDeliversTheTrailingPartialFramePadded() throws {
        let engine = FakeEngine()
        let box = FrameBox()
        let capture = AudioCapture(engine: engine)
        try capture.start { box.add($0) }
        engine.deliver(seconds: 0.075)                  // 1.5 frames at 50 ms
        let before = box.count
        capture.stop()
        #expect(box.count == before + 1)
        #expect(box.bytes % 2 == 0)
    }

    @Test func noInputDeviceThrowsAndLeavesNothingInstalled() {
        let engine = FakeEngine()
        engine.format = nil
        let capture = AudioCapture(engine: engine)
        #expect(throws: CaptureError.self) { try capture.start { _ in } }
        #expect(engine.installs == 0 && !capture.isRunning)
    }

    @Test func unchangedInputResumesWithoutReplacingItsTapOrConverter() throws {
        let engine = FakeEngine(), box = FrameBox()
        let capture = AudioCapture(engine: engine)
        try capture.start { box.add($0) }
        engine.deliver(seconds: 0.025)
        engine.resumeSucceeds = true
        for _ in 0..<10 { engine.changeConfiguration() }
        engine.deliver(seconds: 0.2)
        #expect(engine.resumeAttempts == 10)
        #expect(engine.installs == 1 && engine.removes == 0 && engine.stops == 0)
        #expect(capture.isRunning && box.count > 0)
        capture.stop()
        #expect(engine.taps == 0 && !engine.hasChangeHandler)
    }

    @Test func engineRefreshPrecedesReadingTheInputFormat() throws {
        let engine = FakeEngine()
        engine.format = nil
        engine.onReset = { engine.format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1) }
        let capture = AudioCapture(engine: engine), box = FrameBox()
        try capture.start { box.add($0) }
        engine.deliver(seconds: 0.2)
        #expect(capture.isRunning && engine.installs == 1 && box.count > 0)
        capture.stop()
    }

    @Test func onlyTheWantedDeviceWithTheTapsFormatResumesInPlace() {
        let mono48 = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let mono24 = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let stereo48 = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let usb = 7, builtIn = 3
        #expect(AudioCapture.canResume(on: Int?.none, wanted: nil, tap: mono48, input: mono48))  // follows the default
        #expect(AudioCapture.canResume(on: usb, wanted: usb, tap: mono48, input: mono48))        // picked, still there
        #expect(!AudioCapture.canResume(on: usb, wanted: nil, tap: mono48, input: mono48))       // picked one unplugged
        #expect(!AudioCapture.canResume(on: usb, wanted: builtIn, tap: mono48, input: mono48))   // falling back
        #expect(!AudioCapture.canResume(on: nil, wanted: usb, tap: mono48, input: mono48))       // picked one is back
        #expect(!AudioCapture.canResume(on: usb, wanted: usb, tap: mono48, input: mono24))       // rate changed
        #expect(!AudioCapture.canResume(on: usb, wanted: usb, tap: mono48, input: stereo48))     // channels changed
        #expect(!AudioCapture.canResume(on: usb, wanted: usb, tap: nil, input: mono48))          // no tap (waiting)
    }

    @Test func aDeviceChangeRebuildsTheTapOnTheNewFormat() throws {
        let engine = FakeEngine()
        let box = FrameBox()
        let capture = AudioCapture(engine: engine)
        try capture.start { box.add($0) }
        engine.format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)
        engine.changeConfiguration()
        #expect(engine.installs == 2 && engine.taps == 1 && capture.isRunning)
        engine.deliver(seconds: 0.2)
        #expect(box.count > 0)
        capture.stop()
        #expect(engine.taps == 0)
    }

    @Test func aFailedRebuildUnwindsAndReportsOnce() throws {
        let engine = FakeEngine()
        let failures = FrameBox()
        let capture = AudioCapture(engine: engine)
        try capture.start(onFailure: { failures.add(Data()) }) { _ in }
        engine.startError = Boom()
        engine.changeConfiguration()
        #expect(failures.count == 1)
        #expect(engine.taps == 0 && !capture.isRunning)
        engine.changeConfiguration()                    // handler was removed; nothing more happens
        #expect(failures.count == 1)
    }

    // MARK: a capture that survives losing its input (Live Notes)

    @Test func aLostInputFallsBackToTheNextOneAndSaysWhich() throws {
        let engine = FakeEngine()
        let events = InputEvents(), box = FrameBox(), failures = FrameBox()
        let capture = AudioCapture(engine: engine)
        try capture.start(onInput: { events.add($0) }, onFailure: { failures.add(Data()) }) { box.add($0) }
        engine.fallbacks = [nil, "MacBook Pro Microphone"]   // the default fails too; the built-in works
        engine.startError = FakeEngine.Boom()
        engine.changeConfiguration()
        #expect(events.events == [.switched("MacBook Pro Microphone")])
        #expect(failures.count == 0 && capture.isRunning && engine.taps == 1)
        engine.deliver(seconds: 0.2)
        #expect(box.count > 0)
        capture.stop()
        #expect(engine.taps == 0 && !engine.hasChangeHandler)
    }

    @Test func withNoInputLeftCaptureWaitsAndResumesWhenOneAppears() throws {
        let engine = FakeEngine()
        let events = InputEvents(), box = FrameBox()
        let capture = AudioCapture(engine: engine)
        try capture.start(onInput: { events.add($0) }) { box.add($0) }
        engine.format = nil
        engine.changeConfiguration()
        engine.changeConfiguration()                    // still nothing: reported once
        #expect(events.events == [.lost])
        #expect(capture.isRunning && engine.taps == 0 && engine.hasChangeHandler)
        engine.format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        engine.inputName = "Studio Microphone"
        engine.changeConfiguration()
        #expect(events.events == [.lost, .switched("Studio Microphone")])
        engine.deliver(seconds: 0.2)
        #expect(box.count > 0 && engine.taps == 1)
        capture.stop()
        #expect(engine.taps == 0)
    }

    @Test func aResumeOnAnotherInputOfTheSameFormatSaysWhich() throws {
        let engine = FakeEngine()
        let events = InputEvents()
        let capture = AudioCapture(engine: engine)
        try capture.start(onInput: { events.add($0) }) { _ in }
        engine.resumeSucceeds = true
        engine.onResume = { engine.inputName = "MacBook Pro Microphone" }   // the default moved; same 48 kHz mono
        engine.changeConfiguration()
        engine.changeConfiguration()                    // same input again: nothing more
        #expect(events.events == [.switched("MacBook Pro Microphone")])
        #expect(engine.resumeAttempts == 2 && engine.installs == 1 && engine.removes == 0)
        capture.stop()
    }

    @Test func aRebuildOnTheSameInputSaysNothing() throws {
        let engine = FakeEngine()
        let events = InputEvents()
        let capture = AudioCapture(engine: engine)
        try capture.start(onInput: { events.add($0) }) { _ in }
        engine.changeConfiguration()
        #expect(events.events.isEmpty && engine.taps == 1)
        capture.stop()
    }
}

