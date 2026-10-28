# Mac Settings window: resizing and reflow (#332)

#303 left one Mac question open: how the Settings window resizes and reflows. This folder holds the answer and its evidence.
Every image comes from the app's own offscreen renderer at half the rendered resolution. Each page is filled with the
longest values a user can bring: a long microphone name, long custom sound file names, a deep export folder, a long paired
phone name, long bundle IDs, a long server URL and error, a failed speaker model download, five- and six-digit counts and
a long saved-voice name.

```sh
cd mac && swift build --scratch-path /tmp/chirp-review
CHIRP_SNAPSHOT_REVIEW=332 /tmp/chirp-review/debug/ChirpMac --render-snapshots /tmp/chirp-review-332
```

That renders 34 PNGs. Each page appears twice, light and dark: once as the window shows it (`*-window-*`, 720 × 520) and
once stretched to the whole page (`*-page-*`, same width, for review). This folder keeps the `-window-light` set and four
whole pages.

## How the window sizes

- **The window has one size, so its minimum and maximum are the same.** It is 720 × 520 (`SettingsShell.size`). The
  window has no `.resizable` style, and `contentMinSize` and `contentMaxSize` are both 720 × 520 (`SettingsWindow.swift`).
  This matches the System Settings layout: a 200 pt sidebar and a 520 pt page column with 20 pt gutters.
- **Long pages scroll vertically.** Dictation, History & privacy, Clean-up, Notes and Advanced are taller than the window.
  There is never a sideways scroll, because every page is exactly the width of its column.
- **200% text does not apply here.** Settings is AppKit with fixed point sizes, and macOS has no system text size that
  AppKit apps follow. Chirp's own text size (View ▸ Bigger Text) covers Notes and History, not Settings. If Settings
  ever follows a text size, it will need its own reflow pass.

## What was checked, and what was wrong

| Check | Result |
| --- | --- |
| Every visible view on every page (and on the Saved voices detail page) stays inside the page column at the window's size | Holds with long values. Help text wraps; popups and fixed-width value labels truncate inside their slot. |
| Row titles, section headings and sidebar names | None are cut short. |
| Values that truncate can still be read in full | **Defect, fixed.** The custom start and stop sound names, the export folder path and a paired phone's name were cut short with no way to read them. Each now carries the whole value as its tooltip, as the excluded-apps and per-app style rows already did. VoiceOver already read the whole string. |
| The microphone popup with a long device name | Truncates at the tail inside its 280 pt slot. Opening the popup shows full names, as in any macOS popup. Left as is. |

Not a resizing problem, but noticed in the renders: counts are shown without grouping ("12345 notes",
"123456 dictations"), while the Learned summary uses "1,234". Left for a separate change.

## Tests

`mac/Tests/ChirpCoreTests/SettingsWindowSizeTests.swift` lays out the same long values at 720 × 520:

- `everyPageFitsTheFixedWindowWithLongValues`: each page is as wide as its scroll view, and every visible view stays
  inside it. Any single-line label that truncates must have its full text as a tooltip.
- `savedVoicesFitsTheFixedWindowWithALongName`: the same check on the Saved voices detail page.
- `longPagesScrollInsideTheWindow`: the scroll view reaches the window's bottom edge, and a long page scrolls vertically
  only.
- `cutShortValuesShowInFullAsATooltip`: the four labels that were fixed. There is no tooltip once no file is chosen.

Without the fix, the first and last tests fail on exactly those four labels.
