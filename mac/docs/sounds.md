# Chirp's sounds

Chirp can play a short cue when dictation starts and another when capture stops (Settings → Dictation, under Sounds). They are off by default; **Chirp** is the pack used when you switch them on.

## Packs

All built-in cues are synthesised by [`scripts/make-sounds.swift`](../scripts/make-sounds.swift) (no samples, no third-party code, so no licensing questions), written to `Assets/Sounds/*.wav` as 44.1 kHz mono 16-bit PCM and committed. `scripts/bundle.sh` copies them to `Contents/Resources/Sounds`. If a file is missing the app falls back to the stock system sounds.

| Pack | Start | Stop | Character |
|---|---|---|---|
| **Chirp** (default) | 120 ms, sweep 2.2 → 3.4 kHz, vibrato 32 Hz ±2.5 % | 135 ms, sweep 3.0 → 2.0 kHz, vibrato 26 Hz ±1.5 % | A soft songbird. Fundamental + 0.12 × 2nd + 0.04 × 3rd harmonic; 14/18 ms raised-cosine attack, exponential decay (τ 60/70 ms), 30 ms release. |
| **Soft** | 200 ms, G5 then D6 65 ms later (up a fifth) | 230 ms, D6 then G5 70 ms later (down a fifth) | Marimba/kalimba-like. Partials ×1 / ×4 / ×9.9 at gains 1 / 0.28 / 0.07, exponential decays 75 / 30 / 12 ms; 2 ms attack, 25 ms release. |
| **Glass** | 210 ms, tap at A6 (1760 Hz) | 250 ms, tap at E6 (1318.5 Hz) | Bright, airy. Glass-bowl partials ×1 / 2.32 / 4.25 / 6.63, each doubled by a +0.35 % detuned twin (slow beating) with an 11 Hz tremolo on the tail, plus a 1.5 ms high-passed noise tap. |
| **Click** | 60 ms, damped 2.4 kHz tick | 60 ms, damped 1.4 kHz tick | Minimal. Sine (τ 8/10 ms) + low body (800/600 Hz, τ 14/16 ms) + 0.8 ms noise. |
| **System** | the stock `Tink` | the stock `Pop` | Trimmed (×0.55, ×0.85) so they peak below −12 dBFS. |

### Levels

Every cue is scaled to one loudness, measured as the loudest 30 ms of the A-weighted signal (the Click pack is set 3 dB lower, since a tick is more salient than its energy says). The whole set is then lowered together until the peakiest cue peaks at −12.5 dBFS, so every peak is ≤ −12 dBFS:

```
name           dur_ms  peak_dBFS  bytes
chirp-start     120.0     -18.27  10628
chirp-stop      135.0     -18.51  11952
soft-start      200.0     -13.98  17684
soft-stop       230.0     -15.00  20330
glass-start     210.0     -14.59  18566
glass-stop      250.0     -14.86  22094
click-start      60.0     -12.60   5336
click-stop       60.0     -12.50   5336
```

Every cue starts and ends on an exact zero sample, with raised-cosine fades, so there is no click at either end. Each file is under 30 KB.

### Checking without ears

* `swift scripts/make-sounds.swift --report` prints duration, peak, loudness and the first/last samples; `--sheet FILE.png` draws every cue's waveform and spectrogram ([`sounds-spectrograms.png`](sounds-spectrograms.png) is the committed one); `--system` measures Tink and Pop for the System pack's trim.
* `scripts/check-sounds.sh` regenerates into a temporary folder and compares with the committed files byte for byte.
* `SoundTests.swift` runs the generator and checks, on the committed files: format, size, duration, peak, exact-zero ends and fades, equal loudness (within 4.5 dB, start ≈ stop within 1 dB), that the chirp's zero-crossing rate rises for start and falls for stop, that Soft's start is G5 → D6 and its stop D6 → G5, and that the committed files equal the generator's output.

## Custom sounds

**Custom…** lets you pick any audio file (aiff, wav, caf, m4a, mp3) for the start and the stop cue separately. Chirp copies it to `~/Library/Application Support/Chirp/Sounds/`, so moving or deleting the original does not break it, and shows its name and length. A cue you have not chosen a file for plays the Chirp pack's. Files over 25 MB or that Chirp cannot decode are refused with the reason shown in Settings.

## Recording safety

The start cue must never reach the transcript, or the USB mic would record it. Dictation does not wait for it: the microphone opens as the dictation starts and the cue plays at the same moment, so sounds on or off the first sample is captured at the same time. What the microphone hears from the cue's start for its length plus 40 ms (`SoundTiming.muteWindow`; 160 ms for the Chirp pack, at most 340 ms) is zeroed in the audio sent to the server, so the cue is not transcribed, and speech inside that window is lost with it. The silence and auto-stop detectors ignore the zeroed audio. Live Notes still opens its microphone `min(cue length + 20 ms, 300 ms)` after the cue starts. A start cue longer than 300 ms (a long custom file, or Tink at 614 ms) plays only its first 300 ms, with a 40 ms fade, and Settings says so ("Long start sounds are trimmed to 0.3 s so they aren't recorded."). The stop cue plays after capture has stopped, so its length is not restricted, only capped at 1.5 s (with a fade).

## Playback and volume

Each cue is an `AVAudioPlayer`, loaded and prepared ahead of time, so there is no decode or disk wait. It plays through the default output and does not duck or pause other audio. The volume slider is 0–100 % (default 60 %); the gain is `volume^1.5` (60 % → 0.46, i.e. about −6.7 dB), and 0 % is silent. Previews (▶ Start and ▶ Stop in Settings, and letting go of the volume slider) play at the same volume.
