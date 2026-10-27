# Chirp macOS + Android UX review — 2026-10-27

Read-only review on `398b528d` (branch `koi/chirp-ux-deepseek-a3db07`). No app sources changed.
Evidence: committed `docs/screenshots/{mac,android}`, plus a fresh full offscreen mac render
(`mac/scripts/snapshots.sh all`, 424 PNGs, 26 states that are not committed) and line-level
contrast measurements of the rendered PNGs.

Applied principles, stated plainly: **WCAG 2.2 AA** (1.4.3 contrast for text, 1.4.4 resize,
2.5.8 target size), **platform-convention coherence** (macOS AppKit/SF Symbols and Mac menu
rules; Material 3 + Android adaptive scaffolds), **Nielsen heuristics 1 and 3** (visibility of
system status; user control and freedom), and **single-source semantic roles** (one icon or
colour = one meaning).

Measurement method: `NSImage` → sRGB bitmap, most-common colour in a region = background,
highest-contrast colour = glyph core, WCAG relative-luminance ratio. Sub-pixel antialiasing
means the true contrast is never *higher* than the core value measured here.

---

## 1. macOS secondary/tertiary text fails WCAG AA across Notes (measured 1.87–3.95:1)

**Evidence (measured from committed PNGs)**

| Region | File | Background | Core | Ratio | AA needs |
|---|---|---|---|---|---|
| Empty-state privacy line, 11.5 pt tertiary | `notes-empty-light.png` | `#FFFFFF` | `#BDBDBD` | **1.88:1** | 4.5:1 |
| Same, dark | `notes-empty-dark.png` | `#121C30` | `#4D5463` | **2.24:1** | 4.5:1 |
| "days left", 11 pt tertiary | `notes-deleted-light.png` | `#F1F3F8` | `#B3B4B8` | **1.87:1** | 4.5:1 |
| Sidebar meta "3 min · ☐ 2 open", 11 pt | `notes-library-light.png` | `#ECEFF5` | `#76787B` | **3.84:1** | 4.5:1 |
| Note facts line (date · length · to-dos · audio) | `notes-library-light.png` | `#FFFFFF` | `#808080` | **3.95:1** | 4.5:1 |
| Keycap hint "starts a note from any app" | `notes-empty-light.png` | `#FFFFFF` | `#808080` | **3.95:1** | 4.5:1 |

Dark mode passes comfortably (`inkMuted` on surface = 5.94:1); **light mode is the failing side**,
so the shipped look misreads "light theme" as "low-contrast theme".

**Why the existing tests miss it:** `mac/Tests/ChirpCoreTests/ThemeTests.swift:17` checks only the
`ink`/`inkMuted` tokens against `background`/`surface`, and only on paper. The failing values come
from `NotesInk.tertiary` (an AppKit `tertiaryLabelColor`) and from `.font(.system(size: 11 …))`,
neither of which is a Pond token, so no assertion covers them.

**Where to change**
- `mac/Sources/ChirpUI/NotesView.swift:482-485` — empty-state privacy label (11.5 pt tertiary).
- `mac/Sources/ChirpUI/NotesSidebar.swift:205-209` (relative time, 11 pt), `:259-270` (`MetaLine`,
  11 pt), `:444-447` (days left, 11 pt tertiary).
- `mac/Sources/ChirpUI/NotesView.swift:196-217` — the history/meta line (`ChirpType.meta`, 12 pt).
- `mac/Sources/ChirpUI/NotesView.swift:452-457, 460-464` — empty-state body and keycap hint.

**Before → after behaviour**
- Before: 11 pt `tertiaryLabelColor` at 1.87:1 on white.
- After: meta text is `inkMuted` (`#5B6577`, 5.0:1 on `#FFFFFF` and 4.6:1 on `#ECEFF5`) at no less
  than 12 pt; "days left" becomes `inkMuted`, not tertiary; the privacy line becomes `inkMuted`.
  Keep `tertiary` for hairlines and disabled glyphs only.

**Acceptance**
- New `ThemeTests` case asserting `inkMuted` (light) against `surface` **and** `surfaceRaised`
  ≥ 4.5:1, so the sidebar case is covered.
- A snapshot assertion that no `Text` in `NotesEmptyState`/`MetaLine` uses `NotesInk.tertiary`.
- Re-measure the six regions above from the regenerated PNGs: all ≥ 4.5:1.

---

## 2. macOS has no way to enlarge text, with 95 hard-coded point sizes

**Evidence**
- `rg -o "system\(size:" mac/Sources/ChirpUI | wc -l` → **95** occurrences; only ~35 semantic
  styles (`.callout`, `.caption`, …) in the same module. `ChirpType` (`Theme.swift:120-140`) is
  itself fixed-size (`noteTitle` 26, `body` 15, `meta` 12, `listTitle` 13).
- `mac/Sources/ChirpUI/Theme.swift:8` claims "system text sizes still work", but SwiftUI on macOS
  does not scale `.font(.system(size:))` with the system text-size setting — only semantic styles
  and `dynamicTypeSize` do, and nothing sets `dynamicTypeSize`.
- No View-menu text-size command: the only "Zoom" in the app is `Window ▸ Zoom`
  (`mac/Sources/ChirpMac/NotesWindowController.swift:195`), which resizes the window, not the type.
- No large-text snapshot exists: `mac/Sources/ChirpUI/Snapshots.swift` renders light/dark only
  (`appearances`, line 30). Android, by contrast, ships 200% renders
  (`settings-top-font-200-light.png`, `notes-saved-voices-font-200-*`, `onboarding-font-200-*`).

**Where to change**
- `mac/Sources/ChirpUI/Theme.swift:120-140` — put every size behind a scale factor, e.g.
  `ChirpType.scale` (1.0/1.15/1.3) applied inside `noteTitle/body/timer/listTitle/meta`.
- `mac/Sources/ChirpUI/NotesWindowController.swift` (menu construction) — add
  `View ▸ Bigger Text ⌘+` / `Smaller Text ⌘−` / `Actual Size ⌘0`, persisted next to `notesTab`
  in `Settings`.
- Convert the chrome call sites to semantic styles: `NotesView.swift:588` (banner `.callout` is
  fine), `HUD.swift:276,283,386` (11/13/10 pt fixed), `NotesSidebar.swift:138,195,200`.

**Before → after behaviour**
- Before: ⌘+ does nothing; a user who needs larger text must use macOS display scaling (which
  enlarges everything, including the 260–320 pt sidebar, and shrinks the note).
- After: ⌘+ steps the type (and the row/capsule metrics via `ScaledMetric`) without touching the
  window; the sidebar/editor split stays put.

**Acceptance**
- Snapshots at scale 1.3 for `notes-library`, `notes-recording`, `notes-empty`: no clipped label,
  no truncated toolbar control (the existing `NotesLayoutTests` one-line assertions now run at both
  scales).
- HUD at scale 1.3 stays inside `HUDViewMetrics` bounds.

---

## 3. Android: the Notes tab icon is a hamburger menu, and one glyph means three things

**Evidence**
- `android/app/src/main/res/drawable/ic_notes_tab.xml` is `M3,18h12v-2H3v2zM3,6v2h18V6H3zM3,13h18v-2H3v2z`
  — three horizontal bars. `AppShell.kt:34` assigns it to the **Notes** tab.
- The same drawable is the **Transcript** chip (`NotesScreen.kt:166`) and the History context-menu
  row for the latest note (`HistoryScreen.kt:325`).
- Visible in `notes-library-inner-empty-light.png`: the rail's first destination, labelled "Notes",
  draws a hamburger directly above "History" (clock) and "Settings" (gear) — the two that *are*
  semantic. `ic_note.xml` (a document shape) already exists and is used for Settings ▸ Notes.
- Accessibility is unaffected (the label carries the meaning), so this is a visual-hierarchy defect,
  not a label defect.

**Where to change:** `AppShell.kt:34` → `R.drawable.ic_note` (or a new dedicated note-tab glyph);
`NotesScreen.kt:166` → a text/quote glyph for Transcript; `HistoryScreen.kt:325` → `ic_note`.

**Before → after behaviour**
- Before: the app's primary destination looks like an overflow menu; the same picture means
  "Notes", "Transcript" and "open this note".
- After: three distinct, conventional glyphs; the Notes tab matches the document metaphor the
  library, the empty state and Settings ▸ Notes already use.

**Acceptance:** regenerate `notes-library-{cover,inner}-*`, `keyboard-*` and `history-*`; assert in
`ChirpComponentsTest`-style check that no two `ShellTab` icons share a `pathData`, and that
`ic_notes_tab`'s replacement is not a 3-line path.

---

## 4. macOS: sidebar + inspector can squeeze the note to ~176 pt at the minimum window width

**Evidence**
- `mac/Sources/ChirpUI/NotesView.swift:7-12`: window `minimumSize` is **760×460**, sidebar range
  **260–320**, inspector **260–420**, reading width 680.
- `mac/Sources/ChirpUI/NotesEditor.swift:81`: `inset = max(32, (frame.width - 680) / 2)`.
- 760 − 260 (sidebar) − 260 (inspector) = **240 pt** for the editor; minus 2×32 inset = **176 pt**
  of text column — about 20 characters per line, below any comfortable measure, at a size where
  the user has done nothing unusual (just shown the transcript).
- Nothing collapses: `showsInspector` is a user preference only (`NotesLibraryModel.swift:174,
  253-256`); `NotesLayoutTests` exercises 760 pt but only asserts the toolbar label stays on one
  line, never the editor measure.
- The committed narrow capture `docs/screenshots/desktop/notes-light-narrow.png` and the fresh
  `notes-transcript-*` renders both show the squeeze.

**Where to change:** `NotesView.swift:45-52` — on `GeometryReader` width < 900, present the
transcript as a sheet (or hide the inspector) instead of a third column; mirror the Android rule at
`NotesScreen.kt:70` (`SIDE_BY_SIDE = 1000.dp`) and `NotesLibraryScreen.kt:130` (`extraPane` at
1200 dp landscape).

**Before → after behaviour**
- Before: 760 pt + transcript = 176 pt note column, headings wrap mid-phrase.
- After: below ~900 pt the transcript opens as a sheet over the note (same content, full measure);
  above it, the three columns behave as today.

**Acceptance:** new case in `NotesLayoutTests` — at 760 pt with `showsInspector = true`, the
editor's text-container width ≥ 320 pt; a `notes-transcript-narrow` snapshot renders the sheet.

---

## 5. Android: the primary button says "Record" while a note is already recording

**Evidence**
- `NotesLibraryScreen.kt:269-275`: the FAB row is unconditional —
  `ExtendedFloatingActionButton(onClick = { start(null) }, …) { Text("Record") }`, gated only on
  `!trash && selection.isEmpty()`.
- `start(null)` then hits the guard at `:177` (`if (recording && id == null) pendingNew = true`), so
  tapping it opens a *second* dialog: "Start a new recording? Another note is recording. Stop it
  before starting here."
- The committed render `notes-library-cover-recording-light.png` shows exactly this: a pinned
  "Recording · Product conversation 00:45" card, and directly below the list a prominent
  "Record" pill — the screen's strongest affordance contradicts its own state.

**Where to change:** `NotesLibraryScreen.kt:269-275` — while `recording`, the primary FAB becomes
"Open recording" (jumps to `liveId` via `open(liveId)`); the "stop and start new" path moves to
the library `⋮` menu behind the existing confirmation.

**Before → after behaviour**
- Before: Record → "Start a new recording?" → confirm → current note stops. Two taps plus a
  destructive dialog for the most prominent control.
- After: while recording the FAB says "Open recording" and returns to the live note; starting a
  new note is a deliberate, labelled overflow action.

**Acceptance:** refreshed `notes-library-cover-recording-{light,dark}.png` show "Open recording";
a Robolectric test asserts the FAB label matches `recording` state and that no dialog appears when
it is tapped while recording.

---

## 6. macOS: "Delete Now" in Recently Deleted is irreversible with no confirmation or Undo

**Evidence**
- `mac/Sources/ChirpUI/NotesSidebar.swift:451`: `Button("Delete Now", role: .destructive) {
  library.onPurge(entry.id) }` — no alert.
- `mac/Sources/ChirpUI/NotesSession.swift:932-935`: `onPurge` runs `library.purge(id)` directly.
- Contrast with "Empty…", which *does* confirm (`NotesView.swift:81-86`, with a message naming the
  count), and with the ordinary delete path, which offers Undo (`onTrash` → toast, `⌘Z`).
- So the app is least careful exactly where the action is unrecoverable.

**Where to change:** `NotesSidebar.swift:451` — route through a confirmation mirroring the Empty…
alert ("Delete “<title>” permanently? Its audio goes too. This can't be undone."), or perform the
purge with a 10 s Undo toast (the library keeps the record until the toast expires).

**Before → after behaviour**
- Before: one click on a row's "Delete Now" permanently removes the note and its audio.
- After: one click asks once, or is undoable for 10 s; the Empty… flow is unchanged.

**Acceptance:** a `NotesLibraryTests` case that `onPurge` is not reached without confirmation (or
that the toast's Undo restores the entry); refreshed `notes-deleted-*` captures.

---

## 7. Android: the recording card and the two FABs are voice-only surfaces for TalkBack

**Evidence**
- `NotesLibraryScreen.kt:383-398` — `RecordingNoteCard` is `Surface(click, …)` with no `semantics`:
  the click has no action label, the card has no "recording" state, and the timer and preview are
  three separate reads. The rest of the library is careful (rows at `:411-413` merge descendants
  and expose `customActions`; the connection chip at `:349` has a full `contentDescription`).
- `:269-275` — the mic FAB has `contentDescription` via the icon, but the two FABs sit side by side
  with no grouping, so focus order reads "Record" then "Dictate" with no relationship.
- The recording card is the one element a screen-reader user most needs to reach (it is the only
  way back to the live note from the list).

**Where to change:** `NotesLibraryScreen.kt:387` —
`Modifier.semantics(mergeDescendants = true) { role = Role.Button; stateDescription = "Recording";
onClick(label = "Open the recording note") { click(); true } }`, and announce the elapsed time
with `liveRegion` sparingly (the note screen already does this at `NotesScreen.kt:214`).

**Before → after behaviour**
- Before: TalkBack reads title / "00:45" / preview as three nodes, then an unlabelled "double tap
  to activate".
- After: one node — "Product conversation, recording, 45 seconds, <preview>. Double tap to open
  the recording note."

**Acceptance:** `emulator-talkback.py` case for the library's recording card
(currently only the keyboard/floating-mic cases exist), asserting one merged node with the state
and the action label.

---

## Evidence gaps

- **No hardware TalkBack run.** `docs/screenshots/android/README.md` records TalkBack as blocked;
  finding 7 comes from the Compose semantics tree, not from a device read.
- **Android renders are Robolectric** (API 37, PixelCopy), not hardware; dynamic-colour and Samsung
  One UI behaviour are unchecked here.
- **No macOS large-text evidence** exists at all — finding 2's "after" cannot be shown until a
  scaled snapshot is produced.
- My fresh mac render is 26 states that are not in the committed set (`notes-error`, `notes-paused`,
  `notes-offline`, `notes-mic-silent`, `notes-long-run`, `notes-toast`, `notes-transcript`,
  `notes-show-markdown`, the five `notes-retranscribe-*`, …). They are correct and worth committing
  so the states that matter most (error, paused, offline) are reviewable from the repo.
- Contrast numbers are core-glyph measurements on sub-pixel-antialiased AppKit text, so they are
  upper bounds on the true ratio; the failures are large enough (1.87:1 vs 4.5:1) that this does not
  change any conclusion.

## Cross-check against planner list (#303)

Verified the planner's observations in source and added what was missing. Corrections first.

**Sharpened**
- The `0.01` pt syntax hiding is not only a leak: `NotesEditorStyle.swift:18` hides syntax by face size
  while `NotesEditor.swift:153-181` draws bullets, check boxes and callouts as `CGImage`s, and the file
  has no `setAccessibility*` call at all. A VoiceOver user cannot tick a to-do, and the editor itself is
  unlabelled (only the title field is labelled, `NotesView.swift:187`). Geometry is already available
  (`rect(of:)`, `NotesEditor.swift:122-135`), so AX children over the drawn marks are bounded work.
- `SpeakerChip` (`NotesSpeakerUi.kt:61-66`) is ~28 dp tall: it passes WCAG 2.2 AA 2.5.8 (24 dp) but
  fails Material's 48 dp and the repo's own 48 dp claim. Convention regression, not an AA failure, so
  it should not outrank item 1.
- The single-slot banner is real (`NotesScreen.kt:154-164`): a recovered note or a pending "Who was
  speaking?" disappears behind an action status.
- Pond ink `0x0D1526` is duplicated at four consumer sites (`ScratchpadActivity.kt:243`,
  `QuickDictateActivity.kt:172`, `VoicePanel.kt:71`, plus `ChirpTheme.kt`).

**Corrected**
- Item 1 above is no longer "unverified": it is measured (1.87–3.95:1 vs 4.5:1). Dark passes because
  `inkMuted` is a real token; the failures are AppKit `tertiaryLabelColor` and 11–12 pt sizes, and
  `ThemeTests` needs the `surfaceRaised` case added.
- "Zero Dynamic Type" is right, but `dynamicTypeSize` alone does not fix it: the 680 pt measure
  (`NotesEditor.swift:68-81`) and a 260–320 pt sidebar mean window scaling is no workaround.

**Added (capture controls, actionable states, a11y)**
- Android resume draws a microphone: `NotesScreen.kt:428` (`ic_mic` when paused) inside a toggle whose
  label is "Resume recording notes"; macOS uses `play.fill` (`NotesView.swift:344`).
- Android recording has no accessible name carrying title and time: bare timer text
  (`NotesScreen.kt:432`), and the library card has no semantics at all
  (`NotesLibraryScreen.kt:383-398`), against macOS's "Recording `<title>`, `<elapsed>`" capsule
  (`NotesView.swift:309`).
- `HearingStrip` (`NotesView.swift:765-790`) combines the whole strip and labels it with text that
  changes every partial, without `.updatesFrequently` (which `HUD.swift:326` does set), so VoiceOver
  repeats complete sentences while recording.
- macOS sidebar focus ring: plausible but unproven — a custom `listRowBackground` suppresses the default
  focused-row style and `NotesSidebar.swift:31-60` has no focus-driven style. Check: Tab into the
  sidebar with the window key and compare against an inactive window.

**Closed, so nobody re-spends a wave**
- macOS HUD VoiceOver wiring exists (`NotesController.swift:48-51` posts
  `.announcementRequested`; `HUD.swift:326` sets `updatesFrequently`).
- Onboarding at 200% is already covered (`VoiceUiTest.kt:141`, committed `onboarding-font-200-*`).
- `VoicePanel` `textSize = 15f` is sp and does scale; the risk is fixed dp containers
  (`VoicePanel.kt:118-123`) clipping at 2.0, and `FloatingMicRenderTest` sets no font scale — an
  evidence gap, not a units bug.

## Out of scope / untouched by instruction

`defaults`, `history`, `privacy` scope, iOS, and the mac Audio/`RollingDictation` crash were left
alone; no model or backend changes were proposed.
