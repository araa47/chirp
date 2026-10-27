# Android Notes UX (#302): before/after renders

Each image puts the baseline (`398b528d`) render beside the render from this branch. Both come from the same
Robolectric tests and fixtures (`NotesLibraryScreenTest`, `NotesRenderTest`, `FloatingMicRenderTest`,
`NotesCaptureUxTest`, `NotesSpeakersRenderTest`), at mdpi:

| Prefix | Width | Text |
| --- | --- | --- |
| `notes-library-cover-*`, `notes-cover-*` | 411dp cover | 100% |
| `notes-library-inner-*`, `notes-inner-*` | 840dp / 832dp unfolded | 100% |
| `notes-library-narrow-font-200-*`, `notes-cover-font-200-*` | 360dp narrow cover | 200% |
| `notes-library-inner-font-200-*`, `notes-inner-font-200-*` | 840dp unfolded | 200% |
| `floating-*-font-200-*` | cover and unfolded panel | 200% |

All in light and dark. Before images at 200% were rendered from the baseline with this branch's render helpers and
without its new assertions; the floating panel's 200% before images came from the earlier handoff.
`notes-status-stack-font-200-*` is new (a state the baseline could not show: its single banner slot showed one notice).

What to look for:

- Library primary action: `Open recording` / `Open paused note` while a note holds the microphone (the baseline
  offered `Record`, which asked to stop it). New recording stays under ⋮ → Record new note, with its confirmation.
- Recording card: Paused vs Recording in words and glyph, elapsed time on its own line, one TalkBack button.
  At 200% it is part of the list instead of a sticky header that crowded out the rows, and it stays in view.
- Rows: title on its own line; age, length and `N open tasks` (icon and words instead of a ☐ glyph) wrap below.
- Empty and no-results: New note / Record and Clear search beside the explanation. Couldn't open: Try again / Back.
- Notes dock: the compact pill keeps its size; Recording/Paused is written above the time, Resume uses a play glyph,
  and at 200% or on a narrow screen Hold to edit stacks above the pill instead of shrinking to `H…`.
- Floating panel at 200%: Cancel moves below the mic instead of overlapping it. The Private label's fixed 24dp height is
  now a minimum (by construction; no render turns private mode on, so it is not pictured).
- Speaker chips: the same compact capsules with 48dp touch targets.
- Collapsed library title at 200%: one line with an ellipsis instead of `Note / s`.
