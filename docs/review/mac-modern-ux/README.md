# Mac Notes: readable text and honest capture states (#303)

Before/after evidence for the Mac part of #303. Every image comes from the app's own offscreen renderer
(`ChirpMac --render-snapshots`), at half the rendered resolution. `before/` is the base commit `3fb6722f`;
`after/` is this branch. File names are `<state>-<window width>-<text size>-<appearance>.png`; 760 is the
minimum Notes window (760×460), 1120 the default.

To render the full matrix (100% and 200%, 760 and 1120, light and dark, recording, paused, empty, no results,
error, transcript, Recently Deleted, keyboard focus, History and the formatted reader) into a folder:

```sh
cd mac && swift build --scratch-path /tmp/chirp-review
CHIRP_SNAPSHOT_REVIEW=303 /tmp/chirp-review/debug/ChirpMac --render-snapshots /tmp/chirp-review-303
```

The toolbar looks dim in every capture: the snapshot window is never key, so AppKit draws it inactive. That is
not a contrast defect.

## What changed, and what shows it

| Area | Before | After | Evidence |
| --- | --- | --- | --- |
| Text size | No control; the editor ignored any SwiftUI size. | View ▸ Bigger Text / Smaller Text / Actual Size (⌘+ ⌘− ⌘0), 100–200% in six steps, per Notes window. The AppKit editor rescales its attributes only, so text, UTF-16 offsets, selection and Undo stay native. The library, title, metadata, banners, transcript and the reader follow; toolbar and menu chrome stay native size. History has the same steps in a toolbar menu. | `after/recording-1120-200-light.png`, `recording-760-200-dark.png`, `history-200-*.png`; `textSizeChangesPreserveDocumentSelectionAndUndo` |
| Metadata contrast | Secondary/tertiary label colours on the Pond surfaces (DeepSeek measured 1.87–3.95:1 light, 2.24:1 dark tertiary). | Pond muted ink, measured on the drawn pixels: editor 5.85 / 7.54:1, sidebar 5.08 / 6.66:1, selected row 4.81 / 7.56:1 (light / dark). Increase Contrast turns it into full ink (13.7 / 12.7:1). | `metadataInkMeasuresAtLeastFourAndAHalfToOneWhereItIsDrawn` |
| Narrow transcript | At 760 pt the third column left the note a 159 pt line (`before/transcript-760-100-*.png`). | Below 1000 pt the same transcript sits under the note, not modal: the note keeps a 399 pt measure at 100% and 200%, and recording, typing and replay keep working. Resizing keeps the user's choice. | `after/transcript-760-*.png`; `transcriptKeepsUsefulNoteMeasureAcrossWindowSizes` |
| Paused | Red dot and “Recording” section, “Hearing” over cached words. | Pause glyph in muted ink in the header, sidebar section “Paused”, no ripple, and “Last heard” in the strip. The strip announces a fixed label with the words as its value, not a new sentence per partial. | `before/` vs `after/paused-1120-100-*.png` |
| Tasks | Drawn boxes only; VoiceOver saw Markdown text. | The editor is labelled “Notes editor” and exposes each task as an AXCheckBox child. AXPress goes through the same toggle and Undo as a click, and a stale node refuses to act on another document or a moved line. View ▸ Read Formatted Note shows headings, bullets and tasks without syntax; its checkboxes use the same edit path. | `standardAXTaskActionEditsSameDocumentAndUndoes`, `formattedReaderTogglesTasksThroughTheEditorWithUndo`, `after/reader-*.png` |
| Keyboard focus | Selection and focus looked the same. | A 2 pt koi ring on the selected row while the list is first responder, separate from the selection fill. | `before/` vs `after/focus-760-100-*.png` |
| Delete Now | Purged at once, including kept audio. | Asks first; Cancel leaves the note and its audio. Restore, trash Undo and Empty… are unchanged. | `deletingNowRequiresAnExplicitConfirmationAndCancelPreservesAudio` |
| Large text reflow | n/a | Sidebar rows and Recently Deleted stack their title and date over 130%; meta facts wrap only when they do not fit; the empty state scrolls. | `after/empty-760-200-light.png`, `no-results-760-200-light.png`, `deleted-760-200-dark.png` |

The HUD keeps its layout: only its font roles changed (hint and chips at 12 pt). The capsule's width and border
belong to a separate change.

## Not verified here

- VoiceOver and Increase Contrast at runtime: the host's accessibility settings are not ours to change, and AppKit
  cannot build the high-contrast appearances offscreen. The tests walk the accessibility tree and perform AXPress,
  and check the colour Increase Contrast selects.
- Text size is per window and per session. Remembering it across launches needs a preference, which the
  preferences owner holds.
- History's ⌘+/⌘−/⌘0 sit in a toolbar menu. The menu itself works, but no keystrokes could be synthesised here to
  test the shortcuts.
