import Accelerate
import AVFoundation
import Foundation

/// Converts capture buffers to 16 kHz mono PCM16LE and cuts them into fixed-size frames.
public final class PCMConverter {
    public static let sampleRate: Double = 16_000
    /// 50 ms at 16 kHz mono PCM16 (the protocol allows 20–100 ms).
    public static let frameBytes = 1_600

    private let converter: AVAudioConverter
    private let outFormat: AVAudioFormat
    private var pending = Data()

    public init?(from input: AVAudioFormat) {
        guard input.sampleRate > 0, input.channelCount > 0,
              let out = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.sampleRate,
                                      channels: 1, interleaved: true),
              let c = AVAudioConverter(from: input, to: out) else { return nil }
        outFormat = out
        converter = c
    }

    /// Converts one buffer and returns every complete frame; the remainder waits for the next call.
    /// Frames are Data slices and may retain a nonzero startIndex.
    public func frames(from buffer: AVAudioPCMBuffer) -> [Data] {
        append(convert(buffer))
    }

    /// Drains the converter's resampling delay (~60 ms that would otherwise clip the end of the utterance)
    /// and returns everything still pending, which may be shorter or a bit longer than one frame. Call once, at stop.
    public func flush() -> Data? {
        if let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 4096) {
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in status.pointee = .endOfStream; return nil }
            if error == nil, out.frameLength > 0, let ptr = out.int16ChannelData?[0] {
                pending.append(Data(bytes: ptr, count: Int(out.frameLength) * 2))
            }
        }
        defer { pending.removeAll() }
        return pending.isEmpty ? nil : pending
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> Data {
        let ratio = Self.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return Data() }
        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let input = buffer
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, let ptr = out.int16ChannelData?[0] else { return Data() }
        return Data(bytes: ptr, count: Int(out.frameLength) * 2)
    }

    private func append(_ data: Data) -> [Data] {
        pending.append(data)
        var frames: [Data] = []
        while pending.count >= Self.frameBytes {
            frames.append(pending.prefix(Self.frameBytes))
            pending.removeFirst(Self.frameBytes)
        }
        return frames
    }
}

public struct Level: Sendable, Equatable {
    public var peak: Float   // 0...1
    public var rms: Float    // 0...1
    public static let zero = Level(peak: 0, rms: 0)

    public init(peak: Float, rms: Float) {
        self.peak = peak
        self.rms = rms
    }

    /// Peak/RMS of little-endian PCM16 mono. vDSP in Double: every square and sum of PCM16 samples is exact there, so
    /// this matches a per-sample loop bit for bit, without that loop's cost in debug builds (it runs for every frame).
    public init(pcm16 data: Data) {
        let n = data.count / 2
        guard n > 0 else { self = .zero; return }
        var peak = 0.0, sum = 0.0
        data.withUnsafeBytes { raw in
            withUnsafeTemporaryAllocation(of: Double.self, capacity: n) { d in
                vDSP_vflt16D(raw.baseAddress!.assumingMemoryBound(to: Int16.self), 1, d.baseAddress!, 1, vDSP_Length(n))
                vDSP_maxmgvD(d.baseAddress!, 1, &peak, vDSP_Length(n))
                vDSP_svesqD(d.baseAddress!, 1, &sum, vDSP_Length(n))
            }
        }
        self.peak = Float(peak) / 32768
        self.rms = Float((sum / Double(n)).squareRoot() / 32768)
    }
}

/// Fires once when the input has been digitally silent (peak exactly 0) for `window` seconds,
/// which is what a muted device or a denied microphone permission produces.
public struct SilenceGuard: Sendable {
    public let window: TimeInterval
    /// "Keep listening until I stop": once the input has carried any signal it is a working microphone, so later
    /// digital silence (muted, or gated to zero during a pause) is a pause and never fires.
    public let onlyBeforeSignal: Bool
    private var silentSince: TimeInterval?
    private var heardSignal = false
    private var fired = false

    public init(window: TimeInterval = 1.5, onlyBeforeSignal: Bool = false) {
        self.window = window
        self.onlyBeforeSignal = onlyBeforeSignal
    }

    public mutating func feed(_ level: Level, at time: TimeInterval) -> Bool {
        guard !fired else { return false }
        if level.peak > 0 { silentSince = nil; heardSignal = true; return false }
        if onlyBeforeSignal, heardSignal { return false }
        let since = silentSince ?? time
        silentSince = since
        if time - since >= window { fired = true; return true }
        return false
    }
}
