# note-helper — Handoff / Resume-here

**Read this first after a context compaction.** Then read `REQUIREMENTS.md`
(design + verified API citations + decisions) and `README.md` (user-facing
status). This file = current state + how to continue.

Last updated: 2026-06-19.

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
- ✅ **tsv2md** companion (pure Python+Tkinter, CLI fallback) — done, tested.
- ⬜ **M4 — vector diagram SVG/DXF → lines** (next).
- ⬜ **M5 — Excel import** (read displayed string).

## File map

```
note_helper/
  note_helper.il   loader (umbrella skill_tools.il loads it after dreg_gen)
  nhStore.il       config defaults (charAspect 1.45, paddingRatio 0.4, ...) + pending state
  nhCore.il        parse → IR → emit → place; symbol build/place (nhBuildSymbol etc.)
  nhGui.il         hi* form (nhOpenGUI) + MyTool self-register
  REQUIREMENTS.md  full design + verified citations + decisions
  README.md        user-facing
  HANDOFF.md       this file
  verify_live.py   skillbridge smoke test
  tsv2md/tsv2md.py + tsv2md/README.md
```

Public API: `nhOpenGUI`, `nhParseText`, `nh_buildIR`, `nhEmitTableAt`,
`nhPlaceTable`, `nhBuildSymbol`, `nh_buildSymbolFromIR`, `nhPlaceTableAsSymbol`,
`nhSelfTest`.

## Verified facts (don't re-derive)

- **Font metrics (measured live):** the `fixed` font is the ONLY true
  monospace among the note fonts; glyph advance = **1.435 × height**. So
  `charAspect=1.45`. Column widths account for the larger header glyphs.
- **Netlist-safety (verified):** `dbReplaceProp(symCv "nlAction" "string"
  "ignore")` IS honored — `ciIgnoreDevice(inst)` returns `t`; note symbol has
  0 pins/terminals. Doubly safe.
- **Key APIs (all PDF-cited in REQUIREMENTS §11):** `schCreateNoteShape`/
  `schCreateNoteLabel` (work in schematic AND symbol cv), `enterPoint`
  (callback `(w done pts)`, point=`car(pts)`, guard on `done`),
  `geGetEditCellView`, `dbOpenCellViewByType(lib cell "symbol" "schematicSymbol"
  "w")`, `dbCreateInst(cv master nil pt "R0")`, `dbReplaceProp`, `parseString`
  (3rd arg `t` preserves empty cells), `substring` (1-indexed).
- **skillbridge is Python-drives-Skill** — no clean IL→Python return. So the
  table path is pure IL; M4's vector parser should run via `pyRunScript` →
  write IR-JSON to a temp file → IL reads it (REQUIREMENTS §13 item 5, lock at M4).

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

Created during testing — **`note_demo`** (keep, it's the demo the user is
reviewing) plus test junk **`nh_scratch`, `nh_note_sym`, `nh_inst_test`**
(user was asked whether to delete; pending). Don't leave more than needed.

## Next step: M4 (vector SVG/DXF → lines)

1. Python parser: SVG/DXF path → flatten Béziers → polylines; scale uniformly
   (keep aspect). Emit IR-JSON (`{polylines:[...], labels:[...]}`) to a temp file.
2. IL: `pyRunScript` the parser, read the temp IR-JSON, convert to the same IR
   the table path uses, then reuse `nh_emitIR` / `nhPlaceIR`. (IR already
   supports polylines + labels — Feature A and B share the emit core.)
3. Verify live via the hiExportImage workflow.
Lock decision #5 (Python integration pattern) at the start of M4.

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
