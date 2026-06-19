# note-helper

Add **notes** (non-electrical annotations) to Cadence Virtuoso schematics.
Two features: **(A)** a vector diagram → pure lines; **(B)** a table → a clean
schematic note. Sibling plugin to `dreg_gen` / `mytool`; auto-registers under
the **MyTool** banner menu.

See **[REQUIREMENTS.md](REQUIREMENTS.md)** for the full design, verified API
citations, decisions, and the milestone plan.

## Status — M1 + M3 (Feature B: table → loose shapes or symbol)

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
- **Two output modes** (GUI "Output" cyclic):
  - *loose shapes* (default) — note shapes drawn straight into the schematic.
  - *symbol* — the table is encapsulated as a reusable symbol (cell name from
    the "Symbol cell" field, built in the current schematic's library),
    stamped `nlAction="ignore"` and carrying **zero pins**, then placed as an
    instance with one click. Verified non-netlisting on live IC6.1.8:
    `ciIgnoreDevice(inst)` returns `t`; 0 terminals/pins.
- Emits `schCreateNoteShape` + `schCreateNoteLabel` (both non-electrical).
- One-click placement via `enterPoint` (the click sets the table's top-left).
- Minimal `hi*` form (`nhOpenGUI`): input MLT, Parse status, font-height /
  max-col / grid / output-mode fields, Parse + Place buttons.

> ✅ **Live-verified on IC6.1.8** (2026-06-19): loads clean, Markdown + TSV
> parse correct, layout emits the expected db objects, and a sample table was
> rendered to a schematic and visually confirmed (alignment, header rule, no
> overflow). Font metrics were measured on the live tool — the `fixed` font is
> the only true monospace and advances 1.435×height per glyph, so `charAspect`
> is set to 1.45 (was a 0.55 guess that made columns far too narrow). Column
> widths also account for the larger header glyphs.

Not yet implemented: vector diagrams (Feature A), Excel import.

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
- Headless / scripting entry points:
  - `nhParseText(text)` → table model
  - `nh_buildIR(table cfg)` → IR
  - `nhEmitTableAt(text cv offset cfg)` → emit directly (no click)
  - `nhSelfTest()` → render a sample into the current edit cellview

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

## Companion: tsv2md

`tsv2md/tsv2md.py` — standalone, Cadence-independent (pure CPython + Tkinter):
Excel `Ctrl+C` (TSV) → aligned Markdown → clipboard. GUI by default, CLI
fallback (`--cli`, or pipe stdin). See `tsv2md/README.md`.
