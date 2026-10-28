#!/usr/bin/env python3
"""Estimate the contrast of each text node in emulator captures (a screenshot plus its node JSON).

Usage: uv run --with pillow python3 android/scripts/text-contrast-report.py <capture dir> [--min 4.5]
Within each node's bounds the most common colour is taken as the background and the frequent colour
farthest from it as the text. That is a heuristic for finding screens to look at, not a WCAG audit:
icons, images and selection fills inside a node's bounds can skew it.
"""
import argparse
from collections import Counter
import json
from pathlib import Path

from PIL import Image


def luminance(rgb):
    def channel(c):
        c /= 255
        return c / 12.92 if c <= .04045 else ((c + .055) / 1.055) ** 2.4
    r, g, b = map(channel, rgb)
    return .2126 * r + .7152 * g + .0722 * b


def contrast(a, b):
    la, lb = sorted((luminance(a), luminance(b)), reverse=True)
    return (la + .05) / (lb + .05)


def measure(image, box):
    x1, y1, x2, y2 = box
    if x2 - x1 < 4 or y2 - y1 < 4: return None
    data = image.crop(box).tobytes()
    pixels = Counter(zip(data[0::3], data[1::3], data[2::3]))
    total = sum(pixels.values())
    background = pixels.most_common(1)[0][0]
    # Glyph cores: colours covering at least 0.5% of the box; anti-aliased edges are rarer.
    frequent = [colour for colour, count in pixels.most_common(64) if count / total >= .005 and colour != background]
    if not frequent: return None
    text = max(frequent, key=lambda colour: contrast(colour, background))
    return contrast(text, background), background, text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('captures', type=Path)
    parser.add_argument('--min', type=float, default=4.5)
    args = parser.parse_args()
    lowest = []
    for nodes in sorted(args.captures.glob('*.json')):
        if nodes.name == 'captures.json': continue
        image = Image.open(nodes.with_suffix('.png')).convert('RGB')
        for node in json.loads(nodes.read_text()):
            result = measure(image, tuple(node['bounds']))
            if result: lowest.append((result[0], nodes.stem, node['text'], result[1], result[2]))
    lowest.sort()
    flagged = [row for row in lowest if row[0] < args.min]
    print(f'{len(lowest)} text nodes measured, {len(flagged)} below {args.min}:1')
    for ratio, capture, text, background, colour in flagged:
        print(f'{ratio:5.2f}  {capture}  {text[:48]!r}  text #{"%02x%02x%02x" % colour} on #{"%02x%02x%02x" % background}')


if __name__ == '__main__':
    main()
