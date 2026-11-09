import Foundation

/// Same pause boundaries and ten-minute ceiling as iOS/App/RollingDictation.swift.
public struct RollingDictationSegmenter: Sendable {
    public static let maxTotal: TimeInterval = 600
    public static let maxSegment: TimeInterval = 90
    private var elapsed: TimeInterval = 0
    private var quiet: TimeInterval = 0
    public init() {}
    public mutating func feed(rms: Float, duration: TimeInterval) -> Bool {
        elapsed += duration
        quiet = rms < 0.015 ? quiet + duration : 0
        if elapsed + 1e-6 >= Self.maxSegment { return true }
        guard elapsed + 1e-6 >= 45 else { return false }
        return quiet + 1e-6 >= (elapsed + 1e-6 >= 70 ? 0.3 : 0.6)
    }
}

/// Only the two trailing commands understood by the phones; partials and Use raw remain verbatim.
public enum SpokenCommands {
    public static func apply(_ text: String, enabled: Bool) -> String {
        guard enabled else { return text }
        for (phrase, breaks) in [("new paragraph", "\n\n"), ("new line", "\n")] {
            guard let range = text.range(of: phrase, options: [.backwards, .caseInsensitive]),
                  text[range.upperBound...].allSatisfy({ $0.isWhitespace || ".,!?…".contains($0) }),
                  range.lowerBound == text.startIndex || text[text.index(before: range.lowerBound)].isWhitespace else { continue }
            var head = String(text[..<range.lowerBound])
            while head.last?.isWhitespace == true { head.removeLast() }
            return head + breaks
        }
        return text
    }
}

/// One insertion transaction across ordered sockets. The microphone never closes at a segment boundary.
/// All mutable state is protected by `lock`, including the audio-thread handover. A cancelled transaction
/// cannot publish a final, even when an old socket delivers late. Each StreamSession bounds its audio queue.
public final class RollingDictationSession: @unchecked Sendable {
    public let events: AsyncStream<StreamEvent>
    private let output: AsyncStream<StreamEvent>.Continuation
    private let lock = NSLock()
    private let makeStream: @Sendable () -> StreamSession
    private let correctionTimeout: TimeInterval
    private let commands: Bool
    /// The whole dictation's ceiling in seconds of audio; nil ("Keep listening until I stop") rolls segments forever.
    private let maxTotal: TimeInterval?
    private var segments: [Segment] = []
    private var segmenter = RollingDictationSegmenter()
    private var totalBytes = 0
    private var stopped = false
    private var closed = false
    private var announcedPolishing = false

    private final class Segment: @unchecked Sendable {
        let stream: StreamSession
        let offset: TimeInterval
        let opening: Task<Void, Never>
        var finalizer: Task<Void, Never>?
        var task: Task<Void, Never>?
        var deadline: Task<Void, Never>?
        var partial = ""
        var raw: String?
        var words: [WordTiming]?
        var final: FinalResult?
        var finishing = false
        init(_ stream: StreamSession, offset: TimeInterval) {
            self.offset = offset
            self.stream = stream
            opening = Task { await stream.open() }
        }
    }

    public init(correctionTimeout: TimeInterval, commands: Bool = false,
                maxTotal: TimeInterval? = RollingDictationSegmenter.maxTotal,
                makeStream: @escaping @Sendable () -> StreamSession) {
        self.correctionTimeout = correctionTimeout
        self.commands = commands
        self.maxTotal = maxTotal
        self.makeStream = makeStream
        (events, output) = AsyncStream.makeStream(of: StreamEvent.self)
    }

    public func open() async {
        lock.withLock {
            guard !closed, segments.isEmpty else { return }
            appendSegment()
        }
    }

    /// Called synchronously from capture. Split even an oversized input frame at the hard boundary.
    public func sendAudio(_ data: Data) {
        lock.withLock {
            guard !closed, !stopped else { return }
            if segments.isEmpty { appendSegment() }
            let ceiling = maxTotal.map { Int($0 * PCMConverter.sampleRate) * 2 } ?? .max
            // Normal capture frames are 50 ms. Limit chunks here too so a delayed callback cannot overshoot a cap.
            var offset = 0
            while offset + 1 < data.count, totalBytes < ceiling {
                let count = min(1_600, data.count - offset, ceiling - totalBytes) / 2 * 2
                // PCMConverter prefixes can retain nonzero Data indices after pending.removeFirst().
                let start = data.index(data.startIndex, offsetBy: offset)
                let frame = data.subdata(in: start..<data.index(start, offsetBy: count))
                segments.last!.stream.sendAudio(frame)
                totalBytes += count
                offset += count
                let cut = segmenter.feed(rms: Level(pcm16: frame).rms, duration: Double(count / 2) / PCMConverter.sampleRate)
                if cut, totalBytes < ceiling {
                    finish(segments.count - 1)
                    segmenter = RollingDictationSegmenter()
                    appendSegment()
                }
            }
            if totalBytes >= ceiling {
                stopped = true
                finish(segments.count - 1)
                publish()
            }
        }
    }

    public func stop() async {
        lock.withLock {
            guard !closed, !stopped else { return }
            if segments.isEmpty { appendSegment() }
            stopped = true
            finish(segments.count - 1)
            publish()
        }
    }

    public func cancel() async { await end(cancel: true) }
    public func close() async { await end(cancel: false) }

    private func end(cancel: Bool) async {
        let old: [Segment] = lock.withLock {
            closed = true
            let old = segments
            for segment in old { segment.deadline?.cancel(); segment.task?.cancel(); segment.finalizer?.cancel() }
            segments.removeAll()
            output.finish()
            return old
        }
        await withTaskGroup(of: Void.self) { group in
            for segment in old {
                group.addTask {
                    await segment.opening.value
                    cancel ? await segment.stream.cancel() : await segment.stream.close()
                }
            }
        }
    }

    // All helpers below run under lock. No lock spans an await.
    private func appendSegment() {
        let index = segments.count
        let segment = Segment(makeStream(), offset: Double(totalBytes / 2) / PCMConverter.sampleRate)
        segments.append(segment)
        segment.task = Task { [weak self, stream = segment.stream, opening = segment.opening] in
            await opening.value
            for await event in stream.events {
                guard !Task.isCancelled else { return }
                self?.receive(event, at: index)
            }
        }
    }

    private func finish(_ index: Int) {
        let segment = segments[index]
        guard !segment.finishing else { return }
        segment.finishing = true
        segment.finalizer = Task { [stream = segment.stream, opening = segment.opening] in
            await opening.value
            guard !Task.isCancelled else { return }
            await stream.stop()
        }
        deadline(index, seconds: 25)
    }

    private func deadline(_ index: Int, seconds: TimeInterval) {
        let segment = segments[index]
        segment.deadline?.cancel()
        segment.deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.receive(.closed(reason: "Timed out waiting for the transcript"), at: index)
        }
    }

    private func receive(_ event: StreamEvent, at index: Int) {
        lock.withLock {
            guard !closed, segments.indices.contains(index) else { return }
            let segment = segments[index]
            guard segment.final == nil else { return }
            switch event {
            case .message(.ready):
                if index == 0 { output.yield(event) }
            case .message(.partial(_, let text, _, let words)):
                segment.words = words
                segment.partial = text
                if !announcedPolishing {
                    let parts = segments.map { $0.final?.raw ?? $0.raw ?? $0.partial }
                    if segments.count == 1 { output.yield(event) }
                    else {
                        let timed = segments.allSatisfy { ($0.final?.raw ?? $0.raw ?? $0.partial).isEmpty || ($0.final?.words ?? $0.words) != nil }
                        let words = timed ? segments.flatMap { segment in
                            (segment.final?.words ?? segment.words ?? []).map {
                                WordTiming(text: $0.text, start: $0.start + segment.offset,
                                           end: $0.end + segment.offset, stable: $0.stable)
                            }
                        } : nil
                        output.yield(.message(.partial(seq: 0, text: Self.join(parts), stable: "", words: words)))
                    }
                }
            case .message(.correcting(_, let raw, _, let words)):
                segment.words = words
                segment.raw = raw
                deadline(index, seconds: correctionTimeout)
                publish()
            case .message(.final(let final)):
                segment.final = final
                segment.deadline?.cancel()
                Task { await segment.stream.close() }
                publish()
            case .message(.error), .closed:
                if segment.finishing {
                    let heard = segment.raw ?? segment.partial
                    segment.final = FinalResult(text: heard, correctionError: "segment")
                    segment.deadline?.cancel()
                    Task { await segment.stream.close() }
                    publish()
                } else { output.yield(event) }
            case .message(.unknown): break
            }
        }
    }

    private func publish() {
        guard stopped, !closed else { return }
        if segments.allSatisfy({ $0.final != nil }) {
            let finals = segments.compactMap(\.final)
            let text = Self.join(finals.map { SpokenCommands.apply($0.text.trimmingCharacters(in: .whitespacesAndNewlines), enabled: commands) })
            let raw = Self.join(finals.map { $0.raw.trimmingCharacters(in: .whitespacesAndNewlines) })
            let result = FinalResult(text: text, raw: raw, corrected: finals.contains(where: \.corrected),
                                     correctionError: finals.compactMap(\.correctionError).first,
                                     timings: finals.count == 1 ? finals.first?.timings : nil,
                                     words: finals.count == 1 && !commands ? finals.first?.words : nil)
            output.yield(.message(.final(result)))
            closed = true
            output.finish()
        } else if !announcedPolishing, segments.allSatisfy({ $0.raw != nil || $0.final != nil }) {
            announcedPolishing = true
            output.yield(.message(.correcting(seq: 0, raw: Self.join(segments.map { $0.final?.raw ?? $0.raw ?? "" }),
                                              profile: "", words: segments.count == 1 ? segments.first?.words : nil)))
        }
    }

    /// Preserve spoken line breaks at a boundary; otherwise separate adjacent nonempty segments with one space.
    public static func join(_ parts: [String]) -> String {
        parts.reduce("") { previous, next in
            let space = previous.last.map { !$0.isWhitespace } == true && next.first.map { !$0.isWhitespace } == true
            return previous + (space ? " " : "") + next
        }
    }
}
