# note-helper

Add **notes** (non-electrical annotations) to Cadence Virtuoso schematics.
Two features: **(A)** a vector diagram → pure lines; **(B)** a table → a clean
schematic note. Sibling plugin to `dreg_gen` / `mytool`; auto-registers under
the **MyTool** banner menu.

See **[REQUIREMENTS.md](REQUIREMENTS.md)** for the full design, verified API
citations, decisions, and the milestone plan.

## Status — M1 + M3 + M3b (Feature B: tables) + M4 (Feature A: SVG vectors)

### Feature A — vector diagram → lines (M4)

Import an **SVG** figure and drop it into a schematic as pure note lines:

- GUI: put the SVG path in **"SVG file"**, a target **"Figure width"** (user
  units, aspect always preserved), pick the **Output** mode, and click
  **Import SVG...** — then click once in the schematic to place it.
- Handles `<path>` (with cubic/quadratic Béziers + elliptic arcs, flattened to
  polylines), `<line>`, `<polyline>`, `<polygon>`, `<rect>`, `<circle>`,
  `<ellipse>`, and `<text>`; honours `transform` chains; flips Y (SVG is
  y-down, a schematic is y-up) and scales the whole figure uniformly to the
  requested width.
- A vector figure can go in as *loose shapes*, a *symbol*, or a *resizable
  symbol* — the same three Output modes as tables (the IR is shared).
- **How it runs:** the parser is a standalone, Cadence-independent Python CLI
  (`svg2ir/nh_svg2ir.py`, standard library only — no third-party packages). The
  IL side shells out to it with `system()`, the parser writes a SKILL list
  literal of IR elements to a temp file, and the IL reads it straight back into
  the shared emit core. No `skillbridge` is needed at run time.

> ✅ **Live-verified on IC6.1.8** (2026-06-20): a real SVG (the *game-icons*
> Mona Lisa, a single path of lines + Béziers) imported, flattened, scaled, and
> rendered into a schematic as 9 note polylines — visually confirmed upright and
> faithful to the source.

### Feature B — table → note (M1 / M3 / M3b)

Implemented (pure IL — no Python needed for the table path):

- Markdown pipe table **and** TSV input, auto-detected.
- Canonical model: `rows × cols` text + per-column alignment + header flag.
- Monospace (`fixed`) auto column widths; grid styles `full` / `hrules` /
  `box+header`; header double-rule + larger header font; per-column alignment
  (`:--` / `--:` / `:-:`); optional max-column-width truncation.
- **Adjustable size:** the GUI **"Size = text height"** field scales the
  *entire* table proportionally — text, columns, rows, padding, and gaps all
  together (everything is derived from font height). Set it before placing
  (notes can't be uniformly rescaled after placement).
- **Three output modes** (GUI "Output" cyclic):
  - *loose shapes* (default) — note shapes drawn straight into the schematic.
  - *symbol* — the table is encapsulated as a reusable symbol (cell name from
    the "Symbol cell" field, built in the current schematic's library),
    stamped `nlAction="ignore"` and carrying **zero pins**, then placed as an
    instance with one click. Verified non-netlisting on live IC6.1.8:
    `ciIgnoreDevice(inst)` returns `t`; 0 terminals/pins.
  - *symbol (resizable)* — same as *symbol*, but built as a **self-contained
    pcell** with one parameter, `scale`. Select the placed note and press **q**
    (Edit Object Properties) → change **"Size scale"** → the whole note
    re-renders at the new size (text + cells + padding together). "Self-
    contained" = the pcell body bakes the layout and draws it with `db`
    primitives only, calling no `nh_*` helper, so the note **renders and
    resizes without note_helper loaded** — only its master cell (which lives in
    the design's own library, like any symbol) need be present. Verified live
    IC6.1.8: geometry re-evaluates from `scale` (width ×1 → ×2), `scale` is an
    editable CDF param on the instance, 0 pins.
- Emits `schCreateNoteShape` + `schCreateNoteLabel` (both non-electrical).
- One-click placement via `enterPoint` (the click sets the table's top-left).
- Minimal `hi*` form (`nhOpenGUI`): input MLT, Parse status, a table-file
  (`.md`/`.tsv`) path with **Load file** / **Save .md** buttons, font-height /
  max-col / grid / output-mode fields, SVG file + figure-width fields,
  Parse + Place + Import SVG buttons.
- **Markdown file import/export (Cadence side):** put a path in **Table file**,
  click **Load file** to pull a `.md`/`.tsv` into the input, or **Save .md** to
  write the current table back out as normalized, aligned Markdown
  (`nhTextToMarkdown` — same output as the Python `tsv2md`).

> ✅ **Live-verified on IC6.1.8** (2026-06-19): loads clean, Markdown + TSV
> parse correct, layout emits the expected db objects, and a sample table was
> rendered to a schematic and visually confirmed (alignment, header rule, no
> overflow). Font metrics were measured on the live tool — the `fixed` font is
> the only true monospace and advances 1.435×height per glyph, so `charAspect`
> is set to 1.45 (was a 0.55 guess that made columns far too narrow). Column
> widths also account for the larger header glyphs.

A raster image → SVG tracer (`img2svg`, see below) lets you bring screenshots
and photos in too: trace → SVG → Import SVG. Not yet implemented: DXF vectors
and Excel import.

## Load

Via the umbrella (loads mytool + dreg_gen + note_helper):

```skill
load("/home/yusheng/cadence_work/Test/workarea/skill_tools/skill_tools.il")
```

Or standalone (load `mytool/mytool.il` first if you want the menu entry):

```skill
load(".../skill_tools/note_helper/note_helper.il")
```

## Use

- MyTool → **Note Helper**, or `nhOpenGUI()` in the CIW.
- Paste a Markdown or TSV table, click **Parse** to sanity-check, then
  **Place...** and click once in the schematic.
- For an SVG figure: type its path in **"SVG file"**, set **"Figure width"**,
  then **Import SVG...** and click once to place.
- Headless / scripting entry points:
  - `nhParseText(text)` → table model
  - `nh_buildIR(table cfg)` → IR
  - `nhEmitTableAt(text cv offset cfg)` → emit directly (no click)
  - `nhSelfTest()` → render a sample into the current edit cellview
  - `nhImportVector(svgPath width)` → IR for an SVG figure
  - `nhPlaceVector(svgPath width)` → import + one-click place

Sample input:

```
|Net|Val|Unit|
|:--|--:|:-:|
|Vdd|3.3|V|
|Gnd|0|V|
```

## Live verification

With Virtuoso up **and** its skillbridge server responding
(`/tmp/skill-server-default.sock`; re-`load(".../skillbridge/sbStart.il")` in
the CIW if it is wedged), run:

```bash
python3 note_helper/verify_live.py
```

It loads the plugin, exercises parse → layout, and (if a schematic edit
cellview is open) emits a sample table and reports the shape count.

## Companion tools (standalone, Cadence-independent)

- **`toolbox/toolbox.py`** — a single Tkinter GUI bundling the two data-prep
  front-ends below as tabs (**Image → SVG** + **Table → Markdown**); they're
  logically one job — clean/convert data on the Python side for a schematic.
  Reuses the modules' core logic. `python3 toolbox/toolbox.py`. See
  `toolbox/README.md` (incl. the Linux `python3.11-tkinter` note).
- **`svg2ir/nh_svg2ir.py`** — the Feature-A SVG parser, standard library only.
  Usable on its own: `nh_svg2ir.py in.svg out.il --width 5`. note_helper calls
  it for you; documented in `svg2ir/README.md`.
- **`img2svg/img2svg.py`** — raster image → line-art SVG (Pillow + numpy, no
  potrace/OpenCV). Two modes: **threshold** (clean line art / diagrams /
  silhouettes) and **edge** (photos, more detail). Trace a screenshot/photo,
  save the SVG, then import it here. GUI (live preview) + CLI fallback. The
  lossy raster step lives here, out of the SKILL core. See `img2svg/README.md`.
- **`tsv2md/tsv2md.py`** — pure CPython + Tkinter: Excel `Ctrl+C` (TSV) →
  aligned Markdown → clipboard. GUI by default, CLI fallback (`--cli`, or pipe
  stdin). See `tsv2md/README.md`.
