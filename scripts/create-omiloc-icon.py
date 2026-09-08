#!/usr/bin/env python3
"""Render the code-native omiloc monogram; Pillow is needed only to regenerate assets."""

from pathlib import Path

from PIL import Image, ImageDraw


def render(size=1024):
    scale = 4
    canvas = Image.new('RGBA', (size * scale, size * scale))
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
    destination = Path(__file__).resolve().parents[1] / 'web-local/assets'
    destination.mkdir(parents=True, exist_ok=True)
    icon = render()
    icon.save(destination / 'omiloc.png')
    icon.save(destination / 'omiloc.icns')
