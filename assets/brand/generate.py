#!/usr/bin/env python3
"""Generate the Oriel brand assets: SVG masters + PNG renders.

    python3 assets/brand/generate.py

Needs: fontTools (wordmark outlines from Inter Display), rsvg-convert.
Everything in this folder except this script and README.md is generated.
"""

import subprocess
from pathlib import Path

from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTCollection

OUT = Path(__file__).resolve().parent

# Palette (see README.md)
INK = "#1B1F2A"      # frame, text on light
CREAM = "#F4EFE6"    # frame, text on dark
AMBER = "#F7A41D"    # glass (a nod to Zig's orange)
AMBER_HI = "#FFC857"
NIGHT = "#12151C"    # icon / banner background


def mark(frame: str, prefix: str = "") -> str:
    """The Oriel mark in a 128x128 box: a bay window seen from above. Its
    angled side walls read as `<` `>` around a lit pane: native + web."""
    return f"""
  <defs>
    <linearGradient id="{prefix}glass" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{AMBER_HI}"/><stop offset="1" stop-color="{AMBER}"/>
    </linearGradient>
  </defs>
  <g fill="none" stroke="{frame}" stroke-width="12" stroke-linecap="round" stroke-linejoin="round">
    <path d="M42 30 L16 64 L42 98"/>
    <path d="M86 30 L112 64 L86 98"/>
  </g>
  <rect x="50" y="24" width="28" height="80" rx="6" fill="url(#{prefix}glass)"/>
  <path d="M50 64 H78" stroke="{frame}" stroke-width="5"/>"""


def svg(width: int, height: int, body: str, title: str = "Oriel") -> str:
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" '
        f'width="{width}" height="{height}">\n  <title>{title}</title>{body}\n</svg>\n'
    )


def load_font(style: str = "Bold"):
    """Inter Display <style> from the system Inter collection."""
    path = subprocess.run(["fc-match", "-f", "%{file}", f"Inter Display:{style.lower()}"],
                          capture_output=True, text=True, check=True).stdout
    for font in TTCollection(path).fonts:
        name = font["name"]
        family = name.getBestFamilyName() or ""
        sub = name.getBestSubFamilyName() or ""
        if family.startswith("Inter Display") and style in (family + " " + sub):
            return font
    raise SystemExit(f"Inter Display {style} not found in {path}")


def text_path(font, text: str, size: float, x: float, baseline: float, tracking: float = 0.0) -> str:
    """SVG path data for `text` (outlined, so no font is needed to render it)."""
    glyphs = font.getGlyphSet()
    cmap = font.getBestCmap()
    scale = size / font["head"].unitsPerEm
    pen = SVGPathPen(glyphs)
    cursor = x
    for ch in text:
        name = cmap[ord(ch)]
        glyph = glyphs[name]
        glyph.draw(TransformPen(pen, (scale, 0, 0, -scale, cursor, baseline)))
        cursor += glyph.width * scale + tracking
    return pen.getCommands()


def text_width(font, text: str, size: float, tracking: float = 0.0) -> float:
    glyphs = font.getGlyphSet()
    cmap = font.getBestCmap()
    scale = size / font["head"].unitsPerEm
    return sum(glyphs[cmap[ord(c)]].width * scale for c in text) + tracking * (len(text) - 1)


def write(name: str, content: str) -> Path:
    path = OUT / name
    path.write_text(content)
    return path


def render(svg_path: Path, png_name: str, width: int, height: int | None = None) -> None:
    args = ["rsvg-convert", "-w", str(width)]
    if height:
        args += ["-h", str(height)]
    subprocess.run(args + [str(svg_path), "-o", str(OUT / png_name)], check=True)


def main() -> None:
    bold = load_font("Bold")
    regular = load_font("Regular")

    # Mark: light backgrounds, dark backgrounds.
    mark_light = write("oriel-mark.svg", svg(128, 128, mark(INK)))
    mark_dark = write("oriel-mark-dark.svg", svg(128, 128, mark(CREAM, "d-")))

    # App icon: the mark on a rounded night tile (freedesktop/macOS style).
    icon = write("oriel-icon.svg", svg(512, 512,
        f'\n  <rect x="16" y="16" width="480" height="480" rx="108" fill="{NIGHT}"/>'
        f'\n  <g transform="translate(64 60) scale(3)">{mark(CREAM, "i-")}\n  </g>'))

    # Wordmark: mark + "oriel", for light and dark backgrounds.
    size, tracking = 88, -2.5
    word_w = text_width(bold, "oriel", size, tracking)
    width = int(128 + 20 + word_w + 8)
    for suffix, color, prefix in (("", INK, "w-"), ("-dark", CREAM, "wd-")):
        write(f"oriel-wordmark{suffix}.svg", svg(width, 128,
            f"{mark(color, prefix)}"
            f'\n  <path d="{text_path(bold, "oriel", size, 148, 96, tracking)}" fill="{color}"/>'))

    # Banner for the README / social preview (1280x640).
    tag = "Desktop apps with Zig and the web"
    tag_size = 34
    tag_w = text_width(regular, tag, tag_size)
    title_w = text_width(bold, "oriel", 150, -4)
    group_w = 220 + 40 + title_w
    gx = (1280 - group_w) / 2
    banner = write("oriel-banner.svg", svg(1280, 640,
        f'\n  <rect width="1280" height="640" fill="{NIGHT}"/>'
        f'\n  <g transform="translate({gx:.1f} 170) scale(1.72)">{mark(CREAM, "b-")}\n  </g>'
        f'\n  <path d="{text_path(bold, "oriel", 150, gx + 260, 335, -4)}" fill="{CREAM}"/>'
        f'\n  <path d="{text_path(regular, tag, tag_size, (1280 - tag_w) / 2, 480)}" fill="{AMBER}"/>'))

    # PNG renders.
    for px in (16, 24, 32, 48, 64, 128, 256, 512, 1024):
        render(icon, f"oriel-icon-{px}.png", px)
    render(mark_light, "oriel-mark-512.png", 512)
    render(mark_dark, "oriel-mark-dark-512.png", 512)
    render(OUT / "oriel-wordmark.svg", "oriel-wordmark.png", width * 3)
    render(OUT / "oriel-wordmark-dark.svg", "oriel-wordmark-dark.png", width * 3)
    render(banner, "oriel-banner.png", 1280)
    print(f"generated in {OUT}")


if __name__ == "__main__":
    main()
