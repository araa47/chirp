# Chirp for Android

The **Chirp** app (Notes, Scratchpad, history and settings) and **Chirp Keyboard**, a full HeliBoard keyboard for the Galaxy Z Fold with a microphone key that streams your voice to the `chirp-server` on your Mac — over Tailscale, from any app. Live text appears underlined in the focused field while you speak; the final replaces it. An optional clean-up pass on the Mac polishes the final text, and an opt-in history keeps recent dictations on the phone, encrypted.

The launcher, Settings → Apps and notifications call the app **Chirp**; Android's keyboard picker and keyboard settings list the input method as **Chirp Keyboard**. The application ID and IME component stay `dev.chirp.android` / `dev.chirp.android/.ChirpImeService`, so a signed APK installs as an **update** and preserves your pairing (the token is encrypted under an Android Keystore key). Current version: **0.7.3**, version code 15.

| At a glance | |
|---|---|
| Keyboard base | HeliBoard 4.2 (GPL-3.0), vendored and patched — see [Upstream](#upstream) |
| Looks | **Gboard-like** default, a **Samsung-like** option, three classic HeliBoard looks |
| Fold layout | Phone-style function keys on the inner screen, number row ≥ 600 dp, split landscape |
| Swipe typing | Not bundled; you can load a user-supplied library, or build it into a personal APK — see [Keyboard](#keyboard) |
| Clean-up | On by default after pairing when the Mac cleans up locally; external endpoints need explicit opt-in |
| History | Opt-in, on-device only, AES-GCM encrypted under an Android Keystore key |
| Retention | No audio and no dictated text written by default; unsaved Notes keep an encrypted recovery copy; diagnostics hold numbers-only timings and crash frames |

**Contents**

- [Install](#install) — build the APK, put it on the phone, update over Tailscale, enable the keyboard · [Pair](#pair) — QR, paste, Wi-Fi servers
- [The app](#the-app-home-notes-history-settings) — Home with the Mac's status, Dictate and Notes tiles; History; Settings
- [Dictate](#dictate) — start/stop/cancel, quick options, clean-up, styles, Undo, Use raw
- [Keyboard](#keyboard) — typing, looks, Fold layout, swipe typing, floating mic
- [Scratchpad](#scratchpad) — dictate long text, edit, copy or share; Quick Settings tile and launcher shortcut
- [Notes](#notes) — record a meeting or a long think-aloud into live Markdown notes beside the transcript
- [Dictation history](#dictation-history) · [Privacy](#privacy) · [Troubleshoot](#troubleshoot)
- [Develop and test](#develop-and-test) — toolchain, gradle, emulator harnesses
- [Upstream](#upstream) — HeliBoard, patches, dictionaries, license
- [Validation records](#validation-records) — dated runs, measurements and APK sizes

## Install

### Build the APK (once, on the Mac)

```sh
source ~/.local/share/chirp-android/env.sh   # toolchain; see "Develop and test"
cd android
./gradlew assembleRelease
```

The build produces two signed APKs in `app/build/outputs/apk/release/`: `app-arm64-v8a-release.apk` for the phone (arm64-v8a only) and `app-x86_64-release.apk` for emulator validation. Install the **arm64** APK on the phone — the ABI split makes it smaller than the former dual-ABI APK (25.7 MiB; measured sizes in [Validation records](#validation-records)). Signing uses `keystore/local-debug.keystore` (create it once with `scripts/make-keystore.sh`; without it the release build is unsigned). **Never generate a replacement key for an app that is already installed** — Android would refuse the update. Debug and release builds both use this local key.

### Put it on the phone

Install **as an update, without uninstalling Chirp** — that is what keeps the saved pairing. Either works:

- **Over Tailscale (Taildrop):** from the Mac, `tailscale file cp app/build/outputs/apk/release/app-arm64-v8a-release.apk <phone>:` — the file arrives as a notification in the phone's Tailscale app. Tap it to open the installer.
- **adb:** `adb install -r app/build/outputs/apk/release/app-arm64-v8a-release.apk` over USB or wireless debugging.

- **From your Mac, in the app (updates):** see [Update over Tailscale](#update-over-tailscale).

Opening a sideloaded APK can trigger a **Play Protect** screen warning about an unknown developer. Choose **More details → Install anyway** to continue. (A separate, optional sideload restriction can affect the floating microphone only — see [Optional floating microphone](#optional-floating-microphone).)

### Update over Tailscale

Once the first install is on the phone, later builds can update it in place from the paired Mac.

On the Mac, stage the signed arm64 release APK (`app-arm64-v8a-release.apk`, the phone split) and its manifest, then host that folder yourself at `/chirp-apk/` on the same tailnet host as the pairing (for example with your existing static file server behind `tailscale serve`; this script hosts and publishes nothing):

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

Onboarding is four full-screen pages with one job each and one primary button pinned at the bottom: *Welcome, Keyboard, Microphone, Pair your Mac*. A segmented bar at the top shows where you are; pages slide sideways (a cross-fade when animations are off) and back, including the predictive back gesture, returns to the previous page. It opens on the first unfinished page and advances by itself when you return from system settings. If the phone is already paired, as after an update, the welcome page is skipped; if everything is done the launcher opens the app's [Home](#the-app-home-notes-history-settings) directly, and keeps doing so once onboarding has finished, even if a requirement later lapses (Home then shows it).

1. **Welcome:** what Chirp is in one picture, phone → Mac, then **Get started**.
2. **Keyboard:** the button follows the next unmet requirement — **Enable Chirp Keyboard**, then **Select Chirp Keyboard**, then **Continue** — with an *Enabled* and a *Selected as default* check row. The Samsung path (Settings → General management → Keyboard list and default), personalised suggestions and swipe typing are behind **Samsung path and suggestions**.
3. **Microphone:** **Allow microphone**. The mic opens only when you start dictation and is released as soon as you stop; the details are behind **What Chirp keeps**. If you deny it, the page offers **Open app permissions**.
4. **Pair your Mac:** **Scan code**, or **Paste link instead**. A scanned code or a pasted link is tested and **saved automatically**, with no further tap; the page then shows *Connected · host* with the engine the Mac reports, and **Finish** opens Home. If the Mac can't be reached the page says so with one action (**Open Tailscale** when it is installed, otherwise **Try again**); an unavailable scanner offers **Paste link instead**. The pairing token is stored only after the Mac answers.

Home then shows a first-run **Try it** card: a real text field to type and dictate into, and **Choose keyboard**. **Dismiss** removes it for good. Renders: `docs/screenshots/android/onboarding-*.png` (light, dark, 200% font, and the pairing success, failure and connecting states).

### The app: Home, Notes, History, Settings

After onboarding the launcher opens the app: four destinations in a **navigation bar** on the cover screen and a **navigation rail** on the inner screen (from 600 dp wide; `NavigationSuiteScaffold`). Back pops within a tab (a settings page, a history entry), then returns to Home, then leaves. Opened from outside, from the keyboard's history link or **Chirp settings**, Back from that tab returns where you were.

![Home on the cover screen](../docs/screenshots/android/home-paired-cover-light.png) ![Home offline](../docs/screenshots/android/home-offline-cover-dark.png) ![History on the inner screen](../docs/screenshots/android/history-list-inner-light.png)

- **Home**: a greeting, the **Mac connection card** and two big tiles. The card uses the keyboard's states, most blocking first, each with one fix: *Not paired* → **Pair Mac**; *Microphone is off* → **Allow** (app permissions once Android stops asking); *Tailscale is off* (a tailnet pairing with no VPN up) → **Turn on**; *Mac offline* with the keyboard's reason (*Mac may be asleep, or Chirp isn't running*, …) → **Check again**; otherwise *Mac connected · host · engine*. It is re-checked each time Home comes back and when Tailscale connects, and TalkBack announces changes politely. **Dictate** opens the [Scratchpad](#scratchpad); **Notes** opens the Notes tab and says **Recording** while one runs. Below, **Recent** shows the last three dictations (tap one to open it in History, ⧉ copies it) when [history](#dictation-history) is on, or a one-line **Turn on** when it is off. On the inner screen Recent sits in a second column.
- **Notes** hosts the [Notes](#notes) screen. It is the same session as the Notes screen opened from the shortcut, tile or notification, so a recording started in one shows in the other. Back from the tab returns to Home and keeps the notes.
- **History**: a search bar, entries grouped by **Today**, **Yesterday** and **Earlier**, each with its app, age and whether clean-up changed it. Tap one for the text, the words **before clean-up**, the app and time, with **Copy**, **Copy raw**, **Share** and **Delete**: a bottom sheet on the cover screen, a pane beside the list on the inner screen. Swipe an entry either way to delete it at once, with **Undo** in the snackbar (TalkBack offers **Delete** as an action). The switch, retention and **Clear history** are behind ⋮ → **History settings**. When history is off or empty the tab says so with one button.
- **Settings** is Chirp settings, below.
- The whole app is excluded from Recents thumbnails. Renders: `docs/screenshots/android/home-*.png` (paired, offline, first run) and `history-*.png` (list, empty, off), cover and inner, light and dark.

### Chirp settings

One screen, **Chirp settings** (the Settings tab), holds every setting. Open it from the app, from HeliBoard → Keyboard layouts & settings (the Chirp section at the top is a summary: the connection row, the clean-up switch and **Open Chirp settings**), or from the keyboard's long-press **Chirp settings**. The top level is a list of groups; a row either toggles a switch in place or opens a page:

| Group | Contents |
|---|---|
| Mac connection | A status row (*Connected · host*, *Mac unreachable · host*, *Not paired*) opening the connection page: **Check connection**, **Change pairing**, **Allow Wi-Fi server access** (only when needed), **Forget pairing** (asks first: *You'll need the QR code to pair again*), and **When your Mac is unavailable** (the phone-local recogniser) |
| Dictation | **Clean-up** (only when the Mac offers it), **Styles** (default and per-app styles, prompt editing), **Stop dictation** (when I tap / when I pause), **Spoken commands**, **Press Send after dictating** |
| Keyboard | **Look** (keyboard look and App colours), **Swipe typing**, **Hardware keyboard shortcut**, **Larger mic on the inner screen**, **Layouts, languages & typing** (HeliBoard's own settings) |
| Feedback | **Haptic cues**, **Sound cues** |
| Privacy & history | **Dictation history** (switch, retention, open, clear), **Notes** (battery saver, recovery copy, keep notes on this phone and for how long) |
| Other ways to dictate | **Floating mic** (Accessibility) |
| About | **Updates**, **Diagnostics** (debug overlay, the report, **Copy diagnostics**, **Clear timings**) |

Back from a page returns to the list (predictive back); back from the list returns to Home (or leaves, when opened from the keyboard or HeliBoard). From 600 dp wide (the Fold's inner screen) the list stays on the left and the page opens on the right. Long explanations sit behind **Learn more**. Existing settings keep their stored values; nothing migrates. Renders: `docs/screenshots/android/settings-*.png`.

## Pair

On the Mac, open Chirp → Settings → Devices → **Pair a Phone…**, which checks Tailscale, publishes the server and shows the QR. Without the Mac app, print the secret pairing QR from the command line (see [server/README.md](../server/README.md#pair-a-device); the server must be published on your tailnet, e.g. `https://<your-mac>.<tailnet>.ts.net/chirp`):

```sh
uv run chirp-server pair --url https://<your-mac>.<tailnet>.ts.net/chirp
```

On the phone, onboarding's last page (*Pair your Mac*, or Chirp settings → Mac connection → Change pairing) — with Tailscale on, on both devices:

- **Scan code** is primary (the scanner uses Google Play services). **Paste link instead** works without it.
- A scanned code or pasted link is tested and saved straight away; nothing is stored until the Mac answers.
- A saved pairing shows the Mac host and the engine it reports, and offers **Check Mac connection** and **Forget pairing**.

The token is stored encrypted (AES-GCM) under the Android Keystore alias `chirp_pairing_v1`; pairing links are parsed strictly (`chirp://pair?url=…&token=…`, HTTPS only) and never rendered into logs. Recoverable connection problems offer **Pair Mac**, **Open mic settings** or **Check Tailscale** (which opens the Tailscale app when it is installed).

### Tailscale off when the keyboard opens

When the pairing points at a tailnet host (`*.ts.net`, `100.64.0.0/10` or `fd7a:115c:a1e0::/48`) and no VPN is applied to Chirp, the suggestion row shows **Tailscale is off** with a **Turn on** button. This check is local only, with no DNS lookup or network call. LAN or other pairings are never prompted.

- **Turn on** sends an explicit broadcast to the Tailscale app (`com.tailscale.ipn.CONNECT_VPN` to its exported `IPNReceiver`, the same hook Tasker-style automation uses). Tailscale connects only if you have already granted it Android's VPN permission and signed in. Chirp can't grant that permission or skip Android's consent dialog. Without it, Tailscale posts its own "open Tailscale" notification.
- The row says **Connecting Tailscale…**. When a VPN network appears it says **Tailscale connected** and reconnects to the Mac. If nothing connects within 10 seconds it offers **Open Tailscale**, so you can finish in the app.
- If Tailscale isn't installed, the row offers **Set up**, which opens Chirp setup's connection step.
- ✕, or typing past the prompt, hides it until Tailscale is next seen connected. Tapping the mic while Tailscale is off shows the prompt again instead of a generic *Mac unreachable* error.

Detection is conservative. It only knows whether *some* VPN applies to Chirp, because Android doesn't say which app owns another app's VPN. If a different VPN is active, Chirp shows no prompt, and a failed dictation still offers **Check Tailscale**. A successful Mac health check clears the prompt.

### Servers on your Wi-Fi (Android 17)

Android 17/API 37 needs `ACCESS_LOCAL_NETWORK` for servers reached directly over Wi-Fi/Ethernet. Chirp checks the paired server's resolved addresses and matching VPN routes in its network workers, never on the microphone press path. Setup requests permission only after a connection targets a local address outside a VPN. This includes RFC1918, link-local and local CGNAT/IPv6 addresses. Loopback JVM test servers are exempt.

**Needed only for servers on your Wi-Fi. Tailscale works without this permission.** Android explicitly excludes VPN traffic from its local-network definition, so an operator's `.ts.net` server resolving to 100.x through Tailscale is not permission-gated. Denial never prevents trying that tailnet connection. No DNS result or server address is added to diagnostics. Sources: [Android local-network definition](https://developer.android.com/privacy-and-security/local-network-definition) and [Android 17 permission behavior](https://developer.android.com/privacy-and-security/local-network-permission).

## Dictate

### Start, stop, cancel

- Tap the **mic in the suggestion row** to start. The mic changes colour and icon while listening, with a waveform and a subtle pulse.
- Tap the **stop icon** the mic becomes to finish and insert. **✕** discards the dictation.
- **Long press the mic** for quick options, a sectioned menu: a **Clean-up** switch (or *Mac has clean-up off*) with where the correction runs, a **Style** radio group of the styles the Mac advertises (*rewrites* beside those that may restructure; one choice closes the menu), and a **Chirp settings** row. TalkBack hears the switch and radio roles with their checked state. Long-pressing a history entry opens the same menu style (Copy, Insert raw, Delete).
- A configured keyboard **voice key** still supports push-to-talk: press-and-hold to talk, release to finish; a short tap toggles.
- Haptic cues fire on start, manual stop and successful insertion when haptics are enabled (they follow Android's system setting).
- **Chirp settings → Dictation → Stop dictation**: **When I tap** (default) or **When I pause** with a pause of 1, 1.5, 2, 3 or 5 s (2 s default). Pause mode is a port of the Mac's auto-stop: speech is judged against the room's own noise floor, so steady background noise never counts as talking; it never stops before you have spoken, and gives up after 10 s of silence. Tapping stop still works in both modes.
- **Long dictation**: the Mac accepts 120 s per utterance, so a keyboard dictation is cut into segments of at most 90 s, the way the Mac's Live Notes does it. A dictation shorter than 45 s is never cut. After 45 s the cut comes at the first 0.6 s pause (0.3 s after 70 s), and at 90 s the cut happens whatever you are saying. At a cut the microphone stays open and the next segment takes over at once, buffering until its own socket is ready, so no audio is dropped. The previous segment finishes in the background. Its final, cleaned on its own, is committed at the caret, and the next segment's live text continues right after it. Each segment lands in order, even if a later one finishes first. The live text pauses for a moment after a cut until the earlier segment lands. Each segment is its own history entry. There are no haptics, sound or TalkBack between segments; the word count is announced once at the end.
- **Time limit**: a dictation stops at 10 minutes. In the last 15 s the status adds **N s left** with one haptic tick (TalkBack hears it only at 15, 10, 5, 3, 2 and 1 s), and the dictation is finished and inserted like a normal stop.
- **Hardware keyboard** (Bluetooth or DeX): **Ctrl+Alt+Space** starts and stops dictation and **Esc** cancels while listening. Ctrl+Space is left to language switching. The keys are ignored in password fields and can be turned off in Chirp settings → *Keyboard → Hardware keyboard shortcut* (on by default). If a hardware keyboard has hidden the on-screen keyboard, the chord shows it so the status row and ✕ stay available.
- **Sound cues** (off by default; Chirp settings → *Feedback → Sound cues*): short generated tones for start, stop, inserted and error, played as touch-feedback-class audio and silent when the ringer is on vibrate or mute. They are separate from haptics and from the keyboard's key sounds. The start tone can be faintly audible in the first few milliseconds of a dictation.
- **TalkBack:** the status row is silent while listening, finishing and polishing. Each final is announced once — "Inserted, N words", or "Cleaned, Use raw available" while Use raw is offered — and the Use raw and Undo buttons do not announce a second time. A final that keeps only what was heard reads its own status instead.

The full keyboard always **stays selected after a final** — including when an old installation had the voice-only keyboard's auto-return enabled. (That auto-return is gone; the old voice-only implementation lives only in test sources and is not registered or shipped, and its historical preference now defaults OFF.) **Use raw** is offered for five seconds after a corrected final; moving the cursor or editing the field invalidates it.

### Press Send after dictating

**Chirp settings → Dictation → Press Send after dictating** (off by default): **Off**, **Always**, or **In chat apps only** (apps whose rule is the Chat style, editable under Per-app styles). Once the last words of a dictation have landed, Chirp performs the field's own editor action (`IME_ACTION_SEND`, `GO` or `DONE`), or sends an Enter key when the field has no action. The strip adds "· ↵ sent" to the status. It is the same setting as **Return** on the Mac and **Press Return after dictating** on iPhone; Android names it after Send because it runs the field's own action (a chat app's Send button), which a Mac or iOS keyboard cannot.

- Never in a password field, and never after a result that only kept what was heard, after the caret was moved away, or after an empty result.
- NEXT/PREVIOUS (they would move focus) and SEARCH are left alone.
- A multi-line field whose app says "no action" would take Enter as a newline, so only **Always** presses it there.
- A long dictation presses once, after its last segment. Undo is not offered after a send, since the field has already submitted the text.

### Mid-sentence casing and spoken commands

Finals (never partials) get a small local pass before they are inserted. When the text before the cursor shows a sentence under way (a word, digit, comma or semicolon, even behind a closing quote), the first word is lower-cased, so dictating *"And then we went"* after *"I woke up"* inserts `and then we went`. Field start, a new line, `. ! ?` and similar terminals, opening quotes/brackets, colons and list markers keep the capital. It is deliberately conservative: only common sentence starters (*and, but, so, we, the, it's, don't, …*) are lowered; "I" and its contractions, acronyms and mixed-case words (`NASA`, `GitHub`), and anything that could be a name (*Paris, Monday, Will*) are left as the Mac sent them. Other languages are left alone, and nothing changes if the editor can't show the text before the cursor.

**Spoken commands** are off by default (Chirp settings → *Spoken commands*). When on, a final that is exactly, or ends with, *new line* or *new paragraph* (any case, optional trailing punctuation) inserts one or two line breaks in place of those words, e.g. *"Okay, new line."* → `Okay,` + ⏎. The match is exact, so *new lines* or *a new line of work* are untouched, but a dictation that merely ends in the words does become a break. This runs on the phone after clean-up, so the Mac never sees the commands as text to polish. **Use raw** and dictation history keep the unmodified text the Mac returned.

### Dictated text is never lost

- **Undo** sits in the row for five seconds after every final, cleaned or not. It removes exactly what the dictation inserted, including the space Chirp added before it, and puts back any selection the dictation replaced. Typing, moving the cursor or starting another dictation ends the offer, like **Use raw**. After a long dictation, Undo and **Use raw** apply to the last segment only; earlier segments are already ordinary text.
- **Failures keep what was heard.** If the connection drops, the Mac reports an error (engine, busy, 120-second limit…) or a deadline passes after at least one live partial, the last partial is committed as plain text (no clean-up) and the row shows **Connection lost — kept what I heard** (or the reason, e.g. **Dictation limit is 120 seconds — kept what I heard**) with **Undo**. With history on, the entry is marked **partial**. **✕**, typing over a live dictation, hiding the keyboard and switching to another field still discard it. In a long dictation these discard only the segments that have not landed yet (the underlined text and anything still finishing); segments already inserted stay. A segment that fails keeps what it heard and never touches earlier ones. If an earlier segment fails, the dictation goes on. If the live one fails, the microphone stops and earlier segments still land.
- **Moving the cursor stops instead of cancelling.** Tapping elsewhere in the field while listening sends stop; later partials no longer touch the field, and the final replaces the underlined text where you spoke it while your cursor stays where you put it. If the app dropped the underlined text, the final is inserted at your new cursor instead. The same happens to a long dictation's segment whose live text was not shown yet (you moved the cursor in the moment after a cut).

### When your Mac is unavailable

Off by default: Chirp settings → **When your Mac is unavailable → Use this phone's recogniser** (greyed out when Android reports no on-device recogniser). When it is on and the Mac is known to be unreachable, a tap dictates one utterance with Android's on-device recogniser (`SpeechRecognizer.createOnDeviceSpeechRecognizer`) instead of the Mac. "Known to be unreachable" means the mic shows **Mac offline**, Tailscale is off for a tailnet pairing, or a Mac attempt failed before anything was heard for a reachability reason. A Mac attempt that fails that way hands over on its own, with the status **Mac unavailable · listening on phone**, so say it again. A TLS failure, or a failure after the Mac heard something, never hands over (what was heard is kept as usual). Password fields stay refused.

The status reads **Listening on phone…** and an **on phone** chip stays visible until the notice clears. TalkBack names the provider: the app label of the phone's on-device speech service (from Google or the phone maker), never Chirp's Mac engine. The text is inserted raw: no clean-up and no Use raw. Undo, spoken commands, casing and history (when on) work as usual. The phone's recogniser usually ends on a pause by itself; in *When I pause* mode Chirp asks it to use your pause, which some services ignore. Tapping stop waits at most 5 s for its result. ✕, hiding the keyboard, switching fields or typing releases the microphone at once. Design notes and the bundled-model (sherpa-onnx) evaluation: [docs/research/android-phone-fallback.md](../docs/research/android-phone-fallback.md).

### What you see while you speak

Partials appear only in the text field, underlined with a slightly dimmed tail (supplied as spans when the editor supports them); the suggestion row is replaced by the waveform, status, ✕ and stop. Partials are coalesced to one editor update per 16 ms (latest sequence wins). Editors that can verify their composing text receive only the changed suffix; UTF-16 surrogate pairs stay intact. A server `stable` prefix becomes normal committed text while the remaining tail composes. A final or cancel re-marks the whole utterance so clean-up replaces it atomically and cancel restores the selection.

Showing the keyboard prewarms the bearer-authenticated socket without sending `start` or capturing sound — but only when you are likely to dictate: you dictated in the last 10 minutes, or into this field's app in the last 24 hours. Otherwise the socket opens on press, and typing-only use pays no handshake. The policy (`PrewarmPolicy`) keeps timestamps for at most 16 app packages in memory only: nothing is written to disk, and no text, audio or app names reach logs or diagnostics. The health check on show runs at most once a minute (a failed check, a Tailscale reconnect or a tap on an offline mic still check at once). An unused warm socket closes after 30 seconds or when the keyboard hides. Capture still starts on press, before the server's `ready`, through a bounded buffer, so a cold press loses no speech; Chirp settings → About → Diagnostics shows `ready, warm` and `ready, cold` p50/p90 side by side. Reduced-motion settings disable the pulse, shimmer and transition animations.

### Clean-up

Clean-up asks the Mac to polish the **final** text only; partials always stay raw. After pairing it is **on by default when the Mac's correction stays on that Mac**; an external correction endpoint requires explicit opt-in and a known host. Your toggle is recorded (`correction_explicit`) and persists across refreshes and restarts; if the Mac loses clean-up availability or its correction destination changes, clean-up suspends until you enable it again, and a server reporting clean-up off always dictates with `correction=false`.

While it runs, the raw transcript stays underlined in the field and the row shows a ✦ **Polishing…** with an animated shimmer, the selected style chip and a loading indicator in place of the stop button; polishing stays readable for at least 450 ms even for very fast finals, and state changes fade over 180 ms. The final commits the cleaned text and shows a **cleaned** notice with a **Use raw** button for five seconds — one tap, exposed to TalkBack, invalidated by edits or cursor changes. Correction errors, disconnects and a 12-second polishing timeout commit the raw text with a **kept original** note. Recovery and error notices dismiss after five seconds to restore normal suggestions. An empty or blank final cancels the composition, inserts nothing (not even a separator or a deletion of a selection) and briefly shows **Didn't catch that**.

### Styles

Long press the mic to pick any health-advertised style plus Custom for the current editor. Chirp settings provide a default style and editable package-based overrides; matching uses `EditorInfo.packageName` exactly, and removed rows inherit the default. Initial defaults:

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

Chirp settings → **Keyboard → Look** has a **Keyboard look** chooser with a small preview of each option:

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
| Connecting | accent tint | loading indicator, *Connecting to Mac…*, stop |
| Listening | accent tint | live level bars, status, elapsed time (`0:12`, `0:12 · #2` on a long dictation's second segment), stop |
| Time limit near | accent tint | the time becomes a warning chip with the countdown in the status |
| Polishing | accent tint | ✦ *Polishing…*, style chip, loading indicator |
| Inserted / cleaned | neutral tint | ✓ *Inserted*, **Undo**, **Use raw** chips (five seconds, no hint sentence) |
| Prompts and errors | error tint | ⚠ message and one action pill (*Turn on*, *Pair Mac*, *Retry*); *Mac offline* shows the muted mic |
| Phone recogniser | accent tint | the *on phone* chip next to the level bars |

The mic and stop button morph between a round and a rounded-square shape while the tint fades in (200 ms); with animations off (system animator scale 0) every change is instant and nothing animates. Text on each tint is held to 4.5:1 and the stop icon on its fill to 3:1 (`StripStatesTest`). Debug retention uses the error colours of the palette. The history button's open state is a tonal accent fill with a readable icon. Row height and key height never change between states, and every state keeps its content descriptions, one announcement per final and the spoken countdown.

### App colours

The setup app follows the wallpaper through Android's dynamic colours by default, so it matches the Gboard-like keyboard. **App colours** (Chirp settings → Keyboard → Look) switches it to **Chirp green**. The same choice colours the optional floating mic panel and the in-keyboard history panel and toggle. Nothing else changes, and the keyboard keys always follow the **Keyboard look** above.

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

### Optional floating microphone

The floating accessibility mic is **optional and off by default**; keyboard dictation needs no Accessibility permission. Enable it only if you choose to use another keyboard — it reads the focused field locally to insert safely, runs as a microphone foreground service with a notification, and field contents stay on the phone. For sideload restrictions: Apps → Chirp → ⋮ → Allow restricted settings, then Accessibility → Installed apps → Chirp floating microphone. An already-enabled optional service remains under your Android setting; the app does not enable it on update. Design notes on this and the other input paths considered are in [docs/android-input-options.md](../docs/android-input-options.md).

## Scratchpad

A place to dictate long-form text outside any text field, edit it, then **Copy** or **Share** it. It uses the same streaming client, pairing and clean-up as the keyboard (`DictationStream`, `StreamTransport`, `PcmCapture`), so dictation behaves identically: tap the big mic to start, tap again to finish, and errors offer the same **Pair Mac**, **Open mic settings** and **Check Tailscale** actions.

![Scratchpad idle](../docs/screenshots/android/scratchpad-idle-light.png) ![Listening](../docs/screenshots/android/scratchpad-listening-light.png) ![With text (dark)](../docs/screenshots/android/scratchpad-text-dark.png)

- **Open it** from the **Dictate** tile on Home, the launcher icon's long-press shortcut **Scratchpad**, or a **Quick Settings tile**. Add the tile once: swipe down twice, tap the pencil/Edit button, and drag **Scratchpad** into the panel. Tapping it collapses the shade and opens the Scratchpad (on a locked phone it asks for your screen lock first, because the pairing needs the unlocked phone).
- **Dictate:** each final is placed at the cursor, or replaces the selection, with a space where needed and a lower-cased first word when it continues a sentence. The opt-in **spoken commands** setting ("new line", "new paragraph") applies here too. The text is read-only while you dictate; edit freely otherwise.
- **Style picker:** **Raw** or any clean-up style the Mac offers. It applies to this screen only and never changes the keyboard's own setting; it is hidden when the Mac has clean-up off.
- **Memory only.** The text lives in the screen's view model: it survives rotation and folding, and is gone when you leave the Scratchpad (back, swipe away or the system closes it). Nothing is written to preferences or files, the Recents thumbnail is blank, and the clipboard copy is marked sensitive where Android supports it. Only if you turned on [Dictation history](#dictation-history) is each dictation (not the text in the box) also saved, encrypted, exactly like keyboard dictations; the screen says so while it is on.
- Switching apps mid-dictation discards that utterance; one you already stopped keeps finishing and its text is still added. For a meeting or anything longer, use [Notes](#notes).

## Notes

Live Notes on the phone: tap **Record**, talk for as long as the meeting lasts, and the Mac turns what was said into Markdown notes (headings, bullets, `- [ ]` tasks, **Decision:** and **Question:** lines) while the transcript fills in. It is the Mac's Live Notes design ([mac/README.md](../mac/README.md#live-notes)) on the same server endpoints, with no server changes.

![Notes on the cover screen](../docs/screenshots/android/notes-cover-recording-light.png) ![Notes beside the transcript on the inner screen (dark)](../docs/screenshots/android/notes-inner-recording-dark.png) ![Editing the Markdown, with the formatting bar](../docs/screenshots/android/notes-cover-editing-light.png) ![Recording on the emulator’s inner screen, synthetic speech](../docs/screenshots/android/emulator-notes-inner-dark.png)

- **The page.** The notes are a rendered document, not Markdown source: headings, bullets (nested), numbered lists, to-dos with a box you tick (it writes `- [x]` back into the Markdown, as your own edit), bold, italic, `code`, quotes, and `Decision:` / `Question:` lines as quiet tinted callouts, on a reading column at most 680 dp wide. Structured text that arrives while recording fades in at the end; text above never moves, and the page follows the end only while you are already there. The top bar is just the title (the name you gave it, else a `# ` heading on the first line, else the start time; tap it to **Rename**), the status (**Listening…**, **Paused**, **Organizing notes…**) and **Edit** and **⋮**. Everything else (**Organize**, **Undo organize**, **Structure notes**, **Auto-organize**, **Copy**, **Share**, **Save as Markdown**, **Rename**, **Recent notes**, **New notes**, **Notes settings**) is in the **⋮** menu. Short outcomes ("Organized", a voice edit's refusal) float above the record control for a few seconds. The renderer is Chirp's own (`NotesBlocks`, no WebView, no links followed).
- **Editing.** Tap any line (or **Edit**) to edit the Markdown in place, at the line you tapped, with the syntax lightly styled; **Done**, ✓ or Back returns to the page at the same place. While editing, a bar above the keyboard toggles **Heading**, **Bulleted list** and **Checklist** on the lines you are on, and **Undo** steps back through your typing (until something else changes the notes).

- **Open it** from the **Notes** tab (or tile) in the app, the launcher icon's long-press shortcut **Notes**, or the **Notes** Quick Settings tile (add it like the Scratchpad tile; a tap opens Notes and starts recording, a tap while recording stops it, and the tile says **Recording** or **Paused**). The tab and the separate screen share one session.
- **Record / Pause / Stop**: one control at the bottom. **Record** when stopped; while recording, a floating pill with **Pause** (or **Resume**), a level meter with the elapsed time, and **Stop**. **Pause** lets the current segment finish and closes the microphone (the mic indicator goes off and the clock stops), but the notes keep updating from what was already said; nothing is frozen and no final pass runs. **Resume** continues the same notes on a fresh socket; if the Mac cannot be reached it stays paused and says why. **Stop** works from paused too. The recording is cut into ordinary `/v1/stream` utterances at a pause after 12 s (0.3 s of quiet once past 30 s) and always at 45 s (`DictationSegmenter` with the Notes thresholds). At a cut capture swaps to the next socket at once (`FrameRouter`), which holds up to 12 s of audio until it is **ready**, and the old one finalizes in the background, so nothing is dropped and finals land in capture order even when a later one arrives first. The Mac transcribes one utterance at a time, so the next socket becomes ready only once the old one's final frees the speech engine. Segments use the hidden `live_notes` clean-up style when the Mac has it (only fillers and repeats go), otherwise the default style.
- **Live notes.** After each final (at most every 15 s, never while a segment is still finalizing) the open window goes to `POST /v1/notes/structure` and the answer replaces only the AI-owned **tail** of the notes. The notes stay editable while recording: typing before the tail just shifts it; editing inside it makes it yours, and the next answer starts a new tail after it. An answer that arrives while an input method is composing, or while you are typing in the tail, waits until you stop (at most 10 s). Unstructured speech shows as a quiet italic **Hearing** line at the end of the page. A rejected window is retried in halves and quarters; a part that still fails becomes an editable `_Not structured — see transcript_` block.
- **Organize** structures any raw blocks you have not edited and then reorganizes the trailing sections with `POST /v1/notes/reorganize`. Every result is applied only if the notes are unchanged since the request ("Notes changed while organizing — try again" otherwise), and **Undo organize** restores the text from before it. **Auto-organize** runs the same pass on its own after about 1200 new characters, 3 minutes and 15 s without typing, and once at Stop. A `busy` server (one notes generation at a time, shared with a Mac using the same server) means "retry after the next segment", never an error.
- **Edit by voice** (when the Mac has `POST /v1/notes/edit`; otherwise the button is hidden). Beside the record control, **Hold to edit**: hold it, say what to change ("go to the top and clean that up", "remove the bit about pricing", "change Friday to Thursday"), let go. A quick tap latches it instead (**Tap to send**, with **Cancel** beside it), and TalkBack's double tap does the same. While Notes is recording, the notification has a **Command** action too (it becomes **Send** while listening), so it works from the lock screen. What you say goes to its own `/v1/stream` socket with raw speech and never into the transcript: while recording, capture is diverted to the command from the moment you press (held until its socket is ready) and goes back to a fresh notes socket after it, so no notes audio is dropped; otherwise the command opens the microphone itself and closes it after (leaving the screen drops such a command). A command ends by itself after 20 s. The words are the instruction for `/v1/notes/edit`, which runs in the same one-at-a-time slot as structuring, ahead of it, once the segment before the command is in. The scope is the lines you have selected, else the whole notes, else (past 3500 characters) the trailing sections that fit. The answer is applied only if the notes are unchanged since the request (any typing, or an input method composing, gives "Notes changed while editing — try again"), as one change with an **Edited · Undo** chip for 20 s. It is applied to the notes at once even with the screen off (the editor catches up when it is back). Refusals say why: "Can’t add new content by voice — ask to remove, move, tidy or reword", "Couldn’t tell what to change — try naming the section", "Couldn’t edit notes (rejected: dropped_unasked)". The words and the notes are never logged.
- **Transcript**: a **Notes · Transcript** switch on the cover screen, a panel beside the notes on an unfolded Fold or a tablet (700 dp and wider): one line per segment with its time as quiet metadata, **Show raw** for the text before clean-up, and `⚠︎ audio not transcribed (reason)` for a segment that failed. A failed segment rolls on to a fresh socket; three failures in a row stop the recording and keep everything already captured.
- **Screen off and other apps.** While recording or paused, a microphone foreground service shows **Chirp Notes is recording** (with the running time) or **Chirp Notes is paused**, with **Pause**/**Resume** and **Stop** that work from the notification shade and the lock screen without opening Chirp. The notification never carries notes or transcript text. Back keeps the recording going in the background; tap the notification to return. Android asks once for notification permission; without it the recording still runs but the notification and its buttons are hidden.
- **Structure notes** is on by default when clean-up runs on the Mac. If the Mac's clean-up uses another host, it is off until you turn it on, and the switch names the host. With clean-up off on the Mac, or an older Mac server, Notes is a plain editor beside the live transcript.
- **Copy**, **Share** and **Save** export Markdown: a `# Notes — date` title (or the name you gave it: tap the title, or ⋮ → **Rename**), the notes, `---`, then `## Transcript`. **Share** sends it to any app that takes text (Keep, Obsidian, Docs…); **Save** writes a `.md` file wherever you pick in the system file picker (Downloads, Drive, an Obsidian vault folder). After Save the notes count as saved until they change. **New** and leaving with Back ask first while there is anything unsaved.
- **Battery saver** (on by default; **Save battery while the screen is off** in Settings → Privacy & history → **Notes**, or ⋮ → **Notes settings** on the Notes screen). With the screen off or Notes behind another app, the phone stops drawing: no editor updates, no live partial line, no level meter and no once-a-second clock. Recording, the transcript, the Mac's structuring and reorganize, the recovery copy and the notification all carry on, so the notes are current the moment you look; the notification says **Battery saver** meanwhile. Chirp takes no wake lock of its own: the microphone foreground service and Android's audio capture keep it running. Each session adds a content-free line under Chirp settings → About → **Diagnostics → Notes sessions** (minutes recorded and with the screen off, segments, gaps, notes calls, screen updates run and skipped, and the **last problem** as a status or server code, such as `structure: auth` or `segment: Mac is busy`). The battery run is in [docs/android-device-acceptance.md](../docs/android-device-acceptance.md#6-notes-battery).
- **Keep notes on this phone** (opt-in, off by default, on the same Notes settings page). Notes you stop, leave with Back or replace with New are kept in **Recent notes** (⋮ → **Recent notes** on the Notes screen: a notes list with each title, its age and a preview of the words, and a search field), sealed like history under their own Keystore key, excluded from backup, for 24 hours, 7 days or 30 days. Tap one to open it (the clock and transcript continue), or delete it. With it on, leaving and New no longer ask, because nothing is lost. Turning it off deletes every kept note and its key.
- **Recovery copy.** Until you save, discard or start new notes, Chirp keeps a recovery copy: the notes, the transcript, the name and the elapsed time (never audio), sealed with AES-GCM under its own Android Keystore key in app-private storage that is excluded from backup and device transfer. It is rewritten at most every 2 s, and at once after a segment, an AI update or Pause/Stop. If Android kills Chirp, it crashes, or you swipe it away from Recents (which also stops a recording), Notes reopens stopped with **Recovered unsaved notes from 14:03 · 52 min**, and **Record** continues the same notes and clock. **Save**, **Discard** and **New** delete the copy and its key. Turn it off in the Notes settings (**Keep a recovery copy until notes are saved**); turning it off deletes the current copy. Otherwise nothing about the notes is written to files or preferences, the Recents thumbnail is blank, the clipboard copy is marked sensitive and nothing about the notes is logged.

## Dictation history

Dictation history is **off by default**. When enabled, committed finals (plus the raw text when on-Mac clean-up rewrote them) are stored **on the phone only**, encrypted with AES-GCM under a dedicated Android Keystore alias (`chirp_history_v1`) in credential-encrypted storage — never sent to the Mac, never logged, and excluded from backup and device transfer (`data_extraction_rules.xml` excludes the root, file and sharedpref domains). The store keeps at most **200 entries** and prunes by age: **24 hours, 7 days (default) or 30 days**. Password and incognito fields (`TYPE_TEXT_VARIATION_PASSWORD` variants and `IME_FLAG_NO_PERSONALIZED_LEARNING`) are never recorded, and cancelled dictations leave no entry. While the device is locked the store is unavailable and the panel says so ("Unlock your phone to see dictation history.").

- **Keyboard**: a clock button sits next to the mic in the Chirp row. It opens an in-keyboard panel (over the key area, like HeliBoard's clipboard panel, so height and insets are unchanged). First use offers one-tap **Keep history on this phone** — nothing is written before that. Tapping an entry reinserts it through the same boundary and selection path as a dictated final; long-press offers **Copy**, **Insert raw** (when the entry was cleaned) and **Delete**. **Use raw** after a cleaned dictation updates the stored entry. Back or the keyboard button closes the panel; plaintext stays in memory only while the panel is open, and the keys are hidden from accessibility while it is up.
- **App**: the [History tab](#the-app-home-notes-history-settings) (search, day groups, detail with copy, copy raw, share and delete, swipe to delete with Undo) and **Recent** on Home. Undo writes the entry back as it was; nothing is kept elsewhere meanwhile.
- **Settings**: Chirp settings → **Privacy & history → Dictation history** (and ⋮ → **History settings** in the History tab) has a **Keep dictation history on this phone** switch, the retention chooser, **Open history** and **Clear history**. Turning the feature off asks first and then deletes the file and the Keystore key.

A small pre-existing fix shipped with it: moving the cursor after a cleaned final used to dismiss the raw-undo chip but leave the "cleaned" notice pinned open forever, hiding the row's idle buttons. The notice now expires on its five-second timer.

## Privacy

- **No dictation is retained by default.** Audio and transcripts live in memory for the length of an utterance; the exceptions below are the Notes recovery copy (on until you save), opt-in history and numbers-only diagnostics. No text, audio, URLs or tokens are logged; server error strings are never rendered into diagnostics. While the Mac runs with debug retention, a red **DEBUG: recordings kept on Mac** banner stays visible in the Chirp row.
- **The mic opens only when you start dictation** (or **Record** in Notes, which shows a notification while it runs; **Pause** closes the microphone) and is released as soon as you stop. The optional floating mic declares the same rules in its accessibility description.
- **The phone's recogniser is opt-in and disclosed.** With *Use this phone's recogniser* on, an utterance dictated while the Mac is unavailable goes to Android's on-device speech service, which belongs to Google or the phone maker. Android documents it as recognising on the device, but its own terms apply and Chirp cannot audit it. The **on phone** chip shows each time. Chirp adds no session timing for these utterances and logs no text or audio.
- **Notes keep only a recovery copy until you save.** It is AES-GCM encrypted under its own Keystore key, excluded from backup and transfer, never logged, and deleted on Save, Discard, New or when you turn it off ([Notes](#notes)). **Keep notes on this phone** is opt-in and sealed the same way under another key; turning it off deletes it. Notes session timings are numbers only.
- **History is opt-in and on-device.** Entries never leave the phone, are AES-GCM encrypted under a Keystore key, and are excluded from backup and device transfer.
- **Pairing secrets are encrypted at rest** (Android Keystore) and redacted from any `toString`. Pairing links are treated as secrets; they are parsed strictly and never logged.
- **Session timings are numbers only.** Each dictation on the keyboard records connect, ready, first-partial, stop → final and polishing milliseconds, audio length, outcome and error code, network type (Wi-Fi, cellular, Ethernet), whether a VPN was up and whether the prewarmed socket was used (ready latency is also split into warm and cold). The last 50 stay in a private, backup- and transfer-excluded file; Chirp settings → About → Diagnostics shows p50/p90 per metric and counts per outcome, with **Copy diagnostics** and **Clear timings**. Nothing else is stored: no text, audio, URLs, hosts, tokens or app names, and the serialized form holds only numbers, booleans and fixed enum names.
- **Crash diagnostics are bounded.** Chirp settings → About → Diagnostics shows/copies the last five local uncaught crashes: time, app version, exception class and at most 48 message-free class/method/line frames. The handler writes synchronously before delegating termination. It does not store exception messages, cause messages, filenames, thread names, text, audio, URLs or tokens. The private, backup-excluded log survives an app restart/update. HeliBoard's original crash handler and keyboard logger are disabled so they cannot retain a second content log.
- **Clean-up disclosure.** Styles stay hidden when clean-up is unavailable, including an undisclosed external correction destination; external correction always requires explicit opt-in and shows its host.

## Troubleshoot

Chirp settings → About → **Diagnostics** shows the session timings and the bounded crash log, and **Copy diagnostics** copies both (see [Privacy](#privacy)). The real-device checklist is [docs/android-device-acceptance.md](../docs/android-device-acceptance.md). Common messages on the suggestion-row status bar:

| Bar message | What it means | What to do |
|---|---|---|
| "Pairing refused — pair again in Chirp settings" | Server `auth` error | Re-pair from setup (**Pair Mac**) |
| "Didn't catch that" | Empty/blank final or server `bad_audio` | Speak again; nothing was inserted |
| "Speech engine hiccup" | Server `engine` error | Retry; check `chirp-server doctor` on the Mac |
| "Mac is busy — try again" | Server `busy` (engine occupied) | Retry after a moment |
| "Dictation limit is 120 seconds" | Server `too_long` (a keyboard dictation is cut well before it) | Update Chirp; split long dictations elsewhere |
| "Clean-up prompt too long — shorten it in Chirp settings" | Server `bad_request` on the prompt | Edit the style prompt |
| "Mac speech engine unavailable — try again" | Unknown server error | Retry; check the server |
| "Mac took too long to finish — try again" | Final timed out locally | Retry; check the Mac's load |
| "Mac offline · tap to retry" (mic drawn with a slash) | The last health check or prewarm failed in the past 30 s | Tap the mic or the row: it re-checks for up to 3 s, then dictates or names the reason |
| "Can't find your Mac on the tailnet — is it online?" | DNS lookup of the pairing host failed | Check Tailscale on the phone; check the Mac is online and signed in to the same tailnet |
| "Mac may be asleep, or Chirp isn't running" | Connect timeout or refused connection, or no Ready within 7 s | Wake the Mac; check Chirp is running (see the Mac tip below) |
| "Couldn't make a secure connection to your Mac" | TLS handshake or certificate error | Check the pairing URL is the Mac's `tailscale serve` HTTPS address; re-pair if it changed |
| "Mac connection is too slow — try again" | Transport stalled | Check Tailscale (**Check Tailscale**) |
| "Connection lost — kept what I heard" (or another reason) | The socket dropped, the Mac errored or timed out after partials arrived | The last partial was inserted as plain text; tap **Undo** to remove it |
| "kept original" after Polishing… | Clean-up failed, timed out (12 s) or the socket dropped | Raw text was inserted; edit the style or check the Mac |
| "Listening on phone…" / "on phone" chip | *Use this phone's recogniser* is on and the Mac is unreachable | Expected; the text is recognised on the phone, raw. Turn the setting off to keep dictation Mac-only |
| "Phone has no offline speech for this language" | The on-device recogniser lacks a language pack | Download the language in the phone's speech/voice-input settings, or dictate with the Mac |
| "Phone recogniser failed — try again" (or "…is busy") | The phone's speech service errored or didn't finish within 5 s of stop | Retry; anything already heard was kept |
| "Unlock your phone to see dictation history." | History store is credential-encrypted | Unlock the device |

**Notes.** The Notes screen names what went wrong under the editor, and Diagnostics → **Notes sessions** keeps it as **last problem** (codes only, never notes or transcript):

| Notes shows | What it means | What to do |
|---|---|---|
| "Notes stopped: Mac unreachable — is Tailscale on?" (or another reason) | Three segments in a row failed | Check Tailscale and the Mac; **Record** continues the same notes |
| `⚠︎ audio not transcribed (reason)` in the transcript | One segment failed; recording rolled on | Nothing; the rest is kept |
| "Couldn’t update notes (code) — retrying with the next segment" | A structuring call failed (`auth`: pair again; `busy`: the Mac is generating; `timeout`, `http`) | Usually nothing; it retries |
| "Chirp on your Mac is too old to structure notes — update it." | The server has no `/v1/notes/structure` (404) | Update Chirp on the Mac |
| "Clean-up is off on your Mac…" | The server answered `notes_off` (409) | Turn clean-up on in the Mac's Chirp settings |
| "Couldn’t edit notes (code)" | A voice edit call failed | Try again |
| "Nothing to organize yet — keep going" | **Organize** on notes shorter than 80 characters | Record or type more first |

In 0.7.0 and earlier nothing spoken reached Notes against a real Mac ([#134](https://github.com/araa47/chirp/issues/134)): each cut waited for the next socket to be ready, which the Mac (one utterance at a time) only allows after the previous segment's final, so every cut timed out and the session stopped with "Mac unreachable". A notes call could also fail as `http` on a kept-alive connection the Mac had just closed; such calls now go again once on a fresh connection. In 0.7.1 a segment still became a gap when Pause, a voice command or the next cut came before its socket was ready (its stop now waits for Ready), or when the Mac took more than 5 s to get to it (a Notes socket's send queue now holds the whole 12 s pre-ready buffer).

**Mac tip:** on the Mac, turn on System Settings → Battery → Options → *Wake for network access* and let Chirp launch at login, so the phone can reach it while the Mac is idle.

**Offline mic.** Failure reasons come from exception classes only (no messages, hosts or URLs are kept) and are worded as possibilities, since Android sees the symptom, not the cause. A failed health check or prewarm marks the Mac offline for 30 seconds: the suggestion row shows **Mac offline · tap to retry** and the mic is drawn with a slash, with TalkBack reading "Mac offline, double-tap to retry". ✕ or typing hides the row; the slash stays until the Mac answers or 30 seconds pass. Tapping never waits: it re-checks health for at most 3 seconds, then dictates, or shows the specific reason; a second tap during the check dictates at once. A Mac that answers over HTTP (even with an error) is not offline. **Tailscale is off** keeps priority over this row. Dictation gives up on a Mac that is not Ready within 7 seconds (the pre-Ready buffer holds only 5 seconds of audio).

Recoverable errors also offer **Pair Mac**, **Open mic settings** and **Check Tailscale** actions. With a tailnet pairing and no VPN up, the row shows **Tailscale is off** with **Turn on** instead (see [Tailscale off when the keyboard opens](#tailscale-off-when-the-keyboard-opens)). A historical note: a reproducible 0.5.1-era crash (`NetworkOnMainThreadException` during TLS teardown on stop/keyboard-hide) was fixed by moving all HTTP cancellation, pool eviction and dispatcher shutdown to one process-wide background queue — see the [validation record](#051-stop-crash-fix-2026-10-17). If an editor disconnected during the raw composing-region replacement, older builds could crash; all editor calls in `ComposingSession` now fail safely without exposing editor exceptions, losing the corrected text on a rejected replacement, or allowing late callbacks to insert into another field (lifecycle coverage: final, repeated utterances, hide/unbind/destroy, stale capture/transport callbacks, cancel and raw expiry). The first regression test for that crash failed before the fix; the original installed emulator crash buffer was empty, which does **not** establish that the operator's phone hit that same exception.

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

Run `android/scripts/emulator-smoke.sh` with the toolchain sourced after every change. It builds and installs the minified release APK split matching the emulator's ABI, clears only the authorized disposable emulator's Chirp data, walks state-aware setup, opens/backs out of the real Google QR scanner, opens the native editor, checks keyboard/mic/recovery/options, and exercises actual HeliBoard keys: `teh` → `the` (sentence-cased at field start), `im` → `I'm`, next-word suggestions, clipboard history and emoji. It checks inner and cover layouts in both themes, unfolded landscape split, one-handed reachability, settings/diagnostics, packaged dictionary hashes, absence of debug assets/proprietary glide libraries and the Chirp crash buffer. Failure exits non-zero. Every ADB call pins `emulator-5580`; other serials are refused. It changes no phone, Mac configuration, production server or Tailscale state.

A tiny shell-only UiAutomator probe reads all accessibility windows because Android 17's stock `uiautomator dump` returns the editor window without the IME (`scripts/build-ui-probe.sh` builds it under a temporary directory from `UiHierarchy.java`, pushes it to the disposable emulator and removes it in cleanup; it ships in neither APK). Real release captures are `docs/screenshots/android/release-*.png`, each under 2 MB. Release has no synthetic capture source or emulator cleartext policy.

### Emulator speech checks (debug only)

The operator-authorized emulator is **emulator-5580 only** — `emulator-check.py` refuses other serials (an `ANDROID_SERIAL` that disagrees is rejected too). The helper starts the actual server with a throwaway HOME on port 7899, uses the existing cached speech model, pairs through the QR deep-link path, and feeds generated speech through the real `PcmCapture` framing, buffer, `StreamTransport` and composing/final path. All subprocess/intent output that could contain a credential is suppressed. The test server and test credentials are removed in cleanup; the emulator is left running.

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
| `--history-check` | Dictation-history flow (opt-in, reinsert, Insert raw, ciphertext check) |
| `--notes-check` | Live Notes: the synthetic asset on a loop through Notes' own microphone path; fails unless three segments reach the transcript and structured notes reach the editor while recording (90 s each), then Pause, Resume and Stop |
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

The full `lint testDebugUnitTest assembleDebug assembleRelease` path passed: 175 tests, 0 failures/errors, 2 pre-existing opt-in skips. Release smoke passed scanner open/back, state-aware setup, actual autocorrect/next-word keys, clipboard, emoji, the integrated mic and recovery, inner/cover light/dark, unfolded landscape split, one-handed control reachability, settings/diagnostics and crash checks. `emulator-talkback.py` additionally enabled actual TalkBack and validated mic/status/cancel labels and native click/long-click actions before restoring the settings. Debug synthetic E2E passed against the isolated real Parakeet server with Keystore pairing, live composing text, repeated committed finals, cancellation, quick options, normal typing after dictation, light/dark and IME retention; the throwaway server was stopped. It does not claim live speech transport over HTTPS from the release build — the release APK uses AudioRecord, and smoke validates its UI without a live HTTPS speech session or the debug synthetic/cleartext facilities. Release APK: **26,684,648 bytes (25.45 MiB)**, containing arm64-v8a and x86_64. The English US dictionary added **0 bytes** because the pinned file was already bundled; the new emoji dictionary is 45,272 bytes before APK compression (21,095 packaged bytes). The typing/defaults phase added 25,068 bytes relative to the pre-typing UX release build (26,659,580 bytes). Screenshots in `../docs/screenshots/android/release-*.png` are from the real release emulator, each below 2 MB. No phone, production server, Mac app or Tailscale setting was used or modified.

### 0.5.0 clean-up, styles and streaming (2026-10-17)

`./gradlew lint testDebugUnitTest assembleDebug assembleRelease` passed with **198 tests, zero failures/errors, two opt-in skips**. Tests cover protocol metadata and editable prompts, TLS bearer requests, omission/reset/migration, Unicode limits, exact package mapping, prewarming/expiry, coalescing, suffix edits with a real `BaseInputConnection`, stable-prefix rollback, cancellation, polishing fallback, readable transitions and reduced motion.

Managed cleanup E2E passed against a real Parakeet/Qwen server on **7899** with a temporary HOME, `[correction] mode="managed"`, and the shared offline HF cache. The helper was warmed before UI captures to exclude first-use model/Metal setup; the app still has its normal 12-second polishing deadline. The capture helper requires `ffmpeg` to keep the exported recording below ten seconds. The debug asset used messy synthetic speech generated under `app/build/`; no audio is committed. Both themes captured underlined raw composition, Polishing + style, cleaned + Use raw, and native accessible raw replacement. The test removes its server, credentials and device probes and re-selects Chirp after force-stop. Reproduce with `--cleanup-only` (or `--frames-only` for the uninstrumented run) in the [emulator speech check](#emulator-speech-checks-debug-only) command.

Release `scripts/emulator-smoke.sh` and actual `emulator-talkback.py` also passed on **emulator-5580 only**. Release remains AudioRecord-only and HTTPS-only; live managed speech was exercised through the debug synthetic/cleartext path. APK: **26,716,080 bytes (25.48 MiB)**, version **0.5.0 (6)**, arm64-v8a and x86_64, signed with the existing local key.

Artifacts under `../docs/screenshots/android/`:

- `emulator-cleanup-{polishing,cleaned,styles}-{light,dark}.png` — actual emulator states.
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

An empty/blank final cancels the utterance's composition, inserts nothing, and briefly shows **Didn't catch that**. Stopping capture before the first frame is a normal completion. `bad_audio`, `engine`, `busy`, `too_long`, `auth`, `bad_request` and unknown errors have bounded local messages (see [Troubleshoot](#troubleshoot)); auth keeps the Pair Mac recovery action. Regression tests cover these messages, empty results before and during polishing, repeated stop/cancel/focus-loss callbacks, and main-thread pool eviction.

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

Emulator validation ran on **emulator-5582 only** (a second disposable read-only `chirp-fold` instance, used while emulator-5580 belonged to a parallel worker — the checked-in helper itself pins emulator-5580), debug APK with the throwaway TLS server on port 7899: `--history-check` drives the demo end to end — keyboard opt-in, synthetic dictation with clean-up, ciphertext check (no plaintext words on disk), erase and reinsert from the panel, long-press Insert raw, Fold inner/cover in light and dark, back-closes-panel, history-screen search, and turn-off-deletes-file. Screenshots land in `docs/screenshots/android/` as `emulator-history-*.png`; the pre-feature baseline strip is `history-before-keyboard-inner-{light,dark}.png`. Before that, the full `--stop-check --tls` matrix and the release smoke (`scripts/emulator-smoke.sh`) were re-run on this branch. No physical device or production server was used.

Reproduce after building debug, with the [emulator speech check](#emulator-speech-checks-debug-only) command plus `--history-check --tls` (on the authorized emulator-5580). The branch carried no version bump — still **0.5.1 (7)**, signed release APK **27,025,176 bytes (25.76 MiB)** — and was released as **0.6.0 (10)** with the history feature. No APK was published beyond the repository.

### arm64-only phone APK and 16 KB page gate (2026-10-23)

Release packaging splits by ABI (`splits.abi` in the app module; no universal APK, same version code for both outputs): every build produces `app-arm64-v8a-<build>.apk` and `app-x86_64-<build>.apk` under `app/build/outputs/apk/<build>/`, signed with the existing local key. Signed release sizes: arm64 **26,588,220 bytes (25.36 MiB)**, x86_64 **26,603,730 bytes (25.37 MiB)**. Native libraries are the only ABI-specific payload — compressed `libjni_latinime.so` (≈420 KB arm64 / ≈435 KB x86_64) plus `libandroidx.graphics.path.so` (≈4–5 KB) — so the phone APK saves **about 440 KB** against the equivalent dual-ABI build; the 0.6.0-era dual-ABI release measured 27,025,176 bytes. The keyboard module still compiles both ABIs.

Every assemble finalizes with `check<Build>Native16kAlignment` (`scripts/check-native-alignment.py`): every packaged `.so` must have only `PT_LOAD` segments aligned ≥ 16384, stored zip entries must be 4-byte aligned, and an uncompressed `.so` entry must sit on a 16 KB boundary (`zipalign -P 16` semantics). Both current libraries are NDK r28 builds (aligned by default) and are deflated in the APK (legacy packaging), so ELF alignment is the load-time gate. The swipe-typing card and this README warn that a user-supplied gesture library may not be 16 KB-compatible and can fail to load on Android 15+ 16 KB-page devices. `docs/android-input-options.md` marks Path A (voice subtype, auto-start, `switchToPreviousInputMethod`) retired and fixes the Chirp Keyboard naming.

`./gradlew lint testDebugUnitTest assembleDebug assembleRelease` passed on the rebased head (including #47): **366 tests, zero failures/errors, two pre-existing opt-in skips**, both splits built and both alignment checks green. (Lint's informational downgrade of the time-dependent `GradleDependency`/`NewerVersionAvailable`/`AndroidGradlePluginVersion` checks comes from main and covers the Gradle 9.8.2/OkHttp 5.5.1 releases of mid-October 2026.) Release smoke on **emulator-5580 only**: the script resolves the split by the emulator's reported ABI, and the local `chirp-fold` AVD reports **arm64-v8a** on an **Android 17 16 KB-page image** (`sdk_gphone16k_arm64`, page size 16384) — so smoke runs the app on a 16 KB-page system. The run installed the signed arm64 split and passed artifact inspection, the setup wizard, QR scanner open/back, mic permission and pairing actions, long-press options and the real-key typing checks (`teh`→`the`, `I'm`, next-word, clipboard, emoji) before flaking on the first Fold-loop settings cold start (60 s timeout on a contended host). Three later emulator starts crash-looped at QEMU startup (hanging `QEMU2 main loop` after Vulkan init, with and without software GPU); the only native crash in logcat was the system `android.hardware.uwb-service` aborting for a missing `/dev/uwb0`, never `dev.chirp`. The Fold inner/cover theme sweep, landscape split, one-handed reachability and settings/diagnostics screens were therefore not re-verified in this round, and with no x86_64 emulator on this host the x86_64 split was validated by build, the 16 KB gate and artifact inspection only. No phone, production server or Tailscale state was touched.
