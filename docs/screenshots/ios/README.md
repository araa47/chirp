# iPhone and iPad screenshots

All displayed speech is a generated synthetic fixture. No user speech, real pairing credential or personal text is included. Captures come from the iOS simulator UI tests and the debug fixtures (`ios/scripts/simulator.sh`, `ios/README.md`). The website's copies are derived from these by `site/prepare_images.py`.

Naming: `iphone-…` and `ipad-…` are the device; a `-dark` suffix (or `iphone-dark-…` / `ipad-dark-…` prefix) is the dark appearance and a bare name is light; `-ax5` is the largest accessibility text size. The `notes-…` family (saved voices and speaker naming) is named `-{light,dark}-{iphone,ipad}`.

## Current

- `iphone-dictate-*`, `iphone-dark-dictate-*`, `iphone-ax5-dictate-*`, `iphone-landscape-dictate-finished-{light,dark}.png`, `iphone-reduce-motion-dictate-listening.png`, `ipad-dictate-listening.png`, `ipad-dark-dictate-listening.png`: the Dictate tab (idle, listening, finished with Copy, Share and Use raw).
- `iphone-notes-*`, `ipad-notes-*`: the Notes library (groups, recording row, Recently Deleted, search, empty, the setup card), a note open for reading and editing, the transcript, kept-audio replay, and the recording dock at AX5.
- `iphone-speakers-{transcript,merged}-*`, `iphone-speakers-settings-light.png`, `ipad-speakers-settings-light.png`, `notes-speakers-*`: speaker chips, merging, the Name speakers line and sheet (with **Remember voice**), and Notes → Speakers settings.
- `notes-saved-voices-*`, `notes-voices-recognised-*`: Settings → Notes → **Saved voices** (the library on your Chirp server, shared by every device) and a recognised voice (✓ on the chip).
- `iphone-history-{list,detail}-*`, `iphone-history-empty-light.png`, `iphone-history-list-ax5.png`, `ipad-history-*`: Dictation history (off until you turn it on).
- `iphone-keyboard-*`, `ipad-keyboard-*`: Chirp Keyboard in each state (armed, listening, polishing, finished, error, no session, info, debug, system keyboard). The top row is Chirp's state row, the same height in every state.
- `iphone-settings-*`, `ipad-settings-*`: the Settings pages (home, Connection, Dictation, Keyboard, the style prompt editor).
- `iphone-onboarding-*`, `iphone-dark-onboarding-*`, `iphone-ax5-onboarding-*`, `ipad-onboarding-1-welcome.png`, `ipad-dark-onboarding-1-welcome.png`: first run (welcome, pair, microphone, keyboard).
- `ipad-sidebar-*`, `ipad-dark-sidebar-*`: the iPad sidebar (Notes, Dictate, History, Settings) expanded and collapsed.
- `iphone-session-capsule.png`, `iphone-dark-session-capsule.png`, `iphone-live-activity-*`, `iphone-dynamic-island-*`: the armed-session capsule, Live Activities and Dynamic Island (`.jpg`).
- `strip-compare-*`: Chirp Keyboard's top row beside Android's keyboard strip, for each device and appearance. Rebuild them from current captures with `uv run --with pillow python ios/scripts/strip-compare.py` (the script's docstring says where each side comes from).

## Capturing

The captures come from `TEST_RUNNER_CHIRP_SCREENSHOTS=1` UI runs on iPhone 18 Pro and iPad Pro 13-inch (M5) simulators (iOS 27.0): `ChirpScreenshotUITests/testCaptureShell`, `ChirpSettingsUITests/testCaptureSettingsTour`, `ChirpKeyboardUITests/testKeyboardStateScreenshotsInMessages` (with `TEST_RUNNER_CHIRP_PREVIEW_FILE`), and the screenshot cases in `ChirpNotesUITests`. The status bar is fixed with `xcrun simctl status_bar UDID override --time 09:41`. Export the attachments with `xcrun xcresulttool export attachments`.

- **Dark:** set the device's appearance before the run, and pass `TEST_RUNNER_CHIRP_NOTES_APPEARANCE=dark` so the Notes cases don't switch appearance mid-test. If live switching doesn't take, set `UserInterfaceStyleMode` (2 is dark) in the device's `com.apple.uikitservices.userInterfaceStyleMode.plist` while it is shut down, then boot it. Check that dark captures really are dark.
- **Landscape** (the iPad sidebar and Notes captures, `*-keyboard-landscape-*`, `iphone-landscape-*`): XCUIScreen returns these in portrait bounds with the top of the screen on the right. Rotate them 90° counter-clockwise before committing.
