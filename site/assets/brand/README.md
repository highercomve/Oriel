# Oriel brand

The mark is a **bay window seen from above** (an *oriel* is a bay window
projecting from a wall). Its angled side walls read as `<` `>` around a lit
pane: a native window around the web.

Regenerate everything with `python3 assets/brand/generate.py` (needs
`fontTools` and `rsvg-convert`). All files here except `generate.py` and this
README are generated; edit the generator, not the SVGs.

## Files

| File | Use |
|---|---|
| `oriel-mark.svg` / `oriel-mark-dark.svg` | The mark alone, for light / dark backgrounds |
| `oriel-wordmark.svg` / `oriel-wordmark-dark.svg` | Mark + "oriel", for light / dark backgrounds |
| `oriel-icon.svg`, `oriel-icon-{16…1024}.png` | App icon (mark on a rounded night tile) |
| `oriel-banner.svg` / `.png` | README header and social preview (1280×640) |

## Palette

| Name | Hex | Use |
|---|---|---|
| Ink | `#1B1F2A` | Mark and text on light backgrounds |
| Cream | `#F4EFE6` | Mark and text on dark backgrounds; light surface |
| Amber | `#F7A41D` | The lit pane (a nod to Zig's orange); accents |
| Amber light | `#FFC857` | Top of the pane gradient |
| Night | `#12151C` | Icon tile, banner, dark surfaces |

## Type

Wordmark: **Inter Display Bold**, lowercase, tracking −2.5 at 88 px.
Taglines and body: Inter Regular. The wordmark is outlined in the SVGs, so
it renders without the font installed.

## Usage

- Keep clear space around the mark of at least the pane's width.
- Use the dark variants on dark backgrounds; don't recolor the pane.
- The icon works down to 16 px; below 32 px prefer the icon over the wordmark.
