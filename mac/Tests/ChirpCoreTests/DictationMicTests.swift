import Foundation
import Testing
@testable import ChirpCore

/// A clock the test moves by hand (uptime seconds).
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval
    init(_ t: TimeInterval) { self.t = t }
    func now() -> TimeInterval { lock.withLock { t } }
    func advance(_ d: TimeInterval) { lock.withLock { t += d } }
}

/// What a dictation's sink received: each frame and whether it was zeroed for the cue.
private final class SentAudio: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [(Data, Bool)] = []
    func add(_ frame: Data, _ muted: Bool) { lock.withLock { frames.append((frame, muted)) } }
    var muted: [Bool] { lock.withLock { frames.map(\.1) } }
    var data: Data { lock.withLock { frames.reduce(into: Data()) { $0.append($1.0) } } }
    var samples: [Int16] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }
}

/// The same deliveries through a plain `AudioCapture`: what the microphone heard, frame for frame.
private func heard(_ deliveries: [Double]) throws -> Data {
    let engine = FakeEngine()
    let capture = AudioCapture(engine: engine)
    let box = SentAudio()
    try capture.start { box.add($0, false) }
    for seconds in deliveries { engine.deliver(seconds: seconds) }
    return box.data
}

private func samples(_ seconds: TimeInterval) -> Int { Int((seconds * PCMConverter.sampleRate).rounded()) }

@Suite struct DictationMicTests {
    /// Opening the input on the fake engine costs this much on the test clock.
    static let engineStart: TimeInterval = 0.03
    /// The default pack's start cue (Assets/Sounds/chirp-start.wav).
    static let chirpCue: TimeInterval = 0.12

    private func make() -> (DictationMic, FakeEngine, TestClock) {
        let clock = TestClock(100)
        let engine = FakeEngine()
        engine.onStart = { clock.advance(Self.engineStart) }
        return (DictationMic(capture: AudioCapture(engine: engine), now: { clock.now() }), engine, clock)
    }

    /// What `DictationController` does at a dictation's start: open the microphone (unless the press already did),
    /// attach the dictation's sink, then play the start cue and zero its window. Nothing waits for the cue.
    private func start(_ mic: DictationMic, clock: TestClock, cue: TimeInterval?, into sent: SentAudio) throws {
        try mic.open()
        mic.attach { sent.add($0, $1) }
        if let cue { mic.excludeCue(at: clock.now(), length: SoundTiming.muteWindow(cueDuration: cue)) }
    }

    @Test func soundsOnOrOffTheFirstSampleIsCapturedAtTheSameTime() throws {
        var latency: [Bool: TimeInterval] = [:]
        for soundsOn in [false, true] {
            let (mic, engine, clock) = make()
            let sent = SentAudio()
            let pressed = clock.now()
            try start(mic, clock: clock, cue: soundsOn ? Self.chirpCue : nil, into: sent)
            engine.deliver(seconds: 0.5)
            latency[soundsOn] = try #require(mic.openedAt) - pressed

            let window = samples(SoundTiming.muteWindow(cueDuration: Self.chirpCue))   // 160 ms
            let pcm = sent.samples
            if soundsOn {
                // The cue's window is zeroed; the whole frames inside it are flagged, and what follows is kept.
                #expect(pcm[..<window].allSatisfy { $0 == 0 })
                #expect(pcm[window..<(window + 640)].contains { $0 != 0 })
                #expect(sent.muted.prefix(4) == [true, true, true, false])
            } else {
                #expect(pcm[160..<window].contains { $0 != 0 })
                #expect(!sent.muted.contains(true))
            }
            #expect(sent.data.count == (try heard([0.5])).count)   // zeroed, never dropped
            mic.close()
        }
        // Hotkey-down → first captured sample: only the input's own start-up, with the cue or without it.
        #expect(latency[false] == latency[true])
        #expect(abs(try #require(latency[true]) - Self.engineStart) < 1e-9)
        // Before, the microphone opened only after the cue (cue + 20 ms, at most 300 ms), then started up.
        let before = SoundTiming.micDelay(cueDuration: Self.chirpCue) + Self.engineStart
        #expect(try #require(latency[true]) < before)
    }

    @Test func aCuePlayedBeforeTheMicrophoneCouldOpenZeroesNothing() throws {
        // The first dictation waits for the permission prompt: the cue is long over by the time the input opens.
        let (mic, engine, clock) = make()
        let sent = SentAudio()
        mic.excludeCue(at: clock.now(), length: SoundTiming.muteWindow(cueDuration: Self.chirpCue))
        clock.advance(2)
        try mic.open()
        mic.attach { sent.add($0, $1) }
        engine.deliver(seconds: 0.3)
        #expect(!sent.muted.contains(true))
        #expect(sent.data == (try heard([0.3])))
    }

    @Test func thePreRollIsSentFirstInOrderAndOnlyTheCueInsideItsWindowIsZeroed() throws {
        // A held Right ⌥: the microphone opened on the press, the dictation started (and the cue played) 200 ms later.
        let (mic, engine, _) = make()
        let sent = SentAudio()
        try mic.open()
        engine.deliver(seconds: 0.2)
        mic.attach { sent.add($0, $1) }
        let opened = try #require(mic.openedAt)
        mic.excludeCue(at: opened + 0.2, length: SoundTiming.muteWindow(cueDuration: Self.chirpCue))
        engine.deliver(seconds: 0.3)
        mic.close()

        let reference = try heard([0.2, 0.3])
        let pcm = sent.samples
        let from = samples(0.2), to = samples(0.2 + SoundTiming.muteWindow(cueDuration: Self.chirpCue))
        #expect(sent.data.count >= reference.count + 640)   // plus the trailing frame `stop` flushes
        // The pre-roll, unchanged and first; the window is zeroed (± a sample of rounding); the rest is unchanged.
        #expect(sent.data.prefix((from - 1) * 2) == reference.prefix((from - 1) * 2))
        #expect(pcm[from..<to].allSatisfy { $0 == 0 })
        #expect(sent.data[((to + 1) * 2)..<reference.count] == reference[((to + 1) * 2)...])
    }

    @Test func thePreRollHoldsAtMostOneSecondDroppingTheOldest() throws {
        let (mic, engine, _) = make()
        let sent = SentAudio()
        try mic.open()
        for _ in 0..<6 { engine.deliver(seconds: 0.5) }   // 3 s with no dictation attached
        mic.attach { sent.add($0, $1) }
        let limit = samples(DictationMic.preRollLimit) * 2
        let reference = try heard(Array(repeating: 0.5, count: 6))
        #expect(sent.data.count <= limit)
        #expect(sent.data.count > limit - PCMConverter.frameBytes)
        #expect(sent.data == reference.suffix(sent.data.count))
        mic.close()
    }

    @Test func aPressThatNeverBecomesADictationDropsItsPreRollUnsentAndClosesTheMicrophone() throws {
        let (mic, engine, _) = make()
        try mic.open()
        engine.deliver(seconds: 0.3)
        #expect(mic.isOpen && engine.taps == 1)
        mic.close()   // a chord (⌥←) or an early release
        #expect(!mic.isOpen && engine.taps == 0 && engine.stops >= 1)

        // Nothing of it reaches the next dictation.
        let sent = SentAudio()
        mic.attach { sent.add($0, $1) }
        #expect(sent.data.isEmpty)
        mic.close()
        try mic.open()
        mic.attach { sent.add($0, $1) }
        engine.deliver(seconds: 0.1)
        #expect(sent.data == (try heard([0.1])))
        mic.close()
    }

    /// Delivers `seconds` of input as the hardware does: in `chunk`-long buffers, each one as it fills.
    private func live(_ engine: FakeEngine, _ clock: TestClock, seconds: Double, chunk: Double = 0.04) {
        for _ in 0..<Int((seconds / chunk).rounded()) {
            clock.advance(chunk)
            engine.deliver(seconds: chunk)
        }
    }

    @Test func aRouteChangeDuringThePreRollZeroesTheCueNotTheSpeechAfterIt() throws {
        // Right ⌥ on a Bluetooth headset: the press opens the microphone, the headset switches to its call profile and
        // the input stops for half a second, then resumes on the same format; the dictation starts and the cue plays.
        let (mic, engine, clock) = make()
        let sent = SentAudio()
        try mic.open()
        live(engine, clock, seconds: 0.2)
        engine.resumeSucceeds = true
        clock.advance(0.5)
        engine.changeConfiguration()
        mic.attach { sent.add($0, $1) }
        mic.excludeCue(at: clock.now(), length: SoundTiming.muteWindow(cueDuration: Self.chirpCue))
        live(engine, clock, seconds: 0.6)
        mic.close()

        let pcm = sent.samples
        let resumed = samples(0.2)
        #expect(pcm[..<resumed].contains { $0 != 0 })   // the pre-roll is kept
        // What the microphone heard while the cue played is zeroed (at most one buffer early, inside the margin)…
        #expect(pcm[resumed..<(resumed + samples(Self.chirpCue))].allSatisfy { $0 == 0 })
        // …and the speech after the window is not.
        let window = samples(SoundTiming.muteWindow(cueDuration: Self.chirpCue))
        let after = pcm[(resumed + window)...]
        #expect(after.filter { $0 == 0 }.count < after.count / 100)   // only the tone's zero crossings
        #expect(pcm.count >= samples(0.8))   // zeroed, never dropped
    }

    @Test func anInputThatStartsLateZeroesNoneOfTheSpeechItHears() throws {
        // A Bluetooth microphone takes half a second to deliver its first buffer: the cue is over before the
        // microphone hears anything, so nothing it hears is zeroed.
        let (mic, engine, clock) = make()
        let sent = SentAudio()
        try start(mic, clock: clock, cue: Self.chirpCue, into: sent)
        clock.advance(0.5)
        live(engine, clock, seconds: 0.4)
        mic.close()
        #expect(!sent.muted.contains(true))
        #expect(sent.samples[..<samples(0.4)].filter { $0 == 0 }.count < 40)   // only the tone's zero crossings
    }
}

/// A socket that is still connecting: every send waits until `connect()`. Records audio and text frames.
private final class ConnectingSocket: StreamTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var isConnected = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var frames: [Data] = []
    private var texts: [String] = []
    private let messages: AsyncStream<URLSessionWebSocketTask.Message>
    private let input: AsyncStream<URLSessionWebSocketTask.Message>.Continuation
    let stops: AsyncStream<Void>
    private let stopped: AsyncStream<Void>.Continuation

    init() {
        (messages, input) = AsyncStream.makeStream()
        (stops, stopped) = AsyncStream.makeStream()
    }

    var audio: Data { lock.withLock { frames.reduce(into: Data()) { $0.append($1) } } }
    var sentTexts: [String] { lock.withLock { texts } }

    func connect() {
        let resume = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isConnected = true
            defer { waiting = [] }
            return waiting
        }
        for c in resume { c.resume() }
    }

    func resume() {}
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if isConnected { return true }
                waiting.append(c)
                return false
            }
            if now { c.resume() }
        }
        switch message {
        case .data(let data): lock.withLock { frames.append(data) }
        case .string(let text):
            lock.withLock { texts.append(text) }
            if text.contains("\"type\":\"start\"") {
                input.yield(.string(#"{"type":"ready","session":"test","debug_retention":false}"#))
            }
            if text.contains("\"type\":\"stop\"") { stopped.yield() }
        @unknown default: break
        }
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        var iterator = messages.makeAsyncIterator()
        guard let message = await iterator.next() else { throw URLError(.cancelled) }
        return message
    }
    func cancel(with code: URLSessionWebSocketTask.CloseCode) { input.finish() }
}

/// Real StreamSessions: on the hosted runners' Swift 6.2/6.3 these abort a shared test process, so `ci-test.sh` runs
/// them one test per process (with the other stream suites).
@Suite(.timeLimit(.minutes(1))) struct DictationStartTests {
    @Test func audioCapturedWhileTheSocketConnectsIsSentInOrderOnceItIsUp() async throws {
        let engine = FakeEngine()
        let mic = DictationMic(capture: AudioCapture(engine: engine))
        let socket = ConnectingSocket()
        let session = RollingDictationSession(correctionTimeout: 5, makeStream: {
            StreamSession(transport: socket, options: StartOptions())
        })
        try mic.open()
        mic.attach { frame, _ in session.sendAudio(frame) }
        await session.open()
        for _ in 0..<6 { engine.deliver(seconds: 0.5) }   // 3 s before the socket is up
        #expect(socket.audio.isEmpty)
        socket.connect()
        mic.close()
        await session.stop()
        for await _ in socket.stops { break }
        // Nothing was dropped while connecting: every frame, in order, then the trailing one `stop` flushes.
        let reference = try heard(Array(repeating: 0.5, count: 6))
        #expect(socket.audio.count >= reference.count + 640)
        #expect(socket.audio.prefix(reference.count) == reference)
        await session.close()
    }

    @Test func anAccidentalTapStillCancelsCleanly() async throws {
        var machine = DictationMachine(mode: .holdToTalk)
        let engine = FakeEngine()
        let mic = DictationMic(capture: AudioCapture(engine: engine))
        let socket = ConnectingSocket()
        socket.connect()
        let session = RollingDictationSession(correctionTimeout: 5, makeStream: {
            StreamSession(transport: socket, options: StartOptions())
        })
        #expect(machine.handle(.hotkeyDown(at: 0)) == [.start])
        try mic.open()   // at once: no cue wait
        mic.attach { frame, _ in session.sendAudio(frame) }
        await session.open()
        engine.deliver(seconds: 0.1)
        #expect(machine.handle(.hotkeyUp(at: 0.1)) == [.abort(DictationMachine.holdHint)])
        #expect(machine.state == .error(DictationMachine.holdHint))
        // The controller's teardown: microphone first, then the socket is told to discard.
        mic.close()
        await session.cancel()
        #expect(!mic.isOpen && engine.taps == 0)
        engine.deliver(seconds: 0.1)
        var finals = 0
        for await event in session.events { if case .message(.final) = event { finals += 1 } }
        #expect(finals == 0)
        #expect(!socket.sentTexts.contains { $0.contains("\"type\":\"stop\"") })
    }
}

/// `DictationController`'s Right ⌥ rule, on the real gesture, machine and microphone: the press opens the microphone,
/// and its audio is kept only when the gesture starts a dictation; otherwise the microphone closes and nothing is sent.
private final class RightOptionPress {
    var gesture: HotkeyGesture
    var machine: DictationMachine
    let engine = FakeEngine()
    let clock = TestClock(100)
    let mic: DictationMic
    let sent = SentAudio()
    private var preRollPress: TimeInterval?

    init(mode: ActivationMode) {
        gesture = HotkeyGesture(mode: mode, modifierOnly: true, singleKey: true)
        machine = DictationMachine(mode: mode)
        let clock = self.clock
        engine.onStart = { clock.advance(DictationMicTests.engineStart) }
        mic = DictationMic(capture: AudioCapture(engine: engine), now: { clock.now() })
    }

    func down(at t: TimeInterval) throws {
        if gesture.opensMicOnPress, !machine.state.isActive, !mic.isOpen { try mic.open(); preRollPress = t }
        deliver(gesture.down(at: t))
    }
    func armDue(pressedAt p: TimeInterval, at t: TimeInterval) { deliver(gesture.armDue(pressedAt: p, at: t)); drop(of: p) }
    func up(at t: TimeInterval) { deliver(gesture.up(at: t)); drop() }
    func chord() { deliver(gesture.chord()); drop() }

    private func deliver(_ events: [DictationEvent]) {
        for event in events {
            for effect in machine.handle(event) {
                switch effect {
                case .start:
                    preRollPress = nil
                    try? mic.open()
                    mic.attach { [sent] in sent.add($0, $1) }
                case .finalize, .cancel, .abort: mic.close()
                case .insert: break
                }
            }
        }
    }
    private func drop(of press: TimeInterval? = nil) {
        guard let opened = preRollPress, press == nil || press == opened else { return }
        preRollPress = nil
        if !machine.state.isActive { mic.close() }
    }
}

@Suite struct RightOptionPreRollTests {
    @Test func aHeldPressKeepsWhatWasSaidBeforeItArmed() throws {
        let press = RightOptionPress(mode: .autoStop)
        try press.down(at: 0)
        #expect(press.mic.isOpen)                      // on the press, before the gesture knows
        press.engine.deliver(seconds: 0.2)            // the first words, before armDelay
        press.armDue(pressedAt: 0, at: HotkeyGesture.armDelay)
        #expect(press.machine.state == .connecting)
        press.engine.deliver(seconds: 0.3)
        #expect(press.sent.data == (try heard([0.2, 0.3])))   // nothing lost, nothing reordered
        press.up(at: 2)                              // a hold past tapLimit finishes
        #expect(press.machine.state == .finalizing && !press.mic.isOpen)
    }

    @Test func aTapKeepsItsPreRollAndStaysOn() throws {
        let press = RightOptionPress(mode: .autoStop)
        try press.down(at: 0)
        press.engine.deliver(seconds: 0.1)
        press.up(at: 0.1)
        press.armDue(pressedAt: 0, at: HotkeyGesture.armDelay)   // the old timer must not close the dictation's mic
        #expect(press.machine.state == .connecting && press.mic.isOpen)
        press.engine.deliver(seconds: 0.1)
        #expect(press.sent.data == (try heard([0.1, 0.1])))
    }

    @Test func aChordDropsThePreRollUnsentAndClosesTheMicrophone() throws {
        let press = RightOptionPress(mode: .autoStop)
        try press.down(at: 0)
        press.engine.deliver(seconds: 0.1)
        press.chord()                                // Right ⌥ + ←
        #expect(press.machine.state == .idle)
        #expect(!press.mic.isOpen && press.engine.taps == 0)
        press.armDue(pressedAt: 0, at: HotkeyGesture.armDelay)
        #expect(press.sent.data.isEmpty)
    }

    @Test func anEarlyReleaseInHoldToTalkDropsThePreRoll() throws {
        let press = RightOptionPress(mode: .holdToTalk)
        try press.down(at: 0)
        press.engine.deliver(seconds: 0.1)
        press.up(at: 0.1)                            // before armDelay: never a dictation
        #expect(press.machine.state == .idle && !press.mic.isOpen)
        #expect(press.sent.data.isEmpty)
    }

    @Test func anAccidentalTapAfterArmingStillCancelsCleanly() throws {
        // Hold to talk: armed at 200 ms, let go at 250 ms, under tapThreshold from the arm.
        let press = RightOptionPress(mode: .holdToTalk)
        try press.down(at: 0)
        press.armDue(pressedAt: 0, at: HotkeyGesture.armDelay)
        #expect(press.machine.state == .connecting)
        press.up(at: HotkeyGesture.armDelay + 0.05)
        #expect(press.machine.state == .error(DictationMachine.holdHint))
        #expect(!press.mic.isOpen && press.engine.taps == 0)
    }

    @Test func aStaleArmTimerDoesNotCloseTheNextPressesMicrophone() throws {
        let press = RightOptionPress(mode: .autoStop)
        try press.down(at: 0)
        press.chord()
        try press.down(at: 0.1)                      // a new press before the first one's timer
        press.armDue(pressedAt: 0, at: HotkeyGesture.armDelay)
        #expect(press.mic.isOpen)
        press.armDue(pressedAt: 0.1, at: 0.1 + HotkeyGesture.armDelay)
        #expect(press.machine.state == .connecting && press.mic.isOpen)
    }

    @Test func soundsOnOrOffThePressIsTheFirstSample() throws {
        // With the pre-roll, hotkey-down → first sample is the input's start-up, whatever the cue; the cue (played
        // at the arm) is zeroed inside the recording instead.
        var latency: [Bool: TimeInterval] = [:]
        for soundsOn in [false, true] {
            let press = RightOptionPress(mode: .autoStop)
            let pressed = press.clock.now()
            try press.down(at: 0)
            press.engine.deliver(seconds: 0.2)
            press.clock.advance(HotkeyGesture.armDelay)
            press.armDue(pressedAt: 0, at: HotkeyGesture.armDelay)
            if soundsOn { press.mic.excludeCue(at: press.clock.now(), length: SoundTiming.muteWindow(cueDuration: DictationMicTests.chirpCue)) }
            press.engine.deliver(seconds: 0.4)
            latency[soundsOn] = try #require(press.mic.openedAt) - pressed
            #expect(press.sent.muted.contains(true) == soundsOn)
        }
        #expect(latency[false] == latency[true])
        #expect(abs(try #require(latency[true]) - DictationMicTests.engineStart) < 1e-9)
    }
}
