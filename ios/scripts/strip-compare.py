#!/usr/bin/env python3
"""Build docs/screenshots/ios/strip-compare-{iphone,ipad}-{light,dark}.png: Chirp Keyboard's top row beside Android's
keyboard strip, state by state (idle, listening, polishing, final, offline).

Inputs are current captures, not hand-made crops:
- iOS: docs/screenshots/ios/{iphone,ipad}-keyboard-{armed,listening,polishing,finished,error}-{light,dark}.png
  (ChirpKeyboardUITests/testKeyboardStateScreenshotsInMessages).
- Android: the Robolectric strip renders keyboard-{state}-{look}.png (phone, Gboard look) and
  keyboard-gboard-inner-{state}-{look}.png (unfolded, compared with iPad) from KeyboardRenderTest. Render them with
  `./gradlew testDebugUnitTest --tests dev.chirp.android.KeyboardRenderTest` (they land in
  android/app/build/screenshots).

Usage: uv run --with pillow python ios/scripts/strip-compare.py [--android DIR] [--ios DIR] [--out DIR]
"""
import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
STATES = [  # (row label, Android state, iOS state)
    ("Idle", "idle", "armed"),
    ("Listening", "listening", "listening"),
    ("Polishing", "polishing", "polishing"),
    ("Final · Undo · Use raw", "final", "finished"),
    ("Not ready (offline)", "offline", "error"),
]
# Device width in points, and how much of the keyboard to show: the top row plus the first row of keys (on iPad,
# also the system shortcut bar above Chirp's row).
DEVICES = {
    "iphone": dict(points=402, crop=104, android="keyboard-{state}-{look}.png", android_dp=104,
                   android_title="Android (Gboard-style phone)", ios_title="iOS (iPhone)", column=820),
    "ipad": dict(points=1032, crop=165, android="keyboard-gboard-inner-{state}-{look}.png", android_dp=104,
                 android_title="Android (unfolded)", ios_title="iOS (iPad)", column=900),
}
COLORS = {"light": dict(page=(255, 255, 255), ink=(28, 28, 30)), "dark": dict(page=(18, 18, 20), ink=(235, 235, 240))}


def keyboard_top(image: Image.Image) -> int:
    """First row below the host app that is one colour edge to edge: the top of Chirp's row."""
    rgb = image.convert("RGB")
    w, h = rgb.size
    page = rgb.getpixel((w // 2, int(h * 0.3)))
    for y in range(int(h * 0.4), h):
        row = [rgb.getpixel((x, y)) for x in range(0, w, max(1, w // 120))]
        off = sum(1 for p in row if sum(abs(a - b) for a, b in zip(p, page)) > 24)
        if off > len(row) * 0.97:
            return y
    raise SystemExit("No keyboard found in a capture")


def font(size: int) -> ImageFont.FreeTypeFont:
    for path in ("/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc",
                 "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"):
        if Path(path).exists():
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def fit(image: Image.Image, width: int) -> Image.Image:
    return image.resize((width, round(image.height * width / image.width)), Image.LANCZOS)


def sheet(device: str, look: str, android_dir: Path, ios_dir: Path) -> Image.Image:
    d = DEVICES[device]
    column, gutter, margin, label, gap = d["column"], 20, 20, 30, 24
    title_font, row_font = font(22), font(22)
    rows = []
    for name, android_state, ios_state in STATES:
        a = Image.open(android_dir / d["android"].format(state=android_state, look=look)).convert("RGB")
        a = a.crop((0, 0, a.width, min(a.height, d["android_dp"] * a.width // (673 if device == "ipad" else 411))))
        i = Image.open(ios_dir / f"{device}-keyboard-{ios_state}-{look}.png").convert("RGB")
        top = keyboard_top(i)
        i = i.crop((0, top, i.width, min(i.height, top + round(d["crop"] * i.width / d["points"]))))
        rows.append((name, fit(a, column), fit(i, column)))
    height = margin + label * 2 + sum(label + max(a.height, i.height) + gap for _, a, i in rows) + margin - gap
    out = Image.new("RGB", (margin * 2 + column * 2 + gutter, height), COLORS[look]["page"])
    draw = ImageDraw.Draw(out)
    ink = COLORS[look]["ink"]
    draw.text((margin, margin), d["android_title"], font=title_font, fill=ink)
    draw.text((margin + column + gutter, margin), f"{d['ios_title']} · {look}", font=title_font, fill=ink)
    y = margin + label * 2
    for name, a, i in rows:
        draw.text((margin, y), name, font=row_font, fill=ink)
        y += label
        out.paste(a, (margin, y))
        out.paste(i, (margin + column + gutter, y))
        y += max(a.height, i.height) + gap
    return out


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--android", type=Path, default=ROOT / "android/app/build/screenshots")
    parser.add_argument("--ios", type=Path, default=ROOT / "docs/screenshots/ios")
    parser.add_argument("--out", type=Path, default=ROOT / "docs/screenshots/ios")
    args = parser.parse_args()
    for device in DEVICES:
        for look in ("light", "dark"):
            path = args.out / f"strip-compare-{device}-{look}.png"
            sheet(device, look, args.android, args.ios).save(path, optimize=True)
            print(path)


if __name__ == "__main__":
    main()
