# note-helper — Requirements & Design

> A Cadence Virtuoso SKILL tool for adding **notes** (non-electrical annotations) to
> schematics. Two headline features: **(A)** convert a diagram/architecture figure into
> pure lines and drop it in as a note; **(B)** import a table and render it as a schematic
> note. Sibling to `dreg_gen` / `mytool`, registered into the shared **MyTool** menu.
>
> 中文一句话：在原理图里加“示意图/表格”注释的工具——把矢量图变成线条 note，把表格变成排版好的 note。
> note 是非电气对象，不进 netlist、不进仿真。

Status: **requirements locked, pre-implementation.** No Cadence code written yet.
All API signatures below were verified against the IC6.1.8 reference PDFs (citations inline).

---

## 1. Positioning & native baseline

A schematic has **no native import** for images, tables, or vector files. Everything this
tool produces bottoms out in exactly **two non-electrical primitives**, both of which work in
**a schematic OR a symbol cellview**:

| Primitive | Signature | Source |
|-----------|-----------|--------|
| `schCreateNoteShape` | `schCreateNoteShape(d_cvId t_type t_lineStyle l_points [n_width]) => d_shape/nil` | skcompref.pdf p.242 |
| `schCreateNoteLabel` | `schCreateNoteLabel(d_cvId l_point t_text t_just t_orient t_fontStyle n_fontHeight t_type) => d_label/nil` | skcompref.pdf p.240 |

- `schCreateNoteShape` — `t_type` ∈ {line, rectangle, polygon, arc, ellipse, circle};
  `t_lineStyle` ∈ {solid, dashed}; `l_points` ≥ 2 points; `n_width` optional.
  **A whole N-vertex polyline is one call** — no segment splitting.
- `schCreateNoteLabel` — `t_just` ∈ {upperLeft, upperCenter, upperRight, centerLeft,
  centerCenter, centerRight, lowerLeft, lowerCenter, lowerRight}; `t_orient` ∈
  {R0, R90, R180, R270, MY, MYR90, MX, MXR90}; `t_fontStyle` ∈ {euroStyle, fixed, gothic,
  math, roman, script, stick, swedish, milSpec}; `n_fontHeight` default 0.0625 (user units);
  `t_type` = **normalLabel** for plain static text (NLPLabel/ILLabel only for netlister-expanded text).

Both docs state outright: *“These shapes/labels do not affect the connectivity but can be
useful for annotation.”* → the tool is fundamentally a **converter** that batches calls to
these two functions.

The **tool's job** is to turn high-level input (a vector file, a Markdown/TSV table) into a
normalized **Intermediate Representation (IR)** and then emit that IR as note primitives at a
user-chosen location.

---

## 2. Architecture

```
high-level input ──► parser ──► IR (polylines + positioned text) ──► IL emit core ──► note primitives
                                                                                       └─ schematic cv (loose shapes)
                                                                                       └─ symbol cv     (encapsulated)
```

### 2.1 IR (the contract)
A plain IL structure — the single thing the emit core consumes:

```
IR = list of
  ('polyline  points:<list of x:y>  style:'solid|'dashed  width:<n or nil>)
  ('rect      bbox:<ll ur>          style:...             width:...)
  ('polygon   points:<>             style:...             width:...)
  ('label     point:<x:y>  text:<str>  height:<n>  just:<sym>  orient:<sym>  font:<sym>)
```

Everything (tables, SVG, DXF, Excel) normalizes to this. IR coordinates are computed at the
**origin**; final placement offsets the whole group by the clicked point (§6).

### 2.2 Where parsing runs — pure IL vs Python
**Key finding from research:** skillbridge is **Python-drives-Skill** — a server *inside*
Virtuoso (`python_server.il`) that an external Python *client* calls via
`ws['fn'](args)`. There is **no clean IL→Python "call and return a value"** path
(`pyRunScript` runs a script but only *logs* its result).

Consequence — split the parsers by where they best live:

| Input | Parser | Runs where | Notes |
|-------|--------|-----------|-------|
| **Markdown table** | string-split + `pcreMatchp` | **pure IL** | no Python, no skillbridge — the v1 path |
| **TSV** (Excel copy-paste) | split on `\t` / `\n` | **pure IL** | auto-detected vs Markdown |
| SVG / DXF (vector figure) | Python | Python writes IR-JSON to temp file → IL reads it | IL stays the driver via `pyRunScript`, **or** Python client drives `ws['nhPlaceIR'](ir)` |
| Excel named range | Python (`openpyxl`) | same temp-IR-JSON exchange | read **displayed string**, never raw float |
| raster / screenshot trace | Python (OpenCV/potrace) | same | lossy; out of v1 by default |

→ **Tables need zero Python.** Python only enters for Feature A vectors and Excel. The
Python-integration pattern (temp-file IR exchange vs client-driven) is a **decision deferred
to the Feature-A milestone** (§13, item 5) — it does not block v1.

---

## 3. Feature A — diagram → lines

- **Main path (≈80%): vector source SVG/DXF.** Python parses paths, flattens Béziers to
  polylines, scales uniformly (preserve aspect ratio) → IR polylines → `schCreateNoteShape`.
- **Secondary: raster/screenshot tracing.** Python (OpenCV Canny → findContours →
  `approxPolyDP`, or potrace) + Douglas-Peucker simplification + a hard segment-count cap.
  **Lossy; gated behind a default-off flag** (decision §13 item 3).
- **Limits (inherent to note shapes):** single-layer lines, no fill, no per-shape color,
  text not bold. A polyline maps to one shape; closed boxes → `rectangle`, free outlines →
  `polygon`.

---

## 4. Feature B — table → note

### 4.1 Canonical model (the contract)
```
table = { rows × cols of displayed-text,
          per-column alignment (left|right|center),
          header flag,
          merge spans }      # spans = optional, see §13 item 1
```
Philosophy: **do not mirror Excel's look** — extract *structure + content only* and apply our
own clean styling.

### 4.2 Three front doors, one model
1. **Markdown pipe table (primary).** Alignment encoded in the separator row
   (`:--`=left, `--:`=right, `:-:`=center, `---`=default); header is the row above the
   separator. Self-describing, plain UTF-8, doubles as the IR's text form. 3-dash form
   recommended for portability; visual pipe alignment is irrelevant to parsing.
2. **Excel named range.** Read the **displayed/formatted string** per cell — never the raw
   float (avoids `3.3→3.2999…`, `007→7`, `12%→0.12`, `5→5.0`, scientific notation).
3. **TSV (fallback).** Excel `Ctrl+C` yields TSV; paste straight into the form. Auto-detected
   against Markdown by presence of `\t` / leading `|`.

### 4.3 “Good looks” knobs
- **Fixed (monospace) font default** → predictable column width =
  `maxChars × charWidth + 2×padding`.
- Grid styles: full grid / horizontal rules only / outer box + header rule.
- Header row: double rule + slightly larger font height (no bold — unavailable).
- Numeric columns right-aligned (driven by **declared** alignment, not a "looks like a number"
  heuristic).
- Honor merge spans (if in scope); snap all geometry to grid.

### 4.4 Locked scope
English only (no CJK double-width); fixed font for tables; alignment must be **declared**
in syntax.

---

## 5. Emit core (shared by both output modes)

Because `schCreateNote*` works in schematic **and** symbol cellviews, **one emit core** serves
both modes — only the target `cv` differs:

| IR element | Schematic / symbol emit | Source |
|------------|------------------------|--------|
| polyline | `schCreateNoteShape(cv "line" style pts [w])` | skcompref p.242 |
| rect | `schCreateNoteShape(cv "rectangle" style list(ll ur))` | skcompref p.242 |
| polygon | `schCreateNoteShape(cv "polygon" style pts)` | skcompref p.242 |
| label | `schCreateNoteLabel(cv pt text just orient font h "normalLabel")` | skcompref p.240 |

If we ever need explicit layer-purpose control inside a symbol, the db-level equivalents exist
and are verified: `dbCreateLine` (zero-width; skdfref p.514), `dbCreatePath` (with width),
`dbCreatePolygon` (skdfref p.517), `dbCreateRect` (skdfref p.518), `dbCreateLabel`
(skdfref p.524). **Default to the `schCreateNote*` pair** — simplest, no layer needed.

---

## 6. Placement (one click → whole group)

Verified flow (skuiref.pdf):

1. `enterPoint(?prompts list("Click to place note group.") ?doneProc "nh_placeCB")`
   — single-click capture; callback `nh_placeCB(w done pts)`, point = `car(pts)`. (p.1197)
2. In the callback, **build-directly-at-clicked-point**: for each IR element add the clicked
   point to its origin-relative coords, then `schCreateNoteShape`/`schCreateNoteLabel` at
   absolute coords. Returns ids, lands atomically, nothing flashes at origin.
   - Coordinate math: `dbTransformPointList(pts list(clickPt "R0"))` (skdfref p.585) or plain
     `mapcar` add.
3. Get the target cv inside the callback: `hiGetCurrentWindow()~>cellView` (verify editable).

**Not used:** `schHiCreateNoteShape/Label` (interactive, one-shape-at-a-time, return only `t`,
no shared offset — wrong for a multi-shape group). `hiGetPoint`/`hiGetCommandPoint` are passive
getters, not callbacks. Alternative build-at-origin-then-`dbMoveFig(id nil list(clickPt "R0"))`
(skdfref p.1316) is available if a fixed template is reused.

**Sizing rule:** size is fixed *before* insertion (a note group can't be uniformly rescaled
afterward). Figures → target width or scale factor (uniform). Tables → font height as the
primary dimension.

---

## 7. Output modes

| Mode | How | Netlist safety |
|------|-----|----------------|
| **Loose note shapes** (default) | emit IR straight into the active schematic cv | zero risk — note primitives are non-electrical by construction |
| **Symbol-encapsulated** | `dbOpenCellViewByType(lib cell "symbol" "schematicSymbol" "w")` → emit IR into it → `dbSave`; place with `dbCreateInst` | safe by construction; **belt-and-suspenders:** `dbReplaceProp(symCv "nlAction" "string" "ignore")` |

`nlAction="ignore"` verified in **skartistref.pdf p.150** (*"instances with the nlAction=ignore
property … are ignored during netlisting"*) and **constraintsSKILL.pdf p.460** (`ciIgnoreDevice`:
`dev->master->nlAction == "ignore"` ⇒ ignored). **To verify on live Virtuoso** (§14): whether a
raw `dbReplaceProp` on the cellview is honored vs requiring a CDF param; whether it suppresses
all netlist formats (Spectre/AMS/UltraSim); whether `lvsIgnore="TRUE"` is also needed for LVS.

---

## 8. GUI — minimal `hi*` form (reuse dgenGui patterns)

Verified form flow (skuiref.pdf): `hiCreateAppForm` (p.502) → `hiInstantiateForm` (p.767) →
`hiSetFormSize` (p.813) → `hiDisplayForm` (p.688).

Fields:
- **Multi-line text field** (`hiCreateMLTextField`, p.602) — input Markdown **or** TSV,
  auto-detected. Read content via `parseString(text "\n")`. Plus a “Load .md” button.
- **Parse** button → one-line status (`N rows × M cols` / error line).
- **Font height** + **target width** string fields (`hiCreateStringField`, p.650).
- **Grid style** cyclic field (`hiCreateCyclicField`, p.536).
- **Output mode** radio (loose shapes / symbol).
- **Place** button → `enterPoint` single-click placement (§6).

**Cut from v1:** syntax highlighting, pipe auto-alignment, in-form grid editor, in-form canvas
preview. Preview = draw on the schematic canvas + Undo.

**Mandatory gotcha fixes (from memory + research):**
- After `hiInstantiateForm`, call `(errset (hiSetFormSize form (list W H)) t)` to fix the
  **MLT double-scroll** (Motif wheel hits both inner MLT and outer form scrollbar; sizing the
  viewport to clear stacked panels retracts the outer scrollbar). dgenGui.il:1441-1455.
- Dynamic field writes need a literal symbol → route through
  `(evalstring (sprintf nil "nh_form->%s->value = nh_tmpVal" fieldName))` + a scratch global.

---

## 9. File layout & conventions (mirror dreg_gen)

```
note_helper/
  note_helper.il   # loader: boundp/trailing-slash/isFile preamble, loads modules in order
  nhStore.il       # persistence / config (pin config persists; per-run input is transient)
  nhCore.il        # IR build (table + vector), emit core, placement
  nhGui.il         # the hi* form; ENDS with the MyTool self-register line
  README.md
  USER_GUIDE.md    # bilingual, designer-facing (later)
```

- Prefix **`nh*`**; public API bare camelCase (`nhOpenGUI`), private `nh_snake_case`.
- Load order in `note_helper.il`: `nhStore.il` → `nhCore.il` → `nhGui.il`.
- Idempotent globals: `(unless (boundp 'nh_foo)(setq nh_foo nil))` — no `defvar`.
- **No `let*`** (nest `let` or `let`+`setq`); **`pcreMatchp` over `rexMatchp`**;
  `boundp`+symeval for state; `getd` (not `functionp`) to guard optional deps;
  `errset`-wrap fragile calls (`hiSetFormSize`, timers).

### 9.1 Menu — do NOT add our own
dreg_gen self-registers into the shared **MyTool** framework with one tail line; note_helper
does the same at the end of `nhGui.il`:
```lisp
(when (getd 'mtRegister)
  (mtRegister "Note Helper" 'nhOpenGUI "Open the Note Helper GUI"))
```
The menu plumbing (`hiInsertBannerMenu`, auto-mount timer poll, de-dup) lives entirely in
mytool — note_helper inherits it for free. Umbrella wiring: add to `skill_tools.il`
`(setq nh_dir (strcat skillTools_root "note_helper/"))` and `(load …note_helper.il)`
**after** the dreg_gen / mytool load lines so `mtRegister` is defined.

---

## 10. Companion tool — tsv2md (separate, Cadence-independent)

Pure Python + Tkinter (zero-dep, ships with CPython), no Cadence coupling: Excel `Ctrl+C` (TSV)
→ alignment-beautified Markdown → write back to clipboard. Optional per-column alignment
buttons, header toggle, live conversion. **note-helper does not depend on it** (the form ingests
TSV directly). Probe `python3 -m tkinter` for availability; fall back to a windowless CLI if
absent. Timing per §13 item 4.

---

## 11. Verified API reference (build-time citations)

| Function | Use | Source |
|----------|-----|--------|
| `schCreateNoteShape` | emit polyline/rect/polygon | skcompref.pdf p.242 |
| `schCreateNoteLabel` | emit text label | skcompref.pdf p.240 |
| `enterPoint` | one-click placement (`?doneProc`) | skuiref.pdf p.1197 |
| `dbTransformPointList` / `dbTransformPoint` | offset group to click | skdfref.pdf p.585/586 |
| `dbMoveFig` / `dbCopyFig` | alt build-then-move | skdfref.pdf p.1316/1314 |
| `dbOpenCellViewByType` | create symbol cv (`"schematicSymbol" "w"`) | skdfref.pdf p.898 |
| `dbReplaceProp` / `dbCreateProp` | stamp `nlAction="ignore"` | skdfref.pdf p.557/551 |
| `dbCreateInst` | place note symbol | skdfref.pdf p.941 |
| `dbCreateLine`/`dbCreatePath`/`dbCreatePolygon`/`dbCreateRect`/`dbCreateLabel` | symbol db geometry (optional) | skdfref.pdf p.514/–/517/518/524 |
| `hiCreateAppForm` / `hiInstantiateForm` / `hiSetFormSize` / `hiDisplayForm` | form flow | skuiref.pdf p.502/767/813/688 |
| `hiCreateMLTextField` / `hiCreateStringField` / `hiCreateCyclicField` | form fields | skuiref.pdf p.602/650/536 |
| `mtRegister` (MyTool framework) | menu self-register | mytool/*.il |

---

## 12. Build milestones (incremental)

1. **M1 — minimal closed loop, PURE IL:** Markdown table → IR → loose note shapes, placed by
   one click. Probe-verify on **live Virtuoso** (don't trust mocks). No Python.
2. **M2 — table polish:** TSV auto-detect, grid styles, header styling, alignment, sizing knobs;
   the `hi*` form GUI.
3. **M3 — symbol output mode:** ✅ DONE & live-verified — `dbOpenCellViewByType` symbol +
   `nlAction="ignore"` (0 pins; `ciIgnoreDevice` = t) + `dbCreateInst` one-click placement.
4. **M4 — Feature A vector:** SVG/DXF Python parser + IR-JSON exchange (lock the Python
   pattern, §13 item 5).
5. **M5 — Excel import** (displayed-string), then optionally **raster trace** and **tsv2md**.

---

## 13. Decisions

**Locked (confirmed 2026-06-19):**

| # | Decision | Resolution |
|---|----------|-----------|
| 1 | Merged cells in scope? | **v1: NO** — skip spans; the canonical model carries a `merge` field but the parser/emit ignore it in v1. Add later. |
| 2 | Long-cell behavior | **Widen column by default**, plus a “max column width” knob that switches the column to truncate (…). |
| 3 | Raster tracing in v1? | **Vector-only (SVG/DXF) in v1**; raster/screenshot tracing deferred. |
| 4 | tsv2md timing | **Build now, in parallel** with note-helper (standalone Python+Tkinter). |

**Still open (resolve at the relevant milestone):**

| # | Decision | Plan |
|---|----------|------|
| 5 | Python integration pattern (Feature A) | IL-driven `pyRunScript` → temp **IR-JSON** → IL reads it (keeps IL the driver). Lock at M4. |
| 6 | ~~Default grid style & font heights~~ | **RESOLVED 2026-06-19 from live measurement:** grid `full`, fontHeight 0.125, headerScale 1.15, and `charAspect 1.45` — measured: the `fixed` font (only true monospace among the note fonts) advances 1.435×height/glyph; column widths account for scaled header glyphs. |

---

## 14. Live-Virtuoso probe checklist (per the SKILL-edit verification rule)

- `schCreateNoteShape` `n_width` default & whether width applies to non-line types; `circle`
  vs `ellipse` behavior.
- `schCreateNote*` rendering inside a **symbol** cv (layer, selectability, save).
- `enterPoint` exact callback arglist `(w done pts)` and `?doneProc` vs `?addPointProc`; how to
  fetch the editable cv in the callback; undo-group boundary per call.
- ~~**`nlAction="ignore"`** mechanism~~ **RESOLVED**: a raw
  `dbReplaceProp(symCv "nlAction" "string" "ignore")` IS honored — `ciIgnoreDevice(inst)` returns
  `t` and the note symbol has 0 pins/terminals. Still optional to confirm per netlist format
  (spectre/AMS/UltraSim) and whether `lvsIgnore="TRUE"` is wanted for LVS.
- `dbCreateLabel` exact db-level enum sets (assumed same families as `schCreateNoteLabel`).
