#!/usr/bin/env python3
"""Render the code-native omiloc monogram; Pillow is needed only to regenerate assets."""

import argparse
import json
from pathlib import Path

from PIL import Image, ImageDraw


def render(size=1024, *, ios=False):
    scale = 4
    # iOS applies its own corner mask and requires an opaque app icon.
    canvas = Image.new('RGB' if ios else 'RGBA', (size * scale, size * scale), '#f5f3ee' if ios else 0)
    draw = ImageDraw.Draw(canvas)

    def box(coords):
        return tuple(round(value * size / 1024 * scale) for value in coords)

    draw.rounded_rectangle(box((64, 64, 960, 960)), radius=round(202 * size / 1024 * scale), fill='#f5f3ee')
    # Lowercase o and the wordmark's full stop remain legible at Desktop sizes.
    draw.ellipse(box((234, 286, 682, 734)), fill='#252421')
    draw.ellipse(box((332, 384, 584, 636)), fill='#f5f3ee')
    draw.ellipse(box((718, 650, 802, 734)), fill='#252421')
    return canvas.resize((size, size), Image.Resampling.LANCZOS)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ios', action='store_true', help='Render the Personal Team iOS app icon catalog only.')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    if args.ios:
        destination = root / 'app/ios/Runner/Assets.xcassets/personalAppIcon.appiconset'
        catalog = json.loads((destination / 'Contents.json').read_text())
        for item in catalog['images']:
            size = round(float(item['size'].split('x')[0]) * float(item['scale'].removesuffix('x')))
            render(size, ios=True).save(destination / item['filename'])
        print(f"Rendered {len(catalog['images'])} opaque iOS app icons.")
        raise SystemExit(0)
    destination = root / 'web-local/assets'
    destination.mkdir(parents=True, exist_ok=True)
    icon = render()
    icon.save(destination / 'omiloc.png')
    icon.save(destination / 'omiloc.icns')
