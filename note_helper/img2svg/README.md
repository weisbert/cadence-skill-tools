# img2svg — raster image → line-art SVG

A standalone, **Cadence-independent** companion to note-helper (like `tsv2md`):
trace a raster image (screenshot, diagram, photo) into a clean **line-art SVG**,
then import that SVG into a schematic with note-helper's **Import SVG...**
(Feature A). Pure CPython + **Pillow + numpy** — no potrace, no OpenCV.

## Two modes

| Mode | How | Best for |
|------|-----|----------|
| **threshold** (line-art) | Otsu binarise → trace region outlines | clean line art, logos, block/architecture diagrams, high-contrast figures, silhouettes |
| **edge** (photo) | Sobel edge magnitude → threshold → trace | photos / busy images; more internal detail, but noisier and needs tuning |

Both extract region-boundary contours via **marching squares**, simplify them
with **Douglas–Peucker**, and emit `<path>` outlines (stroke, no fill) in image
coordinates (y-down, standard SVG). note-helper's parser flips Y on import.

## Use

GUI (default): pick an image, choose a mode, tune the sliders, watch the live
preview, **Save SVG...**

```bash
python3 img2svg.py
```

CLI (also the headless fallback when Tkinter is absent):

```bash
python3 img2svg.py IN.png OUT.svg --mode threshold
python3 img2svg.py photo.jpg OUT.svg --mode edge --min-len 12 --simplify 1.2
```

| Option | Meaning | Default |
|--------|---------|---------|
| `--mode threshold\|edge` | tracing mode | threshold |
| `--threshold T` | 0..255 cut | Otsu auto |
| `--invert` | threshold mode: light pixels are foreground | off |
| `--simplify EPS` | Douglas–Peucker epsilon (px) — higher = fewer points | 1.5 |
| `--min-len L` | drop contours shorter than this perimeter (px) — denoise | 8 |
| `--stroke W` | SVG stroke width | 1.0 |
| `--max-dim N` | downscale longer side to N before tracing | 1000 |
| `--blur R` | Gaussian denoise radius before tracing | 0 |

## Tuning tips

- Too much speckle/background noise → raise `--min-len`, raise `--simplify`,
  or add a little `--blur`.
- Faint lines dropped → lower `--threshold` (or `--invert` if your art is
  light-on-dark).
- Too many points (slow/heavy schematic) → raise `--simplify` and/or lower
  `--max-dim`.

## Pipeline

```
raster image ──(img2svg)──► line-art SVG ──(note-helper "Import SVG...")──► schematic note lines
```

note-helper only ever ingests the resulting **vector** file — the (lossy)
raster step lives here, out of the SKILL core, exactly like `tsv2md` keeps the
Excel/clipboard step out.

## Sample

`samples/shapes.png` — a trivial disk + rectangle, for a quick smoke test:

```bash
python3 img2svg.py samples/shapes.png /tmp/shapes.svg --mode threshold
```

## Not yet

Colour layering (per-level posterised contours), and "keep largest N contours"
background suppression. Tune `--min-len` / `--threshold` for now.
