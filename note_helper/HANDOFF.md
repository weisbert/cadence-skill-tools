# note-helper — Handoff / Resume-here

**Read this first after a context compaction.** Then read `REQUIREMENTS.md`
(design + verified API citations + decisions) and `README.md` (user-facing
status). This file = current state + how to continue.

Last updated: 2026-06-20.

> **M4 + img2svg + toolbox + Markdown file I/O — DONE, live-verified, committed &
> pushed to `main`.** This batch added: SVG vector import (Feature A); the
> `img2svg` raster→SVG tracer (with `--levels` detail + `--rmbg`); the `toolbox`
> unified Tkinter GUI (Image→SVG + Table→Markdown tabs); and symmetric Markdown
> file import/export on BOTH sides (Python `Open file`/`Save .md` + tsv2md
> `--in/--out`; SKILL form `Load file`/`Save .md` via `nh_readFile`/`nh_writeFile`
> /`nhTextToMarkdown`). Prior committed work: M3b `f2bbd38`. Repo convention =
> direct to main. Next up: **M5** (Excel) / DXF input.
>
> **Env (done this batch, permanent):** `sudo dnf install python3.11-tkinter`
> gave `/usr/bin/python3` (3.11, has PIL/numpy) a working tkinter; `Xvfb`
> installed for headless GUI verification. See [[reference_python_tkinter_env]].

## Where we are

A Cadence Virtuoso SKILL tool that turns tables into schematic note
annotations. Built and **live-verified on IC6.1.8** (not just static review):

- ✅ **M1/M2 — table → loose note shapes.** Markdown + TSV auto-detect →
  canonical model (text + per-column align + header) → monospace auto-layout
  (grid styles, header double-rule, alignment, optional max-col truncation) →
  `schCreateNoteShape`/`schCreateNoteLabel` → one-click `enterPoint` placement.
- ✅ **Proportional size knob.** GUI "Size = text height" scales the *whole*
  table (text+cells+padding+gaps) uniformly — everything derives from font
  height (`paddingRatio` makes padding proportional).
- ✅ **M3 — symbol output mode.** `Output=symbol` builds a reusable symbol in
  the current schematic's lib (cell name from "Symbol cell" field), stamps
  `nlAction="ignore"`, 0 pins, then `dbCreateInst` places an instance.
- ✅ **M3b — resizable (pcell) symbol mode.** `Output=symbol (resizable)`
  builds a **self-contained schematicSymbol pcell** with one param `scale`.
  Select the placed note + press `q` → edit "Size scale" → re-renders at the
  new size. Body bakes the base IR and draws with `db` primitives only (no
  `nh_*` calls) → renders/resizes with note_helper NOT loaded. nlAction
  ignore, 0 pins, editable CDF `scale` param. Live-verified (×1→×2, self-
  contained body confirmed, real table rendered).
- ✅ **M4 — SVG vector → note lines.** `Import SVG...` (or `nhImportVector` /
  `nhPlaceVector`) runs a standalone stdlib-only Python parser
  (`svg2ir/nh_svg2ir.py`) via `system()`; it flattens paths/Béziers/arcs +
  primitives + `<text>`, applies transforms, flips Y, scales uniformly to a
  target width, and writes a **SKILL IR literal** that IL `read`s straight into
  the shared emit core. A figure can land as loose shapes, a symbol, or a
  resizable symbol (IR is shared with the table path). Live-verified IC6.1.8:
  the game-icons Mona Lisa imported → 9 note polylines, rendered upright &
  faithful. **DXF not done** (only SVG).
- ✅ **Markdown file import/export (both sides).** SKILL form: `Load file`
  (read `.md`/`.tsv` into the input MLT via `nh_readFile`) + `Save .md` (export
  normalized aligned Markdown via `nhTextToMarkdown`/`nh_writeFile`). Python:
  `Open file`/`Save .md` buttons + `tsv2md --in/--out`. Live-verified the SKILL
  side; its export is byte-identical to the Python `tsv2md` output.
- ✅ **Companions:** `tsv2md` (table→MD), `img2svg` (raster→line-art SVG;
  threshold/edge modes, `--levels` detail 1–8, `--rmbg`), and **`toolbox`** —
  one Tkinter GUI bundling Image→SVG + Table→Markdown as tabs (live preview).
  All standalone, Cadence-independent, GUI + CLI fallback.
- ⬜ **M5 — Excel import** (read displayed string); then optionally DXF input.

## File map

```
note_helper/
  note_helper.il   loader (umbrella skill_tools.il loads it after dreg_gen)
  nhStore.il       config defaults (charAspect 1.45, ...) + pending state + parser wiring
  nhCore.il        parse → IR → emit → place; symbol build/place; vector import (M4)
  nhGui.il         hi* form (nhOpenGUI) + MyTool self-register
  REQUIREMENTS.md  full design + verified citations + decisions
  README.md        user-facing
  HANDOFF.md       this file
  verify_live.py   skillbridge smoke test
  svg2ir/nh_svg2ir.py + svg2ir/README.md   (Feature A SVG parser, stdlib-only)
  img2svg/img2svg.py  + img2svg/README.md   (raster->SVG tracer, Pillow+numpy)
  tsv2md/tsv2md.py + tsv2md/README.md
  toolbox/toolbox.py  + toolbox/README.md   (unified Tkinter GUI: both tabs)
```

**Env note (live box, 2026-06-20):** the user's `/usr/bin/python3` is the Rocky 8
packaged **python3.11** (has Pillow/numpy/skillbridge). tkinter was missing
because that build lacks Tk; fixed by `sudo dnf install python3.11-tkinter`
(pulls tcl+tk) — now `import tkinter` works on python3. (The system python3.6 has
a separate `python3-tkinter` but no Pillow/numpy — don't use it.) For headless
GUI verification I also installed `Xvfb`; the unified GUI was built+driven and
screenshotted under `xvfb-run` + `PIL.ImageGrab(xdisplay=...)`. `--selftest`
exercises both tabs headlessly.

Public API: `nhOpenGUI`, `nhParseText`, `nh_buildIR`, `nhEmitTableAt`,
`nhPlaceTable`, `nhBuildSymbol`, `nh_buildSymbolFromIR`, `nhPlaceTableAsSymbol`,
`nhBuildResizableSymbol`, `nh_buildResizableFromIR`, `nh_pcellSource`,
`nhImportVector`, `nhPlaceVector`, `nh_readFile`, `nh_writeFile`,
`nh_tableToMarkdown`, `nhTextToMarkdown`, `nhSelfTest`.

## Verified facts (don't re-derive)

- **Font metrics (measured live):** the `fixed` font is the ONLY true
  monospace among the note fonts; glyph advance = **1.435 × height**. So
  `charAspect=1.45`. Column widths account for the larger header glyphs.
- **Netlist-safety (verified):** `dbReplaceProp(symCv "nlAction" "string"
  "ignore")` IS honored — `ciIgnoreDevice(inst)` returns `t`; note symbol has
  0 pins/terminals. Doubly safe.
- **Resizable note = self-contained pcell (verified, M3b):**
  `pcDefinePCell(list(libId cell "symbol" "schematicSymbol") ((scale float 1.0))
  body)`. View type `schematicSymbol` is valid. **Pcell body may use only
  `db/dd/cdf/rod/tech` + basic SKILL — NOT `sch*`** (skpcellref p.27), so the
  body draws with `dbCreateRect/Line/Label` on `("text" "drawing")` (the layer
  the note shapes already use), font `fixed`, into `pcCellView`. We bake the
  base-scale IR as a `%L` literal into the body and multiply every coord +
  height by `scale` — exact because `nh_buildIR` is linear in font height.
  `dbCreateInst` on the super master places a default-scale instance (0 pins).
  Editable "Size scale" via `cdfCreateBaseCellCDF`+`cdfCreateParam(?editable
  "t" ?display "t")` (these flags are STRINGS, not symbol `t`)+`cdfSaveCDF`.
- **skillbridge gotcha (cost me time):** `ws['evalstring']` evaluates only the
  FIRST top-level form. Wrap multi-statement probes in one `progn(...)`.
- **Key APIs (all PDF-cited in REQUIREMENTS §11):** `schCreateNoteShape`/
  `schCreateNoteLabel` (work in schematic AND symbol cv), `enterPoint`
  (callback `(w done pts)`, point=`car(pts)`, guard on `done`),
  `geGetEditCellView`, `dbOpenCellViewByType(lib cell "symbol" "schematicSymbol"
  "w")`, `dbCreateInst(cv master nil pt "R0")`, `dbReplaceProp`, `parseString`
  (3rd arg `t` preserves empty cells), `substring` (1-indexed).
- **Decision #5 LOCKED (M4 Python integration):** skillbridge is
  Python-drives-Skill (wrong direction for an unattended tool), and `pyRunScript`
  only *logs* its result — so instead the IL **shells out**: `system("python3
  svg2ir/nh_svg2ir.py in.svg out.il --width W")` (sklangref p.638, returns exit
  code, 0=ok), the parser writes a **SKILL list literal** of IR DPLs (NOT JSON)
  to a `makeTempFileName "/tmp/nh_svgir"` file (p.446), and IL `infile`(p.423) +
  `read`(p.461, one s-expr = the whole IR list) + `close`(p.391) reconstructs it
  with zero translation, then `deleteFile`(p.620). See `nhImportVector` in
  nhCore.il. Verified live IC6.1.8 end-to-end.
- **M4 SVG parser facts:** `svg2ir/nh_svg2ir.py` is **stdlib-only** (this box has
  NO svgpathtools/cairosvg/ezdxf/potrace/inkscape; it does have PIL+numpy but the
  parser deliberately avoids them for portability). Own path tokenizer +
  adaptive de Casteljau flatten + arc sampling. **Gotcha fixed:** a relative
  `m` moveto right after `z` (common, e.g. `...H89zm30 30...`) must add the
  current point — guard on a `started` flag, not on whether the subpath buffer
  is non-empty (it was reset by `z`). SVG is y-down → flip Y so the figure is
  upright. Set `nh_pythonCmd "/usr/bin/python3"` if Virtuoso's `system()` shell
  can't find `python3` on PATH.

## Live environment + verification workflow

- skillbridge socket: `/tmp/skill-server-default.sock`. Virtuoso pid was 83026.
  If calls hang (server wedged), re-`load(".../skillbridge/sbStart.il")` in CIW.
- Connect: `from skillbridge import Workspace; ws = Workspace.open()` (python3
  at /usr/bin/python3 has skillbridge). Use `ws['evalstring']("...")` and keep
  intermediates in IL globals (avoid round-tripping DPLs/dicts).
- **Visual self-verification (important):** render any cellview to PNG and Read
  it — I can SEE the result, no need to ask the user:
  ```
  hiExportImage(?fileName "/tmp/x.png" ?window W ?exportRegion 'entireDesign
                ?width 1400 ?colorType 'biColor ?bgColor "white" ?fgColor "black")
  ```
  (`W` from `geOpen(?lib .. ?cell .. ?view .. ?mode "r")`.) Then Read the PNG.
- Calibration probes used: `/tmp/nh_v.py` (parse/layout), `/tmp/nh_calib.py`
  (font metrics), `/tmp/nh_sym.py` (symbol+nlAction), `/tmp/nh_demo.py` (demo).
  These may be gone after /tmp cleanup — the pattern matters, recreate as needed.

## Scratch artifacts in `sim_yusheng` (user's lib)

**Keep (present):** `note_demo` (M3 static-symbol demo), `nh_rs_host` + its
master `nh_note_rs` (M3b resizable demo — open `nh_rs_host/schematic`, select a
note, press `q`, edit "Size scale"; has ×1 and ×2 instances), `nh_svg_demo`
(M4 demo — the Mona Lisa SVG imported as loose note shapes in a schematic).

**Probe junk — deleted** (2026-06-20): `nh_pc_host`, `nh_pc_probe`,
`nh_pc_mini`, `nh_scratch`, `nh_note_sym`, `nh_inst_test`. Cleanup via
`ddDeleteObj(ddGetObj(lib cell))` (skdfref p.1748). GOTCHA: `hiCloseWindow`
on a modified-since-save cellview raises a "Save changes?" MODAL that wedges
the bridge — `dbSave`/clear-modified before closing, or skip the window loop.

## Next step: M5 (Excel import) + optional DXF / raster companion

M4 (SVG) is done. Remaining Feature-A/B work:

- **M5 — Excel named range → table.** Read the **displayed/formatted string**
  per cell (never the raw float). Best in Python (`openpyxl`) — but `openpyxl`
  is NOT installed here; either add it or parse the saved `.xlsx` (a zip of XML)
  with stdlib, reusing the same `system()` → SKILL-IR-literal → `read` pattern
  that M4 established (the cleanest precedent).
- **DXF input** for Feature A — add a DXF branch to `nh_svg2ir.py` (or a sibling)
  emitting the same IR; `ezdxf` is absent, so either add it or parse the DXF
  entities (LINE/LWPOLYLINE/ARC/CIRCLE/TEXT) directly. Same IR-literal exchange.
- **Raster image → SVG tracer** — ✅ DONE as `img2svg/img2svg.py` (Pillow +
  numpy; NO potrace/OpenCV needed). Marching-squares contour trace + Douglas-
  Peucker; two modes (threshold=line-art, edge=photo). GUI w/ live preview + CLI
  fallback. Verified: synthetic shapes, and the REAL Mona Lisa painting photo
  (edge mode → recognisable face/hands line drawing; threshold → clean figure
  silhouette), each round-tripped back through `nh_svg2ir` to prove the output
  imports. Possible next: colour layering, "keep largest N contours" denoise.

The M4 integration pattern (`system()` → temp SKILL-IR-literal → `infile`/`read`)
is the template to copy for all of the above.

## Standing rules (also in auto-memory)

virtuoso-skill mandatory lookup (grep index → read PDF → cite) before any
Cadence API; SKILL has no `let*`; `pcreMatchp` over `rexMatchp`; verify on live
Virtuoso; `foreach` iter vars must be declared locals; form field writes via
the evalstring+scratch-global idiom; `hiSetFormSize` after `hiInstantiateForm`.

## Possible enhancements discussed (not committed)

- Text wrapping for long cells — assessed as MEDIUM effort, deferred; only
  worth it for a free-text column; do per-column if/when needed.
- Per-column max-width / total-table-width cap.
- Independent text-vs-cell sizing — user chose single proportional knob (declined).
