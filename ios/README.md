# Chirp for iPhone and iPad

A native SwiftUI app plus a dictation-first custom keyboard for iOS/iPadOS 18.
Recognition and optional clean-up run on your existing Mac speech server — the
iPhone or iPad only captures audio, streams it over your tailnet, and inserts
text. Same trust model as the Android keyboard: nothing persistent is kept by
default (the only on-device text is the encrypted transient app↔keyboard
mailbox, opt-in encrypted history and the encrypted Live Notes recovery copy
while notes are unsaved), pairing is a secret QR
shown locally on the Mac, the iOS client's pairing accepts only tailnet
`.ts.net` hosts, and the server itself binds to loopback — a public host is
never used.

This is a **personal install** target. No App Store distribution, TestFlight or
ad-hoc readiness is claimed or tested.

## Status: runs end to end on iPhone and iPad simulators; first iPad install done (2026-10-25)

The app, keyboard and widgets **build** with full Xcode, and the unit and UI
tests **pass on an iPhone and an iPad simulator**. The UI tests include a
**live run against a real local chirp-server** (throwaway HOME, port 7899,
real Parakeet model, spoken `say` audio) and the **real installed Chirp
Keyboard** dictating into Messages.

**First device install (2026-10-25):** an iPad Pro 13-inch (M4) on iPadOS 26.7.1,
free Personal Team signing, installed with `xcrun devicectl device install app`.
The app launched and paired, Chirp Keyboard turned on with Full Access, and
the keyboard's **Open Chirp to start session** button opened Chirp and armed a
session. On-device dictation quality, Live Notes and an iPhone install are
still unchecked.

| Check (2026-10-24, iOS 27.0 simulators) | Result |
|---|---|
| `ios/scripts/simulator.sh build` — iPhone 18 Pro and iPad Pro 13-inch (M5) | BUILD SUCCEEDED on both |
| `ios/scripts/simulator.sh test` — same two simulators | 20 tests in 2 suites, both |
| `CHIRP_E2E_APPEARANCE=dark ios/scripts/simulator-e2e.sh` (full UI scheme plus live server) — same two simulators | 11 tests, both: 9 pass, 2 skip with stated reasons (⌘ shortcuts need a hardware keyboard on the simulator; UI tests cannot open Spotlight); server log transcript-free |
| `swift test --package-path ios/Keyboard/Policy` | 62 tests in 9 suites |
| `ios/Shared/scripts/test.sh` | 22 tests in 6 suites |
| `ios/scripts/check-sources.sh` | passed |

Verified on both simulators, against the live server where it matters:
- pairing by pasted secret link and by deep link through iOS's "Open in Chirp?"
  prompt, and the setup checklist;
- in-app dictation with live partials, clean-up plus **Use raw**, encrypted
  history opt-in, End session, switching tabs while armed;
- rotating during dictation (portrait and both landscapes; this caught and
  fixed a crash);
- keyboard enable plus Full Access in Settings, a keyboard session, keyboard
  dictation into Messages (partials, final, End), and the secure-field
  fallback to Apple's keyboard;
- the **Live Activity on the lock screen** for an armed session (content-free
  phase only);
- the Full Keyboard Access → Commands path the hardware-keyboard help gives.

Screenshots: [docs/screenshots/ios/](../docs/screenshots/ios/) (light on iPhone and iPad, dark on iPhone).

Not verified here:
- The app's **⌘ shortcuts**: headless simulators drop synthesized hardware key
  events. `ChirpHardwareKeyboardUITests.testDictationMenuShortcuts` runs them
  when a hardware keyboard is connected to the simulator, and skips with that
  reason otherwise.
- **Toggle from Spotlight / a Full Keyboard Access key**: UI tests could not
  open Spotlight. Toggle's start, stop-and-copy and keyboard-refusal rules are
  unit tested.
- **Split view / Stage Manager windows**: UI tests cannot resize iPad windows.
- **Control Center and Action Button controls**: adding them needs the
  system's edit gallery.
- The real microphone (see Develop and test), signing/provisioning,
  background-audio survival on a device, and App Store acceptance. These remain
  operator device gates in [docs/milestones/M5-ios.md](../docs/milestones/M5-ios.md).

Earlier evidence:
[docs/review/ios-simulator.md](../docs/review/ios-simulator.md),
[docs/review/ios-keyboard.md](../docs/review/ios-keyboard.md),
[docs/review/ios-app.md](../docs/review/ios-app.md).

One server prerequisite: the server must run the updated source from this
branch, which accepts `"ios"` alongside `"mac"` and `"android"` as `client`
values. Restart `chirp-server` from this checkout before pairing iOS. The
production/launchd server on the Mac was not touched by any worker; updating it
is an operator step.

## Requirements

- A Mac running the Chirp speech server from this branch, with Tailscale on.
- iPhone and/or iPad on iOS/iPadOS 18+, on the same tailnet.
- For building and installing: a Mac with **full Xcode** and a matching iOS
  SDK/simulator runtime. The Command Line Tools alone cannot build any of this;
  `ios/scripts/toolchain.sh` exits with `BLOCKED` while CLT is selected.

## Install (operator steps)

Everything here is manual operator work on hardware you own. Agents never
operate devices, and there is intentionally **no auto-install script** — device
installation is Xcode's Run action, performed by you.

1. Verify the toolchain (run from the repo root; the script is cwd-independent):

   ```sh
   ios/scripts/toolchain.sh   # prints iOS Simulator SDK path, Xcode version, available simulators
   ```

   While the Command Line Tools are selected it exits 2 with `BLOCKED: select a
   full Xcode installation…` — install Xcode, launch it once, accept the
   license, and run `sudo xcode-select -s /Applications/Xcode.app` (or
   `xcode-select` to the correct path).

2. The Xcode project is generated deterministically and checked in as
   `ios/Chirp.xcodeproj` (generator: `ios/scripts/generate-project.py`, Python 3
   standard library only, no XcodeGen). Regenerate after moving/adding sources:

   ```sh
   python3 ios/scripts/generate-project.py
   ```

3. Choose your signing identity and identifiers. Defaults live in
   `ios/Config/Project.xcconfig`:

   | Setting | Default |
   |---|---|
   | `CHIRP_BUNDLE_ID` | `dev.chirp.ios` (keyboard `…keyboard`, widgets `…widgets`) |
   | `CHIRP_APP_GROUP` | `group.dev.chirp.ios` |
   | `CHIRP_KEYCHAIN_ACCESS_GROUP` | `$(AppIdentifierPrefix)dev.chirp.ios.shared` |
   | `DEVELOPMENT_TEAM` | empty — you must set it |

   Copy `ios/Config/Local.example.xcconfig` to the **untracked**
   `ios/Config/Local.xcconfig` (the project includes it if present) and set at
   least `DEVELOPMENT_TEAM = <your team>` (Xcode → Settings → Accounts shows
   it); the keychain group follows `CHIRP_BUNDLE_ID` automatically; change the bundle
   prefix, App Group and keychain group there too if `dev.chirp.ios` collides
   with another app on your Apple ID. Whatever you choose, the **same** team,
   App Group and keychain access group must apply to all three targets — app,
   keyboard and widgets — since they share the encrypted mailbox and Keychain.

4. Open `ios/Chirp.xcodeproj` in Xcode, sign in with your personal Apple ID
   (Settings → Accounts), and pick that team for the ChirpIOS,
   ChirpKeyboard and ChirpWidgets targets (automatic signing).

5. Pass the simulator gates on **both** an iPhone and an iPad simulator before
   installing on any hardware. Get explicit UUIDs from
   `xcrun simctl list devices available`, then for each UUID run the three
   actions separately:

   ```sh
   CHIRP_SIMULATOR_UUID='PASTE-AN-AVAILABLE-SIMULATOR-UUID-HERE'
   ios/scripts/simulator.sh build "$CHIRP_SIMULATOR_UUID"
   ios/scripts/simulator.sh test "$CHIRP_SIMULATOR_UUID"
   ios/scripts/simulator.sh ui "$CHIRP_SIMULATOR_UUID"
   ```

   The script regenerates the project and runs `xcodebuild` with simulator-only
   **ad-hoc** signing (`CODE_SIGN_IDENTITY=-`, no team or Apple ID) so the App
   Group and shared-Keychain entitlements exist and the keyboard UI test can
   reach the app; `CHIRP_SIMULATOR_SIGNING=unsigned` reproduces the old unsigned
   build. It targets that explicit available iPhone/iPad simulator UUID: `test` runs the
   `ChirpIOS` scheme unit tests, `ui` the `ChirpIOS-UI` UI tests. It never
   installs on devices. All six gates (build, unit and UI on both device
   families) must pass before the hardware steps below, which are then purely
   your choice as operator.

6. Connect the iPhone by cable, trust the computer, enable Developer Mode on the
   device (Settings → Privacy & Security → Developer Mode), select the device,
   choose the **ChirpIOS** scheme and press ⌘R (Run). Check that both embedded
   extensions got profiles with your App Group and keychain access group.

7. Repeat on the iPad: same project, same team and identifiers, select the
   iPad, Run. It is one universal app (iPhone + iPad device families).

8. **Updates (both devices):** build again and Run over the existing install;
   updating in place preserves pairing, preferences and history. Do not
   uninstall to update: removal deletes the app's container data — losing any
   saved encrypted history — and can force a re-pair, while Keychain items are
   not reliably removed on uninstall, so do not count on uninstall deleting the
   token or history key either.

Sign-in, provisioning and device trust are operator-only actions; no worker
performs Apple ID login. Free Personal Team profiles expire after **seven
days**, after which the app stops launching on device — rebuild and Run again
to re-install. App Groups (and sometimes keychain sharing) are **not guaranteed
on free accounts**: check the actual provisioning profile Xcode generates. If
the capability is missing, the app and keyboard will report that shared storage
is unavailable rather than silently degrading. TestFlight or ad-hoc
distribution needs a paid Apple Developer Program membership and matching
profiles; nothing here is validated for that path.

## Pair with your Mac

1. Connect Tailscale on the Mac and on the iPhone/iPad.
2. On the Mac, open Chirp → Settings → Devices → **Pair a Phone…**: it checks
   Tailscale, publishes the server, names this device and shows the QR. Without
   the Mac app, from `server/`, publish the pairing QR (printed locally only).
   Give this device its own pairing with `--name`, so you can revoke it on its
   own later (`chirp-server devices list`, `chirp-server devices revoke "My iPad"`).
   Without `--name` the QR carries the Mac's shared token:

   ```sh
   uv run chirp-server pair --name "My iPad" --url https://<your-mac>.<tailnet>.ts.net/chirp
   ```

3. In Chirp, open the **Pair Mac** tab → **Scan pairing QR**. Grant camera
   permission when asked; if it is denied, the scanner tells you and you can
   paste the secret link into **Secret pairing link** and tap **Test connection
   and save pairing** instead.
4. Chirp verifies the authenticated connection before saving anything: the
   **Saved pairing** section then shows "Mac pairing saved" with the Mac's
   tailnet host and recognition engine, so you can confirm you paired the
   right machine, and **This device** with the name you gave it. A device
   paired with the shared token shows how to switch to a named pairing. If the
   pairing is revoked, Chirp says "Your Mac refused this device. Pair again
   in Chirp." The token itself is stored in the iOS Keychain. **Check Mac
   connection** re-verifies later; **Forget pairing** clears the token.

Accepted links are exactly `chirp://pair?url=…&token=…` with an HTTPS
`*.ts.net` host and a simple unencoded base path such as `/chirp` (nondefault
HTTPS ports allowed). Public hosts, plain HTTP, userinfo/query/fragment and
encoded paths are rejected, and all redirects are refused. There is no
supported way to point iOS at a public server.

## Enable the keyboard

The **Dictate** tab has a **Set up Chirp Keyboard** checklist: pair your Mac,
turn on the keyboard, start a session. Each step shows a check mark when done.

1. Tap **Open Chirp in Settings** (also in the Settings tab). In Settings →
   Chirp → **Keyboards**, turn on **Chirp Keyboard** and **Allow Full Access**.
   The long way also works: Settings → General → Keyboard → Keyboards → Add
   New Keyboard → Chirp.
2. Open Chirp Keyboard once in any app (globe key). With Full Access it writes
   a content-free timestamp to the App Group, so the checklist marks the step
   done. Without Full Access it cannot, and the step stays open.

Full Access is required because the keyboard talks to the app through the
encrypted App Group mailbox — it never gives the keyboard a microphone; Apple's
sandbox denies keyboard audio access even with Full Access. Without Full Access
the keyboard keeps Space, Delete, Return and the globe (next keyboard), and
shows "Dictation needs Full Access". Secure fields and hosts that disallow
custom keyboards automatically use Apple's keyboard.

## Dictate in the app

The **Dictate** tab is the session owner. **Start keyboard session** arms the
microphone for the keyboard; **Dictate** starts an in-app utterance directly.
Status line and Live Activity show the phase: Session armed · microphone
active, Connecting…, Listening…, Polishing…, Finished · microphone still
active.

Honest microphone behavior: during an armed session the app keeps its capture
engine running so it is ready when a keyboard command arrives. Idle audio is
discarded immediately and **no audio leaves the device between utterances** —
but iOS shows the microphone indicator throughout the armed session. That is
expected; only **End session** turns the microphone off. Every surface (app,
keyboard, Live Activity) exposes End session.

Session length (Settings tab): **5 minutes (default), 15 minutes, 1 hour,
Never**. Never lasts until ended, interrupted, terminated or revoked — iOS may
still suspend the app; indefinite background execution is not guaranteed.
Interruptions (calls, Siri, route changes) and expiry end the session safely.
When dictation fails partway — the connection drops, the Mac answers with an
error, or it doesn't finish in time — Chirp **keeps what was heard**. The last
live text lands as plain text, with no clean-up, and the notice says why
(e.g. "Connection lost. Kept what was heard."). If nothing had been heard yet,
only the reason is shown. A failure during clean-up keeps the original
transcript. Connection failures leave the session armed, so you can try again
once the Mac answers. Only interruptions, expiry and End session turn the
microphone off.

Connection problems are named by cause: this device is offline, the Mac
can't be found on the tailnet, the Mac may be asleep or Chirp isn't running on
it, a secure connection failed, or the Mac refused this device (for example a
revoked device pairing; the Dictate tab offers **Pair again**). While nothing
answers, the Dictate tab shows **Mac offline** with **Check again**; a Mac that
answers but is still loading its speech model shows **Mac loading its model**
with **Check again**, not a network error.

While dictating: **Stop dictation** finalizes. After the final you get
explicit **Copy**, **Share** and — when clean-up changed the text — **Use raw**
for 5 seconds; the original transcript is expandable below.

Hardware keyboard shortcuts in the app live in a **Dictation** menu, so they work
from every tab and show in the iPad's hold-⌘ overlay and menu bar:

| Shortcut | Action |
|---|---|
| ⌘Return | Start or stop dictation (⌘Space is Spotlight on iPadOS) |
| ⌘. (or Esc while dictating) | Cancel dictation |
| ⌘⇧C | Copy result |
| ⌘⇧Z | Use raw transcript |
| ⌘⇧K | Start keyboard session |
| ⌘⇧E | End session |

The app never writes the clipboard by
itself. **Long dictation** runs past the server's
120-second limit. After 45 seconds, at the first pause (0.6 s of quiet, 0.3 s
after 70 s, and at 90 s regardless), Chirp moves the microphone to a new
utterance without dropping audio, while the earlier one finishes. The parts
land in order with a space between them. Undo and Use raw apply to the last
part, and a part that fails keeps what it heard. A dictation stops just under
10 minutes.

If the server runs with `--debug-retain`, a persistent red banner "DEBUG: Mac
keeps recordings" stays on screen in the app, keyboard and Live Activity.

## Live Notes

Long-form notes from speech: talk through a meeting, a lecture or a walk, and
Chirp keeps a transcript and turns it into Markdown notes as you go. On iPad
Live Notes has its own **Notes** tab with notes and transcript side by side; on
iPhone open it with **Live Notes** at the top of the Dictate tab (a picker
switches between Notes and Transcript). It uses the same Mac server as
dictation and needs no keyboard session — the two never hold the microphone at
the same time (end the keyboard session first, and a keyboard session cannot
start while notes record).

- **Record** opens the microphone (until a Mac is paired, **Pair Mac** beside
  it opens the Pair Mac tab). Speech goes to your Mac in rolling segments
  of at most 45 seconds (cut at pauses, ordinary `/v1/stream` utterances), and
  the live partial shows under the notes. Clean-up applies when you turned it
  on in Styles, using the Mac's notes style.
- **Structuring** runs on your Mac (`/v1/notes/structure`): finished segments
  become headings, bullets, tasks, decisions and questions. It is on when
  clean-up stays on your Mac; if your Mac's clean-up sends text elsewhere,
  Notes settings shows the destination and structuring stays off until you turn
  it on for that host. With clean-up off on the Mac, or an older server, notes
  stay a transcript. Type anywhere in the notes to add your own; while you type,
  new structure waits for you (up to 10 seconds after the last keystroke).
- **Organize** regroups the whole notes (`/v1/notes/reorganize`) and
  **Undo Organize** puts them back (asking first if you edited since).
  "Organize automatically" (Notes settings) runs it now and then on its own.
- **Transcript** lists the segments with their times; **Show raw** shows them
  before clean-up.
- **Pause** closes the microphone and finishes the current segment; **Resume**
  continues the same notes and clock. A call or Siri pauses Live Notes, and it
  resumes when iOS says recording may continue. **Stop** finishes the last
  segment and the final structuring pass; the notes stay until **New notes**
  (which asks first when they are not saved). **Record more** continues them.
- **Export** menu: **Copy**, **Share…** and **Save to Files…** — all give
  Markdown with the notes and the timed transcript. Saving counts as saved.
- If the Mac is unreachable mid-recording, recording goes on: up to 10 minutes of
  audio waits in memory and is sent when the Mac answers again.

**Locked screen and background.** Recording continues with the screen locked
or Chirp in the background (the audio background mode). A Live Activity on the
lock screen and in the Dynamic Island shows the state and the elapsed time with
**Pause/Resume** and **Stop** — never any text. With Live Activities off for
Chirp, recording still works; the lock screen just has no controls. **Battery
saver while locked** (on by default) skips all screen updates while Chirp is in
the background; recording, the Mac's structuring and the Live Activity's own
timer go on, and the notes catch up when you return. iOS may suspend Chirp
while Live Notes is paused in the background; Resume from the Live Activity or
reopen Chirp. Shortcuts actions: **Start Chirp Live Notes**, **Pause or resume
Chirp Live Notes**, **Stop Chirp Live Notes**.

**Recovery copy.** Until you save or start new notes, Chirp keeps the notes and
transcript in an AES-GCM-encrypted file (key in this device's Keychain, never
synced; folder excluded from backups and file-protected) so a crash or a
force-quit loses nothing. Next launch offers **Keep** or **Discard**. Never
audio. "Keep an encrypted recovery copy" in Notes settings turns it off, which
deletes the file and its key.

Hardware keyboard (iPad): ⌘⇧R record/stop, ⌘⇧P pause/resume.

## Dictate from any app (keyboard)

Chirp Keyboard is voice-first: keep Apple's keyboard for typing and switch to
Chirp to dictate. There is deliberately no QWERTY layout.

Layout, top to bottom:

- **Status line** — phase, a keyboard-local **elapsed timer** while this
  keyboard's own utterance is connecting/listening, and **time remaining** in
  the session (omitted for "Never"), e.g. `Listening… · 0:07 · 12:30 left`.
  Below it a detail line (collapsed in landscape iPhone) shows short,
  content-free guidance for the session's error code (unreachable → check
  Tailscale/Mac, auth → re-pair in Chirp, permission → microphone in Chirp,
  timeout, interrupted, busy, too long, storage, …).
- **One large primary button** (≥ 64 pt; full width on iPhone, capped at a
  readable width and centered on iPad) whose role follows state: *Open Chirp
  to start session* → *Start dictation* → *Stop dictation* → disabled
  *Polishing…*. A small *Open Chirp* link appears only in fallback states.
- **Secondary row** — **Cancel** (while recording), which becomes **Undo** for
  5 s after the text lands; **Use raw** (shows the seconds left in its 5 s
  window); and the **Style** menu. Undo removes exactly the dictation that just
  landed, and only if the field still shows it as Chirp left it. Otherwise it
  says "Text changed — nothing to undo".
- **Bottom row** — globe (only when iOS asks for it), **Space**, **Delete**
  (press and hold repeats, accelerating; it stops on release and if the
  keyboard takes ownership of an utterance), **Return** and **End session**.

Start and stop give a light haptic when Full Access is on.

1. Arm a session in the app first (see above). The keyboard shows "Session
   armed".
2. Tap **Start dictation**. The primary button reads *Open Chirp to start
   session* when no session exists; tapping it tries to open Chirp via
   `chirp://session/start`; iOS may refuse this from a keyboard
   extension. The keyboard then tells you to open Chirp manually and return
   with the system Back-to-app affordance or the app switcher — automatic
   return is not possible.
3. Live text appears in the field as partials and is replaced by the final.
   **Stop dictation** finalizes; **Cancel** retracts the partial; **Use raw**
   (5 s window, only when clean-up changed the text) swaps the original back;
   **Style** picks the server's clean-up profile; **End session** stops the
   microphone.

**Casing and spoken commands.** When the text just before a dictation shows a
sentence already under way (it ends in a word, a digit, a comma or a
semicolon), a common first word such as "so", "and" or "the" lands
lower-case: "We met and" + "So we left" gives "We met and so we left". Names,
"I", acronyms and mixed-case words stay as Chirp heard them, and a new
sentence, line or field keeps its capital. With **Spoken commands** on
(Settings, off by default), ending a dictation with "new line" or "new
paragraph" types one or two line breaks instead of the words. Use raw always
inserts the server's text unchanged.

**Press Return after dictating** (Settings; off by default). A custom
keyboard can only type Return; the app decides what it does. **On Send, Go or
Done keys** types Return only where the field's Return key does that, such
as search boxes and many chat fields, so the message goes out. **Always** also
types Return in plain fields, where it is a newline. It never fires after a
dictation that failed partway, after you moved the cursor, after an empty
result, in Search or Next fields, or between the parts of a long dictation.
Once it fires, the status shows "↵ sent" and Undo is not offered. A keyboard
can't press an app's own Send button (Messages has one), and it can't tell
which app it is in, so there is no "chat apps only" mode as on Android.

The keyboard edits only a verified owned suffix: it binds what it inserted to
the exact editor context and refuses to delete anything it cannot prove it
wrote. Live text is updated by rewriting only the part that changed, and long
dictation hands each part over at the caret, so text that has landed is never
retyped. Hosts show the keyboard only a window around the caret (Messages
about 1,000 characters before it). Chirp works through such a window as long
as it is an exact view of the text it expects and at least 256 characters
long. Some hosts expose shorter, shifted or asynchronous editor context; in
those the automatic replacement can stop with a partial already inserted — the
keyboard shows "Text kept in place" and leaves your text alone. Recover
explicitly in the Chirp app (the last transcript stays there); the keyboard
never blindly deletes by length. Size bounds: results up to 8,192 UTF-16 units,
per-side context evidence up to 16,384 UTF-16 units, results up to 65,536 UTF-8
bytes — oversized input is refused before any edit rather than half-written.

## iPad with a hardware keyboard

Two iPadOS limits shape this: iPadOS hides on-screen keyboards, including Chirp
Keyboard, while a hardware keyboard is attached; and keyboard extensions never
receive hardware key presses. So there are two ways to dictate into another app:

- **Show Chirp Keyboard.** Press the globe key (or Control-Space) until Chirp is
  chosen, then use the small keyboard bar at the bottom of the screen to show
  it, and tap Start/Stop dictation. Text goes in at the cursor as usual.
- **Toggle from anywhere.** Start a session in Chirp, then from any app press
  ⌘Space, type *Toggle dictation* and press Return; do it again to stop. Chirp
  copies the final text, so press ⌘V to paste.
- **A global shortcut key.** In the Shortcuts app, make a shortcut with Chirp's
  **Toggle Chirp dictation** action. Then Settings → Accessibility →
  **Keyboards & Typing** → **Full Keyboard Access** → on → **Commands**, and give
  that shortcut a key combination (iOS lists Shortcuts-app shortcuts there once
  you have made one). Press it to start; press it again to stop and copy.

With a session armed, Toggle runs in the background without leaving your app.
With no session it opens Chirp to set one up (permission and setup need Chirp
on screen). While Chirp Keyboard owns the current dictation, Toggle refuses
rather than stopping or copying it. Stop that dictation in the keyboard.

## Companion controls (Action Button, Control Center, Shortcuts)

Two iOS 18 controls — **Chirp dictation** (start) and **End Chirp session** —
can be added to Control Center and the Action Button (supported hardware). App
Shortcuts phrases: "Start dictation with Chirp", "Toggle dictation with
Chirp", "Stop dictation with Chirp", "Cancel dictation with Chirp", "End session with Chirp". While a
session runs, a Live Activity on the lock screen/Dynamic Island shows the
content-free phase (e.g. "Microphone active · dictating") with Start/Stop/
Cancel/End buttons; enable Live Activities for Chirp in system settings or
session start refuses.

Companion start runs in the background when a session is armed. With no
session it opens Chirp for permission and setup rather than recording cold in
the background. Companion
**Stop** (and **Toggle** when it stops) is the one path that explicitly copies its own fresh final to the
clipboard; keyboard and in-app dictation never write the clipboard implicitly.
Nothing transcript-like ever appears on the lock screen.

## Clean-up and styles

**Styles** tab. Clean-up starts off. The disclosure line says where it runs —
"Sends final text to \<host\>" for an external destination — and enabling an
external destination takes an explicit per-destination consent that suspends
when the destination changes. Styles come from your Mac's authenticated
profile list (Default, Chat, Email, … plus custom server profiles); each has an
editable prompt with a **Reset to server default** button. The keyboard's
**Style** menu mirrors the same server profiles (one Chirp has no name for
shows its id, in the menu and on the button) and also holds **Private session ·
exclude history**, the same switch as in Settings. On clean-up failure or
timeout, the raw transcript is kept and offered instead.

## History (off by default)

**History** tab: "Keep encrypted history on this device" is off initially.
When on: at most 200 nonempty finals, 4 MiB total, retention 24 hours / 7 days
(default) / 30 days, searchable, with per-entry copy, copy-original, delete and
a Clear all action. Entries are AES-GCM encrypted with a device-only Keychain
key, excluded from backups and never synced. Turning history off deletes the
ciphertext and the key. Cancelled and empty utterances are never recorded, and
the **Private session** toggle (Settings, or Chirp Keyboard's Style menu) keeps an utterance out of history —
but Chirp cannot detect every editor's private mode, so switch it on yourself
when it matters; surrounding editor text is never collected.

## Privacy & security

- **Nothing persistent by default.** No audio is ever written to disk, and
  there is no persistent transcript storage by default — with two transient
  exceptions: the app↔keyboard mailbox holds AES-GCM-encrypted text on disk
  until it is consumed or expires, deleted opportunistically on the next
  access (there is no background purge daemon), and the Live Notes recovery
  copy holds AES-GCM-encrypted notes until they are saved, discarded or
  replaced (Notes settings turns it off). Opt-in encrypted history is
  separate and always ciphertext. The server's opt-in debug retention is
  bannered in red on every surface, and idle audio is discarded on device,
  never streamed.
- **Pairing is a secret.** The QR/link is printed locally on the Mac only;
  treat it like a password. The token lives in the iOS Keychain (this-device,
  after first unlock, never synced) and is never rendered or logged. Do not
  paste real pairing links or tokens into issues, docs or chat.
- **Tailnet-only.** HTTPS `*.ts.net` hosts with simple paths; no HTTP, no
  public hosts, no redirects, TLS validation always on.
- **IPC is encrypted.** The keyboard/app mailbox is AES-GCM sealed with a
  shared Keychain key; no transcript ever touches UserDefaults or plaintext
  files. Mailbox contents are transient with opportunistic expiry deletion on
  next access — there is no background purge daemon.
- **Diagnostics are content-free.** Version, OS, phase, fixed local error
  codes, durations and counts only — no transcripts, prompts, audio, URLs,
  hosts, tokens or device identifiers. Settings → Content-free diagnostics also keeps
  **timings of the last 50 dictations**: time to ready, to the first words,
  from stop to the final, polishing and audio length, plus the outcome
  (final, empty, kept, failed, cancelled), error code, where you dictated
  (app, keyboard, companion), the kind of network (Wi-Fi, cellular, wired) and
  how many parts a long dictation used. It shows p50/p90 summaries, is included
  in Share diagnostics, and has a **Clear timings** button.
- **No telemetry, no background sync, no analytics.**

## Troubleshooting

| Symptom | Meaning / fix |
|---|---|
| "Dictation needs Full Access" | Enable Full Access for Chirp Keyboard in Settings → General → Keyboard → Keyboards. |
| Setup step 2 never shows done | Open Chirp Keyboard once in any app with Full Access on. The step needs the keyboard to reach the App Group, which only works with Full Access. |
| Chirp Keyboard doesn't appear on iPad | A hardware keyboard is attached. Show it from the keyboard bar at the bottom of the screen, or use the Toggle dictation shortcut key. |
| "Start a session in Chirp" in the keyboard | No armed session (or the lease expired). Open Chirp, tap Start keyboard session, return to your editor. |
| "iOS could not open Chirp from this keyboard" | Expected fallback; open Chirp manually and return via app switcher. |
| "Text kept in place" | The editor's context changed or is unreliable; recover the dictation in the app. Your text is never auto-deleted. |
| "Protected storage unavailable. Unlock and reopen Chirp." | Keychain/App Group not accessible (device locked or missing capability). Check the provisioning profile includes the App Group and keychain access group. |
| "Connection failed. Check Tailscale and your Mac." | Tailnet down or server not running the updated source; use Check Mac connection after fixing. |
| "Can't find your Mac on the tailnet…" | The Mac's tailnet name didn't resolve: the Mac is off the tailnet, or Tailscale is off on this device. |
| "Your Mac may be asleep, or Chirp isn't running on it." | Nothing answered at the Mac's address. Wake the Mac, check chirp-server, then tap Check again. |
| "Your Mac refused this device. Pair again in Chirp." | The pairing was revoked or replaced (`chirp-server devices revoke`). Pair again from the Pair Mac tab. |
| "Kept what was heard" | Dictation failed partway; the text heard so far was inserted without clean-up. Undo removes it for 5 s. |
| "The Mac did not finish in time." | Finalization/clean-up deadline hit; raw text is kept when possible. |
| Arming fails or the session ends immediately | Check microphone permission, that Live Activities are enabled for Chirp, and Tailscale; the Dictate tab shows the local error. |

## Develop and test

Portable logic (runs on macOS; also works with only the Command Line Tools):

```sh
ios/Shared/scripts/test.sh                 # 22 tests / 6 suites
mac/scripts/test.sh && (cd mac && swift build -c release)   # 380 tests / 61 suites + release
swift test --package-path ios/Keyboard/Policy   # full Xcode selected; with only the CLT add
#   -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
ios/scripts/check-sources.sh                # regenerate + structural, plist and per-target syntax checks
ios/scripts/typecheck-catalyst.sh           # optional Catalyst compiler aid (see below)
ios/scripts/ci-test.sh                      # what GitHub Actions runs: the checks above + app unit tests on one iPhone simulator
```

`check-sources.sh` regenerates the project, runs the structural project check
(`check-project.py`), lints every plist/entitlement and the pbxproj, parses
each target's Swift sources and shell/Python syntax — its own output says "no
iOS typechecking claimed". `typecheck-catalyst.sh` is an optional compiler
aid: it compiles the session coordinator, microphone capture, pairing scanner
and debug-fixture sources for the Mac Catalyst target, substituting a
temporary ActivityKit facade in a scratch directory (shipping sources are
unmodified). It has already caught one real conditional-API mistake, but it
does not validate the iOS SDK, signing, the simulator, SwiftUI view macro
expansion, App Intents or ActivityKit, and it is not runtime evidence.

**Live end to end on a simulator** (full Xcode, the cached model at
`~/.koi/voice-models/parakeet-mlx`, `ffmpeg`):

```sh
ios/scripts/simulator-e2e.sh SIMULATOR-UUID   # full UI scheme + live server; prints iOS E2E: PASS
CHIRP_E2E_APPEARANCE=dark ios/scripts/simulator-e2e.sh SIMULATOR-UUID   # same, in dark mode
```

It starts a throwaway `chirp-server` (temporary HOME and token, port 7899 or
`CHIRP_E2E_PORT`, no LaunchAgent), a deterministic local clean-up stand-in
(`ios/scripts/fake-cleanup.py`, drops "um"/"uh") and a synthetic `say`
sentence. Then it runs the UI tests and checks the server log holds no transcript
words. Two **Debug, Simulator-only** hooks make this possible. Neither exists in
Release or on a device:

- Pairing also accepts exactly `chirp://pair?url=http://127.0.0.1:PORT&token=…`
  (the simulator shares the Mac's loopback); `chirp-server pair --url
  http://127.0.0.1:PORT` prints one.
- `--chirp-sim-audio FILE` plays a speech file through the real capture sink
  instead of the microphone. On this build Mac the simulator's microphone
  input hangs inside AudioToolbox (an RPC timeout abort in
  `AVAudioEngine.inputNode`), so real capture is never armed there; looping
  silent output keeps the app running in the background as the microphone
  does on a device.

Observed simulator behavior the tests account for: iOS 27.0's globe-key
input-mode list shows third-party keyboards as unlabeled rows, so tests cycle
the globe key (iPad's Emoji keyboard has no globe key, so there they fall back to the list). While any secure field is on screen, iOS offers no third-party
keyboard to the window's other fields either. Safari never reports idle to
XCUITest, so Messages is the other-app host.

With full Xcode: `ios/scripts/toolchain.sh`, then the three simulator actions
from the install section — build, unit tests (`ChirpIOS` scheme) and UI tests
(`ChirpIOS-UI` scheme, which includes `ChirpKeyboardUITests`) — on a disposable
iPhone **and** iPad simulator. The keyboard UI test changes simulator Settings
(adds Chirp Keyboard, allows Full Access); only use simulators you don't mind
reconfiguring, and don't run two UI suites on one simulator at once. Simulator
results cannot establish hardware keyboard handoff, background-audio survival,
lock-screen behavior or App Store acceptance. Evidence and exact logs:
[docs/review/ios-simulator.md](../docs/review/ios-simulator.md),
[docs/review/ios-foundation.md](../docs/review/ios-foundation.md),
[docs/review/ios-keyboard.md](../docs/review/ios-keyboard.md),
[docs/review/ios-app.md](../docs/review/ios-app.md), shared-package
API contract in [Shared/README.md](Shared/README.md).

## Layout

```
ios/
  App/        SwiftUI app: session coordinator, microphone capture, pairing scanner, views,
              Live Notes (LiveNotes*.swift: controller, capture, views, Live Activity)
  Keyboard/   Keyboard extension + Keyboard/Policy (verified-insertion logic under test)
  Intents/    App Intents, App Shortcuts, Live Activity (app-process execution)
  Widgets/    WidgetKit bundle: Live Activity UI, Control Center controls
  Shared/     ChirpIOSCore package: pairing, Keychain, preferences, encrypted history/bridge
  Config/     Project.xcconfig, Info.plists, entitlements (per target)
  scripts/    toolchain.sh, generate-project.py, simulator.sh,
              check-sources.sh, check-project.py, typecheck-catalyst.sh
  Tests/      Simulator unit tests (app)
  UITests/    Simulator UI tests
```

## Known limits

- **Live Notes on a device is unverified.** Background recording with the screen
  locked, the Live Activity and Dynamic Island buttons, call interruptions and
  battery use need an operator check on an iPhone and an iPad; the simulator
  covers the flows with synthetic and file audio only.
- **Only one device install so far.** One iPad (see Status); no iPhone yet,
  and most on-device checks (real microphone quality, Live Notes, background
  survival) are still operator steps.
- **Secure fields hide Chirp Keyboard for the whole screen** (seen on the
  iOS 27.0 simulator): while a password field is visible, iOS uses Apple's
  keyboard for the screen's other fields too.
- **Personal install only.** No App Store readiness; the keyboard's URL-open
  handoff is a known App Store review risk.
- **The keyboard has no microphone, ever** (Apple sandbox). A session must be
  armed in the app. `extensionContext.open` always fails for keyboards, so the
  keyboard opens `chirp://session/start` through the UIApplication in its
  responder chain (works on iPadOS 26.7.1); if iOS ever refuses it, the keyboard
  says so and Chirp must be opened by hand.
- **No automatic return** to your editor and no guaranteed cold/background
  microphone start from companion controls.
- **"Never" session length is not forever**: iOS may suspend or terminate the
  app; the microphone indicator stays on for the whole armed session by design.
- **Free provisioning expires every 7 days** and App Group availability on
  free accounts is not guaranteed — verify the actual profile.
- Editor-context quirks (short/truncated/asynchronous context windows) can stop
  automatic replacement and leave a partial; recovery is manual in the app.
