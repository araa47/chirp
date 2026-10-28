#!/usr/bin/env python3
"""Regenerate responsive WebP assets from committed screenshots. Requires Pillow.

Run: uv run --with pillow python site/prepare_images.py
The normal site build needs only Python's standard library and never uses the network.
"""
import hashlib
import json
import re
from pathlib import Path

from PIL import Image, ImageOps

ROOT = Path(__file__).resolve().parent.parent
SHOTS = ROOT / "docs/screenshots"
DEST = ROOT / "site/assets/screenshots"
PATTERN = re.compile(r"<!--shot:([\w/.-]+)\|")


def sources(name):
    light = SHOTS / f"{name}-light.png"
    single = SHOTS / f"{name}.png"
    main = light if light.exists() else single
    if not main.exists():
        raise SystemExit(f"Missing screenshot: {name}")
    dark = SHOTS / f"{name}-dark.png"
    if name.startswith("ios/"):
        dark = SHOTS / (name.replace("ios/iphone-", "ios/iphone-dark-").replace("ios/ipad-", "ios/ipad-dark-") + ".png")
    return [main] + ([dark] if dark.exists() and dark != main else [])


def main():
    artwork = {}
    for source_name, target_name, lossless in [('approved-pond-fullbleed.png', 'pond.webp', False), ('approved-glyph.png', 'glyph.webp', True)]:
        source = ROOT / 'android/artwork/chirp-icons' / source_name
        image = Image.open(source)
        target = ROOT / 'site/assets' / target_name
        image.save(target, 'WEBP', lossless=lossless, quality=86, method=4)
        artwork[target_name] = {'source': source_name, 'sha256': hashlib.sha256(source.read_bytes()).hexdigest(), 'width': image.width, 'height': image.height}
    pond = Image.open(ROOT / 'android/artwork/chirp-icons/approved-pond-fullbleed.png')
    for size in (128, 256, 640):
        name = f'pond-{size}.webp'
        pond.resize((size, size), Image.Resampling.LANCZOS).save(ROOT / 'site/assets' / name, 'WEBP', quality=86, method=4)
        artwork[name] = dict(artwork['pond.webp'], width=size, height=size)
    (ROOT / 'site/assets/artwork.json').write_text(json.dumps(artwork, indent=2) + '\n')
    wanted = set()
    for page in (ROOT / "site/pages").rglob("*.html"):
        for name in PATTERN.findall(page.read_text()):
            wanted.update(sources(name))
    DEST.mkdir(parents=True, exist_ok=True)
    manifest = {}
    expected = set()
    for source in sorted(wanted):
        rel = source.relative_to(SHOTS).as_posix()
        image = ImageOps.exif_transpose(Image.open(source)).convert("RGB")
        width, height = image.size
        entries = []
        for size in sorted({min(width, x) for x in (320, 640, 960, 1440)}):
            target = DEST / f"{rel[:-4]}-{size}.webp"
            target.parent.mkdir(parents=True, exist_ok=True)
            resized = image.resize((size, round(height * size / width)), Image.Resampling.LANCZOS)
            resized.save(target, "WEBP", quality=88, method=4)
            entries.append({"file": target.relative_to(DEST).as_posix(), "width": size, "height": resized.height})
            expected.add(target)
        manifest[rel] = {"sha256": hashlib.sha256(source.read_bytes()).hexdigest(), "width": width, "height": height, "variants": entries}
    for old in DEST.rglob("*.webp"):
        if old not in expected:
            old.unlink()
    (DEST / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Prepared {len(expected)} responsive images from {len(wanted)} committed screenshots")


if __name__ == "__main__":
    main()
