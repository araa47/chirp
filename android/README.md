# Chirp for Android

The **Chirp** app (a Notes library, the Scratchpad, dictation history and settings) and two ways to dictate in any app: **Chirp Keyboard**, a full HeliBoard keyboard for the Galaxy Z Fold with a microphone key, or the **floating mic** beside your own keyboard. Both stream your voice to the `chirp-server` on your computer over Tailscale. Live text appears underlined in the focused field while you speak; the final replaces it. An optional clean-up pass on the computer polishes the final text, and history keeps recent dictations on the phone, encrypted.

The launcher, Settings → Apps and notifications call the app **Chirp**; Android's keyboard picker and keyboard settings list the input method as **Chirp Keyboard**. The application ID and IME component stay `dev.chirp.android` / `dev.chirp.android/.ChirpImeService`, so a signed APK installs as an **update** and preserves your pairing (the token is encrypted under an Android Keystore key). Current version: **0.7.3**, version code 15.

| At a glance | |
|---|---|
| Keyboard base | HeliBoard 4.2 (GPL-3.0), vendored and patched — see [Upstream](#upstream) |
| Looks | **Gboard-like** default, a **Samsung-like** option, three classic HeliBoard looks |
| Fold layout | Phone-style function keys on the inner screen, number row ≥ 600 dp, split landscape |
| Swipe typing | Not bundled; you can load a user-supplied library, or build it into a personal APK — see [Keyboard](#keyboard) |
| Clean-up | On by default after pairing when the computer cleans up locally; external endpoints need explicit opt-in |
| History | On by default (an explicit opt-out stays off), on-device only, AES-GCM encrypted under an Android Keystore key |
| Retention | Dictation keeps no audio; history is encrypted on this phone by default; notes are kept until you delete them; kept audio is opt-in; diagnostics hold numbers-only timings and crash frames |

**Contents**

- [Install](#install) — build the APK, put it on the phone, update over Tailscale, enable the keyboard · [Pair](#pair) — QR, paste, Wi-Fi servers
- [The app](#the-app-notes-history-settings) — Notes (the start tab, with the connection status chip, Record and Dictate), History, Settings
- [Dictate](#dictate) — start/stop/cancel, push-to-talk, quick options, clean-up, styles, Undo, Use raw
- [Keyboard](#keyboard) — typing, looks, Fold layout, swipe typing; [Keep your keyboard](#keep-your-keyboard) — the floating mic
- [Scratchpad](#scratchpad) — dictate long text, edit, copy or share; Quick Settings tile and launcher shortcut
- [Notes](#notes) — a notes library: record a meeting into live Markdown notes, search, Recently Deleted, kept-audio replay
- [Dictation history](#dictation-history) · [Privacy](#privacy) · [Troubleshoot](#troubleshoot)
- [Develop and test](#develop-and-test) — toolchain, gradle, emulator harnesses
- [Upstream](#upstream) — HeliBoard, patches, dictionaries, license
- [Validation records](#validation-records) — dated runs, measurements and APK sizes

## Install

### Build the APK (once, on the computer)

```sh
source ~/.local/share/chirp-android/env.sh   # toolchain; see "Develop and test"
cd android
./gradlew assembleRelease
```

The build produces two signed APKs in `app/build/outputs/apk/release/`: `app-arm64-v8a-release.apk` for the phone (arm64-v8a only) and `app-x86_64-release.apk` for emulator validation. Install the **arm64** APK on the phone — the ABI split makes it smaller than the former dual-ABI APK (25.7 MiB; measured sizes in [Validation records](#validation-records)). Signing uses `keystore/local-debug.keystore` (create it once with `scripts/make-keystore.sh`; without it the release build is unsigned). **Never generate a replacement key for an app that is already installed** — Android would refuse the update. Debug and release builds both use this local key.

### Put it on the phone

Install **as an update, without uninstalling Chirp** — that is what keeps the saved pairing. Either works:

- **Over Tailscale (Taildrop):** from the computer, `tailscale file cp app/build/outputs/apk/release/app-arm64-v8a-release.apk <phone>:` — the file arrives as a notification in the phone's Tailscale app. Tap it to open the installer.
- **adb:** `adb install -r app/build/outputs/apk/release/app-arm64-v8a-release.apk` over USB or wireless debugging.

- **From your computer, in the app (updates):** see [Update over Tailscale](#update-over-tailscale).

Opening a sideloaded APK can trigger a **Play Protect** screen warning about an unknown developer. Choose **More details → Install anyway** to continue. (A separate, optional sideload restriction can affect the floating microphone only — see [Keep your keyboard](#keep-your-keyboard).)

### Update over Tailscale

Once the first install is on the phone, later builds can update it in place from the paired computer.

On the computer, stage the signed arm64 release APK (`app-arm64-v8a-release.apk`, the phone split) and its manifest, then host that folder yourself at `/chirp-apk/` on the same tailnet host as the pairing (for example with your existing static file server behind `tailscale serve`; this script hosts and publishes nothing):

```sh
./gradlew assembleRelease
scripts/make-update-manifest.sh                       # → build/chirp-apk/chirp-<version>.apk + latest.json
```

`latest.json` holds `version_code`, `version_name`, `file` (a plain `*.apk` name in that folder), `sha256` and `size`. The script refuses an unsigned APK or one that isn't `dev.chirp.android`, and writes the manifest last.

On the phone, Chirp settings → **About → Updates** checks `https://<paired host>/chirp-apk/latest.json` when it opens, and **Check for updates** checks on demand. **Download and install** fetches the file, verifies its size and SHA-256 and that it is this app at the announced version, then hands it to Android's installer. Android shows its own confirmation and accepts the update only if it is signed with the installed key, so pairing is kept. The first time, Android asks you to allow Chirp to install updates.

- Only a pairing on a tailnet host (`*.ts.net` or a Tailscale address) gets update checks; the host is always the pairing's own, and the manifest can name only a file in that folder, never another URL. Redirects are not followed.
- The pairing token is never sent to the update path. Nothing about your text or audio is involved; the only request is the version file, and only when you open setup or tap check.
- Update logs, URLs and versions are not written to diagnostics.

### First launch

Onboarding has five steps: **Welcome · How you’ll dictate · Keyboard or Floating mic · Microphone · Pair**. A segmented bar shows progress and one primary button stays at the bottom, including at 200% font. Back returns to the previous step. Returning from system settings refreshes the checklist and advances when the requirement is met. Existing users who finished onboarding go straight to Notes after an upgrade.

1. **Welcome:** dictation and Notes, then **Get started**.
2. **How you’ll dictate:** choose **Use Chirp Keyboard** or **Keep Gboard** (or your selected keyboard’s name). Neither is preselected; Continue requires a choice. Notes, Scratchpad, History and tiles work either way.
3. **Keyboard:** enable and select Chirp Keyboard. **Floating mic:** read the disclosure, open the service’s Accessibility details, then allow it. Returning with it still off offers restricted-settings help. **Skip for now** leaves a dismissible reminder in Notes. Advanced Protection replaces the setup action with **Use Chirp Keyboard instead** and **Continue without it**.
4. **Microphone:** allow it while using the app. It opens only during dictation or a recording note.
5. **Pair:** scan your computer's QR code or paste its pairing link. Chirp tests the link before saving it. **Finish** opens Notes.

Switch later in **Settings → How you dictate**, directly below Connection. The selected mode has a live checklist and keyboard picker or the same floating-mic guide. Choosing a mode never disables an IME or service. Keyboard preferences remain available; the hardware shortcut requires Chirp Keyboard. The floating mic hides while Chirp Keyboard is selected in either mode. Renders: `docs/screenshots/android/keepkb-*.png` and `onboarding-*.png`.

### The app: Notes, History, Settings

After onboarding the launcher opens the app on **Notes**: three destinations in a **navigation bar** on the cover screen and a **navigation rail** on the inner screen (from 600 dp wide; `NavigationSuiteScaffold`). Back pops within a tab (a note, a settings page, a history entry), then returns to Notes, then leaves. Opened from outside, from the keyboard's history link or **Chirp settings**, Back from that tab returns where you were.

![The notes library on the cover screen](../docs/screenshots/android/notes-library-cover-populated-light.png) ![A note beside the library on the inner screen](../docs/screenshots/android/notes-library-inner-detail-dark.png) ![Dictation history on the inner screen](../docs/screenshots/android/history-list-inner-light.png)

- **Notes** is the [notes library](#notes). Its top bar carries the connection chip: **● Computer** when the paired computer answers, **● Offline** when it doesn't (or Tailscale is off for a tailnet pairing), and **● Phone** when there is no pairing but the phone's own recogniser is on. Tapping it opens Settings → Connection. Unfinished setup (no pairing, no microphone permission, the chosen keyboard or floating mic not on) shows as one dismissible card at the top of the list, **Finish setup**, and at most one banner shows at a time. At the bottom right, the extended **Record** button starts a note and the small mic button beside it opens the [Scratchpad](#scratchpad).
- **History** is [dictation history](#dictation-history), titled "Dictation history" with one line saying what it holds: a search bar, entries grouped by **Today**, **Yesterday** and **Earlier**, each led by the target app's icon with its age and whether clean-up changed it. Tap one for the text, the words **before clean-up**, the app and time, with **Copy**, **Copy raw**, **Share** and **Delete**: a bottom sheet on the cover screen, a pane beside the list on the inner screen. Long-press offers **Add to note** (appended to your latest note). Swipe an entry either way to delete it at once, with **Undo** in the snackbar (TalkBack offers **Delete** as an action). The switch, retention and **Clear history** are behind ⋮ → **History settings**. When history is off or empty the tab says so with one button.
- **Settings** is Chirp settings, below.
- The whole app is excluded from Recents thumbnails. Renders: `docs/screenshots/android/notes-library-*.png` and `history-*.png` (list, empty, off), cover and inner, light and dark.

### Chirp settings

One destination, **Chirp settings** (the Settings tab), holds every setting. Open it from the app, from HeliBoard → Keyboard layouts & settings (the Chirp section at the top is a summary: the connection row, the clean-up switch and **Open Chirp settings**), or from the keyboard's long-press **Chirp settings**. The top level is one grouped card of eight category rows, each with an icon and a live one-line summary ("Clean-up on · stops on pause", "Gboard look · swipe on"); each opens a page. Paragraph help sits behind the ⓘ on a row.

| Row | Its page |
|---|---|
| Connection | A status row (*Connected · host*, *Computer unreachable · host*, *Not paired*), **Check connection**, **Change pairing** (or **Pair computer**), **Allow Wi-Fi server access** (only when needed), **Forget pairing** (asks first: *You'll need the QR code to pair again*), and **When your computer is unavailable** (the phone-local recogniser) |
| How you dictate | **Chirp Keyboard** or **Keep my keyboard**, with a live checklist and the keyboard picker or the floating-mic guide (see [First launch](#first-launch)) |
| Dictation | **Clean-up** (only when the computer offers it) and **Styles** (default and per-app styles, prompt editing), **Stopping** (when I tap / when I pause), **Spoken commands**, **Press Send** after dictating |
| Keyboard | **Keyboard look**, **Swipe typing**, **Hardware keyboard shortcut** (Ctrl+Alt+Space, works with Chirp Keyboard), **Larger mic on the inner screen**, **Layouts, languages & typing** (HeliBoard's own settings). Its summary says when it isn't in use because you keep your own keyboard |
| Feedback & look | **App colours** (Pond, or Match wallpaper), **Haptic cues**, **Sound cues** |
| Notes | **Save battery while the screen is off**, **Keep a recovery copy until notes are saved**, **Keep notes on this phone** (or **Enable notes library** after an earlier opt-out), **Delete notes older than** (Never, 1 year, 90 days, 30 days), **Keep audio with notes**, **Delete kept audio (size)**, **Delete all notes** |
| Privacy & history | **Dictation history** (switch, retention, open, clear) and what Chirp keeps |
| About | **Updates**, **Diagnostics** (debug overlay, the report, **Copy diagnostics**, **Clear timings**) |

Back from a page returns to the list (predictive back); back from the list returns to Notes (or leaves, when opened from the keyboard or HeliBoard). From 600 dp wide (the Fold's inner screen) the list stays on the left and the page opens on the right, and the summaries stay live while a page is open. Existing settings keep their stored values; nothing migrates. Renders: `docs/screenshots/android/settings-*.png`.

## Pair

On the computer, open Chirp → Settings → Devices → **Pair a Phone…**, which checks Tailscale, publishes the server and shows the QR. Without the Chirp desktop app, print the secret pairing QR from the command line (see [server/README.md](../server/README.md#pair-a-device); the server must be published on your tailnet, e.g. `https://<your-computer>.<tailnet>.ts.net/chirp`):

```sh
uv run chirp-server pair --url https://<your-computer>.<tailnet>.ts.net/chirp
```

On the phone, onboarding's last page (*Pair your computer*, or Chirp settings → Connection → Change pairing) — with Tailscale on, on both devices:

- **Scan code** is primary (the scanner uses Google Play services). **Paste link instead** works without it.
- A scanned code or pasted link is tested and saved straight away; nothing is stored until the computer answers.
- A saved pairing shows the paired computer's host and the engine it reports, and offers **Check connection** and **Forget pairing**.

The token is stored encrypted (AES-GCM) under the Android Keystore alias `chirp_pairing_v1`; pairing links are parsed strictly (`chirp://pair?url=…&token=…`, HTTPS only) and never rendered into logs. Recoverable connection problems offer **Pair computer**, **Open mic settings** or **Check Tailscale** (which opens the Tailscale app when it is installed).

### Tailscale off when the keyboard opens

When the pairing points at a tailnet host (`*.ts.net`, `100.64.0.0/10` or `fd7a:115c:a1e0::/48`) and no VPN is applied to Chirp, the suggestion row shows **Tailscale is off** with a **Turn on** button. This check is local only, with no DNS lookup or network call. LAN or other pairings are never prompted.

- **Turn on** sends an explicit broadcast to the Tailscale app (`com.tailscale.ipn.CONNECT_VPN` to its exported `IPNReceiver`, the same hook Tasker-style automation uses). Tailscale connects only if you have already granted it Android's VPN permission and signed in. Chirp can't grant that permission or skip Android's consent dialog. Without it, Tailscale posts its own "open Tailscale" notification.
- The row says **Connecting Tailscale…**. When a VPN network appears it says **Tailscale connected** and reconnects to the computer. If nothing connects within 10 seconds it offers **Open Tailscale**, so you can finish in the app.
- If Tailscale isn't installed, the row offers **Set up**, which opens Chirp setup's connection step.
- ✕, or typing past the prompt, hides it until Tailscale is next seen connected. Tapping the mic while Tailscale is off shows the prompt again instead of a generic *Computer unreachable* error.

Detection is conservative. It only knows whether *some* VPN applies to Chirp, because Android doesn't say which app owns another app's VPN. If a different VPN is active, Chirp shows no prompt, and a failed dictation still offers **Check Tailscale**. A successful health check clears the prompt.

### Servers on your Wi-Fi (Android 17)

Android 17/API 37 needs `ACCESS_LOCAL_NETWORK` for servers reached directly over Wi-Fi/Ethernet. Chirp checks the paired server's resolved addresses and matching VPN routes in its network workers, never on the microphone press path. Setup requests permission only after a connection targets a local address outside a VPN. This includes RFC1918, link-local and local CGNAT/IPv6 addresses. Loopback JVM test servers are exempt.

**Needed only for servers on your Wi-Fi. Tailscale works without this permission.** Android explicitly excludes VPN traffic from its local-network definition, so an operator's `.ts.net` server resolving to 100.x through Tailscale is not permission-gated. Denial never prevents trying that tailnet connection. No DNS result or server address is added to diagnostics. Sources: [Android local-network definition](https://developer.android.com/privacy-and-security/local-network-definition) and [Android 17 permission behavior](https://developer.android.com/privacy-and-security/local-network-permission).

## Dictate

### Start, stop, cancel

- Tap the **mic in the suggestion row** to start. The mic changes colour and icon while listening, with a waveform and a subtle pulse.
- Tap the **stop icon** the mic becomes to finish and insert. **✕** discards the dictation.
- **Press and hold the mic to talk, release to finish** (push-to-talk): the press starts listening at once; a short tap keeps listening (tap again to stop), and a hold of 0.3 s or more stops and inserts on release. Quick options moved to the **⋯** beside the mic (TalkBack also offers them as a **Dictation options** action on the mic; double-tap still starts and stops). **⋯ opens quick options**, a sectioned menu: a **Clean-up** switch (or *Clean-up is off on your computer*) with where the correction runs, and a **Style** radio group of the styles the computer advertises (*rewrites* beside those that may restructure; one choice closes the menu), and a **Chirp settings** row. TalkBack hears the switch and radio roles with their checked state. Long-pressing a history entry opens the same menu style (Copy, Insert raw, Delete).
- A configured keyboard **voice key** supports the same push-to-talk: press-and-hold to talk, release to finish; a short tap toggles. The strip mic needs no voice key for this.
- Haptic cues fire on start, manual stop and successful insertion when haptics are enabled (they follow Android's system setting).
- **Chirp settings → Dictation → Stopping**: **When I tap** (default) or **When I pause** with a pause of 1, 1.5, 2, 3 or 5 s (2 s default). Pause mode is a port of the Mac's auto-stop: speech is judged against the room's own noise floor, so steady background noise never counts as talking; it never stops before you have spoken, and gives up after 10 s of silence. Tapping stop still works in both modes.
- **Long dictation**: the server accepts 120 s per utterance, so a keyboard dictation is cut into segments of at most 90 s, the way the Mac's Live Notes does it. A dictation shorter than 45 s is never cut. After 45 s the cut comes at the first 0.6 s pause (0.3 s after 70 s), and at 90 s the cut happens whatever you are saying. At a cut the microphone stays open and the next segment takes over at once, buffering until its own socket is ready, so no audio is dropped. The previous segment finishes in the background. Its final, cleaned on its own, is committed at the caret, and the next segment's live text continues right after it. Each segment lands in order, even if a later one finishes first. The live text pauses for a moment after a cut until the earlier segment lands. Each segment is its own history entry. There are no haptics, sound or TalkBack between segments; the word count is announced once at the end.
- **Time limit**: a dictation stops at 10 minutes. In the last 15 s the status adds **N s left** with one haptic tick (TalkBack hears it only at 15, 10, 5, 3, 2 and 1 s), and the dictation is finished and inserted like a normal stop.
- **Hardware keyboard** (Bluetooth or DeX): **Ctrl+Alt+Space** starts and stops dictation and **Esc** cancels while listening. Ctrl+Space is left to language switching. The keys are ignored in password fields and can be turned off in Chirp settings → *Keyboard → Hardware keyboard shortcut* (on by default). If a hardware keyboard has hidden the on-screen keyboard, the chord shows it so the status row and ✕ stay available.
- **Sound cues** (off by default; Chirp settings → *Feedback → Sound cues*): short generated tones for start, stop, inserted and error, played as touch-feedback-class audio and silent when the ringer is on vibrate or mute. They are separate from haptics and from the keyboard's key sounds. The start tone can be faintly audible in the first few milliseconds of a dictation.
- **TalkBack:** the status row is silent while listening, finishing and polishing. Each final is announced once — "Inserted, N words", or "Cleaned, Use raw available" while Use raw is offered — and the Use raw and Undo buttons do not announce a second time. A final that keeps only what was heard reads its own status instead.

The full keyboard always **stays selected after a final** — including when an old installation had the voice-only keyboard's auto-return enabled. (That auto-return is gone; the old voice-only implementation lives only in test sources and is not registered or shipped, and its historical preference now defaults OFF.) **Use raw** is offered for five seconds after a corrected final; moving the cursor or editing the field invalidates it.

### Press Send after dictating

**Chirp settings → Dictation → Press Send** (off by default): **Off**, **Always**, or **In chat apps only** (apps whose rule is the Chat style, editable under Per-app styles). Once the last words of a dictation have landed, Chirp performs the field's own editor action (`IME_ACTION_SEND`, `GO` or `DONE`), or sends an Enter key when the field has no action. The strip adds "· ↵ sent" to the status. It is the same setting as **Return** on the Mac and **Press Return after dictating** on iPhone; Android names it after Send because it runs the field's own action (a chat app's Send button), which a Mac or iOS keyboard cannot.

- Never in a password field, and never after a result that only kept what was heard, after the caret was moved away, or after an empty result.
- NEXT/PREVIOUS (they would move focus) and SEARCH are left alone.
- A multi-line field whose app says "no action" would take Enter as a newline, so only **Always** presses it there.
- A long dictation presses once, after its last segment. Undo is not offered after a send, since the field has already submitted the text.

### Mid-sentence casing and spoken commands

Finals (never partials) get a small local pass before they are inserted. When the text before the cursor shows a sentence under way (a word, digit, comma or semicolon, even behind a closing quote), the first word is lower-cased, so dictating *"And then we went"* after *"I woke up"* inserts `and then we went`. Field start, a new line, `. ! ?` and similar terminals, opening quotes/brackets, colons and list markers keep the capital. It is deliberately conservative: only common sentence starters (*and, but, so, we, the, it's, don't, …*) are lowered; "I" and its contractions, acronyms and mixed-case words (`NASA`, `GitHub`), and anything that could be a name (*Paris, Monday, Will*) are left as the server sent them. Other languages are left alone, and nothing changes if the editor can't show the text before the cursor.

**Spoken commands** are off by default (Chirp settings → *Spoken commands*). When on, a final that is exactly, or ends with, *new line* or *new paragraph* (any case, optional trailing punctuation) inserts one or two line breaks in place of those words, e.g. *"Okay, new line."* → `Okay,` + ⏎. The match is exact, so *new lines* or *a new line of work* are untouched, but a dictation that merely ends in the words does become a break. This runs on the phone after clean-up, so the server never sees the commands as text to polish. **Use raw** and dictation history keep the unmodified text the server returned.

### Dictated text is never lost

- **Undo** sits in the row for five seconds after every final, cleaned or not. It removes exactly what the dictation inserted, including the space Chirp added before it, and puts back any selection the dictation replaced. Typing, moving the cursor or starting another dictation ends the offer, like **Use raw**. After a long dictation, Undo and **Use raw** apply to the last segment only; earlier segments are already ordinary text.
- **Failures keep what was heard.** If the connection drops, the server reports an error (engine, busy, 120-second limit…) or a deadline passes after at least one live partial, the last partial is committed as plain text (no clean-up) and the row shows **Connection lost — kept what I heard** (or the reason, e.g. **Dictation limit is 120 seconds — kept what I heard**) with **Undo**. With history on, the entry is marked **partial**. **✕**, typing over a live dictation, hiding the keyboard and switching to another field still discard it. In a long dictation these discard only the segments that have not landed yet (the underlined text and anything still finishing); segments already inserted stay. A segment that fails keeps what it heard and never touches earlier ones. If an earlier segment fails, the dictation goes on. If the live one fails, the microphone stops and earlier segments still land.
- **Moving the cursor stops instead of cancelling.** Tapping elsewhere in the field while listening sends stop; later partials no longer touch the field, and the final replaces the underlined text where you spoke it while your cursor stays where you put it. If the app dropped the underlined text, the final is inserted at your new cursor instead. The same happens to a long dictation's segment whose live text was not shown yet (you moved the cursor in the moment after a cut).

### When your computer is unavailable

Off by default: Chirp settings → **When your computer is unavailable → Use this phone's recogniser** (greyed out when Android reports no on-device recogniser). When it is on and the computer is known to be unreachable, a tap dictates one utterance with Android's on-device recogniser (`SpeechRecognizer.createOnDeviceSpeechRecognizer`) instead of the computer. "Known to be unreachable" means the mic shows **Computer offline**, Tailscale is off for a tailnet pairing, or a dictation attempt failed before anything was heard for a reachability reason. An attempt that fails that way hands over on its own, with the status **Computer unavailable · listening on phone**, so say it again. A TLS failure, or a failure after the computer heard something, never hands over (what was heard is kept as usual). Password fields stay refused.

The status reads **Listening on phone…** and an **on phone** chip stays visible until the notice clears. TalkBack names the provider: the app label of the phone's on-device speech service (from Google or the phone maker), never Chirp's own engine. The text is inserted raw: no clean-up and no Use raw. Undo, spoken commands, casing and history (when on) work as usual. The phone's recogniser usually ends on a pause by itself; in *When I pause* mode Chirp asks it to use your pause, which some services ignore. Tapping stop waits at most 5 s for its result. ✕, hiding the keyboard, switching fields or typing releases the microphone at once. Design notes and the bundled-model (sherpa-onnx) evaluation: [docs/research/android-phone-fallback.md](../docs/research/android-phone-fallback.md).

### What you see while you speak

Partials appear only in the text field, underlined with a slightly dimmed tail (supplied as spans when the editor supports them); the suggestion row is replaced by the waveform, status, ✕ and stop. Partials are coalesced to one editor update per 16 ms (latest sequence wins). Editors that can verify their composing text receive only the changed suffix; UTF-16 surrogate pairs stay intact. A server `stable` prefix becomes normal committed text while the remaining tail composes. A final or cancel re-marks the whole utterance so clean-up replaces it atomically and cancel restores the selection.

Showing the keyboard prewarms the bearer-authenticated socket without sending `start` or capturing sound — but only when you are likely to dictate: you dictated in the last 10 minutes, or into this field's app in the last 1 day. Otherwise the socket opens on press, and typing-only use pays no handshake. The policy (`PrewarmPolicy`) keeps timestamps for at most 16 app packages in memory only: nothing is written to disk, and no text, audio or app names reach logs or diagnostics. The health check on show runs at most once a minute (a failed check, a Tailscale reconnect or a tap on an offline mic still check at once). An unused warm socket closes after 30 seconds or when the keyboard hides. Capture still starts on press, before the server's `ready`, through a bounded buffer, so a cold press loses no speech; Chirp settings → About → Diagnostics shows `ready, warm` and `ready, cold` p50/p90 side by side. Reduced-motion settings disable the pulse, shimmer and transition animations.

### Clean-up

Clean-up asks the computer to polish the **final** text only; partials always stay raw. After pairing it is **on by default when the computer's correction stays on that computer**; an external correction endpoint requires explicit opt-in and a known host. Your toggle is recorded (`correction_explicit`) and persists across refreshes and restarts; if the computer loses clean-up availability or its correction destination changes, clean-up suspends until you enable it again, and a server reporting clean-up off always dictates with `correction=false`.

While it runs, the raw transcript stays underlined in the field and the row shows a ✦ **Polishing…** with an animated shimmer, the selected style chip and a loading indicator in place of the stop button; polishing stays readable for at least 450 ms even for very fast finals, and state changes fade over 180 ms. The final commits the cleaned text and shows a **cleaned** notice with a **Use raw** button for five seconds — one tap, exposed to TalkBack, invalidated by edits or cursor changes. Correction errors, disconnects and a 12-second polishing timeout commit the raw text with a **kept original** note. Recovery and error notices dismiss after five seconds to restore normal suggestions. An empty or blank final cancels the composition, inserts nothing (not even a separator or a deletion of a selection) and briefly shows **Didn't catch that**.

### Styles

Tap the ⋯ beside the mic to pick any health-advertised style plus Custom for the current editor. Chirp settings provide a default style and editable package-based overrides; matching uses `EditorInfo.packageName` exactly, and removed rows inherit the default. Initial defaults:

| Style | Packages |
|---|---|
| Chat | Slack, WhatsApp, Discord, Google Messages, Samsung Messages |
| Email | Gmail, Outlook, Samsung Email |
| Code | Termux and code editors (Acode, RHMsoft, Spck, DroidEdit) |
| Notes | Samsung Notes, Keep, Obsidian, Notion |

Styles missing from current health fall back to the selected default (or Default), and stay hidden when clean-up is unavailable — including an undisclosed external correction destination.

### Editable style prompts

**Clean-up styles** loads editable defaults from the authenticated `GET /v1/correction/profiles`. Every style shows its description; its prompt editor offers an **Edited** badge, a Unicode character count, the server's limit (at most 4000) and **Reset to default**. Fixed safety rules always apply. Existing Custom instructions migrate into Custom's prompt. Only edited styles send the optional `start.correction_prompt`; resetting omits the field so future server defaults apply. The legacy `correction_instructions` field remains limited to 2000 characters. Health caches only profile metadata, not default prompts. User edits are private app preferences excluded from backup; text and prompts are never logged. A server that does not yet expose the endpoint still supports normal styles; the editor then shows a retry action.

## Keyboard

### Typing

English (US) QWERTY, autocorrect at moderate confidence, suggestions, next-word prediction, auto-capitalisation, double-space period, key popups and symbol/accent long presses work out of the box. Personalised suggestions learn typed words on this device; turn them off in Keyboard layouts & settings → Text correction. Dictation finals bypass keyboard autocorrection and learning. The already-bundled English US dictionary is pinned to Codeberg, with an added English emoji suggestion dictionary; see [dictionary provenance and licenses](keyboard/UPSTREAM.md#english-typing-and-emoji-dictionaries-2026-10-17).

One-handed, split, clipboard history and emoji are reachable from the expandable toolbar. Light/dark follows the system.

### Keyboard look

Chirp settings → **Keyboard** has a **Keyboard look** chooser with a small preview of each option:

| Look | HeliBoard settings it writes |
| --- | --- |
| **Gboard-like** (default) | Rounded style, key borders on, *Dynamic* (Material You) colours day and night |
| **Samsung-like** | Rounded style, key borders on, user colour themes `Samsung-like` / `Samsung-like dark` |
| HeliBoard classic | Material style, no borders, Light / Dark (HeliBoard's own defaults) |
| HeliBoard rounded | Rounded style, borders, Light / Dark |
| HeliBoard Holo | Holo style, Holo White |

Every look is applied only through HeliBoard's existing theme preferences (`theme_style`, `theme_key_borders`, `theme_colors`, `theme_colors_night`, `theme_auto_day_night`) and its user colour themes; nothing in the vendored keyboard was changed for this. The Gboard-like look follows the wallpaper through Android's dynamic colours: neutral keys with gaps on a tinted background, accent-tinted Shift/Backspace/?123 keys, an accent Enter key and long-press hint labels. The Samsung-like look uses neutral white/grey (light) or charcoal (dark) keys, grey function keys and a blue Enter key. Both can be fine-tuned under Appearance, which also still offers every HeliBoard colour, style and background; when Appearance holds anything other than a preset, the chooser shows it as a custom look. Key height, number row, one-handed and split settings are unchanged.

The migration `chirp_keyboard_look_v1` runs once in `ChirpApplication`, next to the existing `chirp_keyboard_defaults_v1` / typing defaults. An install with no theme preference at all (fresh, or 0.5.x that never opened Appearance) switches to the Gboard-like look; any theme preference already written was chosen explicitly and is kept. Later choices are never overwritten.

The Chirp row takes its colours from the active HeliBoard theme instead of a fixed green palette. Idle it is transparent, so HeliBoard's own suggestion-row colour (or a background image) shows through, with the mic in the accent colour. Every other state tints the row, derived from the keyboard's background, text and accent so it suits the Gboard-like, Samsung-like and HeliBoard looks in light and dark:

| State | Row | Shows |
|---|---|---|
| Connecting | accent tint | loading indicator, *Connecting to your computer…*, stop |
| Listening | accent tint | live level bars, status, elapsed time (`0:12`, `0:12 · #2` on a long dictation's second segment), stop |
| Time limit near | accent tint | the time becomes a warning chip with the countdown in the status |
| Polishing | accent tint | ✦ *Polishing…*, style chip, loading indicator |
| Inserted / cleaned | neutral tint | ✓ *Inserted*, **Undo**, **Use raw** chips (five seconds, no hint sentence) |
| Prompts and errors | error tint | ⚠ message and one action pill (*Turn on*, *Pair computer*, *Retry*); *Computer offline* shows the muted mic |
| Phone recogniser | accent tint | the *on phone* chip next to the level bars |

The mic and stop button morph between a round and a rounded-square shape while the tint fades in (200 ms); with animations off (system animator scale 0) every change is instant and nothing animates. Text on each tint is held to 4.5:1 and the stop icon on its fill to 3:1 (`StripStatesTest`). Debug retention uses the error colours of the palette. The history button's open state is a tonal accent fill with a readable icon. Row height and key height never change between states, and every state keeps its content descriptions, one announcement per final and the spoken countdown.

### App colours

The setup app uses Chirp's own **Pond** palette by default. **App colours** (Chirp settings → Feedback & look) switches it to **Match wallpaper** (Android's dynamic colours). The same choice colours the floating mic panel and the in-keyboard history panel and toggle. Nothing else changes, and the keyboard keys always follow the **Keyboard look** above.

### Fold inner/cover layout

Unfolding keeps the cover keyboard's function-key arrangement in both looks: **Shift starts the third letter row, Backspace ends it, and Enter sits after the period at bottom-right** — instead of HeliBoard's tablet arrangement. Chirp seeds HeliBoard's phone functional layout once (migration `chirp_functional_layout_v1`); explicitly chosen global or per-language functional layouts remain yours. The number row defaults on at inner-screen widths (600 dp and wider; an explicit choice wins). Unfolded landscape defaults to split; cover layouts stay compact. See [Fold layout details](keyboard/UPSTREAM.md#fold-function-key-arrangement-2026-10-18) and the `fold-layout-*.png` before/after emulator captures in [docs/screenshots/android](../docs/screenshots/android).

**Larger mic** (Chirp settings → *Keyboard → Larger mic on the inner screen*, off by default): on screens ≥ 600 dp wide the suggestion row grows to 48 dp and the mic key widens to 56 dp. Without it the controls are at least 48 dp wide and as tall as HeliBoard's suggestion row (36–44 dp); all sizes are in dp, so large font scales do not shrink them.

### Swipe typing

HeliBoard's gesture typing needs a native decoder, and HeliBoard 4.2 ships none. It supports `System.load` of a user-supplied library (`JniUtils`, `LoadGestureLibPreference`), normally Google's proprietary `libjni_latinimegoogle.so`, with a SHA-256 check against a known release for each ABI. **Chirp must not bundle or download that file**, so no gesture library is bundled — but Chirp settings can load one you supply. Options reviewed (2026-10-18):

- **User-supplied library through HeliBoard's loader (implemented).** Same mechanism and checksums as HeliBoard's *Load gesture typing library*. You obtain the file and choose it; Chirp does not distribute, download or link to it. Quality matches Gboard's decoder, because it is that decoder.
- **HeliBoard's own open-source decoder** ([NLnet GestureTyping](https://nlnet.nl/project/GestureTyping/)): planned as a GPL drop-in for the same JNI interface. Gesture data gathering runs until November 2026; no release exists yet. Preferred future option — it would need no Chirp UI change beyond bundling it.
- **[CleverKeys](https://github.com/tribixbite/CleverKeys)** (GPL-3.0, fork of Unexpected Keyboard): an on-device CTC/transformer swipe model with ONNX Runtime (MIT), about 89% top-1 on its own English benchmark. Licence-compatible but a different keyboard: porting its decoder, model and ONNX Runtime into HeliBoard's batch-input path means several MB of APK and a separate maintenance burden. Not release-ready; needs an operator decision.
- **FlorisBoard `StatisticalGlideTypingClassifier`** (Apache-2.0, GPL-3.0 compatible): small and pure Kotlin, but FlorisBoard labels glide typing alpha, disabled by default; its quality does not justify replacing the option above.
- **AnySoftKeyboard** (Apache-2.0): separate architecture with widely reported accuracy problems. **FUTO Keyboard**'s decoder uses the Source First licence, which is not open-source compatible — rejected.

**Enable swipe typing** (Chirp settings → Keyboard → Swipe typing):

1. The card explains that Chirp has no built-in swipe typing, that a compatible library is usually Google's `libjni_latinimegoogle.so` from a GApps package, that Chirp never downloads or includes it, and that using it is your choice under that library's own licence. It names the ABI the phone needs (`arm64-v8a` on the Fold).
2. **Add gesture library…** opens the system file picker. The file is copied privately (64 MB limit) and checked: an ELF shared object for this ABI, then SHA-256.
3. A matching checksum shows **Verified gesture library**. Anything else shows **Unknown library**, with the start of its hash and a warning, and needs an explicit **Use anyway**. A wrong ABI or a non-library file is rejected and deleted.
4. Chirp installs the file exactly where HeliBoard's loader expects it (read-only `files/libjni_latinime.so`, checksum in `lib_checksum`) and restarts, because native code loads once per process. HeliBoard's Gesture typing settings then appear.
5. When the library is active, the card offers a **Swipe to type** switch and **Remove gesture library**. A file that fails to load is reported, with a Remove action.

**Personal build with the library built in.** To skip the import, build your own APK with the library packaged: `./gradlew assembleRelease -Pchirp.gestureLib=/path/to/libjni_latinimegoogle.so` (the arm64 file; the build refuses anything but HeliBoard's known arm64 SHA-256). It goes in as `lib/arm64-v8a/libjni_latinimegoogle.so`, which HeliBoard's loader picks up at start (`System.loadLibrary`), so swipe typing works on first launch and the card shows **Built into this build of Chirp** with the **Swipe to type** switch. A library you added earlier still loads first and can be removed; the built-in one then takes over. **Never publish or share such an APK** — it contains Google's proprietary code; published builds and release smoke stay library-free. The library is 64 KB-aligned, so the 16 KB alignment gate passes.

The card warns that the library runs inside Chirp with Chirp's permissions, including network access — use only a file from a source you trust — and that a user-supplied library may not be built for 16 KB memory pages and so can fail to load on Android 15+ devices that use them (Chirp's own packaged libraries are checked for 16 KB alignment at every build). Release smoke still asserts that no `libjni_latinimegoogle` file is packaged.

### Keep your keyboard

Choose **Keep my keyboard** at first launch or in **Settings → How you dictate**. The floating mic stays off until you explicitly enable **Chirp floating mic** in Android Accessibility. The guide explains what Chirp can see before opening that service’s own details page (or the Accessibility list if unavailable).

Chirp reads only the focused editable field locally to insert text safely. Password and disabled fields get no bubble; a field Chirp can't fill shows the bubble with a clipboard badge, and your words wait to be copied. The floating mic does not work in every app; selecting Chirp does not redirect Samsung Keyboard’s or Gboard’s own microphone. Only dictated audio goes to your own computer. Idle capture, network activity and timers are absent. Recording uses a microphone foreground notification.

If Android blocks a sideloaded app, return to Chirp and expand **Did Android say “Restricted setting”?** Open app info, tap **⋮ → Allow restricted settings**, confirm your screen lock, then try Accessibility again. The menu appears only after a blocked attempt, and varies by phone; managed phones may disallow it. Advanced Protection can prevent activation or turn the service off. Chirp explains this and offers its keyboard or continuing without the mic. Notes and Scratchpad remain available.

- **The bubble.** A 48 dp mic docked to the screen edge appears only when a text field you can dictate into has focus. It hides on focus loss, a window change, the lock screen, password and disabled fields, and while Chirp Keyboard is the input method (it has its own mic).
  - **Tap** opens the panel and starts dictating. **Hold** (250 ms) is push-to-talk with the Ripple and a one-line preview beside the bubble; release stops.
  - **Drag** moves it; it snaps to the nearer edge and remembers the height for each screen (cover and inner, portrait and landscape). A drag never opens the microphone.
  - Drop it on the **✕** that appears at the bottom to hide it in the current app until you leave that app.
  - With TalkBack, double tap dictates, and the actions menu has **Move to other side** and **Hide in this app**.
- **The panel** shows Connecting, Listening (live words with the Ripple), Finishing or Polishing, then **Inserted**. After clean-up, **Use raw** swaps in your exact words for 5 s.
- **Nothing you say is lost.** If the field changed, focus moved, the app refused the text, or the field can't be filled automatically (a clipboard badge on the bubble says so in advance), the words wait in the panel under **Ready to copy**.
  - **Copy** puts them on the clipboard, marked sensitive. Samsung's clipboard history may still keep a copy.
  - **Open in Scratchpad** opens them there, handed over in memory only.
  - **Done** discards them.
  - Chirp never copies on its own. The words are cleared on Done, ✕, screen off, or after 2 minutes.
- **Errors carry one fix each:** Pair computer, Allow (the microphone), Check again (Computer offline), Turn on (Tailscale), or Use Quick dictate if Android blocks the microphone there.
- **Limits.** Not every app exposes its text field to Accessibility. Rich editors and some WebViews may only offer Ready to copy. Writing with `ACTION_SET_TEXT` drops the other keyboard's composing state.

Design notes on this and the other input paths are in [docs/android-input-options.md](../docs/android-input-options.md#c-accessibility-floating-microphone).

### Quick dictate

Notes and the Scratchpad tile already work with any keyboard. A dedicated Dictate-to-clipboard tile, Speak-button handler and widget are planned separately; this setup change does not add them. Input-path decisions and sources are in [android-input-options.md](../docs/android-input-options.md).

## In-app hardware keyboard shortcuts

Android lists the **Chirp** group in the system **Meta+/** helper. Commands apply to the visible screen; note controls require an open note. These mirror iPad's Command shortcuts with Ctrl on Android.

| Action | Android | iPad |
|---|---|---|
| New note | Ctrl+N (Notes) | ⌘N |
| Focus search | Ctrl+F (Notes / History) | ⌘F |
| Record / Stop open note | Ctrl+Shift+R | ⌘⇧R |
| Pause / Resume recording | Ctrl+Shift+P | ⌘⇧P |
| Edit / Done | Ctrl+E | ⌘E |
| Start / Stop dictation | Ctrl+Enter (Scratchpad) | ⌘Return |
| Cancel dictation / close sheet | Esc | ⌘. / Esc |
| Copy result | Ctrl+Shift+C (Scratchpad) | ⌘⇧C |
| Use raw, while offered | Ctrl+Shift+Z (Scratchpad) | ⌘⇧Z |
| Notes / History / Settings | Ctrl+1 / 2 / 3 (app shell) | ⌘1 / 2 / 3 |

The separate keyboard shortcut **Ctrl+Alt+Space** still toggles dictation in other apps; Esc cancels. The in-app commands never start a recording from History or Settings.

**Private session** in **Settings → Privacy & history**, the keyboard's **⋯ Dictation options**, or the floating panel's **⋯** excludes new dictations from history and learning, and sends no learned items. A small lock **Private** chip marks the strip and panel. It is off by default and ends when the screen locks, after **1 hour**, or if the app process exits. Existing history, notes, clean-up, and the connection to your computer retain their settings.

Time-limited **Use raw (4s)** and **Undo (4s)** actions count down with tabular digits. TalkBack receives a stable availability description once; the changing digits are silent. Quick dictate shows time while its automatic-close timer runs; interaction cancels that timer, so the retained action no longer has a countdown.

## Scratchpad

A place to dictate long-form text outside any text field, edit it, then **Copy** or **Share** it. It uses the same streaming client, pairing and clean-up as the keyboard (`DictationStream`, `StreamTransport`, `PcmCapture`), so dictation behaves identically: tap the big mic to start, tap again to finish, and errors offer the same **Pair computer**, **Open mic settings** and **Check Tailscale** actions.

![Scratchpad idle](../docs/screenshots/android/scratchpad-idle-light.png) ![Listening](../docs/screenshots/android/scratchpad-listening-light.png) ![With text (dark)](../docs/screenshots/android/scratchpad-text-dark.png)

- **Open it** from the small mic button beside **Record** in Notes, the launcher icon's long-press shortcut **Scratchpad**, or a **Quick Settings tile**. Add the tile once: swipe down twice, tap the pencil/Edit button, and drag **Scratchpad** into the panel. Tapping it collapses the shade and opens the Scratchpad (on a locked phone it asks for your screen lock first, because the pairing needs the unlocked phone).
- **Dictate:** each final is placed at the cursor, or replaces the selection, with a space where needed and a lower-cased first word when it continues a sentence. The opt-in **spoken commands** setting ("new line", "new paragraph") applies here too. The text is read-only while you dictate; edit freely otherwise.
- **The page** is blank and borderless, with **Copy** and **Share** in the top bar and **Save as note** and **Clear** in ⋮. The style choices sit as one connected group above the large mic (Ripple rings while listening, Stop in red).
- **Style picker:** **Raw** or any clean-up style the computer offers. It applies to this screen only and never changes the keyboard's own setting; it is hidden when the computer has clean-up off.
- **Memory only, unless you save it.** The text lives in the screen's view model: it survives rotation and folding, and is gone when you leave the Scratchpad (back, swipe away or the system closes it). **Save as note** puts it in the [notes library](#notes) as a new note. Nothing is written to preferences or files, the Recents thumbnail is blank, and the clipboard copy is marked sensitive where Android supports it. While [Dictation history](#dictation-history) is on is each dictation (not the text in the box) also saved, encrypted, exactly like keyboard dictations; the screen says so while it is on.
- Switching apps mid-dictation discards that utterance; one you already stopped keeps finishing and its text is still added. For a meeting or anything longer, use [Notes](#notes).

## Notes

A notes library on the phone: choose **New note** in the library toolbar (or **Ctrl+N**) to type locally, without a paired computer or microphone permission. A blank note opens in the editor as **Untitled note** and keeps itself in the library. Or tap **Record**, talk for as long as the meeting lasts, and the computer turns what was said into Markdown notes (headings, bullets, `- [ ]` tasks, **Decision:** and **Question:** lines) while the transcript fills in. Every note keeps itself (there is no Save step) and stays until you delete it. It is the Mac's Live Notes design ([mac/README.md](../mac/README.md#live-notes)) on the same server endpoints.

![The library on the cover screen](../docs/screenshots/android/notes-library-cover-populated-light.png) ![A note recording, pinned above the library (dark)](../docs/screenshots/android/notes-library-cover-recording-dark.png) ![List and note side by side on the inner screen](../docs/screenshots/android/notes-library-inner-detail-light.png) ![Kept audio playing from the transcript, on the emulator](../docs/screenshots/android/emulator-notes-kept-audio-playing.png)

- **Keyboard shortcuts.** **Ctrl+N** creates a blank typed note, including while another note records. **Ctrl+Shift+R** separately starts/stops recording; **Ctrl+Shift+P** pauses/resumes it in the note.
- **The library.** Notes are listed most recently modified first, grouped **Today**, **Yesterday**, **Previous 7 days**, **Previous 30 days**, then by month. Each row has a serif title, the time, a two-line snippet and a meta line with the length, the number of open to-dos and a mic mark when it has kept audio. The note that is recording sits in its own **Recording** section above the groups, with the Ripple, a live timer and a frozen preview; a note recovered after a crash is marked **Recovered**. A title you give wins forever; otherwise it is the first heading, else the first meaningful line, else the date.
- **Layout.** On the Fold's inner screen (600 dp and wider) the list and the open note sit side by side (`ListDetailPaneScaffold`); on the cover screen and phones a note opens over the list and Back returns. On wide landscape windows the transcript is a third pane; elsewhere the **Transcript** chip on the note opens it in a sheet.
- **Find and tidy.** The docked **Search notes** bar searches titles, notes and transcripts and highlights matches, saying "No matches" apart from an empty library ("Your notes will live here"). Swipe a row to delete it, with **Undo** in the snackbar; long-press to select several. A deleted note waits 30 days in **Recently Deleted** (⋮ → **Recently Deleted**, with **Restore**, **Delete permanently** and **Empty Recently Deleted**, which asks once). A note that is recording can't be deleted until it stops.
- **Open it** from the **Notes** tab, the launcher icon's long-press shortcut **Notes**, or the **Notes** Quick Settings tile (add it like the Scratchpad tile; a tap opens Notes and starts recording, a tap while recording stops it, and the tile says **Recording** or **Paused**).
- **The note.** The notes are a rendered document, not Markdown source: headings, bullets (nested), numbered lists, to-dos with a box you tick (it writes `- [x]` back into the Markdown, as your own edit), bold, italic, `code`, quotes, and `Decision:` / `Question:` lines as quiet tinted callouts, on a reading column at most 680 dp wide. Structured text that arrives while recording fades in at the end; text above never moves, and the page follows the end only while you are already there. The top bar has the title (tap it to rename in place), the status (**Listening…**, **Paused**, **Organizing notes…**), **Edit** and **⋮**: **Organize**, **Undo organize**, **Structure notes**, **Auto-organize**, **Copy**, **Share**, **Export Markdown**, **Rename**, **Delete audio** (when it has kept audio; it asks first and shows the size in MB), **Notes settings** and **Delete** (into Recently Deleted, with **Undo**; disabled while the note is recording). Short outcomes ("Organized", a voice edit's refusal) float above the record control for a few seconds. The renderer is Chirp's own (`NotesBlocks`, no WebView, no links followed).
- **Editing.** Tap any line (or **Edit**) to edit the Markdown in place, at the line you tapped, with the syntax lightly styled; **Done**, ✓ or Back returns to the page at the same place. While editing, a bar above the keyboard toggles **Heading**, **Bulleted list** and **Checklist** on the lines you are on, and **Undo** steps back through your typing (until something else changes the notes).
- **Record / Pause / Stop**: the extended **Record** button starts a new note; on a finished note it reads **Continue**, which adds a quiet `Continued · <date>` divider and carries on the clock. If another note is recording, Chirp offers **Stop current and continue here** (or **Stop current and record**); only one note records at a time, and browsing other notes never stops it. While recording, a floating dock with **Pause** (or **Resume**), the Ripple with the elapsed time, and **Stop** in red. **Pause** lets the current segment finish and closes the microphone (the mic indicator goes off and the clock stops), but the notes keep updating from what was already said; nothing is frozen and no final pass runs. **Resume** continues the same notes on a fresh socket; if the computer cannot be reached it stays paused and says why. **Stop** works from paused too. The recording is cut into ordinary `/v1/stream` utterances at a pause after 12 s (0.3 s of quiet once past 30 s) and always at 45 s (`DictationSegmenter` with the Notes thresholds). At a cut capture swaps to the next socket at once (`FrameRouter`), which holds up to 12 s of audio until it is **ready**, and the old one finalizes in the background, so nothing is dropped and finals land in capture order even when a later one arrives first. The computer transcribes one utterance at a time, so the next socket becomes ready only once the old one's final frees the speech engine. Segments use the hidden `live_notes` clean-up style when the computer has it (only fillers and repeats go), otherwise the default style.
- **Live notes.** After each final (at most every 15 s, never while a segment is still finalizing) the open window goes to `POST /v1/notes/structure` and the answer replaces only the AI-owned **tail** of the notes. The notes stay editable while recording: typing before the tail just shifts it; editing inside it makes it yours, and the next answer starts a new tail after it. An answer that arrives while an input method is composing, or while you are typing in the tail, waits until you stop (at most 10 s). Unstructured speech shows as a quiet italic **Hearing** line at the end of the page. A rejected window is retried in halves and quarters; a part that still fails becomes an editable `_Not structured — see transcript_` block.
- **Organize** structures any raw blocks you have not edited and then reorganizes the trailing sections with `POST /v1/notes/reorganize`. Every result is applied only if the notes are unchanged since the request ("Notes changed while organizing — try again" otherwise), and **Undo organize** restores the text from before it. **Auto-organize** runs the same pass on its own after about 1200 new characters, 3 minutes and 15 s without typing, and once at Stop. A `busy` server (one notes generation at a time, shared with the Mac app using the same server) means "retry after the next segment", never an error.
- **Edit by voice** (when the server has `POST /v1/notes/edit`; otherwise the button is hidden). Beside the record control, **Hold to edit**: hold it, say what to change ("go to the top and clean that up", "remove the bit about pricing", "change Friday to Thursday"), let go. A quick tap latches it instead (**Tap to send**, with **Cancel** beside it), and TalkBack's double tap does the same. While Notes is recording, the notification has a **Command** action too (it becomes **Send** while listening), so it works from the lock screen. What you say goes to its own `/v1/stream` socket with raw speech and never into the transcript: while recording, capture is diverted to the command from the moment you press (held until its socket is ready) and goes back to a fresh notes socket after it, so no notes audio is dropped; otherwise the command opens the microphone itself and closes it after (leaving the screen drops such a command). A command ends by itself after 20 s. The words are the instruction for `/v1/notes/edit`, which runs in the same one-at-a-time slot as structuring, ahead of it, once the segment before the command is in. The scope is the lines you have selected, else the whole notes, else (past 3500 characters) the trailing sections that fit. The answer is applied only if the notes are unchanged since the request (any typing, or an input method composing, gives "Notes changed while editing — try again"), as one change with an **Edited · Undo** chip for 20 s. It is applied to the notes at once even with the screen off (the editor catches up when it is back). Refusals say why: "Can’t add new content by voice — ask to remove, move, tidy or reword", "Couldn’t tell what to change — try naming the section", "Couldn’t edit notes (rejected: dropped_unasked)". The words and the notes are never logged.
- **Label speakers** (on by default; an explicit off stays off; ⋮ on a note, or Settings → **Notes**). Who said what: the transcript starts each person's turn with a coloured chip, **Person 1**, **Person 2**…, numbered in the order they first speak. After **Stop**, **Who was speaking? → Name speakers** opens one sheet for everyone (a dialog on the Fold’s inner screen), also available from the transcript header and chip menu. Each row has a name field with suggestions from saved voices first, then recent local notes, a **Remember voice** checkbox (on by default when the server library is enabled), a first-turn sample (playable when audio was kept), and **Same as ▸**. **Done** applies all names with one **Also replace names in the notes (N places)** toggle; **Cancel** discards changes. Tap a chip to **Rename** them ("Maya" replaces "Person 2" everywhere in this note: the transcript, what structuring reads, and the export; it can also replace the old name in the notes text). The dialog suggests the same saved and recent names as **Name speakers**, and offers **Remember voice**, on by default only when the server’s library is on. The menu can also say they are the **Same person as** someone else (when the computer split one voice in two), or **Separate** a merge again. Structuring then reads `Name: …` lines, so owners come out as `- [ ] **Maya** to send the spec`. The server tells the voices apart ([server/README.md](../server/README.md#speaker-labels)): the first labelled note downloads the pinned speaker model automatically. Recording starts immediately; an inline status offers **Turn off**, or **Retry** if the download fails. Turning labels off cancels an in-progress download (requires a server with the cancel action). Labels start on segments opened after the model is ready. Settings refreshes the model state and offers **Remove speaker model**; an older server disables the switch with an update hint. Each turn has a chip menu with **This turn is… → Person N / New person** to correct only that turn. Names, merges and turn overrides are saved with the note and used by the transcript, raw/Markdown export, structuring and kept-audio speaker samples. Naming remembers a voice in your computer’s shared library after 20 seconds of speech; shorter voices are retried as more segments arrive in that note. A first-time notice explains this and offers **Don’t remember voices**. In a later note a recognised name has a **✓**; **Not X** returns to Person N and suppresses that match for this person, without changing the saved voice. The chip menu also offers **Update X’s saved voice**. Settings → Notes → **Saved voices** lists the server library, with Rename, Forget, Forget all and a server-wide **Remember voices of people I name** switch. Turning it off stops saving and recognising on all paired devices, with a choice to keep or forget existing voices. A server without saved-voice support shows an update hint and hides Remember voice. Phones keep no local voiceprint library. Kept audio still plays per segment.
- **Transcript**: the **Transcript** chip opens it in a sheet (a third pane on wide landscape windows): one line per segment with its time as quiet metadata, **Show raw** for the text before clean-up, and `⚠︎ audio not transcribed (reason)` for a segment that failed. A failed segment rolls on to a fresh socket; three failures in a row stop the recording and keep everything already captured.
- **Screen off and other apps.** While recording or paused, a microphone foreground service shows **Chirp Notes is recording** (with the running time) or **Chirp Notes is paused**, with **Pause**/**Resume** and **Stop** that work from the notification shade and the lock screen without opening Chirp. The notification never carries notes or transcript text. Back keeps the recording going in the background; tap the notification to return. Android asks once for notification permission; without it the recording still runs but the notification and its buttons are hidden.
- **Structure notes** is on by default when clean-up runs on the computer. If the computer's clean-up uses another host, it is off until you turn it on, and the switch names the host. With clean-up off on the computer, or an older server, Notes is a plain editor beside the live transcript.
- **Copy**, **Share** and **Export Markdown** export Markdown: a `# ` title (the name you gave it, else `Notes — <date>`), the notes, `---`, then `## Transcript`. **Share** sends it to any app that takes text (Keep, Obsidian, Docs…); **Export Markdown** writes a `.md` file wherever you pick in the system file picker (Downloads, Drive, an Obsidian vault folder). Exporting makes a copy; the note stays in the library.
- **Battery saver** (on by default; **Save battery while the screen is off** in Settings → **Notes**, or ⋮ → **Notes settings** on a note). With the screen off or Notes behind another app, the phone stops drawing: no editor updates, no live partial line, no level meter and no once-a-second clock. Recording, the transcript, the computer's structuring and reorganize, the library writes and the notification all carry on, so the notes are current the moment you look; the notification says **Battery saver** meanwhile. Chirp takes no wake lock of its own: the microphone foreground service and Android's audio capture keep it running. Each session adds a content-free line under Chirp settings → About → **Diagnostics → Notes sessions** (minutes recorded and with the screen off, segments, gaps, notes calls, screen updates run and skipped, and the **last problem** as a status or server code, such as `structure: auth` or `segment: Chirp server is busy`). The battery run is in [docs/android-device-acceptance.md](../docs/android-device-acceptance.md#6-notes-battery).
- **Kept on this phone** (Settings → Notes → **Keep notes on this phone**, on by default; an earlier explicit opt-out is kept, with an **Enable notes library** action). One sealed file per note (`files/notes/<id>.bin`) and a sealed `index.bin` for the list, under their own Keystore key in credential-encrypted storage, excluded from backup and device transfer, never indexed by app search. There is no cap; explicitly created typed notes are kept even while blank. An untouched recording placeholder is not kept. **Delete notes older than** is Never by default, or 1 year, 90 days or 30 days, its own setting apart from dictation history. A file that cannot be opened is moved to a quarantine folder, never deleted. Turning the switch off stops keeping new notes but never deletes the old ones; **Delete all notes** is a separate action.
- **Re-transcribe…** in a stopped note’s menu or transcript header sends kept clips to the current paired Chirp server only after a consent sheet shows duration, clip count, destination, models, clean-up and retention warnings. Gap rows have **Try again**; long-press a kept segment for a single-clip run. **Allow re-transcribing** (Settings → Notes, on by default) hides these actions and cancels a run when off. AAC is decrypted and decoded in memory, then streamed as 16 kHz PCM with no previews or new speaker labelling. Results apply atomically, preserving names, manual turn assignments, title and notes body. **Undo** and **Restore previous transcript** swap the one sealed previous version, including after reopening. Optional **Also rebuild the notes** starts off; it uses the existing structure windows, asks before replacing concurrent edits and provides **Notes rebuilt · Undo**. Cancelling discards staged results; process death leaves text unchanged and shows an interrupted notice once. Runs continue while the process lives, without a foreground service. Older servers show an update message and receive no audio.
- **Kept audio** (Settings → Notes → **Keep audio with notes**, off by default) keeps each spoken segment as AAC-LC mono, about 32 kbps, sealed in the note's folder, with its offset, duration and sample rate. In the transcript each segment then has a play button and its row highlights while it plays ("Couldn’t play kept audio" if a clip can't be read). Settings shows the total with **Delete kept audio**; a note's ⋮ has **Delete audio**, which asks first, shows the size in MB and keeps the text.
- **Recovery copy** (Settings → Notes → **Keep a recovery copy until notes are saved**, on by default). While a note records, Chirp also keeps a sealed recovery journal of it (the notes, the transcript, the name and the elapsed time, never audio) under its own Keystore key, rewritten at most every 2 s and at once after a segment, an AI update or Pause/Stop. If Android kills Chirp, it crashes, or you swipe it away from Recents (which also stops a recording), the note comes back in the library marked **Recovered**, with no dialog, and **Continue** carries on the same notes and clock. Turning it off deletes the current copy. Nothing about the notes is logged, the Recents thumbnail is blank and the clipboard copy is marked sensitive.

## Dictation history

Dictation history is **on by default**, including upgrades where you never chose; an explicit off choice stays off. When enabled, committed finals (plus the raw text when on-computer clean-up rewrote them) are stored **on the phone only**, encrypted with AES-GCM under a dedicated Android Keystore alias (`chirp_history_v1`) in credential-encrypted storage — never sent to the computer, never logged, and excluded from backup and device transfer (`data_extraction_rules.xml` excludes the root, file and sharedpref domains). The store keeps at most **200 entries** and prunes by age: **1 day, 7 days (default) or 30 days**. Password and incognito fields (`TYPE_TEXT_VARIATION_PASSWORD` variants and `IME_FLAG_NO_PERSONALIZED_LEARNING`) are never recorded, and cancelled dictations leave no entry. While the device is locked the store is unavailable and the panel says so ("Unlock your phone to see dictation history.").

- **Keyboard**: a clock button sits next to the mic in the Chirp row. It opens an in-keyboard panel (over the key area, like HeliBoard's clipboard panel, so height and insets are unchanged). History is ready from first use. If you turned it off, the panel offers **Keep history on this phone**. Tapping an entry reinserts it through the same boundary and selection path as a dictated final; long-press offers **Copy**, **Insert raw** (when the entry was cleaned) and **Delete**. **Use raw** after a cleaned dictation updates the stored entry. Back or the keyboard button closes the panel; plaintext stays in memory only while the panel is open, and the keys are hidden from accessibility while it is up.
- **App**: the [History tab](#the-app-notes-history-settings) (search, day groups, detail with copy, copy raw, share and delete, swipe to delete with Undo, long-press **Add to latest note (“<title>”)** or **Save as new note**). Additions to an open or recording note go through its editor, so later autosaves keep them. Undo writes the entry back as it was; nothing is kept elsewhere meanwhile.
- **Settings**: Chirp settings → **Privacy & history → Dictation history** (and ⋮ → **History settings** in the History tab) has a **Keep dictation history on this phone** switch, the retention chooser, **Open history** and **Clear history**. Turning the feature off asks first and then deletes the file and the Keystore key.

A small pre-existing fix shipped with it: moving the cursor after a cleaned final used to dismiss the raw-undo chip but leave the "cleaned" notice pinned open forever, hiding the row's idle buttons. The notice now expires on its five-second timer.

## Learn from my edits

Settings → Dictation → **Learn from my edits** is on while history is on. After a verified insertion, Chirp Keyboard watches that same field for at most 60 seconds, until focus changes or the next dictation starts. The floating mic watches only its focused node. Only changes inside the inserted span count; unrelated edits, large rewrites, passwords, incognito editors and Private sessions are excluded. Floating-mic learning uses Android 13's editor-info access to honor the actual incognito flag, without changing your selected keyboard. It also excludes fields that disable suggestions. On Android 12 this editor-info access is unavailable, so floating-mic learning stays off; Chirp Keyboard learning works on every supported version.

Correct the same name or technical word twice to activate a vocabulary item. Lowercasing the first word or removing the final period twice teaches style for that app's package. **Learned** groups items by app, shows the source edit and Learning / In use / Off status, and offers Approve, Undo, Delete and Reset app. Undo keeps an item off even if the edit happens again. History detail → **Teach Chirp** lets you correct an entry and activate it once.

The store holds at most 200 items, AES-GCM sealed with its own Android Keystore key in credential-encrypted app storage, excluded from backup and device transfer. Clear history leaves learned items intact. Active terms and the target app's style and up to three examples are sent in versioned `start.learned` to your own server for keyboard, floating mic and Quick Dictate (Speak uses its calling package; clipboard sessions have no target app). Notes do not use learning. Conservative respellings and styles also work with clean-up off or an older server. Nothing is logged. An external clean-up host, if configured, receives this context like the transcript.

![Learned corrections in light mode](../docs/screenshots/android/learned-list-light.png) ![Learned corrections in dark mode](../docs/screenshots/android/learned-list-dark.png)

Run `android/scripts/e2e-all.sh --only learn` for the real-server dictation → edit twice → learned → next dictation check and light/dark Learned captures.

## Privacy

- **Dictation audio is transient; history is local and encrypted.** Dictation history is on by default; an explicit opt-out stays off. The other local stores are the notes library, opt-in kept audio, learned corrections and numbers-only diagnostics. No text, audio, URLs or tokens are logged; server error strings are never rendered into diagnostics. While the server runs with debug retention, a red **DEBUG: recordings kept on the server** banner stays visible in the Chirp row.
- **The mic opens only when you start dictation** (or **Record** in Notes, which shows a notification while it runs; **Pause** closes the microphone) and is released as soon as you stop. The floating mic declares the same rules in its accessibility description. Words it couldn't insert wait in its panel, in memory only, until you copy them or 2 minutes pass. It never copies on its own.
- **The phone's recogniser is opt-in and disclosed.** With *Use this phone's recogniser* on, an utterance dictated while the computer is unavailable goes to Android's on-device speech service, which belongs to Google or the phone maker. Android documents it as recognising on the device, but its own terms apply and Chirp cannot audit it. The **on phone** chip shows each time. Chirp adds no session timing for these utterances and logs no text or audio.
- **Speaker labels are on by default and keep no voiceprints.** With **Label speakers** on, each Notes segment asks your own server who spoke; it compares voices in its memory (forgotten after 6 idle hours or a restart) and with its shared saved-voice library when enabled, and returns turns and matched names, never a voiceprint. The phone keeps only the turns and the names you give, inside the sealed note. The server's pinned speaker model downloads automatically on first use; its size comes from server health. **Turn off** stops labelling and cancels a download; **Remove speaker model** deletes it from the server. Naming suggests names from the server’s saved voices and recent notes in the sealed local library. Named voices are saved only on your own server; Settings → Notes → Saved voices has the server-wide stop-storing switch and Forget controls. Nothing about voices, names or turns is logged.
- **Notes stay on the phone.** The **notes library** (on by default) keeps every note until you delete it, AES-GCM sealed under a Keystore key, excluded from backup and transfer, never indexed by app search, never logged and never sent anywhere except the text the computer structures. Optional **kept audio** (off by default) is sealed the same way next to its note. Re-transcription sends it only to the current paired Chirp server after confirmation, transcribes in memory there, and retains no server copy unless the disclosed debug retention is enabled. External clean-up receives text only. The recording note's recovery journal is sealed under its own key. **Delete all notes** crypto-shreds the library. Notes session timings are numbers only ([Notes](#notes)).
- **History is on by default and on-device.** Entries never leave the phone, are AES-GCM encrypted under a Keystore key, and are excluded from backup and device transfer.
- **Pairing secrets are encrypted at rest** (Android Keystore) and redacted from any `toString`. Pairing links are treated as secrets; they are parsed strictly and never logged.
- **Session timings are numbers only.** Each dictation on the keyboard records connect, ready, first-partial, stop → final and polishing milliseconds, audio length, outcome and error code, network type (Wi-Fi, cellular, Ethernet), whether a VPN was up and whether the prewarmed socket was used (ready latency is also split into warm and cold). The last 50 stay in a private, backup- and transfer-excluded file; Chirp settings → About → Diagnostics shows p50/p90 per metric and counts per outcome, with **Copy diagnostics** and **Clear timings**. Nothing else is stored: no text, audio, URLs, hosts, tokens or app names, and the serialized form holds only numbers, booleans and fixed enum names.
- **Crash diagnostics are bounded.** Chirp settings → About → Diagnostics shows/copies the last five local uncaught crashes: time, app version, exception class and at most 48 message-free class/method/line frames. The handler writes synchronously before delegating termination. It does not store exception messages, cause messages, filenames, thread names, text, audio, URLs or tokens. The private, backup-excluded log survives an app restart/update. HeliBoard's original crash handler and keyboard logger are disabled so they cannot retain a second content log.
- **Clean-up disclosure.** Styles stay hidden when clean-up is unavailable, including an undisclosed external correction destination; external correction always requires explicit opt-in and shows its host.

## Troubleshoot

Chirp settings → About → **Diagnostics** shows the session timings and the bounded crash log, and **Copy diagnostics** copies both (see [Privacy](#privacy)). The real-device checklist is [docs/android-device-acceptance.md](../docs/android-device-acceptance.md). Common messages on the suggestion-row status bar:

| Bar message | What it means | What to do |
|---|---|---|
| "Pairing refused — pair again in Chirp settings" | Server `auth` error | Re-pair from setup (**Pair computer**) |
| "Didn't catch that" | Empty/blank final or server `bad_audio` | Speak again; nothing was inserted |
| "Speech engine hiccup" | Server `engine` error | Retry; check `chirp-server doctor` on the computer |
| "Chirp server is busy — try again" | Server `busy` (engine occupied) | Retry after a moment |
| "Dictation limit is 120 seconds" | Server `too_long` (a keyboard dictation is cut well before it) | Update Chirp; split long dictations elsewhere |
| "Clean-up prompt too long — shorten it in Chirp settings" | Server `bad_request` on the prompt | Edit the style prompt |
| "Speech engine unavailable — try again" | Unknown server error | Retry; check the server |
| "Chirp server took too long — try again" | Final timed out locally | Retry; check the computer's load |
| "Computer offline · Check again" (mic drawn with a slash) | The last health check or prewarm failed in the past 30 s | Tap the mic or the row: it re-checks for up to 3 s, then dictates or names the reason |
| "Can't find your computer on the tailnet — is it online?" | DNS lookup of the pairing host failed | Check Tailscale on the phone; check the computer is online and signed in to the same tailnet |
| "Computer may be asleep, or Chirp isn't running" | Connect timeout or refused connection, or no Ready within 7 s | Wake the computer; check Chirp is running (see the Mac tip below) |
| "Couldn't make a secure connection to your computer" | TLS handshake or certificate error | Check the pairing URL is the computer's `tailscale serve` HTTPS address; re-pair if it changed |
| "Connection too slow — try again" | Transport stalled | Check Tailscale (**Check Tailscale**) |
| "Connection lost — kept what I heard" (or another reason) | The socket dropped, the server errored or timed out after partials arrived | The last partial was inserted as plain text; tap **Undo** to remove it |
| "Kept what was heard" after Polishing… | Clean-up failed, timed out (12 s) or the socket dropped | Raw text was inserted; edit the style or check the computer |
| "Listening on phone…" / "on phone" chip | *Use this phone's recogniser* is on and the computer is unreachable | Expected; the text is recognised on the phone, raw. Turn the setting off to keep dictation computer-only |
| "Phone has no offline speech for this language" | The on-device recogniser lacks a language pack | Download the language in the phone's speech/voice-input settings, or dictate with the computer |
| "Phone recogniser failed — try again" (or "…is busy") | The phone's speech service errored or didn't finish within 5 s of stop | Retry; anything already heard was kept |
| "Unlock your phone to see dictation history." | History store is credential-encrypted | Unlock the device |

**Notes.** The Notes screen names what went wrong under the editor, and Diagnostics → **Notes sessions** keeps it as **last problem** (codes only, never notes or transcript):

| Notes shows | What it means | What to do |
|---|---|---|
| "Notes stopped: Computer unreachable — is Tailscale on?" (or another reason) | Three segments in a row failed | Check Tailscale and the computer; **Record** continues the same notes |
| `⚠︎ audio not transcribed (reason)` in the transcript | One segment failed; recording rolled on | Nothing; the rest is kept |
| "Couldn’t update notes (code) — retrying with the next segment" | A structuring call failed (`auth`: pair again; `busy`: the server is generating; `timeout`, `http`) | Usually nothing; it retries |
| "Chirp on your computer is too old to structure notes — update it." | The server has no `/v1/notes/structure` (404) | Update Chirp on the computer |
| "Clean-up is off on your computer…" | The server answered `notes_off` (409) | Turn clean-up on in the computer's Chirp settings |
| "Couldn’t edit notes (code)" | A voice edit call failed | Try again |
| "Nothing to organize yet — keep going" | **Organize** on notes shorter than 80 characters | Record or type more first |

In 0.7.0 and earlier nothing spoken reached Notes against a real Mac ([#134](https://github.com/araa47/chirp/issues/134)): each cut waited for the next socket to be ready, which the Mac (one utterance at a time) only allows after the previous segment's final, so every cut timed out and the session stopped with "Mac unreachable". A notes call could also fail as `http` on a kept-alive connection the Mac had just closed; such calls now go again once on a fresh connection. In 0.7.1 a segment still became a gap when Pause, a voice command or the next cut came before its socket was ready (its stop now waits for Ready), or when the Mac took more than 5 s to get to it (a Notes socket's send queue now holds the whole 12 s pre-ready buffer).

**Mac tip:** on the Mac, turn on System Settings → Battery → Options → *Wake for network access* and let Chirp launch at login, so the phone can reach it while the Mac is idle.

**Offline mic.** Failure reasons come from exception classes only (no messages, hosts or URLs are kept) and are worded as possibilities, since Android sees the symptom, not the cause. A failed health check or prewarm marks the computer offline for 30 seconds: the suggestion row shows **Computer offline · Check again** and the mic is drawn with a slash, with TalkBack reading "Computer offline, double-tap to retry". ✕ or typing hides the row; the slash stays until the computer answers or 30 seconds pass. Tapping never waits: it re-checks health for at most 3 seconds, then dictates, or shows the specific reason; a second tap during the check dictates at once. A computer that answers over HTTP (even with an error) is not offline. **Tailscale is off** keeps priority over this row. Dictation gives up on a computer that is not Ready within 7 seconds (the pre-Ready buffer holds only 5 seconds of audio).

Recoverable errors also offer **Pair computer**, **Open mic settings** and **Check Tailscale** actions. With a tailnet pairing and no VPN up, the row shows **Tailscale is off** with **Turn on** instead (see [Tailscale off when the keyboard opens](#tailscale-off-when-the-keyboard-opens)). A historical note: a reproducible 0.5.1-era crash (`NetworkOnMainThreadException` during TLS teardown on stop/keyboard-hide) was fixed by moving all HTTP cancellation, pool eviction and dispatcher shutdown to one process-wide background queue — see the [validation record](#051-stop-crash-fix-2026-10-17). If an editor disconnected during the raw composing-region replacement, older builds could crash; all editor calls in `ComposingSession` now fail safely without exposing editor exceptions, losing the corrected text on a rejected replacement, or allowing late callbacks to insert into another field (lifecycle coverage: final, repeated utterances, hide/unbind/destroy, stale capture/transport callbacks, cancel and raw expiry). The first regression test for that crash failed before the fix; the original installed emulator crash buffer was empty, which does **not** establish that the operator's phone hit that same exception.

## Develop and test

### Toolchain (once)

```sh
android/scripts/setup-toolchain.sh   # user-scoped; no sudo, no emulator images
```

Installs Zulu JDK 21 and the Android SDK (platform-tools, android-37.2, build-tools 37.0.0) under `~/.local/share/chirp-android/` (override with `CHIRP_TOOLS`/`ANDROID_HOME`) and writes `~/.local/share/chirp-android/env.sh`, which exports `JAVA_HOME`, `ANDROID_HOME` and `PATH`.

### Build and unit tests

```sh
source ~/.local/share/chirp-android/env.sh
cd android
./gradlew lint testDebugUnitTest assembleDebug assembleRelease
```

Use the **existing** `keystore/local-debug.keystore` to sign updates; never generate a replacement key for an already-installed app. The keyboard module builds both ABIs, but the app splits packaging (`splits.abi`, no universal APK): every build yields an `app-arm64-v8a-<build>.apk` for phones and an `app-x86_64-<build>.apk` for x86_64 emulator validation, under `app/build/outputs/apk/{debug,release}/`. Release smoke installs whichever split matches the connected emulator's ABI (the local `chirp-fold` AVD reports `arm64-v8a` on Apple Silicon). Each assemble also runs `check<Build>Native16kAlignment` (`scripts/check-native-alignment.py`): every packaged `.so` must have only 16 KB-aligned ELF `PT_LOAD` segments and the APK zip layout must satisfy `zipalign -P 16`, because Android 15+ devices may use 16 KB memory pages. The host and library use NDK 28.0.13004108 (NDK r28 aligns by default); the app setting is needed to strip JNI symbols. App lint remains strict (warnings as errors); only the vendored keyboard's `lint*Analyze*` tasks are disabled (upstream lint crash — see [Upstream](#upstream)). See [keyboard/UPSTREAM.md](keyboard/UPSTREAM.md) for the pinned source, license, adapter, upstream patch and vendor-only lint workaround.

Robolectric runs on API 31 and 37 with fake input connections, transport and capture. `ScratchpadTest`, `ScratchpadTileTest` and `ScratchpadRenderTest` cover the Scratchpad states, share/copy intents, tile and shortcut wiring, and assert that no file or preference holds dictated text (the `scratchpad-*.png` screenshots come from the render test). `NotesDocumentTest`, `NotesRecorderTest` and `NotesScreenTest` cover Notes with fake sockets, microphone and notes calls: the rolling hand-off (the next socket is ready before the swap, every frame lands once, finals commit in order), failure gaps and the three-failure stop, structuring and reorganize application rules (applied only to unchanged notes, held while composing, split on reject, `busy`/409 handling), the foreground service and its notification, and light/dark cover/inner renders (`notes-*.png`: idle, recording, command, edited, paused, editing, and the cover's transcript view). `NotesBlocksTest` covers the Markdown renderer (headings, lists, to-dos, callouts, inline spans, block keys), ticking a to-do back into the Markdown, the formatting bar and editor undo; `NotesPageTest` drives the rendered page (no Markdown source on screen, tick a to-do, tap a line to edit, the overflow menu, the transcript view). The integrated keyboard renders actual HeliBoard keys and the production Chirp row in idle/listening/final states, light/dark, under `../docs/screenshots/android/`. Existing transport tests use isolated TLS loopback servers. LiveServerTest stays opt-in (`-Pchirp.live.url` …); no production Chirp server or port 7821 is used by the default check.

The Robolectric renders write to `app/build/screenshots/`, so an ordinary test run never touches the committed PNGs. To refresh `docs/screenshots/android/` after a visual change, run `./gradlew testDebugUnitTest -Pchirp.updateScreenshots` and commit only the images your change affects; the renders are not pixel-stable across runs (ripple and anti-aliasing), so the rest show small differences.

### Mandatory release smoke

Run `android/scripts/emulator-smoke.sh` with the toolchain sourced after every change. It builds and installs the minified release APK split matching the emulator's ABI, clears only the authorized disposable emulator's Chirp data, walks state-aware setup, opens/backs out of the real Google QR scanner, opens the native editor, checks keyboard/mic/recovery/options, and exercises actual HeliBoard keys: `teh` → `the` (sentence-cased at field start), `im` → `I'm`, next-word suggestions, clipboard history and emoji. It checks inner and cover layouts in both themes, unfolded landscape split, one-handed reachability, settings/diagnostics, packaged dictionary hashes, absence of debug assets/proprietary glide libraries and the Chirp crash buffer. Failure exits non-zero. Every ADB call uses the shared emulator-only serial guard: `ANDROID_SERIAL` or `--serial`, matching `emulator-<port>`; physical devices are refused. The default is `emulator-5580`. It changes no phone, Mac configuration, production server or Tailscale state.

A tiny shell-only UiAutomator probe reads all accessibility windows because Android 17's stock `uiautomator dump` returns the editor window without the IME (`scripts/build-ui-probe.sh` builds it under a temporary directory from `UiHierarchy.java`, pushes it to the disposable emulator and removes it in cleanup; it ships in neither APK). Real release captures are `docs/screenshots/android/release-*.png`, each under 2 MB (the keyboard, typing and TalkBack captures from before the redesign were removed; see [the screenshot notes](../docs/screenshots/android/README.md)). Release has no synthetic capture source or emulator cleartext policy.

### Emulator speech checks (debug only)

Use a disposable **read-only** `chirp-fold` instance on your own free even port. Set `ANDROID_SERIAL=emulator-<port>` or pass `--serial emulator-<port>`; every emulator helper shares the same physical-device refusal guard (default `emulator-5580`). Never select another session’s instance. The speech helper uses a throwaway HOME and cached model on `--server-port` (default 7899), deep-link pairing and debug-only synthetic audio. It suppresses credential-bearing output and removes test credentials afterward.

`--keepkb-check` verifies the fresh choice, disclosure, service-details and app-info deep links, returned-off help, enable/resume, pairing without changing Gboard, Settings switching and picker, and bubble hiding with Chirp selected. It saves/restores Accessibility settings and the default IME. Run `emulator-talkback.py --keepkb-check` for the actual TalkBack radio-card contract. The debug-only `EditorProbeActivity` supplies plain, password, unsupported and WebView fields, plus clipboard/recognizer length reports. It never ships in release. Restricted sideload blocking, Advanced Protection enrollment and One UI policy require [device acceptance](../docs/android-device-acceptance.md).

It then runs the floating mic bubble checks (`emulator-bubble-check.py`; `--bubble-check` runs them alone, with Gboard, the service, synthetic speech and pairing set up for you). They cover:

- show and hide, a drag that never starts the microphone service, and the dropped position kept per posture;
- dictation inserted at the caret, and Use raw after warmed clean-up;
- a field changed while finishing ending in Ready to copy with a sensitive clip;
- copy mode handing the words to the Scratchpad, and the WebView outcome;
- the custom TalkBack actions, Allow (microphone revoked) and Check again (server stopped).

After every case it asserts no foreground service, recording client or crash. Captures go to `docs/screenshots/android/emulator-floating-*.png`. Run `emulator-talkback.py --bubble-check` on the release APK for the bubble under actual TalkBack.

```sh
source ~/.local/share/chirp-android/env.sh
python3 android/scripts/emulator-check.py \
  --python /path/to/chirp/server/.venv/bin/python \
  --model-dir /path/to/cached/parakeet-mlx \
  --apk android/app/build/outputs/apk/debug/app-x86_64-debug.apk
```

| Flag | Runs |
|---|---|
| *(none)* | Debug synthetic-speech E2E |
| `--tls` | HTTPS/WSS on 7899 with the disposable debug CA |
| `--stop-check` | The eight-scenario stop matrix (all stop/teardown paths, incl. crash checks) |
| `--learn-check` | Two edit windows, Learned activation, real-server `start.learned` application, sealed store, light/dark list |
| `--history-check` | Dictation-history flow (default-on, reinsert, Insert raw, ciphertext check) |
| `--notes-check` | Live Notes: the synthetic asset on a loop through Notes' own microphone path; fails unless three segments reach the transcript and structured notes reach the editor while recording (90 s each), then Pause, Resume and Stop |
| `--speakers-check` | Speaker labels alone (the notes check runs them at its end): a two-voice synthetic asset (two `say` voices), **Label speakers** on by default with automatic model preparation and inline status, two distinct people in the transcript, naming in the sheet and from a chip saves voices on the throwaway server, kept-audio replay, a new note automatically names them with ✓, Update voice, and Not X suppression. Needs the speaker model: `CHIRP_SPEAKER_MODEL=/path/to/voxceleb_resnet34_LM.onnx` or `chirp-server model fetch --speakers`; it is copied into the throwaway HOME (the server runs offline) |
| `--cleanup-only` | Managed clean-up E2E only |
| `--frames-only` | Uninstrumented frame metrics (no recording/polling during speech) |
| `--expect-crash` | Pre-fix TLS baseline expecting `NetworkOnMainThreadException` |
| `--server-root PATH` | Use another server checkout (default: the repo's `server/`) |
| `--tls-dir PATH` | Root for the debug CA/key (default `android/app/build`) |

Reproduce the TLS stop matrix after building debug (requires `openssl` for the generated test cert):

```sh
source ~/.local/share/chirp-android/env.sh
python3 android/scripts/emulator-check.py --stop-check --tls \
  --python /path/to/server/.venv/bin/python --model-dir /path/to/cached/parakeet-mlx \
  --apk android/app/build/outputs/apk/debug/app-x86_64-debug.apk
# Omit --tls for HTTP. To check old behaviour, create a disposable detached worktree
# at a31415b^ and add --server-root /path/to/old-worktree/server.
```

The debug-only test cert/key is generated under `app/build/` (`generated/chirp-debug-res/raw/emulator_ca.pem` and `emulator-tls/key.pem`; 7-day CA, renewed near expiry, SAN restricted to `10.0.2.2`/`127.0.0.1`), with trust restricted to `10.0.2.2`; the private key stays on the host. The matching cert is bundled in debug only.

The debug test-step switch **Debug: synthetic speech (no microphone)** selects a say-generated 16 kHz mono WAV (in Notes and its voice commands it repeats with 4 s of silence between, like a meeting). The asset is generated into `app/build/`, never committed. On macOS the debug build invokes `say`/`afconvert`; other hosts may set `CHIRP_SYNTHETIC_WAV` to a generated synthetic-only WAV. This file source, switch and asset are excluded from release. The release capture uses AudioRecord only. The debug cleartext policy permits only `10.0.2.2`; URL validation further restricts HTTP to port 7899. Release permits HTTPS only and has no cleartext exception.

Emulator screenshots are independent of the deterministic Robolectric renders. Neither run establishes Galaxy hardware microphone quality, battery cost or Tailscale latency; those still need operator acceptance on the phone.

### TalkBack, icons, fold captures, battery

```sh
android/scripts/build-ui-probe.sh                    # rebuild the shell probe first
python3 android/scripts/emulator-talkback.py         # enables real TalkBack, validates mic/status/cancel
                                                     # labels and native click/long-click, restores settings
python3 android/scripts/emulator-icons.py            # captures release-launcher-icon.png,
                                                     # release-app-icon-settings.png, release-keyboard-picker-icon.png
python3 android/scripts/emulator-fold-layout.py --look samsung   # (or gboard) fold-layout-*.png captures
android/scripts/battery-session.sh                   # operator-driven battery session → docs/bench.md row
```

`make-icons.swift` regenerates the launcher/notification icon resources from the approved artwork — sources, deterministic packaging and asset paths are in [artwork/chirp-icons/README.md](artwork/chirp-icons/README.md).

## Upstream

- **Source**: HeliBoard v4.2 stable (checked 2026-10-17), pinned at commit `0c60dffb03a4e2e7a37cb82210f5299f93c03979`; `keyboard/upstream/` is the complete vendored release source archive, not a submodule.
- **License**: HeliBoard is GPL-3.0 (with AOSP Apache-2.0 code and separately licensed assets). The combined Android app includes GPL-3.0 HeliBoard code. Personal use; corresponding source is available in this repository. Keep the upstream licenses/notices intact. See [keyboard/UPSTREAM.md](keyboard/UPSTREAM.md).
- **Patches**: every upstream change is marked **CHIRP** and recorded in `keyboard/patches/chirp.patch` — host hooks, disabled crash reporter and keyboard logging, in-process voice availability, voice-key touch handling, number-row/fold defaults, accessibility refresh, split-layout cache fix.
- **Dictionaries**: `main_en-US.dict` and `emoji_en.dict` from the Codeberg-pinned [aosp-dictionaries](https://codeberg.org/Helium314/aosp-dictionaries); SHA-256s are tabulated and smoke-checked. See [dictionary provenance](keyboard/UPSTREAM.md#english-typing-and-emoji-dictionaries-2026-10-17).
- **Lint**: AGP 9.4.1/Kotlin 2.4.21 lint crashes on one upstream file; only the vendored library's `lint*Analyze*` tasks are disabled (reports kept). The Chirp app lint stays strict.
- **Icons**: app-level overlays replace HeliBoard's icon IDs; sources and packaging are in [artwork/chirp-icons/README.md](artwork/chirp-icons/README.md).

## Validation records

Dated records of what was actually run, per feature, with the APK sizes of the day. The earliest full record (0.3.0) is [docs/android-keyboard-validation.md](../docs/android-keyboard-validation.md).

### Round 4 typing release (2026-10-17)

The full `lint testDebugUnitTest assembleDebug assembleRelease` path passed: 175 tests, 0 failures/errors, 2 pre-existing opt-in skips. Release smoke passed scanner open/back, state-aware setup, actual autocorrect/next-word keys, clipboard, emoji, the integrated mic and recovery, inner/cover light/dark, unfolded landscape split, one-handed control reachability, settings/diagnostics and crash checks. `emulator-talkback.py` additionally enabled actual TalkBack and validated mic/status/cancel labels and native click/long-click actions before restoring the settings. Debug synthetic E2E passed against the isolated real Parakeet server with Keystore pairing, live composing text, repeated committed finals, cancellation, quick options, normal typing after dictation, light/dark and IME retention; the throwaway server was stopped. It does not claim live speech transport over HTTPS from the release build — the release APK uses AudioRecord, and smoke validates its UI without a live HTTPS speech session or the debug synthetic/cleartext facilities. Release APK: **26,684,648 bytes (25.45 MiB)**, containing arm64-v8a and x86_64. The English US dictionary added **0 bytes** because the pinned file was already bundled; the new emoji dictionary is 45,272 bytes before APK compression (21,095 packaged bytes). The typing/defaults phase added 25,068 bytes relative to the pre-typing UX release build (26,659,580 bytes). Its screenshots were real release-emulator captures, each below 2 MB; they showed the pre-redesign strip and were removed in the redesign docs sweep. No phone, production server, Mac app or Tailscale setting was used or modified.

### 0.5.0 clean-up, styles and streaming (2026-10-17)

`./gradlew lint testDebugUnitTest assembleDebug assembleRelease` passed with **198 tests, zero failures/errors, two opt-in skips**. Tests cover protocol metadata and editable prompts, TLS bearer requests, omission/reset/migration, Unicode limits, exact package mapping, prewarming/expiry, coalescing, suffix edits with a real `BaseInputConnection`, stable-prefix rollback, cancellation, polishing fallback, readable transitions and reduced motion.

Managed cleanup E2E passed against a real Parakeet/Qwen server on **7899** with a temporary HOME, `[correction] mode="managed"`, and the shared offline HF cache. The helper was warmed before UI captures to exclude first-use model/Metal setup; the app still has its normal 12-second polishing deadline. The capture helper requires `ffmpeg` to keep the exported recording below ten seconds. The debug asset used messy synthetic speech generated under `app/build/`; no audio is committed. Both themes captured underlined raw composition, Polishing + style, cleaned + Use raw, and native accessible raw replacement. The test removes its server, credentials and device probes and re-selects Chirp after force-stop. Reproduce with `--cleanup-only` (or `--frames-only` for the uninstrumented run) in the [emulator speech check](#emulator-speech-checks-debug-only) command.

Release `scripts/emulator-smoke.sh` and actual `emulator-talkback.py` also passed on **emulator-5580 only**. Release remains AudioRecord-only and HTTPS-only; live managed speech was exercised through the debug synthetic/cleartext path. APK: **26,716,080 bytes (25.48 MiB)**, version **0.5.0 (6)**, arm64-v8a and x86_64, signed with the existing local key.

Artifacts under `../docs/screenshots/android/`:

- `emulator-cleanup-{polishing,cleaned,styles}-{light,dark}.png` — actual emulator states (removed in the redesign docs sweep; they showed the pre-redesign strip).
- `emulator-cleanup-streaming.mp4` — a silent 9.54-second screen recording (10-second capture cap).
- `emulator-cleanup-gfxinfo.txt` — recorded run: 194/199 janky frames, p50 85 ms.
- `emulator-cleanup-uninstrumented-gfxinfo.txt` — no capture/polling during speech: 161/170 janky frames, p50 133 ms.
- `emulator-release-typing-gfxinfo.txt` — ordinary release typing baseline: 83/95 janky frames, p50 32 ms.

These measurements do **not** establish smooth 60 fps. The authorized AVD has `hw.gpu.enabled=no`; ordinary typing is also substantially janky, and its host concurrently runs ASR/cleanup. The source recording averages about 14.9 fps. GPU-backed device validation remains necessary to assess animation smoothness. The emulator's GPU configuration was not changed. No phone, production Chirp configuration/server, Mac app, LaunchAgent or Tailscale setting was modified.

### 0.5.0 launcher and themed icons

The release uses the operator's **full-bleed moonlit pond bird** artwork. The adaptive icon has that complete composition as its background, navy overscan to keep the moon and bird inside the safe viewport, and an empty foreground (the explicitly approved fallback). No rounded tile is added; the launcher supplies its own mask. Legacy density variants use the same opaque source, with resource aliases sharing normal/round names. App-level overlays replace HeliBoard's icon IDs, including the About/settings icon, and the IME service references the new launcher mipmap explicitly. Android 13+ monochrome uses the selected round fin-bird glyph **with** waves. The floating microphone notification uses the **same original alpha without the detached waves**, retaining its eye/pupil, fins and feet. The exact supplied sources, deterministic packaging script and asset paths are documented in [artwork/chirp-icons/README.md](artwork/chirp-icons/README.md). Built-in imagegen cutout attempts were discarded; generated replacements do not ship.

The full lint/unit/debug/release path passed with **202 tests, zero failures/errors, two opt-in skips**. Icon tests on API 31/37 verify application and IME service icon resolution, HeliBoard's resource overlay, visible orange bird/yellow moon under the adaptive mask, monochrome availability and notification alpha. Release smoke passed after the icon update. `scripts/emulator-icons.py` also passed on emulator-5580, leaving Chirp selected, capturing `release-launcher-icon.png` (actual app drawer), `release-app-icon-settings.png` (actual Android app-info icon) and `release-keyboard-picker-icon.png` (native picker; this Android build uses text-only rows, while the IME's icon metadata is verified by the API tests). Signed release APK: **26,949,136 bytes (25.70 MiB)**, still **0.5.0 (6)**. App lint retains warnings-as-errors; two narrow icon-style exceptions cover the v26 vendor-overlay qualifier and deliberately full-bleed legacy artwork.

### 0.5.1 stop-crash fix (2026-10-17)

The phone's crash was TLS teardown on the main thread. A minified baseline built from `2c9c2e8` (the Android implementation also present at `a31415b`), with only the emulator TLS trust setup and version metadata changed, reproduced it on **emulator-5580**. Both `adb logcat -b crash` and the app's Diagnostics recorded:

```text
android.os.NetworkOnMainThreadException
  ConscryptEngineSocket.drainOutgoingQueue → ConscryptEngineSocket.close
  okhttp3.internal.connection.RealConnectionPool.evictAll → ConnectionPool.evictAll
  KeyboardDictation.start$lambda$9 (KeyboardDictation.kt:267)
  DictationStream.event$lambda$0 (DictationStream.kt:91)
```

The R8 debug mapping (`app/build/intermediates/mapping/debug/minifyDebugWithR8/mapping.txt`, R8 9.4.24) confirms the synthetic callback and source line. TLS `close_notify` writes explain why earlier cleartext speech checks passed. The same synchronous pool eviction was called on keyboard hide and through setup/style-editor client disposal.

All HTTP call cancellation, pool eviction and dispatcher shutdown now use one process-wide background queue. Cancellation snapshots the outgoing session's calls before enqueueing, so late cleanup cannot cancel calls created after an immediate keyboard hide/show. WebSocket close/cancel stays asynchronous. Health, pairing and profile HTTP requests already run on `Dispatchers.IO`; their lifecycle cancellation/disposal now also leaves the main thread. Debug builds enable StrictMode network detection with `penaltyDeath`.

An empty/blank final cancels the utterance's composition, inserts nothing, and briefly shows **Didn't catch that**. Stopping capture before the first frame is a normal completion. `bad_audio`, `engine`, `busy`, `too_long`, `auth`, `bad_request` and unknown errors have bounded local messages (see [Troubleshoot](#troubleshoot)); auth keeps the Pair computer recovery action. Regression tests cover these messages, empty results before and during polishing, repeated stop/cancel/focus-loss callbacks, and main-thread pool eviction.

`./gradlew lint testDebugUnitTest assembleDebug assembleRelease` passed: **217 tests, zero failures/errors, two opt-in skips**. The stop matrix passed with real cached Parakeet and managed Qwen cleanup, throwaway HOME and port **7899** only:

- Current server over HTTP: all eight cases plus in-app Diagnostics.
- Current server over TLS: all eight cases with clean logcat and crash preferences.
- Pre-`a31415b` server (`2c9c2e8`) over TLS: all eight cases plus in-app Diagnostics, including a zero-frame stop returning `bad_audio` rather than an empty final.
- Cases: stop before Ready with zero audio frames, listening, after a partial, during polishing, repeated stop taps, stop/hide, stop/focus loss, and stop/IME unbind.

The harness delays Ready and the first synthetic frame for the immediate case, holds final delivery briefly to observe real managed polishing, and waits for each server session to retire. These controls affect only debug capture and the disposable test server. No audio, transcripts, credentials or TLS private keys are committed. Content-free baseline/fixed crash evidence is stored outside git under `/tmp/chirp-stopcrash-{baseline,fixed}/`. Reproduce with `--stop-check --tls` as shown in [Develop and test](#emulator-speech-checks-debug-only).

Release artifact inspection confirms no synthetic source, cleartext exception, emulator trust certificate or private key. `scripts/emulator-smoke.sh` passed the signed minified release on **emulator-5580 only**, including setup/scanner, typing/autocorrect, clipboard, emoji, Fold layouts/themes, mic recovery, settings and Diagnostics with no Chirp crash. Chirp was reselected after force-stops. Release was **0.5.1 (7)**, **26,950,788 bytes (25.70 MiB)**, arm64-v8a and x86_64, signed with the existing local development key.

### 0.5.1 clean-up default follow-up (2026-10-18)

Clean-up now defaults **on** after pairing with an available **on-Mac** correction server. The `correction_explicit` flag records a user's toggle independently of the legacy `correction` boolean: an untouched 0.5.0 `false` no longer hides the feature after upgrade. Explicit OFF persists across refreshes and restarts. Setup, keyboard settings and the mic menu record choices; changing haptics or the debug overlay does not. External correction still requires explicit opt-in and a known host. Availability drops or correction-destination changes suspend correction until the user enables it again. A server reporting correction off always produces `correction=false` on start, even after an earlier explicit ON. Setup places Clean-up and styles directly below the paired Mac/engine, explains that local cleanup polishes punctuation/filler words without text leaving the Mac, and shows **Mac has clean-up off** when unavailable. External correction retains its destination disclosure.

The full `lint testDebugUnitTest assembleDebug assembleRelease` path passed: **235 tests, zero failures/errors, two opt-in skips**. New coverage includes local/external defaults, legacy preference migration, explicit OFF, privacy/availability transitions, server-off start frames, visible controls and independent toggle callbacks. The real managed TLS stop matrix passed all eight scenarios on **emulator-5580**, without enabling correction in the harness: every observed start frame carried `correction=true`, and managed polishing ran with clean logcat and in-app Diagnostics. The signed minified release UI smoke also passed. Live speech/start-frame checks use debug's isolated TLS trust; release retains system trust only. The AVD was run as a disposable read-only instance at port 5580 after stale AVD locks blocked normal startup. No physical device or production server was used. Signed release APK at that point: **26,950,808 bytes (25.70 MiB)**; no APK was published.

### Fold inner-screen layout (2026-10-18)

Fold-layout validation: `lint testDebugUnitTest assembleDebug assembleRelease` passed (256 cases, zero failures/errors, two opt-in skips). Forty release screenshots cover before/after, both looks, light/dark, native AVD, inner portrait/landscape and cover portrait/landscape. Key geometry checks passed; cover and native-AVD coordinates remain unchanged. Release `emulator-smoke.sh` and the TLS stop matrix (`emulator-check.py --tls --stop-check`) passed on emulator-5580 only. All eight stop scenarios delivered STOP and retired their stream, with clean Chirp crash/Diagnostics checks under StrictMode network death. The disposable server reported `engine` during polishing and `bad_audio` during focus teardown; the matrix checks stop/teardown safety rather than correction quality. No phone or emulator-5582 was used, and the version remained **0.5.2 (8)** at that point.

### Dictation history (2026-10-18; released as 0.6.0)

Unit coverage (Robolectric): encryption round-trip with software keys, tamper/corrupt file discard, retention pruning, the 200-entry cap, opt-in gating, password/incognito exclusion, clear-on-disable (including a record racing the disable), used-raw updates, insert boundary logic, panel states, settings-screen search, and the notice-expiry regression (fails without the fix). `./gradlew lint testDebugUnitTest assembleDebug assembleRelease` passed on the merged branch: **285 tests, zero failures/errors, two opt-in skips**.

Emulator validation ran on **emulator-5582 only** (a second disposable read-only `chirp-fold` instance, used while emulator-5580 belonged to a parallel worker — the checked-in helper itself pins emulator-5580), debug APK with the throwaway TLS server on port 7899: `--history-check` drives the demo end to end — keyboard opt-in, synthetic dictation with clean-up, ciphertext check (no plaintext words on disk), erase and reinsert from the panel, long-press Insert raw, Fold inner/cover in light and dark, back-closes-panel, history-screen search, and turn-off-deletes-file. Screenshots landed in `docs/screenshots/android/` as `emulator-history-*.png` (removed in the redesign docs sweep, with the pre-feature baseline `history-before-keyboard-inner-{light,dark}.png`). Before that, the full `--stop-check --tls` matrix and the release smoke (`scripts/emulator-smoke.sh`) were re-run on this branch. No physical device or production server was used.

Reproduce after building debug, with the [emulator speech check](#emulator-speech-checks-debug-only) command plus `--history-check --tls` (on the authorized emulator-5580). The branch carried no version bump — still **0.5.1 (7)**, signed release APK **27,025,176 bytes (25.76 MiB)** — and was released as **0.6.0 (10)** with the history feature. No APK was published beyond the repository.

### arm64-only phone APK and 16 KB page gate (2026-10-23)

Release packaging splits by ABI (`splits.abi` in the app module; no universal APK, same version code for both outputs): every build produces `app-arm64-v8a-<build>.apk` and `app-x86_64-<build>.apk` under `app/build/outputs/apk/<build>/`, signed with the existing local key. Signed release sizes: arm64 **26,588,220 bytes (25.36 MiB)**, x86_64 **26,603,730 bytes (25.37 MiB)**. Native libraries are the only ABI-specific payload — compressed `libjni_latinime.so` (≈420 KB arm64 / ≈435 KB x86_64) plus `libandroidx.graphics.path.so` (≈4–5 KB) — so the phone APK saves **about 440 KB** against the equivalent dual-ABI build; the 0.6.0-era dual-ABI release measured 27,025,176 bytes. The keyboard module still compiles both ABIs.

Every assemble finalizes with `check<Build>Native16kAlignment` (`scripts/check-native-alignment.py`): every packaged `.so` must have only `PT_LOAD` segments aligned ≥ 16384, stored zip entries must be 4-byte aligned, and an uncompressed `.so` entry must sit on a 16 KB boundary (`zipalign -P 16` semantics). Both current libraries are NDK r28 builds (aligned by default) and are deflated in the APK (legacy packaging), so ELF alignment is the load-time gate. The swipe-typing card and this README warn that a user-supplied gesture library may not be 16 KB-compatible and can fail to load on Android 15+ 16 KB-page devices. `docs/android-input-options.md` marks Path A (voice subtype, auto-start, `switchToPreviousInputMethod`) retired and fixes the Chirp Keyboard naming.

`./gradlew lint testDebugUnitTest assembleDebug assembleRelease` passed on the rebased head (including #47): **366 tests, zero failures/errors, two pre-existing opt-in skips**, both splits built and both alignment checks green. (Lint's informational downgrade of the time-dependent `GradleDependency`/`NewerVersionAvailable`/`AndroidGradlePluginVersion` checks comes from main and covers the Gradle 9.8.2/OkHttp 5.5.1 releases of mid-October 2026.) Release smoke on **emulator-5580 only**: the script resolves the split by the emulator's reported ABI, and the local `chirp-fold` AVD reports **arm64-v8a** on an **Android 17 16 KB-page image** (`sdk_gphone16k_arm64`, page size 16384) — so smoke runs the app on a 16 KB-page system. The run installed the signed arm64 split and passed artifact inspection, the setup wizard, QR scanner open/back, mic permission and pairing actions, long-press options and the real-key typing checks (`teh`→`the`, `I'm`, next-word, clipboard, emoji) before flaking on the first Fold-loop settings cold start (60 s timeout on a contended host). Three later emulator starts crash-looped at QEMU startup (hanging `QEMU2 main loop` after Vulkan init, with and without software GPU); the only native crash in logcat was the system `android.hardware.uwb-service` aborting for a missing `/dev/uwb0`, never `dev.chirp`. The Fold inner/cover theme sweep, landscape split, one-handed reachability and settings/diagnostics screens were therefore not re-verified in this round, and with no x86_64 emulator on this host the x86_64 split was validated by build, the 16 KB gate and artifact inspection only. No phone, production server or Tailscale state was touched.

## Quick dictate, widget and sharing

Keep Gboard, Samsung Keyboard or any other keyboard selected. Settings → How you dictate → Other ways to dictate has **Add Dictate tile**, **Add Notes tile**, and **Add Widget**. Android 13+ shows a system add-tile prompt; older versions show “swipe down twice → Edit.” Launchers that support pinning show an Add Widget prompt; otherwise long-press the home screen → Widgets → Chirp.

The **Dictate** tile opens a bottom sheet and listens immediately. Stop finishes the utterance, copies it with the sensitive flag, and shows **Copied — paste anywhere**. **Use raw** re-copies the original when clean-up changed it; **Edit in Scratchpad** hands it over in memory. The panel closes after four untouched seconds following a final; touching it keeps it open. Leaving during capture or polishing cancels the utterance. A locked phone must be unlocked before pairing is read. The Scratchpad and Notes tiles retain their existing behavior.

The static 2×1 widget offers **Dictate** and **Record**; resize to 1×1 for Dictate alone. It never displays your words and has no periodic updates. Record opens Notes with its existing record action.

Apps’ **Speak** buttons can choose Chirp through Android’s recognizer chooser. Chirp returns one final to that app; it does not copy it. The server decides language, Activity results cannot stream partials, and an offline preference does not turn Chirp into on-device recognition. This does not replace the voice provider behind Gboard’s or Samsung’s own mic. [Contract and decisions](../docs/android-input-options.md#keyboard-free-entry-decisions-165--168).

**Share → Save to Chirp Notes** accepts plain text up to 100,000 characters. Save as new note uses the subject or first nonblank line as its title. While a note is recording or paused, Add to that note appends as your own edit. Shared text stays local; it is sent to the computer only if you later choose Organize. Cancel saves nothing.

The entry-point emulator matrix is `emulator-check.py --quickdictate-check --tls` (also included in `--keepkb-check`); `emulator-talkback.py --quickdictate-check` checks the new controls under TalkBack. Widget taps and resizing are covered with RemoteViews tests; launcher placement and Samsung clipboard history need [device acceptance](../docs/android-device-acceptance.md).

Verified on 2026-10-25 through `e2e-all.sh --only quickdictate release`: real synthetic speech, sensitive auto-copy/paste, raw replacement, Speak result/cancel/network error, Share saving, widget-provider discovery, Notes tile recording/stopping, release typing/layout smoke and actual TalkBack controls all passed in one read-only Fold session. The emulator was stopped and its host-wide lease released. Widget placement and Samsung clipboard retention still need the device steps above.
