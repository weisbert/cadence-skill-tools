# nh_svg2ir — SVG → note-helper IR

The Feature-A vector parser for **note-helper**. Reads an SVG figure and writes
a **SKILL list literal** of note-helper IR elements, which the SKILL side reads
straight back (`infile` + `read`) and renders as schematic note lines.

Standalone and **Cadence-independent** — Python **standard library only** (no
`svgpathtools`, `cairosvg`, `numpy`, …), so it runs anywhere CPython 3 does.

## Use

note_helper invokes this for you (the GUI **Import SVG...** button, or
`nhImportVector` / `nhPlaceVector` in SKILL). To run it directly:

```bash
python3 nh_svg2ir.py INPUT.svg OUTPUT.il --width 5.0
```

Options:

| Option | Meaning | Default |
|--------|---------|---------|
| `--width W` | target figure width in user units (aspect preserved) | 5.0 |
| `--height H` | target height instead of width (aspect preserved) | — |
| `--font-height FH` | override `<text>` label height (user units) | derive from SVG `font-size` |
| `--curve-tol REL` | Bézier flatness as a fraction of the figure diagonal | 0.0015 |
| `--max-seg N` | max subdivision depth per Bézier | 18 |
| `--arc-n N` | arc sampling hint | 24 |
| `--ellipse-n N` | points per circle/ellipse | 48 |

## What it handles

- `<path>` `d` data: `M/L/H/V` lines, `C/S` cubic + `Q/T` quadratic Béziers
  (adaptively flattened to polylines), `A` elliptic arcs (sampled), `Z` close —
  absolute and relative forms (incl. the relative `m` after `z`).
- `<line>`, `<polyline>`, `<polygon>`, `<rect>`, `<circle>`, `<ellipse>`.
- `<text>` → an IR label (position + text + a scaled height).
- `transform` attributes (`matrix`/`translate`/`scale`/`rotate`/`skewX`/`skewY`),
  composed down the element tree.
- `defs`/`symbol`/`clipPath`/gradients/etc. are skipped.

## Coordinates

SVG user space is **y-down**; a Cadence schematic is **y-up**. The whole figure
is collected in user units (after applying transforms), bbox-normalised to the
origin, **uniformly** scaled to the requested width (aspect preserved), and
**Y-flipped** so it lands upright in the positive quadrant.

## Output format

One top-level list of IR DPLs, identical to the table path's IR (see
`../nhCore.il`):

```skill
(
 (nil kind shape stype "line" lstyle "solid" points ((x y) ...) width nil)
 (nil kind label point (x y) text "..." height 0.125
      just "lowerLeft" orient "R0" font "fixed" ltype "normalLabel")
)
```

Numbers are written in plain fixed-point (no exponent), so SKILL `read`
reconstructs the list directly — no JSON, no parser on the SKILL side.

## Sample

`samples/mona_lisa.svg` — a quick end-to-end test figure (a single path of
lines + cubic Béziers):

```bash
python3 nh_svg2ir.py samples/mona_lisa.svg /tmp/mona.il --width 5
```

Source: the "Mona Lisa" icon by Delapouite at
[game-icons.net](https://game-icons.net/), CC BY 3.0.

## Not yet

DXF input (would want a DXF reader), and `<image>` / embedded raster (would need
a separate tracing step — kept as a future standalone companion, not here).
