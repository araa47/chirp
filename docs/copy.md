# Copy glossary

The words Chirp uses for the same thing on every platform (Mac, iPhone/iPad, Android, Windows/Linux desktop). It settles T2–T9 and T13 of the cross-platform audit ([#271](https://github.com/araa47/chirp/issues/271), work item W7). When you add or change user-facing text, use the canonical text below; if a term is missing, add a row here in the same PR.

Rules that apply to every row:

- **Words are shared, chrome is native.** Capitalization, menus, sheets and icons follow the platform (see the last column). Apple alert and confirmation buttons are title case (“Delete Permanently”); Android and the desktop app are sentence case (“Delete permanently”). Everything else is sentence case as shipped.
- **Quotes:** typographic double quotes around quoted text, “x”, and a typographic apostrophe, ’. Never ‘x’ or straight quotes in UI text. Example: No results for “x”.
- **Never user-facing:** “speech server”, “this Mac’s server”, “the server’s …”, “token”, “host”. The `chirp-server` binary appears only in code font, as the command a user runs.

| Concept | Canonical text | Where used | Platform idiom / notes |
|---|---|---|---|
| The server (phones, desktop) | “your computer”; “Computer offline”; “Update Chirp on your computer to save voices” | Every phone and desktop string that names where Chirp runs | Never “your Mac”: the server can be Windows or Linux (#261). Where the process itself must be named (pairing help), “Chirp server”. |
| The server (Mac) | “this Mac” when the server is local; “your Chirp server” when it is remote | Mac Settings, Notes, pairing, errors: “Update Chirp on this Mac to save voices” / “Update your Chirp server to save voices”; “Chirp server offline” | Replaces “this Mac’s server” and “speech server”. Choose the local or remote form from the configured server address. |
| Dictation clean-up (setting) | “Clean-up” | Settings switch and heading on every platform | Hyphenated, one word. No suffix such as “· Correction on your computer”; put detail in the footer. Desktop: “Polish dictation with your computer’s clean-up model”. |
| Clean-up style | “Clean-up style”; “Refresh styles” | Style picker under Clean-up | Names and descriptions come from the computer’s styles API. Desktop offers the same styles as Mac and the phones, without editing prompts. |
| Press Enter after dictating | “Off”; “On Send, Go or Done”; “Always” | Desktop dictation settings. iOS uses the same three labels (“On Send, Go or Done”). Android’s middle choice is “In chat apps only” | Desktop cannot see the field’s Send, Go or Done key. That choice presses Enter only after a single-line typed insertion. Always also presses Enter after line breaks. Not after a clipboard-only result, and not in a terminal. |
| Computer connection (desktop chip) | “Connected”; “Connecting…”; “Computer offline” | Desktop header chip; opens Connection & shortcuts | “Computer offline” and the ellipsis match the phones. The phones’ short chip says “Computer” or “Offline”; the desktop chip uses these three words. |
| Clean-up (live state, result) | “Polishing…” while working; “Polished” when done | Mac HUD, iOS keyboard row, Android strip; History marker for a polished dictation | The history chip and phone meta say “Polished”, not “Cleaned”/“cleaned”. Keep the ellipsis on every platform’s “Listening…” and “Polishing…”. |
| Merge two speakers | “Same person as” | Speaker menu on every platform, Name speakers sheet | Mac: a submenu; iOS: menu and confirmation dialog; Android: dropdown. Not “Merge into”, not “Same as”. |
| Undo a merge | “Separate” | Speaker menu, previously merged person | Unchanged wording; listed so it stays paired with “Same person as”. |
| Reassign one turn | “This turn is” → a person, or “New person” | Speaker chip menu on a transcript turn, every platform | Changes that turn only and is kept through later labels and Re-transcribe. Mac and iOS: a submenu “This turn is”; Android: “This turn is…” opens the list. |
| Auto-organize | “Organize automatically” | Notes toggle (Mac note inspector, iOS and Android note menus) | Not “Auto-reorganize”, not “Auto-organize”. |
| Resume a stopped note | “Continue recording” | Mac toolbar, iOS note, Android FAB on a stopped note | Android’s FAB may show the icon with this label as its content description. |
| Empty the trash | “Empty Recently Deleted?” with “Delete Permanently” | Notes library on every platform and Mac Settings | See [Dialogs](#dialogs). Menu/toolbar entry: “Empty Recently Deleted” (Mac adds “…”). Not “Delete Forever”, not “Permanently delete these notes?”. |
| First saved voice notice | “Remembering voices” | One-time notice the first time a named voice is saved, all platforms | Replaces “Remember voices in later notes” (Mac) and “Remembered voice” (Android). Body names “your computer” on phones, “this Mac”/“your Chirp server” on the Mac. |
| Voice library | “Saved voices” | Settings → Notes → Saved voices, and the server-wide switch “Remember voices of people I name” | A detail page on the Mac (the Notes row is the title with a chevron, not “Saved voices…”). A page on the phones. |
| Privacy settings | “History & privacy” (Mac); “Privacy & history” (phones) | Settings category | Dictation history (the switch and how long it is kept), Private session, Learn from my edits, Learned, and excluded apps. Footer: the notes privacy line below. |
| Remember one person’s voice | “Remember voice” | Per-person toggle in the Name speakers sheet and in Rename | Android’s per-chip Rename must offer it too (A2-9). On by default only when the server’s library is on. |
| Reject a voice match | “Not <name>” | Speaker menu on a recognised person | Mac: “Not Maya” button; phones: menu item. |
| Refresh a saved voice | “Update <name>’s voice” | Speaker menu on a recognised person | Replaces “Update <name>’s saved voice” and “Update … Saved Voice”. |
| Pairing: act | “Pair” / “pairing”; buttons “Pair computer” (phones), “Pair a Phone” (Mac window and Settings → Devices) | Onboarding, Settings → Connection, Mac Devices | Phones call it “Pair computer”, the Mac calls the other side “a Phone”. Settings row: “Change pairing” / “Pair computer”. |
| Pairing: the secret | “code”: “Scan the code” | Pair pages, Mac pairing window | “QR code” only in help text. Never “token” or “key” in headings. |
| Pairing: steps | “On your computer, open Chirp → Settings → Devices → Pair a Phone, or run `chirp-server pair` on your server.” | Onboarding pair page and Connection page, phones | Same text on iOS and Android (W1). Page title “Pair your computer”; secondary link “About pairing”; skip link “Skip for now” (offer it on both). |
| Pairing: undo | Row “Forget pairing”; dialog “Forget this computer?” | Settings → Connection | See [Dialogs](#dialogs). |
| Dictation history | “Dictation history”; switch “Keep dictation history”; search field “Search history” | Settings group, tab/screen title (“History” on the phones’ tab bar), keyboard panel | The feature is “Dictation history” everywhere it is named in full; the tab or window may shorten it to “History”. Not “Search dictations”. |
| History: save to notes | Add to latest note (“<title>”); “Save as new note” | Android History entry menu and accessibility actions | Name the destination before appending; keep the new-note choice alongside it. |
| Temporary privacy | “Private session” | Settings switch and keyboard/strip control, where it exists | Means the pause **ends by itself** (lock, one hour or session end). If a pause persists until the user turns it off, it must not be called a private session. |
| Persistent privacy | “Pause dictation history” | Any switch that stops saving until turned off | Use this name for iOS’s persistent preference (A2-12) and any equivalent. Existing history is kept; stopping and deleting is “Turn off dictation history”. |
| Stop on pause | “Stop dictation”: “When I tap” / “When I pause”; “Pause length” (1 s, 1.5 s, 2 s, 3 s, 5 s) | Android and iOS Settings → Dictation | Off (“When I tap”) by default on the phones. The Mac keeps it in its Mode menu as “Auto-stop” with “Stop after”, because there it is one of the hotkey modes beside hold-to-talk. Stop always works; a hardware key held to talk ignores pauses. |
| Teach a correction | “Teach Chirp” | History entry action; Mac “Teach Chirp…” opens a sheet | Sheet title “Teach Chirp”; the action that opens a sheet gets “…” on the Mac only. |
| Learned items | “Learned” | Settings page/list of what Chirp learned; the setting “Learn from my edits” | Empty state: “Nothing learned yet.” |
| Notes: create blank | “New note” | Notes library (⌘N / Ctrl+N), Dock menu | Mac menu title case, “New Note”, in the Dock menu too. A note with no title is “Untitled note” everywhere. |
| Notes: record | “Record” | Notes library, empty state | Mac, iOS dock, Android FAB. Separate from “New note” (A2-7). |
| Notes: voice edit | “Edit by voice” | Note toolbar/menu, also while recording | Result “Edited” with “Undo”. |
| Notes: restructure | “Organize” | Note toolbar (one tap on all three) | The toggle that does it for you is “Organize automatically”. |
| Notes: transcribe again from kept audio | “Re-transcribe…”; one segment “Transcribe again” (Mac; iOS row context menu), gap rows “Try again” (phones); sheet title Re-transcribe “<title>”?; button “Re-transcribe” (“Re-transcribe anyway” when the server keeps debug recordings) | Note menus (Mac: Notes menu “Re-transcribe Note…”, sidebar, transcript ⋯), the consent sheet, transcript rows | Shown only when the note kept audio and the setting is on (hidden, never greyed). Progress: “Re-transcribing · 12 of 40 · 1:32 of 8:10”; waiting: “Waiting for your computer…” (Mac: “Waiting for Chirp on this Mac…” / “Waiting for your Chirp server…”). Finish toast “Transcript updated” with “Undo” (Mac also “Show changes”); partial “38 of 40 updated. 2 kept their old text.”; cancel “Cancelled. Nothing changed.” Mac menu items and alert buttons are title case (“Re-transcribe Anyway”, “Transcribe Again…”). |
| Notes: allow re-transcribing (setting) | “Allow re-transcribing” | Settings → Notes, under Keep audio with notes | On by default; disabled when Keep audio is off and no audio is kept. Off hides every Re-transcribe and Try again action. |
| Notes: put the previous transcript back | “Restore previous transcript” | Same menus as Re-transcribe, after a run | Mac menu title case: “Restore Previous Transcript”. The toast’s “Undo” does the same thing right after a run. Not “Revert”. |
| Notes privacy footer | “Notes stay on this <device>.” | Privacy page | <device> is “Mac”, “iPhone”, “iPad”, “phone” (Android) or “computer” (desktop). Always a full sentence with a period. |
| No results | No results for “x” | Notes and History search | iOS may use the system “No Results for “x””. Android moves from ‘x’ to “x”. |

## Dialogs

Titles and buttons are exact. Message text is the canonical wording; add counts or names where the platform already does.

| Dialog | Title | Message | Buttons |
|---|---|---|---|
| Empty Recently Deleted (all platforms, incl. Mac Settings and desktop) | Empty Recently Deleted? | These notes and their audio will be deleted for good. This can’t be undone. (Mac may lead with the count: “3 notes and their audio …”.) | **Delete Permanently** (destructive) · Cancel |
| Forget the pairing | Forget this computer? | You’ll need to scan a new code to dictate. This also ends the session. | **Forget** (destructive) · Cancel |
| Forget one saved voice | Forget <name>? | Removes <name>’s voice from your computer for every device. Names in existing notes stay. This can’t be undone. | **Forget** (destructive) · Cancel |
| Forget all saved voices | Forget all voices? | Removes all saved voices from your computer for every device. Names in existing notes stay. This can’t be undone. | **Forget** (destructive) · Cancel |
| Turn off dictation history | Turn off dictation history? | New dictations won’t be saved. Keep existing dictations until they expire, or delete them from this <device> now. | **Turn off, keep history** · **Turn off and delete** (destructive) · Cancel |
| Delete dictation history | Delete dictation history? | This deletes every saved dictation and its encryption key from this <device>. This can’t be undone. The Keep dictation history setting stays the same. | **Delete history** (destructive) · Cancel |
| Delete one note’s audio | Delete audio? | This deletes this note’s audio. The text and transcript stay. The menu shows the size in MB, in the phone’s locale. | **Delete audio** (destructive) · Cancel |

Notes: on the Mac the voice and pairing messages say “this Mac”/“your Chirp server” instead of “your computer”. The pairing dialog’s Cancel replaces Android’s “Keep pairing”, and “Forget <host>?” becomes “Forget this computer?” (a host name is a server name; do not show it as a title). Use the button name that carries the verb (“Delete Permanently”, “Forget”), never a bare “OK”, “Yes” or “Delete Forever”.
