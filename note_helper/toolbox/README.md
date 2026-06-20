# note-helper toolbox — one GUI for the Python data-prep front-ends

A single Tkinter window that bundles note-helper's standalone Python companions
as tabs. Logically they're the same job — **clean/convert raw data on the Python
side so it drops cleanly into a Cadence schematic**:

| Tab | Tool | Does | Feed into |
|-----|------|------|-----------|
| **Image → SVG** | `img2svg` | trace a raster image to a line-art SVG (threshold/edge, Levels detail, rm-bg) with a live preview | note-helper **Import SVG...** |
| **Table → Markdown** | `tsv2md` | Excel-copied TSV (clipboard or **Open file**) → aligned Markdown, to clipboard or **Save .md** | paste into the note-helper form |

The algorithms are **imported** from the sibling modules (`../img2svg/img2svg.py`,
`../tsv2md/tsv2md.py`) — this file is only the shared UI, so there's one source
of truth for the logic. Standard library + Pillow + numpy.

## Run

```bash
python3 toolbox.py            # the unified GUI
python3 toolbox.py --selftest # headless build + exercise both tabs (CI/smoke)
```

The standalone tools still work on their own (`python3 ../img2svg/img2svg.py`,
`python3 ../tsv2md/tsv2md.py`) — the toolbox just composes them.

## tkinter requirement (Linux note)

tkinter is in the Python standard library but is a wrapper over the Tcl/Tk C
library, so on Linux it's a **separate package** and is only present if the
interpreter was built with Tk. On Rocky/RHEL 8 with the packaged `python3.11`:

```bash
sudo dnf install python3.11-tkinter      # pulls tcl + tk
python3 -c "import tkinter; print(tkinter.TkVersion)"   # verify
```

(The system `python3.6` has a separate `python3-tkinter`, but lacks Pillow/numpy
— use the `python3.11` that already has them.)

## Pipeline

```
            ┌─ Image → SVG ──► .svg ─┐
raw data ──►│                        ├──► note-helper ──► schematic notes
            └─ Table → Markdown ─────┘     (Import SVG / paste table)
```
