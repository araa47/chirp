# Android: Match wallpaper on real wallpapers (#332)

Until #332, dynamic colour ("Match wallpaper") had only been checked against Robolectric fixture schemes. These sheets
come from the emulator with real system wallpapers. Each wallpaper is set through `WallpaperManager`, Android extracts
its colours, and System UI builds the Monet palette the app reads with `dynamicLightColorScheme` /
`dynamicDarkColorScheme`.

```sh
android/scripts/e2e-all.sh --only wallpaper            # captures + palettes.json in <evidence>/wallpaper
uv run --with pillow python3 android/scripts/text-contrast-report.py <evidence>/wallpaper
```

`match-wallpaper-light.png` and `match-wallpaper-dark.png` show, per wallpaper (rows), the Notes library, a note, History,
Settings, Feedback & look (Match wallpaper chosen) and Quick dictate on the 1080 × 2520 cover screen.

## Wallpapers and the palettes they produced

The debug-only `WallpaperProbeActivity` draws five photo-like gradients (warm, cool, green, pale and near-black) with
fine grain, and sets each one as the home and lock wallpaper.

| Wallpaper | Seed from `WallpaperColors.fromBitmap` | Palette System UI applied | How it was applied |
| --- | --- | --- | --- |
| sunset (warm, mid) | `CC4057` | `CC4057` | seed (see below) |
| ocean (cool, light → dark) | `2A84B2` | `2780AF` | System UI, from the wallpaper |
| forest (green, dark) | `346231` | `406C37` | System UI, from the wallpaper |
| snow (pale, light) | `C8D2DE` | `D0D7E1` | System UI, from the wallpaper |
| night (near-black, dark) | `302C5F` | `27244A` | System UI, from the wallpaper |

On the freshly booted read-only AVD, System UI didn't re-theme for the first wallpaper change. The check then writes
`theme_customization_overlay_packages` with the extracted seed, as the Wallpaper & style picker does, and Monet ran on
it. After that, System UI applied each new wallpaper's own palette by itself.

## Findings

- **The app follows the wallpaper everywhere it should.** That covers surfaces, the search field, cards, the Record /
  Continue recording / Allow buttons, chips, switches and the navigation bar.
- **No contrast problems.** `text-contrast-report.py` measured 628 text nodes across the 60 captures.
  - Lowest in light: 4.97:1, the "Computer" connection chip. That's Chirp's fixed brand green on the dynamic surface,
    the same on every wallpaper. Next lowest are the search placeholders, at 5.2:1.
  - Lowest in dark: 6.04:1 ("Continue recording" on its container).
  - The report is a heuristic, but nothing it found falls below 4.5:1, and the sheets show no text that's hard to read.
- **Fixed brand roles stay fixed, as designed** (`chirpRoles` in `ui/ChirpTheme.kt`): the Quick dictate mic ring
  (orange), the connection green and the record red don't take the wallpaper's hue.
- **"Hold to edit" uses the tertiary container**, so it takes the palette's third hue: pink on sunset, yellow on forest,
  lilac on ocean. That is Material 3's intended role and reads at ≥ 6:1. No change.
- **Not covered here:** the keyboard strip and floating mic panel follow the keyboard look and the panel palette, which
  `StripStatesTest` and `FloatingMicRenderTest` cover. A physical-phone pass is in the operator checklist.
- In the Notes and note captures, the on-screen keyboard stays open from the search field. That's a capture artefact,
  not app behaviour.
