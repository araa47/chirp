# Host-wide queue

Run only one Chirp emulator at a time across all worktrees. `e2e-all.sh` queues
with `emulator-lock.py`; do not bypass its lease by launching an AVD separately.
For a targeted manual session, hold the same lease in the shell that owns the
emulator and release it from that shell's EXIT trap:

```bash
python3 android/scripts/emulator-lock.py acquire --pid "$$" --worktree "$PWD"
# Install your own emulator cleanup trap too; stop only the PID you launch.
trap 'python3 android/scripts/emulator-lock.py release --pid "$$"' EXIT
```

The owner metadata is local runtime data. Never commit it. A live owner is
never evicted; a dead PID is reclaimed. A timeout is a queued-run failure, not
permission to launch a parallel instance. Heavy unrelated builds can still
starve QEMU; keep resource settings modest and record host contention.

# Targeted checks and evidence

Run targeted commands only with `ANDROID_SERIAL=emulator-<owned-even-port>` and
the toolchain sourced. `build-ui-probe.sh` installs a shell-only probe. Stock
`uiautomator dump` omits the IME window on API 37 and can disrupt accessibility
services; use the preserving all-window probe instead:

```bash
android/scripts/build-ui-probe.sh
adb -s "$ANDROID_SERIAL" shell CLASSPATH=/data/local/tmp/chirp-ui-probe.jar \
  app_process / dev.chirp.smoke.UiHierarchy
adb -s "$ANDROID_SERIAL" pull /sdcard/chirp-windows.xml "$CHIRP_E2E_OUTPUT/ui.xml"
adb -s "$ANDROID_SERIAL" exec-out screencap -p > "$CHIRP_E2E_OUTPUT/screen.png"
```

Capture only after pairing has closed: its screen can contain the token.
Hierarchies and screenshots contain synthetic notes, so keep them in private
run evidence. Inspect crash presence/counts in memory with
`adb -s "$ANDROID_SERIAL" logcat -b crash -d -s AndroidRuntime:E`; do not print
unfiltered logcat or transcript text. Never capture live user audio. Server
observations in `emulator-stop-server.py` contain frame counts/statuses only.

Notes library acceptance after recording: Back to notes → saved row; search
for a synthetic word and a missing word; open the result → title / Rename →
Save title; continue recording → pause/resume/stop; swipe row left → Undo;
delete again → Library options → Recently Deleted → Restore. Reopen transcript
and Play segment 1; require Stop playback then natural completion. Check the
row persists after app relaunch. This supplements rolling capture assertions.

Floating mic: enable `dev.chirp.android/.ChirpAccessibilityService` in the
owned emulator's accessibility settings. Focus an editable non-password field;
find `Chirp microphone: tap to dictate, hold to talk`; tap, observe partials,
stop and verify the text landed; repeat with hold/release; Cancel discards.
Restore previous enabled services afterwards.

Fold/unfold while recording: use the AVD's supported states
(`adb … shell cmd device_state print-states`), select folded/open states and
restore `cmd device_state state reset`; check recording and text survive.
`emulator-fold-layout.py` additionally tests viewport sizes/rotation. A viewport
resize alone does not certify physical hinge transitions.

TalkBack: run `emulator-talkback.py` with probe installed. Use actual
accessibility click/long-click actions; coordinate taps behave differently
with touch exploration. For 200% font, save `settings get system font_scale`,
set it to `2.0`, relaunch Notes/Scratchpad/Settings and verify every primary
action has a visible usable hit rectangle; capture screenshots and restore the
original value (delete it if previously null).

# Pitfalls

- **Invisible orphan:** `adb devices` is insufficient. QEMU can own console or
  adb ports while absent from the list. Inspect listening ports and emulator
  process argv read-only. Reserve both ports and use a different pair; never
  kill the orphan without proof it belongs to this run.
- **QEMU thread hang:** a busy host can hang a 4-core / large-memory AVD. Use
  `-cores 2 -memory 2048` (the wrapper defaults), then 1 core if necessary. Stop
  only your recorded PID and relaunch on a fresh pair. Keep emulator.log.
- **Ready stress:** the stop matrix deliberately delays ready, while ordinary
  dictation/Notes checks use zero artificial delay. Do not apply the six-second
  Notes stress delay to dictation: its smaller pre-ready buffer overflows.
- **Persisted AVD install:** read-only clones inherit installed app data and may
  have another signing key. Uninstall Chirp only on your own disposable clone
  before installing debug. `install -r` alone can fail signature validation.
- **Modern Notes-first shell:** `section=try` opens the library, not an editor.
  Choose Dictate for Scratchpad, then focus its text field for IME checks.
  Prefer accessibility labels/test tags over coordinates. Settings, onboarding,
  Scratchpad and keyboard-strip copy/layout may change; revisit those selectors
  when UI restyling lands.
