import AVFoundation
import Foundation

/// The start/stop sound packs. Four are synthesised by `scripts/make-sounds.swift` and shipped as WAV files in the
/// app's Resources/Sounds; `system` is the stock Tink/Pop; `custom` is the user's own files.
public enum SoundPack: String, CaseIterable, Sendable {
    case chirp, soft, glass, click, system, custom

    /// What a fresh install plays when sounds are switched on.
    public static let `default`: SoundPack = .chirp
    /// The packs that need no setup, in menu order.
    public static let builtIn: [SoundPack] = [.chirp, .soft, .glass, .click, .system]

    public static func resolve(id: String?) -> SoundPack { id.flatMap(SoundPack.init(rawValue:)) ?? .default }

    public var title: String {
        switch self {
        case .chirp: "Chirp"
        case .soft: "Soft"
        case .glass: "Glass"
        case .click: "Click"
        case .system: "System"
        case .custom: "Custom…"
        }
    }

    public var detail: String {
        switch self {
        case .chirp: "A soft songbird: rises to start, falls to stop."
        case .soft: "Marimba-like notes: up a fifth to start, down to stop."
        case .glass: "Bright, airy taps with a short shimmer."
        case .click: "Minimal, subtle ticks."
        case .system: "The stock macOS Tink and Pop."
        case .custom: "Your own audio files."
        }
    }

    /// The bundled file's name without extension (`chirp-start`), for the packs that ship one.
    public func resourceName(for cue: SoundCue) -> String? {
        switch self {
        case .chirp, .soft, .glass, .click: "\(rawValue)-\(cue == .start ? "start" : "stop")"
        case .system, .custom: nil
        }
    }

    /// Gain applied on top of the volume. The generated packs are already normalised (peaks ≤ −12 dBFS, one loudness);
    /// the stock sounds are louder, so they are trimmed to peak below −12 dBFS and sit near the packs' level.
    /// Measured with `swift scripts/make-sounds.swift --system`.
    public func levelTrim(for cue: SoundCue) -> Double {
        switch (self, cue) {
        case (.system, .start): 0.55   // Tink peaks at −8.8 dBFS → −13.7
        case (.system, .stop): 0.85    // Pop peaks at −11.1 dBFS → −12.5
        default: 1
        }
    }
}

/// A user-chosen file, copied into Application Support. The original can move or disappear.
public struct CustomSound: Codable, Equatable, Sendable {
    /// The copy's name inside the sounds folder.
    public var fileName: String
    /// What the user picked, for display.
    public var displayName: String
    public var duration: TimeInterval

    public init(fileName: String, displayName: String, duration: TimeInterval) {
        self.fileName = fileName
        self.displayName = displayName
        self.duration = duration
    }
}

/// The recording-safety rules and the volume curve, as pure functions.
public enum SoundTiming {
    /// The start cue must be over before the microphone opens, or the mic would record it.
    public static let startLimit: TimeInterval = 0.3
    public static let startMargin: TimeInterval = 0.02
    /// The stop cue plays after capture has stopped, so only a sanity cap applies.
    public static let stopLimit: TimeInterval = 1.5
    /// The fade over the end of a cue that is cut short.
    public static let trimFade: TimeInterval = 0.04
    /// A short fade at the end of any custom file, so a hard stop never clicks.
    public static let endFade: TimeInterval = 0.01

    public static let defaultVolume = 0.6
    public static let longStartWarning = "Long start sounds are trimmed to 0.3 s so they aren't recorded."

    /// After the cue's end, how much more dictation audio is zeroed: the speaker's and the input's latency.
    public static let muteMargin: TimeInterval = 0.04

    /// How long the microphone waits after the start cue begins: its length plus a margin, never more than 300 ms.
    /// Live Notes still waits; dictation opens the microphone at once and zeroes `muteWindow` instead.
    public static func micDelay(cueDuration: TimeInterval) -> TimeInterval {
        min(max(cueDuration, 0) + startMargin, startLimit)
    }

    /// How much dictation audio from the start cue's first sample is zeroed, so the cue is never transcribed: what
    /// plays of it (at most 300 ms) plus `muteMargin`.
    public static func muteWindow(cueDuration: TimeInterval) -> TimeInterval {
        min(max(cueDuration, 0), startLimit) + muteMargin
    }

    /// How much of a file plays: all of it, except a start cue over 300 ms or a stop cue over 1.5 s.
    public static func playLength(_ cue: SoundCue, duration: TimeInterval) -> TimeInterval {
        min(max(duration, 0), cue == .start ? startLimit : stopLimit)
    }

    public static func isTrimmed(_ cue: SoundCue, duration: TimeInterval) -> Bool {
        duration > playLength(cue, duration: duration) + 0.0005
    }

    /// The fade over the last part of what plays. Built-in cues carry their own fade, unless they are cut short.
    public static func fadeOut(_ cue: SoundCue, duration: TimeInterval, custom: Bool) -> TimeInterval {
        let length = playLength(cue, duration: duration)
        if isTrimmed(cue, duration: duration) { return min(trimFade, length / 2) }
        return custom ? min(endFade, length / 2) : 0
    }

    /// The slider (0…1) to a linear gain: a gentle curve, so the low end has some range. 1 is the file's own level.
    public static func gain(volume: Double) -> Double {
        pow(min(max(volume, 0), 1), 1.5)
    }

    public static func percent(volume: Double) -> Int { Int((min(max(volume, 0), 1) * 100).rounded()) }

    /// "0.42 s" for the Settings rows.
    public static func durationText(_ seconds: TimeInterval) -> String {
        seconds < 10 ? String(format: "%.2f s", seconds) : String(format: "%.1f s", seconds)
    }
}

// MARK: files

/// The file operations the custom-sound import needs, so tests can inject a fake.
public protocol SoundFileSystem: Sendable {
    func fileExists(at url: URL) -> Bool
    func fileSize(at url: URL) -> Int?
    func createDirectory(at url: URL) throws
    /// Copies `source` to `destination`, replacing what is there.
    func copyItem(at source: URL, to destination: URL) throws
    func removeItem(at url: URL) throws
    /// The length of an audio file; throws when it cannot be decoded.
    func audioDuration(at url: URL) throws -> TimeInterval
}

public struct DiskSoundFileSystem: SoundFileSystem {
    public init() {}

    public func fileExists(at url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    public func fileSize(at url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
    }
    public func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    public func copyItem(at source: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.copyItem(at: source, to: destination)
    }
    public func removeItem(at url: URL) throws { try FileManager.default.removeItem(at: url) }
    public func audioDuration(at url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        return rate > 0 ? Double(file.length) / rate : 0
    }
}

/// Imports the user's own sound files into `~/Library/Application Support/Chirp/Sounds/`.
public struct CustomSoundStore: Sendable {
    public enum ImportError: Error, Equatable, LocalizedError {
        case missing, unreadable, tooBig, copyFailed(String)

        public var errorDescription: String? {
            switch self {
            case .missing: "The file is gone."
            case .unreadable: "That file isn't audio Chirp can play (use aiff, wav, caf, m4a or mp3)."
            case .tooBig: "That file is too big for a start or stop sound."
            case .copyFailed(let why): "Couldn't copy the file: \(why)"
            }
        }
    }

    /// A start or stop sound is a blip, not a track.
    public static let maxBytes = 25 * 1024 * 1024

    public let directory: URL
    private let fs: any SoundFileSystem
    private let makeID: @Sendable () -> String

    public init(directory: URL = CustomSoundStore.defaultDirectory, fs: any SoundFileSystem = DiskSoundFileSystem(),
                makeID: @escaping @Sendable () -> String = { String(UUID().uuidString.prefix(8)).lowercased() }) {
        self.directory = directory
        self.fs = fs
        self.makeID = makeID
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Chirp/Sounds", isDirectory: true)
    }

    public func url(for sound: CustomSound) -> URL { directory.appendingPathComponent(sound.fileName) }

    /// Copies `source` in as the sound for `cue` and removes the one it replaces. The copy is checked, so a file that
    /// fails to decode leaves nothing behind.
    public func importFile(from source: URL, cue: SoundCue, replacing old: CustomSound? = nil) throws -> CustomSound {
        guard fs.fileExists(at: source) else { throw ImportError.missing }
        if let size = fs.fileSize(at: source), size > Self.maxBytes { throw ImportError.tooBig }
        guard let sourceDuration = try? fs.audioDuration(at: source), sourceDuration > 0 else { throw ImportError.unreadable }

        let ext = Self.cleanExtension(source.pathExtension)
        let name = "custom-\(cue == .start ? "start" : "stop")-\(makeID()).\(ext)"
        let destination = directory.appendingPathComponent(name)
        do {
            try fs.createDirectory(at: directory)
            try fs.copyItem(at: source, to: destination)
        } catch {
            throw ImportError.copyFailed(error.localizedDescription)
        }
        guard let duration = try? fs.audioDuration(at: destination), duration > 0 else {
            try? fs.removeItem(at: destination)
            throw ImportError.unreadable
        }
        if let old, old.fileName != name { remove(old) }
        return CustomSound(fileName: name, displayName: source.lastPathComponent, duration: duration)
    }

    public func remove(_ sound: CustomSound?) {
        guard let sound else { return }
        try? fs.removeItem(at: url(for: sound))
    }

    /// Lower-case letters and digits only (the name ends up on disk); "audio" when nothing usable is left.
    static func cleanExtension(_ ext: String) -> String {
        let clean = ext.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return clean.isEmpty ? "audio" : String(clean.prefix(5))
    }
}

// MARK: resolving

/// A cue ready to play: which file, how much of it, how loud, and how long the microphone has to wait.
public struct ResolvedCue: Equatable, Sendable {
    public var cue: SoundCue
    public var url: URL
    public var duration: TimeInterval
    public var playLength: TimeInterval
    public var fadeOut: TimeInterval
    /// The pack's own gain (see `SoundPack.levelTrim`).
    public var trim: Double
    public var isCustom: Bool

    /// How long the mic waits after this cue starts (zero for the stop cue, which plays after capture ends).
    public var micDelay: TimeInterval { cue == .start ? SoundTiming.micDelay(cueDuration: playLength) : 0 }
    /// How much dictation audio from this cue's start is zeroed (zero for the stop cue).
    public var muteWindow: TimeInterval { cue == .start ? SoundTiming.muteWindow(cueDuration: playLength) : 0 }
    public var isTrimmed: Bool { SoundTiming.isTrimmed(cue, duration: duration) }
}

/// Finds the file for a cue. A missing or unreadable file falls back: custom → the default pack → the stock system
/// sounds → silence, so dictation never loses its cues to a missing resource.
public struct SoundLibrary: Sendable {
    public static let systemDirectory = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)

    private let fs: any SoundFileSystem
    private let bundled: URL?
    private let store: CustomSoundStore
    private let system: URL

    /// `bundled` is Contents/Resources/Sounds (nil outside an app bundle).
    public init(bundled: URL?, store: CustomSoundStore, fs: any SoundFileSystem = DiskSoundFileSystem(),
                system: URL = SoundLibrary.systemDirectory) {
        self.bundled = bundled
        self.store = store
        self.fs = fs
        self.system = system
    }

    public func resolve(_ cue: SoundCue, pack: SoundPack, custom: CustomSound?) -> ResolvedCue? {
        if pack == .custom, let custom, let r = make(cue, url: store.url(for: custom), pack: .custom, isCustom: true) { return r }
        let builtIn: SoundPack = pack == .custom ? .default : pack
        if let name = builtIn.resourceName(for: cue), let bundled,
           let r = make(cue, url: bundled.appendingPathComponent("\(name).wav"), pack: builtIn, isCustom: false) { return r }
        return make(cue, url: system.appendingPathComponent("\(cue.systemSoundName).aiff"), pack: .system, isCustom: false)
    }

    private func make(_ cue: SoundCue, url: URL, pack: SoundPack, isCustom: Bool) -> ResolvedCue? {
        guard fs.fileExists(at: url), let duration = try? fs.audioDuration(at: url), duration > 0 else { return nil }
        return ResolvedCue(cue: cue, url: url, duration: duration, playLength: SoundTiming.playLength(cue, duration: duration),
                           fadeOut: SoundTiming.fadeOut(cue, duration: duration, custom: isCustom),
                           trim: pack.levelTrim(for: cue), isCustom: isCustom)
    }
}
