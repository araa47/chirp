---
name: chirp-android-e2e
description: Recreate and run Chirp Android end-to-end checks against a disposable real server. Use for "test android", "run the emulator", "e2e on android", or "check notes on android" in this repository.
---

# Chirp Android E2E

Run from the repository root on macOS. Read `docs/TESTING.md` for the full local
checks and physical-device acceptance boundaries. This sweep uses synthetic
speech through the real capture/transport/MLX server, not a fake transcript.

```bash
source ~/.local/share/chirp-android/env.sh
android/scripts/e2e-all.sh
# Optional focused retry, still on a fresh owned AVD:
android/scripts/e2e-all.sh --only notes
# Speaker labels alone (needs the speaker model; another run holds 7899 → CHIRP_E2E_PORT=7898):
CHIRP_SPEAKER_MODEL=/path/to/voxceleb_resnet34_LM.onnx android/scripts/e2e-all.sh --only speakers
```

**One emulator at a time across the entire host. Queue; do not parallelise.**
The wrapper acquires `/tmp/chirp-emulator.lock` before building or booting,
records its shell PID and worktree, waits up to 30 minutes (override
`CHIRP_E2E_LOCK_TIMEOUT` in seconds), recovers a dead owner, and releases on exit.
Other emulator scripts must use the same lease; see `reference.md`.

The wrapper builds debug, syncs the server environment, reserves a free even
console port and its adjacent adb port, launches `chirp-fold` **read-only**, waits
for boot, and traps exit to stop only its own emulator PID. Never reuse or kill
another instance. Each server check refuses an occupied **7899** (or `CHIRP_E2E_PORT`:
when another run on the host holds 7899, pick a free port such as 7898; never 7821), uses temporary
HOME and its own token, and terminates its own server. Never use 7821.
`CHIRP_MODEL_DIR` can select an already downloaded Parakeet model directory.
Debug build generates a disposable TLS certificate with
`android/scripts/make-emulator-tls.sh`; the server uses its key and the APK
trusts its certificate for `https://10.0.2.2` (any port) only in debug.

| Script under `android/scripts/` | Coverage / invocation |
| --- | --- |
| `e2e-all.sh`, `e2e-all.py` | One-command lifecycle and pass/fail table; `--only dictation cleanup notes speakers history learn stop device bubble quickdictate visual wallpaper keepkb release` selects checks |
| `emulator-check.py --quickdictate-check --tls …` | Dictate tile, sensitive clipboard, Speak result/cancel/error, Share, Notes tile and a **real launcher widget** (pinned through the probe's *Pin widget* button, tapped, resized to one and four cells, light/dark/200% font); no Accessibility service |
| `e2e-all.sh --only quickdictate release` | The entry-point matrix, release smoke and entry-point TalkBack checks in the same owned AVD |
| `emulator-check.py` / `emulator-dictation-check.py` | Real verified pairing, native IME tap/hold, composing partial/final and light/dark; device-side listening/Ripple screenshots |
| `emulator-check.py --cleanup-only --tls …` | Managed clean-up, Polishing, cleaned final, Use raw, frame metrics |
| `UiHierarchy.java await-action click\|observe <label> <ms>` | Tight-polling probe for a transient action (Use raw's 5 s window); prints `PRESENT`/`CLICKED`/`EXPIRED` and whether the editor held fixture fillers, so an expired action is told apart from unchanged clean-up |
| `emulator-check.py --notes-check --tls …` / `emulator-notes-check.py`, `emulator-library-check.py` | Notes segments/structure, voice edit, screen-off, pause/resume/stop; list/search/rename/delete/undo/Recently Deleted/restore/continue; kept AAC replay, Share, Scratchpad |
| `e2e-all.sh --only speakers` / `emulator-speakers-check.py` | Default-on labels, automatic model download and inline status (no consent), exactly two synthetic speakers, post-Stop naming sheet, rename and labelled kept-audio replay, naming → saved voice → recognition in a second note, Update voice and Not X; requires `CHIRP_SPEAKER_MODEL`, which also adds this phase to the default sweep |
| `emulator-check.py --history-check --tls …` / `emulator-history-check.py` | History default-on, encrypted storage, raw/clean reinsertion, cover/inner UI, opt-out |
| `e2e-all.sh --only learn` / `emulator-learn-check.py` | Dictate, correct twice in the native debug editor, see Learned active, dictate again; real server confirms receipt/application; sealed storage and light/dark Learned screenshots |
| `emulator-check.py --stop-check --tls …` / `emulator-stop-check.py` | Immediate/partial/polishing/double stop, hide/focus/unbind, crash checks; deliberately delayed ready fixture |
| `emulator-check.py --device-check --tls …` / `emulator-device-check.py` | Fresh onboarding, real TalkBack, font 200%, actual folded/open states; individual device results retained |
| `emulator-check.py --bubble-check --tls …` / `emulator-bubble-check.py` | First-class floating mic: tap/hold, real final insertion, copy fallback, drag/snap, cancellation and keyboard retention |
| `emulator-smoke.sh` / `emulator-smoke.py` | Separate release acceptance: onboarding, scanner, typing, unpaired recovery; builds/installs release, not needed to exercise real-server debug |
| `e2e-all.sh --only wallpaper` / `emulator-wallpaper-check.py` | Match wallpaper on five real system wallpapers (set by the debug-only `WallpaperProbeActivity`), light and dark: Notes, note, History, Settings, Feedback & look, Quick dictate; not in the default sweep. Then `uv run --with pillow python3 android/scripts/text-contrast-report.py <evidence>/wallpaper` lists low-contrast text |
| `emulator-fold-layout.py` | Keyboard geometry across cover/inner and rotations; run with probe installed |
| `emulator-talkback.py` | Enable TalkBack, accessible mic click, ⋯ options and cancel and restore previous services |
| `build-ui-probe.sh`, `UiHierarchy.java` | Shell-only all-window UiAutomator probe; never packaged into the app |

Evidence is printed at startup (`/tmp/chirp-android-e2e.*` by default); set
`CHIRP_E2E_OUTPUT` to retain it elsewhere. Each check gets a directory with a
`run.log` and screenshots; `results.json` is the machine-readable table.
Do not commit run logs, tokens, generated keys, pairing links, or XML containing
credentials. Read [reference.md](reference.md) for targeted UI checks, safe
evidence collection, and recovery from emulator/harness failures.
