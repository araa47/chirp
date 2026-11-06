# Android UI review renders

All displayed speech is a generated synthetic fixture. No user speech, real pairing
credential or personal text is included.

- `keyboard-{idle,connecting,listening,countdown,polishing,final,tailscale,offline,phone,retention}-{light,dark}.png`:
  Robolectric native graphics on API 37, actual HeliBoard QWERTY keys with Chirp's production strip at 411 px
  width (Gboard-like look, cover screen), settled with animator scale 0. While listening the strip shows the three
  Pond Ripple (one steady arc with Reduce Motion; three arcs when animated) and Stop as a filled `record` pill (dark ink on the light dark-theme red);
  `final` shows the Undo / Use raw chips, `tailscale` the *Tailscale is off · Turn on* prompt, `offline` *Computer offline*,
  `phone` the phone-recogniser chip, `retention` the debug banner. The same states are rendered for the other looks
  and the 673 px inner screen as `keyboard-{gboard,samsung}-{cover,inner}-<state>-{light,dark}.png` (the default
  combination keeps the short names). `KeyboardRenderTest` also asserts the strip and key-area height is identical
  in every state.
- `floating-{idle,idle-copy,hold,connecting,listening,finishing,polished,ready,ready-copy-mode,error,error-tailscale}-{cover,inner}-{light,dark}.png`:
  the floating mic (keep-my-keyboard path) over a synthetic reply field: the edge-docked Pond bubble (with the
  clipboard badge where a field can't be filled), hold-to-talk with its one-line preview, and the voice panel's
  states, from Connecting and Listening (Ripple rings, Stop in `record`) to Polished with Use raw, **Ready to copy**
  with Copy / Open in Scratchpad / Done, and errors that each carry one fix. Rendered by `FloatingMicRenderTest`.
- `emulator-floating-{idle,listening,ready}-{cover,inner}-{light,dark}.png`: the same bubble and panel on a real
  Android 17 emulator with Gboard selected, from `emulator-bubble-check.py` (`e2e-all.sh --only bubble`).
- `keepkb-{choice,floating,restricted,protected,settings}-{cover,inner}-{light,dark}.png`, plus `-font-200`:
  onboarding's **How you'll dictate** choice, the guided floating-mic page (disclosure first), the Restricted
  setting help, the Advanced Protection fallback and Settings → How you dictate. Rendered by `InputModeUiTest`.
- `settings-{top,top-font-200,connection,dictation,keyboard,feedback,notes,history,about,two-pane,two-pane-about}-*.png`:
  the settings tree (spec §D): a top level of seven category rows in one grouped card, each with an icon and a
  live one-line summary, and one detail page per category behind them (medium top bars collapse on scroll).
  Paragraph help lives behind the ⓘ on the row; Notes retention and kept audio sit under Notes, dictation
  history under Privacy & history. `two-pane` shows the Fold inner screen's list-and-detail layout.
  Regenerate with `./gradlew -Pchirp.updateScreenshots testDebugUnitTest --tests '*SettingsRenderTest*'`.
- `history-{list,empty,off}-{cover,inner}-{light,dark}.png`: the History tab, titled "Dictation history" with
  one line saying what it holds. Flat list rows lead with the target app's icon (PackageManager by label, with a
  neutral glyph fallback), long-press names the latest note and offers a new-note alternative, and search, day groups,
  the raw comparison, private Copy and swipe-delete Undo are unchanged. Rendered by `ShellRenderTest`.
- `history-note-actions-{cover,inner,large}-{light,dark}.png`: the History long-press menu names the latest
  destination and offers **Save as new note**. Popup renders cover phone and tablet widths, a wrapped title,
  and Android font scale 200% (`large`). Rendered by `HistoryActionsRenderTest`; regenerate with
  `./gradlew :app:testDebugUnitTest --tests '*HistoryActionsRenderTest' -Pchirp.updateScreenshots`.
- `onboarding-{welcome,keyboard,microphone,pair}-{light,dark}.png` plus `-font-200-*`, `keyboard-done-*`,
  `pair-{failed,checking,connected}-*`: the four-page wizard. The welcome page carries the approved full-bleed
  pond art edge to edge and introduces Notes as well as dictation; every page keeps one koi primary button and
  the segmented progress. Rendered by `VoiceUiTest`.
- `scratchpad-{idle,listening,use-raw,text}-{light,dark}.png`: the Scratchpad laid out like iOS's Dictate tab — the
  text on a white card over the pond background, Copy · Share · Save as note (and Use raw while offered) under it,
  the status line in `record` with its clock while listening and "Polished" with a **Before clean-up** disclosure
  after clean-up, Cancel under the large mic, and the one privacy line only while the page is blank. Rendered by
  `ScratchpadRenderTest` with animator scale 0 (the settled ripple).

Regenerate the Robolectric artifacts from `android/`:

```sh
./gradlew testDebugUnitTest --tests '*VoiceUiTest*' --tests '*KeyboardRenderTest*'
```

For actual emulator captures, use `android/scripts/emulator-check.py` as documented
in `android/README.md`; it targets only the explicitly authorized emulator serial,
uses port 7899 and a throwaway HOME, then stops its server and removes its credentials.
No production server, Mac app or phone is accessed. The emulator has an unrelated
UWB HAL crash loop; the helper checks specifically for Chirp Java/native crashes.

These are review artifacts, not pixel-golden assertions or Galaxy hardware battery,
latency or microphone measurements. Samsung editor quirks and folding still need
operator acceptance on the phone.

### Secondary surfaces validation (2026-10-25, #160)

Rebased on the Notes-first shell from #163. Refreshed and reviewed the Settings,
History, onboarding, Scratchpad, keyboard and voice-panel renders, including light
and dark, cover and inner layouts, and onboarding/Settings at 200% font. Scratchpad's
listening fixture now disables animation and asserts the active Stop control before
capturing, so the render cannot silently capture a connection timeout instead.

`./gradlew lint testDebugUnitTest assembleDebug assembleRelease` passed: 964 test
cases, zero failures/errors, two opt-in skips. Regression coverage includes live
Settings summaries while the detail pane stays open, preserving note duration/name
when appending from History, and quarantining an unreadable note while saving the
dictation as a new note with a new ID. The smoke helper follows Notes → Dictate →
the borderless Scratchpad, and accepts an explicit release artifact with
`CHIRP_SMOKE_APK`.

Emulator smoke and TalkBack remain **blocked**. The shared `emulator-5580` was
unreachable and was left untouched. A separately owned read-only `chirp-fold` on
`emulator-5600` booted. The unsigned release artifact was signed in `/tmp` with the
standard Android debug key for this check; no keystore or signing configuration is
part of this change. After clearing the disposable instance's Chirp install to
resolve `INSTALL_FAILED_UPDATE_INCOMPATIBLE`, the final attempt reached onboarding
but lost ADB during the wait for “Scan code” (`ADB operation failed: shell`).
TalkBack could not push its probe because `emulator-5600` was no longer present.
The owned emulator had already exited at cleanup; other instances were untouched.
No further emulator retries were made, and no successful smoke/TalkBack result or
new emulator captures are claimed for this change.

## Design components

- `components-{light,dark}.png`: the shared settings components (`ui/ChirpComponents.kt`) in Pond:
  `SettingsGroup` with `SwitchRow`, `NavRow` and a destructive `ActionRow`, `ChoiceChips`, the four
  `StatusBanner` kinds and the `InfoSheet` body. `components-dynamic-{light,dark}.png` show the
  default wallpaper colours (Robolectric's stock dynamic palette), and `components-font-200.png`
  is the same gallery at 200% font. The test also checks that no label is clipped and every row
  is at least 48 dp tall. Regenerate with `./gradlew testDebugUnitTest --tests '*ChirpComponentsTest*'`.

## Keyboard looks

- `keyboard-look-{gboard,samsung}-{idle,listening}-{light,dark}.png`: Robolectric
  renders of the Gboard-like default (HeliBoard Rounded + borders, dynamic colours) and
  the Samsung-like look (Rounded + borders, Chirp's One UI-style user colours). The
  Chirp strip takes its ink, accent and highlight from the active keyboard colours.
  Regenerate with `./gradlew testDebugUnitTest --tests '*KeyboardRenderTest*'`.
## Android glossary and note toolbar (#271 W10/W14, 2026-10-27)

The affected Notes, library, Saved voices, Dictation settings, History and final keyboard renders follow
[the copy glossary](../../copy.md). `notes-{cover,inner}-organize-toolbar-{light,dark}.png` shows the one-tap
Organize action in `moon`; `notes-saved-voices-font-200-{light,dark}.png` shows the same Saved voices page
at Android font scale 200%. Its named overflow control has a 48 dp target, and Forget all is last.
`settings-connection-forget-*` and `notes-library-{cover,inner}-empty-trash-*` capture the canonical
confirmations. Notes captures draw the actual Compose window and reject blank exports, including the
previously blank light idle and speaker-preparation frames. All affected light and dark renders were
visually reviewed.

Validation: `./gradlew lint testDebugUnitTest assembleDebug assembleRelease` passed (1,215 cases,
zero failures/errors, two existing opt-in skips). The host-locked `e2e-all.sh --only device` passed fresh
onboarding, actual TalkBack, font 200%, the inner-screen rail and fold/unfold. Builds use the disposable
debug keystore; the real server and emulator evidence are isolated from production. Responsive site
images were regenerated for the affected gallery sources, and the site build passed its image, link
and privacy checks.

## Release captures (round 4)

`release-*.png` are direct, unmodified PNG captures from the minified release APK on
an Android 17 emulator. Each file is below 2 MB.

- `release-pairing-light.png`, `release-scanner-light.png`: QR-first pairing and actual
  Google Play scanner surface, opened from the release APK.
- `release-launcher-icon.png`, `release-app-icon-settings.png`, `release-keyboard-picker-icon.png`
  (archived evidence, from `emulator-icons.py`): the launcher, app-settings and keyboard-picker icons. The icon art
  is unchanged; the labels predate the app's rename to **Chirp**.

The round-4 keyboard, pairing-action, typing and TalkBack captures were removed in the redesign docs sweep
(2026-10-25): they were taken over the retired setup "Try it" page with the old green strip. Re-run the scripts
below to capture the current release UI.

Regenerate with the toolchain sourced:

```sh
android/scripts/emulator-smoke.sh
android/scripts/build-ui-probe.sh
python3 android/scripts/emulator-talkback.py
```

The scripts restore display size/density/night mode and TalkBack service settings.
The smoke intentionally resets only Chirp's data on the authorized disposable emulator.
The shell-only probe supplements stock `uiautomator dump`, which omits the IME window
on this image. It is not packaged with the app. Neither release nor debug captures
establish Samsung hardware microphone quality or Tailscale performance.

## Fold function-key placement

**Archived evidence.** These captures prove the key geometry, which has not changed, but the page behind the
keyboard is the retired setup screen. They are kept for the layout record, not as current UI.

`fold-layout-{before,after}-{gboard,samsung}-{form}-{light,dark}.png` are direct
release-APK captures on emulator-5580. `before` is unmodified 0.5.2; `after` includes
the functional-layout fix without a version bump. Both looks use the same geometry.

| Form | Display override | Density | Result before the fix |
| --- | --- | --- | --- |
| `avd-native` | reset (2076 × 2152) | reset (390 dpi) | Phone arrangement; about 851 dp smallest width |
| `inner-portrait` | 1968 × 2184 | 420 dpi | Tablet arrangement; about 749 dp smallest width |
| `inner-landscape` | 2184 × 1968 | 420 dpi | Tablet arrangement, split |
| `cover-portrait` | 1080 × 2520 | 420 dpi | Phone arrangement |
| `cover-landscape` | 2520 × 1080 | 420 dpi | Phone arrangement |

The native AVD misses the bug: upstream's sw768dp metric is 2, below the tablet
test of 3; sw600dp is 3. The representative inner overrides expose it. After the fix,
Backspace aligns with Z–M and Enter aligns with space/period at bottom-right. Shift
starts row three; the tablet-only punctuation and second Shift disappear. Portrait
uses the full width with comfortable letter proportions; inner landscape keeps the
existing split mode. Cover key coordinates are unchanged in both looks and themes.

With the desired APK installed and toolchain sourced, regenerate either look:

```sh
android/scripts/build-ui-probe.sh
python3 android/scripts/emulator-fold-layout.py --look gboard
python3 android/scripts/emulator-fold-layout.py --look samsung
# Add --before only when running the unmodified 0.5.2 baseline APK.
```

The helper asserts real accessibility key bounds, letter widths, bottom-row order
and landscape split; it restores size, density, night mode and rotation settings.
It selects the requested look through the production chooser and leaves it selected.
The dimensions approximate the reported Fold inner screen; these are emulator
layout checks, with hardware acceptance left to the operator.

## Notes library (Pond)

`notes-library-{cover,inner}-{state}-{light,dark}.png` are API 37 Robolectric native
renders of the production Notes-first shell at 411 × 891 dp (cover, navigation bar)
and 840 × 900 dp (inner, navigation rail and list/detail). States:

- `empty`: glyph and static rings, type-or-record guidance and local-storage line.
- `populated`: serif titles, relative times, two-line previews, duration and open tasks.
- `recording`: pinned Ripple card with frozen preview and tabular timer.
- `search` / `no-results`: local body/transcript search and highlighted matches.
- `recently-deleted`: restore controls and the 30-day explanation.
- `multi-select`: selected rows and bulk delete, while another note keeps recording.
- `detail`: the rendered document, Continue, and a jump back to the active recording.
- `transcript-sheet`: the actual modal sheet with per-segment playback controls.

`notes-library-wide-landscape-{light,dark}.png` additionally show the transcript as
a third pane at 1280 × 800 dp. Normal inner windows use a sheet to preserve reading
space. Motion is disabled for these review captures, so Ripple uses its static
accessibility treatment. `NotesScreenshots.kt` draws Material's separate sheet
window over the activity because it does not expose `DialogWindowProvider` to the
Robolectric PixelCopy helper.

Regenerate this set and the existing detail states deliberately:

```sh
./gradlew testDebugUnitTest -Pchirp.updateScreenshots \
  --tests '*NotesLibraryScreenTest*' --tests '*NotesRenderTest*'
```

The starting screen is Notes (the retired Home dashboard's `home-*` captures were removed); `notes-{cover,inner}-*`
remain detail/editor review states of the note pane on its own. All fixture
words and audio references are synthetic. Pixel renders do not establish codec
support; the emulator check separately exercises the real platform codecs.

The strengthened `emulator-check.py --notes-check` opts into kept audio on the
throwaway emulator and requires a real MediaCodec AAC segment to prepare, start,
play for at least two seconds, and complete naturally through MediaPlayer. It
rejects decoder errors and keeps its output content-free.

`emulator-notes-kept-audio-playing.png` is a real Android 17 arm64 capture from a
separate read-only `chirp-fold` instance on `emulator-5600`. It shows the segment
highlight and Stop playback control during actual playback, using only generated
speech. The complete notes check passed: rolling transcription/structuring,
voice edit, screen-off capture, pause/resume/stop, real kept-audio replay, native
Markdown editing, Organize, Share and Scratchpad dictation. The owned emulator was
shut down after the run; no other emulator instance was touched. The content-free
result is in `emulator-notes-result.txt`.

The original `emulator-5580` remains the default. To target the explicitly allowed
read-only instance instead, set `ANDROID_SERIAL=emulator-5600` when invoking the
check and the UI probe builder. The fixture's six-second Ready delay applies to
Notes streams only; ordinary dictation uses the normal two-second delay so its
smaller pre-ready buffer is not exhausted by the Notes stress scenario.

### Keyboard-free entries (#168)

`QuickDictateRenderTest` renders `quick-dictate-{listening,copied,error}-{cover,inner}-{light,dark}.png`, the static `quick-dictate-widget-{1x1,2x1}-*.png` previews and `share-to-notes-dialog-*.png`. `InputModeUiTest` adds `keepkb-entry-points-*.png`, including 200% font. The new sheet is capped at 560 dp on inner screens; status, finals, raw replacement and cancellation use the existing Pond roles and Ripple.

`e2e-all.sh --only quickdictate release` records the actual tile/listening/copied, network-error and Share dialog in its private evidence folder. Only reviewed synthetic screenshots are copied here; no logs or UI XML are committed. There is no previous Quick dictate surface to compare; `keepkb-settings-*.png` is the earlier Settings context.

The committed `quick-dictate-emulator-{polishing,copied,error}.png` and `share-to-notes-emulator-dialog.png` come from the passing real-server entry matrix. The black backdrop is the debug probe’s secure window underneath the translucent Activity; it contains no user content. The copied capture shows Android’s sensitive clipboard overlay with its text preview hidden.

## Android Notes parity and W12 refresh (#271)

Capture source: `e635260a` (based on `61774f28`), 27 October 2026. API 37 Robolectric native graphics; Pond light/dark, cover 411 dp and inner 840 dp (Notes library), plus wide landscape 1280 dp. Standard font size except `settings-top-font-200-light.png` (200%). Keyboard fixtures use the existing 411/673 px widths and both looks, with animator scale 0.

- `notes-library-{cover,inner}-new-note-{light,dark}.png`: **New note** opens a focused local editor as **Untitled note**, with the computer offline and microphone setup incomplete. The library captures now include its toolbar action and current empty-state copy.
- `notes-speakers-reassign-menu-{light,dark}.png`: **This turn is…** opens choices for other people and **New person**. `notes-speakers-reassigned-*` shows the corrected turn as Person 4; `notes-speakers-merged-*` shows a chip for every turn, including adjacent turns by the same person, so each can be corrected separately.
- The three formerly blank light captures (`notes-cover-idle-light.png`, `notes-inner-idle-light.png`, `notes-speakers-preparing-light.png`) were regenerated and visually checked. Main already contains the visible-content export fix from `9589cff9`; these regenerate identically.
- All keyboard listening captures were regenerated. The old wedge was a real viewport-clipping bug, already fixed by `86c65e0b` in `KeyboardStrip.kt` (height-bounded radius), not a Robolectric-only artifact. Compare the explicitly historical `e2e-keyboard-ripple-clipped.png` / `e2e-keyboard-ripple-fixed.png` emulator evidence. Current reduced-motion renders show the steady arc; the existing `KeyboardRippleTest` checks that it crosses the visible middle. Offline renders were regenerated and remain byte-identical.
- `settings-top-*` now use the reserved synthetic `computer.example.test` fixture and current app version. The obsolete final-verification and gaps capture directories were removed, their historical report now links to this index, and the site widget reference uses current Quick Dictate captures. Historical before/after images remain labelled as historical evidence above.

Validation: `lint testDebugUnitTest assembleDebug assembleRelease` passed (1,221 tests, zero failures/errors, two opt-in skips). Captures were visually reviewed in both appearances. A separate locked, disposable emulator dictation run stopped before listening because the selected IME remained Gboard and the probe could not find Chirp’s mic action; no new end-to-end listening success is claimed. The iOS/Android strip-comparison composites are owned by the later iOS W2 pass and were left unchanged.
