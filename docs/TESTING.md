# Testing Chirp

## 1. Automated checks (no mic, phone, permissions or network)

Run from the repo root:

```sh
(cd server && uv sync --locked && uv run ruff check . && uv run pytest -q && uv run pytest -q -m model)
(cd mac && ./scripts/test.sh)
(source ~/.local/share/chirp-android/env.sh && cd android && ./gradlew lint testDebugUnitTest assembleDebug)
./scripts/e2e-local.sh
python3 site/build.py   # website: links, anchors, no external requests, no host names/tokens/paths
```

`scripts/e2e-local.sh` starts a real `chirp-server` on 127.0.0.1:7899 with a throwaway HOME, so it uses its own token. It then streams a synthetic `say` sentence through three clients:

- the server's own simulator
- the Mac app's `--selftest`
- the Android IME transport, run on the JVM

It then checks that a wrong token is refused, that the server log contains no transcript, and that no unexpected files were written. It prints the work directory and leaves it for you to delete.

For iPhone/iPad, `ios/scripts/simulator-e2e.sh SIMULATOR-UUID` does the same with the iOS app on a simulator: throwaway server on 127.0.0.1:7899, a local clean-up stand-in, the full UI scheme including the live-server suite and the real Chirp Keyboard. It then checks that the server log contains no transcript. See [ios/README.md](../ios/README.md#develop-and-test).

Live Notes has two more checks of its own:

- **The harness tests** (`NotesSessionTests`, `NotesFaultTests` and `NotesSoakTests` in `mac/scripts/test.sh`) run whole sessions through the real `NotesSession`, `StreamSession` and editor against scripted sockets and a scripted notes endpoint, on a fake clock. They cover the fault matrix (socket drops, outages, structure errors, Organize races, sleep/wake, crash recovery) and a 2-hour soak with budgets (see [bench.md](bench.md#live-notes-session-soak-66)). Rows that describe behaviour not built yet are disabled tests that name their issue.
- **`mac/scripts/notes-selftest.sh`** starts a throwaway `chirp-server` (temporary HOME, port 7899, never 7821 or the running app) and plays a 25 s `say` recording through `ChirpMac --notes-selftest`: once clean (it must hear "budget" and "Thursday") and once with `--fault drop@14`. It prints the segments, status changes, notes and transcript, and checks that the server log has no spoken words.

Latency figures from these runs are observations on a shared, loaded host, not targets. Measured engine numbers are in [bench.md](bench.md).

### Desktop Linux

The Tauri client has native Rust session/hotkey/audio tests and frontend state tests.
Its Notes tests cover private durable storage, exclusive access, crash recovery,
search/trash, edit-version conflicts and draining Stop across stream boundaries.
Frontend tests cover typing during automatic saves, stale Organize responses,
late events after changing notes and delete/Undo.
See [desktop/README.md](../desktop/README.md#build-and-test) for native and Docker
commands. The Linux desktop workflow builds a Debian package on Ubuntu; it does
not need microphone permissions, a model download, or a running server.

### Desktop Windows

`desktop-windows.yml` runs the same frontend and Rust checks on `windows-latest`,
then `desktop/scripts/windows-smoke.py` on the runner's desktop: SendInput types
Unicode, multiline and tab text into a real Tk text field, a long text is pasted
and the clipboard restored, US and German layouts pick Right Alt and Right Ctrl,
and the keyboard hook installs. It then builds the per-user NSIS installer. Real
key presses and real apps are the operator's Windows checklist in [#214](https://github.com/araa47/chirp/issues/214).

### CI

GitHub Actions (`.github/workflows/`) runs the Linux and Windows checks on every pull request and on pushes to `main`. Each workflow is path-filtered, so a PR only runs the components it touches, and superseded or finished-with runs are cancelled (see [Stale runs](#stale-runs)). The macOS workflows (`mac.yml`, `ios.yml`, the Intel job of `server.yml`) cost 10x Linux minutes and only run when started by hand; the Mac and iOS gates run on a Mac with `scripts/local-gate.sh` instead (see [Local gate](#local-gate)). No secrets, tailnet access or model downloads are involved.

| Workflow | Runner | Runs | Notes |
|---|---|---|---|
| `server.yml` | ubuntu | `uv sync --locked`, `ruff check`, `ruff format --check`, `pytest -q` | MLX packages are darwin-only, so Linux installs the portable set. `-m model` tests (real cached models) are deselected by `addopts`; run them on the Mac. The `intel-mac` job runs by hand only. |
| `desktop-linux.yml` | ubuntu | frontend checks, Rust formatting/Clippy/tests, Xvfb insertion/hotkeys, private-bus portal lifecycle, headless Sway insertion/fallback, Tauri Debian package | The shared desktop client; no speech model download or live server. |
| `desktop-windows.yml` | windows | frontend checks, Rust formatting/Clippy/tests, SendInput/clipboard/layout smoke in a real Tk window, NSIS installer | The Windows platform module; no speech model download or live server. |
| `android.yml` | ubuntu, JDK 21, Android SDK 37.2 | `./gradlew lint testDebugUnitTest assembleDebug assembleRelease` | The release APK is unsigned (no keystore secret). Lint and test reports upload on failure. |
| `mac.yml` | macos | `mac/scripts/ci-test.sh` (wraps `test.sh`) | **By hand only** (`gh workflow run mac.yml --ref <branch>`); the automatic gate is `local/mac-full` from the local gate. |
| `ios.yml` | macos, newest installed Xcode | `ios/scripts/ci-test.sh`: `check-sources.sh`, `Shared/scripts/test.sh`, the keyboard policy package tests, then `ios/scripts/simulator.sh test` (build and unit tests of the app with its keyboard and widgets) on one iPhone simulator | **By hand only**; the automatic gate is `local/ios` from the local gate, which covers `ios/**` and the `mac` package sources the app links (`ChirpCore`, `ChirpSpeakers`, `Package.*`). Ad-hoc simulator signing, no team or secrets. |
| `pr-closed-cancel.yml` | ubuntu | `gh api` calls only | When a PR is merged or closed, cancels that PR's queued and running runs of every workflow above. No checkout, no secrets, token limited to `actions: write`. |

The hosted runners only have Xcode 26 (Swift 6.2/6.3). On them, several stream, recorder and Notes suites abort the shared test process (`freed pointer was not the last allocation`) although every test passes alone and on Swift 6.4, so `ci-test.sh` runs those one test per process, together with the Live Notes soak (`NotesSoakTests`; `test.sh` with no arguments also runs it after the rest, so its 2-minute limit covers the soak alone). It skips `GeneratedSoundTests` (needs `swift make-sounds.swift`) and `SnapshotTests` (the runner's fonts render PNGs over the committed-size cap). Both run in `mac/scripts/test.sh` on the Mac.

iOS CI runs the portable checks and the app's unit tests only. The UI schemes and the live-server end to end (`ios/scripts/simulator-e2e.sh`) stay on the Mac: they need `say`, ffmpeg, the cached model and a real keyboard setup, which the runners do not have, and headless simulator UI runs are not reliable enough to gate a PR. Run `ios/scripts/simulator.sh ui` or `simulator-e2e.sh` before merging UI changes.

#### Stale runs

Runners are shared, so a run nobody needs any more should not keep one busy:

- **Newer push to the same PR:** every workflow has `concurrency: group: <workflow>-<PR number or ref>`, `cancel-in-progress: true`. The group holds one workflow of one PR (or of one ref), so a PR's push cancels only its own older run, never another PR's, never `main`'s, and never another workflow's.
- **Newer push to `main`:** same group, keyed by `refs/heads/main`. The superseded run is cancelled; the newer commit contains the older one, so its run covers it. A commit in the middle of a burst of pushes therefore has no hosted result of its own.
- **Merged or closed PR:** `concurrency` cannot see a PR closing, so `pr-closed-cancel.yml` (`pull_request: types: [closed]`) lists the unfinished `pull_request` runs of the PR's head branch and cancels them. It matches by branch because GitHub leaves a run's `pull_requests` list empty in some cases, stands down if another open PR uses the same head branch or if the PR was reopened in the meantime, and skips fork PRs (their token is read-only). The push to `main` after a merge runs the same checks anyway.
- **Pages:** `pages.yml` sets concurrency per job. Builds cancel like the others; the deploy job is alone in the `pages` group with `cancel-in-progress: false`, so a deploy that has started always finishes and the newest queued one runs after it.

#### Local gate

`scripts/local-gate.sh` runs, on a Mac, the gates for the platforms a branch touches and records the result on GitHub for the exact commit it tested:

```sh
scripts/local-gate.sh             # gates derived from the diff against origin/main
scripts/local-gate.sh --dry-run   # only print the commit and the gates
scripts/local-gate.sh mac ios     # explicit gates
```

| Gate (status context) | Runs when the diff touches | Command (from the repo root) |
|---|---|---|
| `local/mac-full` | `mac/**` except `mac/README.md`, `mac/docs/**` | `cd mac && CHIRP_MAC_SERIAL=1 ./scripts/test.sh` (serial, no-argument full suite including the soak) |
| `local/ios` | `ios/**` except the READMEs, `mac/Package.*`, `mac/Sources/ChirpCore/**`, `mac/Sources/ChirpSpeakers/**` | `cd ios && ./scripts/ci-test.sh` (portable checks, then app unit tests on a simulator) |
| `local/android` | `android/**` | `cd android && ./gradlew lint testDebugUnitTest assembleDebug --rerun-tasks` |
| `local/server` | `server/**` | `uv sync --locked`, `ruff check`, `ruff format --check`, `pytest -q` |

Each gate gets a `pending` status when it starts and `success`, `failure` or `error` (could not run) when it ends, with a short description (test counts, host, minutes). A run of all derived gates also sets `local/gate`, which is `success` only if every gate passed; require that one context if branch protection is ever turned on. A single PR comment lists the gates, counts, host and Xcode version, and the log tail of any failed gate.

- **Why statuses and not a committed results file:** a file in the commit cannot name that commit's SHA, and committing it changes the SHA, so it would always describe its parent. A status is attached to the SHA from outside, so it is exact, and any new commit shows no `local/*` status until the gates are run again. The trade-off: a status lives on GitHub, not in the repository history, and anyone with write access can post one (the same trust as the Mac the author runs the gate on). A results file would be reviewable in the diff and survive a repository move, but only as a claim about an earlier tree.
- **Preconditions:** a clean tree and a pushed `HEAD`. The script refuses a dirty tree, and does not post a result if `HEAD` or a tracked file changes while the gate runs.
- **Shared Mac:** heavy gates take the host's leases (`/tmp/chirp-mac-full.lock`, `/tmp/chirp-ios-sim.lock`, `/tmp/chirp-gradle-full.lock`) and wait for them, and build into `/tmp/chirp-local-gate` (not under `~/Documents`, TCC). Logs are in `/tmp/chirp-local-gate/<sha>/`. Android needs the environment from `android/scripts/setup-toolchain.sh` (`CHIRP_ANDROID_ENV` overrides `~/.local/share/chirp-android/env.sh`).
- **Not covered:** the UI schemes, `ios/scripts/simulator-e2e.sh`, the emulator sweep and `scripts/e2e-local.sh` stay manual (see the sections below); so does the desktop client, which keeps its hosted Linux and Windows workflows.
- **Options:** `--base REF`, `--pr N` (default: the open PR of the branch), `--no-post` (run only), `--prefix local/` (the context prefix).

`scripts/e2e-local.sh` and the operator steps below need a real Mac, `say` and (for the app) permissions, so they stay local.

### Android emulator sweep

On macOS with the Android toolchain and cached speech/clean-up models installed:

```sh
source ~/.local/share/chirp-android/env.sh
android/scripts/e2e-all.sh
# A focused retry still owns a fresh read-only emulator:
android/scripts/e2e-all.sh --only notes
```

`e2e-all.sh` runs every emulator check in one command: dictation, clean-up,
learning from edits (two corrections, activation and real-server application, with light/dark Learned captures),
Notes (including the library: search, rename, delete and Undo, Recently Deleted,
Continue and kept-audio replay), history, the stop matrix, device checks
(onboarding, TalkBack, 200% font including the inner-screen rail, folded and open), the floating mic bubble
(with a deterministic Use raw replacement and expiry),
Quick Dictate, a real launcher widget (placed, tapped, resized, light/dark/200% font) and Share entry points, the keep-keyboard onboarding fork,
release smoke with TalkBack, and a cover/inner, light/dark main-screen capture matrix.
The visual phase captures evidence for human review; it does not certify visual quality.
`--only <check…>` picks some of them. It builds and installs the debug app, boots
its own read-only `chirp-fold` AVD on a free even port, and uses a real
throwaway server on 7899 (`CHIRP_E2E_PORT=7898` picks another when a parallel run holds
7899; the debug certificate and network config are bound to `10.0.2.2`, not a port) with a
temporary HOME and debug-only TLS. It prints a
pass/fail table and a private evidence folder (`results.json`, a `run.log` and
screenshots per check). Never use the server on 7821.

**The emulator lock.** Only one Chirp emulator runs on a host at a time, across
all worktrees. `e2e-all.sh` takes the host-wide lease
(`android/scripts/emulator-lock.py`, `/tmp/chirp-emulator.lock`) before it builds
or boots, records its PID and worktree, waits up to 30 minutes for another run
to finish (`CHIRP_E2E_LOCK_TIMEOUT`, in seconds), takes over from an owner that
has died, and releases the lease on exit. Other emulator scripts must take the
same lease. Queue runs; never start them in parallel.

### Testing skills

Agent workflows for these checks live under [`.claude/skills/`](../.claude/skills/):

| Skill | Use it for |
|---|---|
| [`chirp-android-e2e`](../.claude/skills/chirp-android-e2e/SKILL.md) | "test android", "run the emulator", "check notes on android": the `e2e-all.sh` sweep, the script coverage table, targeted UI checks, safe evidence collection and recovery from emulator or harness failures ([reference.md](../.claude/skills/chirp-android-e2e/reference.md)). |

The iOS skill is `.claude/skills/chirp-ios-e2e/SKILL.md`; `ios/scripts/e2e-all.sh` runs the whole iPhone and iPad sweep (portable checks, build, unit tests, live UI) with one command and prints a pass/fail table.

## 2. Operator steps

Each step needs the operator's hands or approval. Do them in order.

### Mac server

1. **Start the server** (foreground): `cd server && uv sync --locked && uv run chirp-server --root-path /chirp`.
   - It binds to 127.0.0.1:7821 only.
   - It reuses the cached model at `~/.koi/voice-models/parakeet-mlx`.
   - On first run it creates `~/.config/chirp/token` (mode 0600).
   - Optional, keeps the model warm across reboots: `uv run chirp-server service install`. Remove it with `uv run chirp-server service uninstall`.
2. **Publish on the tailnet only.** This adds one path to your existing Serve config, and it is never Funnel.
   ```sh
   tailscale serve --bg --set-path /chirp http://127.0.0.1:7821
   tailscale serve status        # shows https://<your-mac>.<tailnet>.ts.net/chirp (tailnet only)
   ```
   Roll back with `tailscale serve --set-path /chirp off`.
   - Every route except the minimal health check, and the WebSocket, require the bearer token.

### Mac app

3. **Create the signing certificate** once: `cd mac && ./scripts/make-cert.sh`. It may ask for your login password or for keychain *Always Allow*.
4. **Build and install:** `./scripts/bundle.sh && ./scripts/install.sh && open ~/Applications/Chirp.app`.
5. **Grant permissions.** On first launch the app asks for **Microphone** and **Accessibility**; grant both in System Settings → Privacy & Security. Input Monitoring is not needed.
6. **Dictate:**
   - Focus any text field, hold Right ⌥ Option, speak, then let go: that is push-to-talk. A quick tap starts a hands-free dictation that ends on a pause or the next tap; Esc cancels. The shortcut needs Accessibility (Settings → Dictation shows ⌃⌥Space as an alternative that does not).
   - Right ⌥ must not get in the way: Left ⌥ + E still types é, Right ⌥ + a key (or a click) does not start dictation, and ⌥-shortcuts in other apps still work.
   - Check that live text appears in the HUD and the final text lands in the field.
   - Try TextEdit, Safari, Slack or VS Code (these paste), and Terminal.

### Out-of-date server

Use a throwaway server on another port, never the real one on 7821 (the app's port is Settings → Server → URL).

1. Start an older server by hand on 7899 from a checkout before this change, point Settings → Server at `http://127.0.0.1:7899`, and open Live Notes. Settings → Server, the menu's status line and the Notes banner say "out of date" with the sentence about where it started; the button is **Use Chirp's managed server instead** (the process is not a LaunchAgent).
2. Stop it, start the current server by hand on 7899: no "Out of date" anywhere.
3. `scripts/install-mac.sh --server-only` with `CHIRP_PORT=7899` while a hand-started server holds 7899 prints the pid and command and the two commands to switch, and restarts nothing.
4. On the reference Mac, with Chirp's own LaunchAgent running an old checkout, **Restart server** brings it to the current code; Settings → Server shows the restart result.

### Mac Live Notes

Run on the reference Mac after installing the build with `./scripts/install-mac.sh` and selecting the default correction model.

1. Press ⌃⌥N and talk for about 3 minutes through a mock meeting with a decision, two to-dos and a "we will **not** …" sentence. Check the headings, the `☐` tasks, the Decision line, and that the negation is kept.
2. Leave it running for at least 10 minutes with intermittent silence. Check that the menu-bar bird pulses throughout, that segments keep landing in the transcript (each ≤ 45 s, none lost at a cut), filler words (um, uh, like, yeah) are gone from the transcript when clean-up is on, and that frozen sections do not change.
3. Press the dictation hotkey while Notes records → the "Notes is recording — stop it to dictate" toast and no dictation. Stop Notes, then dictate normally.
4. Stop. The note is already in the library sidebar (there is no Save step): open the Share menu → **Export Markdown…** to the Desktop and open the `.md` file (notes, `---`, then the `## Transcript` appendix). Record a little more, then quit Chirp mid-recording → no Save/Discard alert; relaunch → the note is in the library marked **Recovered** with what was said so far.
5. Touch a marker file, run a session and stop it, then `find ~/Library -newer <marker> -path '*Chirp*'` and look in `~/Library/Saved Application State`: the only files are under `Application Support/Chirp/Notes/<uuid>/` (`note.json`, plus `index.json` beside it; `ls -l` shows `-rw-------`, the folders `drwx------`; no audio unless **Keep audio with notes** is on) and nothing is in Saved Application State. Delete the note → it moves to Recently Deleted; **Delete Now** or Empty… removes its folder. Check `log show --predicate 'subsystem == "dev.chirp.mac"' --last 15m` and the server log: no spoken words.
6. Set the server's correction mode to off and restart it → Notes shows the explanation banner above the editor, the editor stays editable, and Copy/Export Markdown give your typed notes plus the transcript.
7. ⌃⌥N, then talk for about 5 minutes through a mock meeting that revisits "budget" twice, with two to-dos, a decision and a "we will **not** …" sentence. While it records, type your own bullet above the AI tail and fix a word inside the tail. Check: the caret never jumps; the tail you edited loses its tint; new AI notes appear after it.
8. Wait for an auto-reorganize (about 3 minutes, after 15 s without typing). Check: the budget sections merge; the to-dos and the negation survive; the **Organized · Show changes · Undo** chip appears, and **Undo** restores the previous text in one step.
9. Press Organize, then type immediately → "Notes changed while organizing — try again", and your typing is intact. With a "Not structured — see transcript" section in the notes (left alone), press Organize again → the status counts `Organizing notes… 1/2`, the section is replaced by structured notes, and one ⌘Z brings it back.
10. Toggle Preview → the same content, read-only. Click a `[ ]` in the editor → it toggles, and ⌘Z untoggles it.
11. Turn Auto-reorganize off → for 5 minutes no automatic reorganize, while the button still works. Turn "Structure notes" off → the editor stays editable and the Hearing strip still shows speech.
12. Stop, then Export Markdown… → the `.md` has your edits, the reorganized notes and the transcript appendix. Close and reopen the note from the library → the same text.
13. Privacy recheck as in step 5: no notes on disk except the library folder under `Application Support/Chirp/Notes/`, no text in `log show` (the journal logs `notes journal bytes=… ms=…` only) or the server log.
14. Crash recovery: record a minute, type a line, wait 3 s, then `kill -9` the Chirp process and relaunch it. The note is in the library marked **Recovered**, without a prompt; open it → the notes, typed line and transcript are back, the note is stopped, and **Continue recording** carries the timestamps on from a dated boundary. Export Markdown… with **Keep saving changes to this file** checked, type, wait 3 s and check the `.md` has the change; rename the file, type again → the footer says “Stopped saving — file moved”, and the library note keeps saving. Right-click in the editor → Writing Tools is absent or disabled.
15. Dock: open Notes (menu → Open Notes, or ⌃⌥⇧N) → Chirp appears in the Dock and ⌘-Tab, with a Window menu listing Chirp Notes. Close the window (nothing recorded, nothing unsaved) → the Dock icon goes and the menu-bar bird stays. Start ⌃⌥N, close the window → the Dock icon stays and a click brings it back; stop, close → gone. Move and resize the window, quit and relaunch → it reopens there. Dock menu: Open Notes, New Notes, Start/Stop Recording, and Pause Recording while it records. ⌘W closes the Notes and Settings windows. Settings → General → Always show Chirp in the Dock keeps the icon with no window.
16. Shortcuts: Settings → Shortcuts → Open Notes → Record Shortcut…, try ⌃⌥N and your dictation hotkey (both refused, with the reason), then ⌃⌥O; the new one works and the menu shows it. Reset restores ⌃⌥⇧N. Pressing it never starts recording. Record ⌃⌥M for Live Notes → ⌃⌥M starts and stops Notes from another app, the menu and the empty Notes window show ⌃⌥M, and ⌃⌥N does nothing; Reset brings ⌃⌥N back. Record ⌃⌥U for Use raw → after a cleaned dictation the menu row shows ⌃⌥U and it puts the raw words back.
17. Dictation hotkey in Notes: click into the Notes window and press the dictation hotkey → Notes records (no HUD); press again → it pauses, and once more → it resumes (Stop is the button, ⌘⇧R or the Live Notes shortcut). Switch to another app → the hotkey dictates. The header reads "<key> to record · <key> again to pause", then "<key> to resume".
18. Two-hour soak in real time (optional, before a release): start a throwaway server as `mac/scripts/notes-selftest.sh` does, build a 2-hour `say` playlist (for example `say -f talk.txt -o talk.aiff` over a long text, then `ffmpeg -ar 16000 -ac 1`), and run `ChirpMac --notes-selftest talk.wav --url http://127.0.0.1:7899 --token-file <throwaway>/.config/chirp/token` without `--fast`. It should end with `notes-selftest: OK`, `gaps=0` on stderr, and the process's memory in Activity Monitor flat after the first minutes. Add `--fault down@600-660` to watch a one-minute outage (today Notes stops after three failed segments; #62 keeps it recording).
19. Speaker labels on by default (Mac): with the speaker model removed (Settings › Notes › Speakers › Remove, then switch **Label speakers** back on) or a fresh preferences domain, Record in Notes → text starts at once, no alert appears, and a line above the notes reads "Getting the speaker model ready (106 MB, once)… N%" with **Turn off**; when it finishes the line goes away and later speech is labelled (earlier speech stays unlabelled). Turn off in that line (or ✦ › Label speakers) cancels the download and the next Record neither downloads nor labels; switching it on again fetches the model without asking. With the network off the line says "Couldn’t download the speaker model." with **Retry** and **Turn off**, and recording carries on. `defaults write dev.chirp.mac notesSpeakerLabels -bool false` on an old install (no `speakerLabelsDefault` key) is cleared at the next launch and labels are on again.
20. Speaker fix-ups (Label speakers on, two people talking): click a **Person 2** chip → Rename "Person 2"…, type Maya, Return → every Person 2 chip says Maya, the banner offers "Also replace “Person 2” with “Maya” in the notes?"; Replace → only whole `Person 2` words change (a `Person 20` stays), and one ⌘Z in the editor puts them back. Merge Maya into Person 1 → her paragraphs relabel and the next thing she says is Person 1 too; the banner's Undo separates her again. Right-click one paragraph → This turn is ▸ New person → it becomes Person 3 and stays so after Stop. Export Markdown… → the transcript uses the names. VoiceOver on a chip reads "Speaker: Maya".
21. Saved voices: Settings → Notes → Saved voices shows the server’s library and the shared Remember voices switch. Name a speaker before 20 s; their name stays in the note and saves when enough settled speech arrives. On the first save, OK continues and Don’t remember voices disables the server-wide switch. Record another note: after 10 s a matching voice is named automatically with ✓. Not Maya restores Person N and never reapplies that voice in this note, without deleting it. Rename a saved voice from ⋯: existing notes keep their names; Forget and Forget all confirm. Switch off offers to forget existing voices and stops recognition on every device. An old server hides Remember voice and shows the update explanation. `mac/scripts/notes-selftest.sh --voices` runs the two-note flow and library actions against its own throwaway server; no app state or Keychain is used. The committed Saved voices and recognised-chip snapshots cover light and dark. Logs contain counts and codes only.
22. Hotkey registration without pressing keys: `log show --predicate 'subsystem == "dev.chirp.mac"' --info --last 5m | grep "hotkey register id=4"` shows `combo=control-option-n status=0` after launch; `hotkey register id=5` shows `combo=control-option-shift-n status=0`.

### iPhone/iPad Live Notes (device)

The simulator gates (`ios/scripts/simulator.sh test` and `ios/scripts/simulator-e2e.sh` on an iPhone and an iPad simulator) run Live Notes with synthetic sockets and with a spoken file against a throwaway server. On your own device:

1. Pair, open Live Notes (the Notes tab on iPhone and iPad), Record and talk for a few minutes. Segments land in the transcript about every 45 s or at pauses, and structured bullets appear in the notes.
2. Lock the phone and keep talking for 5+ minutes. The lock screen and Dynamic Island show "Live Notes · recording" with a running timer and Pause/Stop, and no text. Pause and Resume from the lock screen, then unlock: the notes caught up with what was said while locked.
3. Take a call (or invoke Siri) while recording → "Paused · another app or a call took the microphone"; after the call it resumes. Unplug or connect a headset mid-recording → recording continues.
4. Turn Wi-Fi off for a minute while recording → “Computer offline · keeping …”; back on → the offline segments arrive.
5. Organize, then Undo Organize; Export → Save to Files… and open the `.md` in Files.
6. Record, then force-quit Chirp from the app switcher. Reopen → the note is in the library marked **Recovered**, with no Keep/Discard prompt, and what was recorded is in it. **Continue recording** picks it up.
7. Settings → Battery: compare an hour locked with Battery saver on and off.
8. Label speakers (on by default; Settings → Notes, or a note's ⋯ menu, turns it off): with a server that has no speaker model there is no prompt: the note shows "Getting the speaker model ready (27 MB, once)…" with **Turn off**, recording starts at once, and Settings → Notes reads “Speaker model on your computer: downloading” and then “…: ready”; a failed download shows "Couldn’t download the speaker model." with **Retry**; **Turn off** keeps labels off (also after relaunch) Record two people talking: the transcript shows **Person 1** and **Person 2** capsules; tap one → **Rename…** (Maya) renames it on every turn and offers to replace the old name in the notes; **Same person as** merges, **Separate** undoes it; the notes read `Maya: …` and the export shows the names. Against an older server the switch is disabled with “Update Chirp on your computer to save voices”. Simulator: `ios/scripts/e2e-all.sh --only speakers` runs this with two `say` voices against the real server and model.

### Fold 8

7. **Enable wireless debugging and pair adb:** `adb pair IP:PAIRPORT`, then `adb connect IP:PORT`. See `android/README.md`.
8. **Install the app:**
   - Build and install: `cd android && ./scripts/make-keystore.sh && ./gradlew assembleRelease && adb install -r app/build/outputs/apk/release/app-arm64-v8a-release.apk`.
   - Or install the debug APK.
9. **Set up on the phone:** open **Chirp**. On **How you’ll dictate**, choose **Use Chirp Keyboard** and enable it (Settings → General management → Keyboard list and default; keep Samsung Keyboard on), or choose **Keep Samsung Keyboard** and turn on **Chirp floating mic** from the guided page (expect the Restricted setting step on a sideloaded install). Grant the microphone.
10. **Pair:**
    - On the computer, open Chirp → Settings → Devices → **Pair a Phone…** (it checks Tailscale Serve and shows the QR code), or run `cd server && uv run chirp-server pair --url https://<your-computer>.<tailnet>.ts.net/chirp`, which prints a secret link and a terminal QR code.
    - Tap **Scan code** on the Pair your computer page. Google Play services owns the scanner UI and camera access; Chirp needs no camera permission. The Fold 8 has Play services; the scanner module may download on first use. A valid scan is tested and saved automatically. Paste remains available if scanning is unavailable or cancelled. The real scanner still needs device acceptance.
    - Never put the link in chat, shell history or screenshots.
    - Wait for **Connected · host**, then tap **Finish**; Notes opens with the **● Computer** chip. Relaunching the app now opens Notes, not onboarding.
    - App shell: Notes · History · Settings in a bar on the cover screen and a rail on the inner screen; Back from a tab returns to Notes, then leaves. Turn Tailscale off or quit Chirp on the computer → the chip says **● Offline**, and tapping it opens Settings → Connection with **Check connection**. With history on, swipe an entry in History away and tap **Undo**: it comes back; long-press one → **Add to note**.
11. **Dictate:**
    - In Samsung Notes or a browser field, switch to Chirp with the keyboard icon and tap the mic. (Floating mic mode: tap the bubble beside the field instead; hold it to talk; drag it to the other edge.)
    - Live text appears underlined in the field, and the final text replaces it.
    - Check these cases from `android/README.md`: hold-to-talk, ✕ cancel, fold/unfold mid-utterance, hiding the keyboard, and Wi-Fi vs LTE.
    - With a Bluetooth keyboard: Ctrl+Alt+Space starts and stops, Esc cancels; with TalkBack on, one "Inserted, N words" per final and nothing while listening.
12. **Notes** (the Notes tab, or long-press the launcher icon → **Notes**):
    - Record a 5-minute mock meeting with a decision, two to-dos and a "we will **not** …" sentence. Check that notes appear under the AI tail after each segment, that the transcript has one line per segment (none longer than 45 s, nothing lost at a cut) and that the negation is kept.
    - While recording, type a line above the notes and fix a word inside them: the caret never jumps and new notes appear after your edit.
    - Turn the screen off for 2 minutes, then on: the **Chirp Notes is recording** notification stayed (no notes text in it), and the transcript kept growing. From the lock screen, **Pause** (mic indicator off, notification says paused), then **Resume**; **Stop** in the notification finishes the notes.
    - Battery saver: record, turn the screen off for 2 minutes while speaking, turn it on → the notes and transcript are current at once and the notification said **Battery saver** while off. Chirp settings → About → Diagnostics → **Notes sessions** shows a numbers-only line with many skipped updates. The full measurement is [android-device-acceptance.md §6](android-device-acceptance.md#6-notes-battery).
    - Notes keep themselves (**Keep notes on this phone** is on by default; Chirp settings → Notes): Stop, and the note is in the library with no prompt. Search for a word from the transcript; rename a note by tapping its title; swipe one away and tap **Undo**; delete it again and restore it from ⋮ → **Recently Deleted**. **Continue** on a finished note adds a `Continued` divider and keeps the clock. Turning the switch off keeps the notes; **Delete all notes** removes them. With **Keep audio with notes** on, record a minute: a segment plays from the **Transcript** sheet, the total under Notes settings grows and **Delete kept audio** returns it to zero.
    - Add the **Notes** Quick Settings tile: a tap opens Notes and starts recording, the tile shows **Recording**/**Paused**, and a second tap stops it.
    - Record a minute and type a line, wait 3 s, then `adb shell am kill dev.chirp.android` (or swipe Chirp away) and reopen Notes → the note is in the library marked **Recovered**, with the line and transcript, stopped, and **Continue** carries on the timestamps. ⋮ → **Export Markdown** to Downloads → the `.md` opens with the notes and transcript.
    - Fold and unfold: the list and the open note sit side by side on the inner screen; on the cover screen the note opens over the list and the **Transcript** chip opens a sheet, with nothing lost.
    - Edit by voice: with Notes recording, hold **Hold to edit by voice**, say "remove the first bullet", let go. The transcript has none of those words, notes keep arriving after, and **Edited · Undo** appears; **Undo** restores the text. Try "add a summary" (refused with a reason), a tap (latches; the next tap sends), **Cancel**, a selection (only those lines change) and typing while "Editing notes…" shows (a conflict, your typing intact). With the screen off, use the notification's **Command**, then **Send**: the notes are already edited when the screen is on. Outside a recording the button opens the microphone for the command only. Check `adb logcat` and the server log: lengths and outcome codes, never the words.
    - Press **Organize**, then type at once → "Notes changed while organizing — try again", typing intact. Organize again, then **Undo organize** restores the text.
    - Stop the Chirp server for 30 s mid-recording: failed segments show `⚠︎ audio not transcribed`, and three in a row stop the recording with the notes kept.
    - **Copy** and paste into a note app: title, notes, `---`, `## Transcript`. `adb shell run-as dev.chirp.android ls -R files shared_prefs` (debug build) shows only sealed `notes/*.bin` files and no plain notes text.
13. **Battery:** run `android/scripts/battery-session.sh`, which resets batterystats, runs a scripted session and dumps the results. Record the result in `docs/bench.md`.
14. **Full acceptance pass:** follow [android-device-acceptance.md](android-device-acceptance.md) (battery, Perfetto, stop matrix, session timings from Diagnostics).

## 3. Privacy checks

- **Default:** `curl -s -H "Authorization: Bearer $(cat ~/.config/chirp/token)" http://127.0.0.1:7821/v1/health` shows `"debug_retention":false`. Nothing is written under `~/Library/Application Support/Chirp/debug/`.
- **Debug mode:**
  1. Start with `uv run chirp-server --debug-retain`.
  2. Both clients must show the red **DEBUG** badge or banner, and the debug folder fills.
  3. Run `uv run chirp-server debug purge` to clear it, then restart without the flag.
- **Correction:** off by default. If enabled with a non-loopback endpoint, both clients label it "sends text to HOST". Only final text is sent, never audio.
