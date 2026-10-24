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
```

**One emulator at a time across the entire host. Queue; do not parallelise.**
The wrapper acquires `/tmp/chirp-emulator.lock` before building or booting,
records its shell PID and worktree, waits up to 30 minutes (override
`CHIRP_E2E_LOCK_TIMEOUT` in seconds), recovers a dead owner, and releases on exit.
Other emulator scripts must use the same lease; see `reference.md`.

The wrapper builds debug, syncs the server environment, reserves a free even
console port and its adjacent adb port, launches `chirp-fold` **read-only**, waits
for boot, and traps exit to stop only its own emulator PID. Never reuse or kill
another instance. Each server check refuses an occupied **7899**, uses temporary
HOME and its own token, and terminates its own server. Never use 7821.
`CHIRP_MODEL_DIR` can select an already downloaded Parakeet model directory.
Debug build generates a disposable TLS certificate with
`android/scripts/make-emulator-tls.sh`; the server uses its key and the APK
trusts its certificate for `https://10.0.2.2:7899` only in debug.

| Script under `android/scripts/` | Coverage / invocation |
| --- | --- |
| `e2e-all.sh`, `e2e-all.py` | One-command lifecycle and pass/fail table; `--only dictation cleanup notes history stop device` selects checks |
| `emulator-check.py` / `emulator-dictation-check.py` | Real verified pairing, native IME tap/hold, composing partial/final, typing and light/dark; device-side listening/Ripple screenshots |
| `emulator-check.py --cleanup-only --tls …` | Managed clean-up, Polishing, cleaned final, Use raw, frame metrics |
| `emulator-check.py --notes-check --tls …` / `emulator-notes-check.py`, `emulator-library-check.py` | Notes segments/structure, voice edit, screen-off, pause/resume/stop; list/search/rename/delete/undo/Recently Deleted/restore/continue; kept AAC replay, Share, Scratchpad |
| `emulator-check.py --history-check --tls …` / `emulator-history-check.py` | History opt-in, encrypted storage, raw/clean reinsertion, cover/inner UI, opt-out |
| `emulator-check.py --stop-check --tls …` / `emulator-stop-check.py` | Immediate/partial/polishing/double stop, hide/focus/unbind, crash checks; deliberately delayed ready fixture |
| `emulator-check.py --device-check --tls …` / `emulator-device-check.py` | Fresh onboarding, floating mic tap/hold, real TalkBack, font 200%, actual folded/open states; individual device results retained |
| `emulator-smoke.sh` / `emulator-smoke.py` | Separate release acceptance: onboarding, scanner, typing, unpaired recovery; builds/installs release, not needed to exercise real-server debug |
| `emulator-fold-layout.py` | Keyboard geometry across cover/inner and rotations; run with probe installed |
| `emulator-talkback.py` | Enable TalkBack, accessible mic click/long-click/cancel and restore previous services |
| `build-ui-probe.sh`, `UiHierarchy.java` | Shell-only all-window UiAutomator probe; never packaged into the app |

Evidence is printed at startup (`/tmp/chirp-android-e2e.*` by default); set
`CHIRP_E2E_OUTPUT` to retain it elsewhere. Each check gets a directory with a
`run.log` and screenshots; `results.json` is the machine-readable table.
Do not commit run logs, tokens, generated keys, pairing links, or XML containing
credentials. Read [reference.md](reference.md) for targeted UI checks, safe
evidence collection, and recovery from emulator/harness failures.
