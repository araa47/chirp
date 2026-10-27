import AVFoundation
import AppKit
import ChirpCore

/// The start/stop cues. Each is an `AVAudioPlayer` that is loaded and `prepareToPlay()`-ed ahead of time, so the first
/// sound after a hotkey press has no decode or disk wait. AVAudioPlayer plays through the default output and does not
/// duck or pause other apps' audio.
///
/// Recording safety lives in `SoundTiming`: the start cue plays at most 300 ms (with a fade when it is cut).
/// Dictation never waits for it: `DictationController` opens the microphone at once and zeroes `startCueWindow()` of
/// what it sends. Live Notes opens its microphone only after `startDelay()` has passed.
@MainActor
enum Sounds {
    private struct Loaded {
        let resolved: ResolvedCue
        let player: AVAudioPlayer
    }

    private static let store = CustomSoundStore()
    private static let library = SoundLibrary(bundled: Bundle.main.resourceURL?.appendingPathComponent("Sounds", isDirectory: true),
                                              store: store)
    private static var loaded: [SoundCue: (key: String, value: Loaded)] = [:]
    /// Bumped on every play, so a fade scheduled for an earlier play does not touch a later one.
    private static var playToken = 0

    static var customStore: CustomSoundStore { store }

    /// Loads both cues for the current pack. Call at launch and after a pack or custom file changes.
    static func prepare() {
        for cue in [SoundCue.start, .stop] { _ = load(cue) }
    }

    /// How long the microphone must wait after the start cue begins (zero when sounds are off).
    static func startDelay() -> TimeInterval {
        guard settings.soundsEnabled, settings.soundVolume > 0 else { return 0 }
        return load(.start)?.resolved.micDelay ?? 0
    }

    /// How much dictation audio from the start cue is zeroed (zero when sounds are off).
    static func startCueWindow() -> TimeInterval {
        guard settings.soundsEnabled, settings.soundVolume > 0 else { return 0 }
        return load(.start)?.resolved.muteWindow ?? 0
    }

    /// Plays the current pack's cue. The caller decides whether sounds are on: dictation checks the switch, while
    /// Settings and the menu play it anyway to audition a pack.
    static func play(_ cue: SoundCue) {
        guard let loaded = load(cue) else { return }
        start(loaded)
    }

    private static func start(_ loaded: Loaded) {
        let gain = SoundTiming.gain(volume: settings.soundVolume) * loaded.resolved.trim
        guard gain > 0 else { return }
        let player = loaded.player
        playToken += 1
        let token = playToken
        player.stop()   // a quick second tap restarts the cue instead of being swallowed
        player.currentTime = 0
        player.volume = Float(min(gain, 1))
        player.play()
        let r = loaded.resolved
        guard r.fadeOut > 0 else { return }
        // Fade over the end of what plays (a trimmed or custom cue), then stop.
        let fade = r.fadeOut, length = r.playLength
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, length - fade)) {
            MainActor.assumeIsolated {
                guard token == playToken else { return }
                player.setVolume(0, fadeDuration: fade)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + length + 0.01) {
            MainActor.assumeIsolated { if token == playToken { player.stop() } }
        }
    }

    /// The prepared player for `cue` under the current settings, rebuilt when the pack or custom file changed.
    private static func load(_ cue: SoundCue) -> Loaded? {
        let pack = settings.soundPack
        let custom = settings.customSound(for: cue)
        let key = "\(pack.rawValue)|\(custom?.fileName ?? "-")"
        if let hit = loaded[cue], hit.key == key { return hit.value }
        loaded[cue] = nil
        // A custom file that exists but cannot be played falls back to the default pack.
        for candidate in [(pack, custom), (SoundPack.default, nil)] {
            guard let resolved = library.resolve(cue, pack: candidate.0, custom: candidate.1),
                  let player = try? AVAudioPlayer(contentsOf: resolved.url) else { continue }
            player.prepareToPlay()
            let value = Loaded(resolved: resolved, player: player)
            loaded[cue] = (key, value)
            return value
        }
        return nil
    }
}
