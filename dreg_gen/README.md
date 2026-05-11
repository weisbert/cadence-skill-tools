# Dreg Generator

A Cadence SKILL tool that auto-generates a "driver register" cell from a DUT
cell's pins. Each enabled pin becomes a CDF parameter on the Dreg instance;
the user fills 1/0 (digital), output voltage = `value × DVDD`. Bus pins
(`D<7:0>`) collapse to one integer parameter, bit-decomposed in Verilog-A.

**Status:** Steps 1–5 + 7 complete and validated on IC6.1.8 / `sim_yusheng/Test_cell`,
plus Phase C plugin wiring (registers under the **MyTool** banner menu on every
schematic / Maestro / ADE-XL window). Step 8 (packaging, GitHub tag) is pending.

## Files and public functions

| File | Public function | Purpose |
|------|----------------|---------|
| `dgenPinScan.il` | `dgenScanPins(libName cellName viewName)` | Open source cellview, return list of pin descriptor plists. Bus parsing (`D<7:0>`, `D<3>`, `D`) and bit-decomposed merge included. |
| `dgenStore.il` | `dgenSpecToString` / `dgenStringToSpec`, `dgenSavePropOnCell` / `dgenLoadPropFromCell`, `dgenSaveLastState` / `dgenLoadLastState` | Spec serialization, cell-property round-trip (`dgenConfig` prop), last-state file at `~/.skill_tools/dreg_gen.last`. |
| `dgenPatterns.il` | `dgenPatternsClassify(pin pats)`, `dgenPatternsLoad`, `dgenPatternsSave`, `dgenPatternsDefault` | Pin classification engine. Returns `'power` / `'dreg` / `'other` for each DUT pin from name + direction. Keyword dictionary at `~/.skill_tools/dreg_gen.patterns` (auto-falls-back to baked-in default). |
| `dgenSymbol.il` | `dgenWriteSymbol(spec [outLib outCell])` | Generate symbol view via `schPinListToSymbolGen`, all pins as direction `"output"` (right-side placement). Includes write-lock post-condition check. |
| `dgenVerilogA.il` | `dgenWriteVerilogA(spec [outLib outCell])` | Write `veriloga.va` + `master.tag` into the cell's `veriloga/` dir, refresh lib via `ddUpdateLibList`, add cell to "dreg" category. |
| `dgenCDF.il` | `dgenWriteCDF(spec [outLib outCell])` | Build cell-level base CDF (`cdfCreateBaseCellCDF` + `cdfCreateParam` × N + `cdfSaveCDF`). 4 `defaultMode` options + a defensive legacy branch. |
| `dgenRun.il` | `dgenRun(spec)` | End-to-end orchestrator: calls symbol → .va → CDF in mandatory order, fail-fast on any substep nil-return. No lib/cell overrides — set `spec~>target` instead. |
| `dgenGui.il` | `dgenOpenGUI(@optional dutLib dutCell dutView)` | Modeless form. With no args: opens "DUT-less" — top section only (Lib/Cell/View combos + 3 picker buttons), pre-filled from last-state v2. With `dutLib`+`dutCell`: opens fully rendered (legacy path). Source: 3 linked combos + `[Select from Schematic]` / `[Browse Library...]` / `[Load Pins]`. Target editable + DVDD/mode/pattern + per-pin enable/value. Buttons OK / Cancel / Defaults / Apply. Last-state remembered across sessions; pin "value" fields auto-grey when mode ≠ literal AND swap their displayed text to the resolved variable name (pin name for `variable_pin`, pattern-substituted for `custom`, `""` for `empty`) so the row reads as a faithful preview of what will be emitted. The user's literal number is preserved in `dgen_pinLiteralCache` and restored when the user toggles back to literal mode. **Self-registers as a MyTool plugin** at load time (entry "Dreg Generator"; guarded with `getd` so dgenGui.il still loads if mytool/ is absent). |
| `test_step5_auto.il` | (loadable test) | End-to-end smoke test for the GUI that bypasses display so it doesn't trap the skillbridge evaluator. Loads through `ws['load'](...)`. |

## Spec plist format

```skill
spec = list(nil
  'source        list(nil 'lib "L" 'cell "C" 'view "symbol")
  'target        list(nil 'lib "TL" 'cell "TC" 'view "veriloga")
  'dvddDefault   "0.9"
  'defaultMode   "literal"      ; or "empty" / "variable_pin" / "custom"
  'defaultPattern "d_*"         ; only used when defaultMode="custom"; "*" = pin name
  'pins          list(
    list(nil 'name "D"   'isBus t   'busHi 7 'busLo 0 'enabled t   'default "0")
    list(nil 'name "EN"  'isBus nil                   'enabled t   'default "0")
    list(nil 'name "CLK" 'isBus nil                   'enabled nil))    ; skipped
  'customVars    list(                                                  ; user-added in GUI; may be absent
    list(nil 'name "XX_EN"   'kind "digital" 'isBus nil                   'default "0")
    list(nil 'name "XX_ctrl" 'kind "digital" 'isBus t   'busHi 3 'busLo 0 'default "0")
    list(nil 'name "VDD1P8"  'kind "analog"                               'default "1.8")))
```

`'customVars` is appended to `'pins` in the unified emit list (`dgen_specEmitList` in
`dgenStore.il`), so the symbol view gets one extra output pin per customVar, the
`.va` gets one extra port/parameter/analog-line, and the CDF gets one extra
parameter. Naming convention enforced by `dgen_emitParamName`:

| Kind    | .va parameter   | CDF parameter | Drive expression           |
|---------|-----------------|---------------|----------------------------|
| digital | `integer d_<N>` | `d_<N>`       | `V(N) <+ d_<N> * DVDD;`    |
| analog  | `real v_<N>`    | `v_<N>`       | `V(N) <+ v_<N>;` (literal) |

Pins are always digital. Analog customVars are always scalar (the GUI
doesn't expose bus syntax for analog; the emitters defensively force
scalar shape if a buggy spec carries `'isBus t` on an analog item).

`outputLib` / `outputCell` args, when non-nil, override `spec~>target~>lib` /
`spec~>target~>cell` for that single call.

## Pin auto-categorization

Each DUT pin row in the GUI carries a category prefix on its checkbox
label (`[PWR] VDD`, `[DREG] EN<3:0>`, bare name otherwise) so the user
can scan supply rails vs. control inputs at a glance. Above the pin
list, a five-button toolbar drives one-click prefill actions:

| Button | Effect |
|--------|--------|
| `All Pins` | Every enable -> t |
| `No Pins` | Every enable -> nil |
| `Only DREG` | Enable iff classifier returns `'dreg` |
| `Auto Suggest` | `'dreg` -> t, `'power` -> nil, `'other` -> direction default |
| `Edit Patterns...` | Open a secondary form to edit the keyword dictionary |

Classification (in `dgenPatterns.il`) priority, first match wins:

1. `srcDirection == "output"` -> `'other` (outputs aren't drivable inputs)
2. name matches power keyword -> `'power`
3. `isBus == t` -> `'dreg` (multi-bit -> digital bus)
4. name matches dreg keyword -> `'dreg`
5. `srcDirection == "inputOutput"` -> `'power` (rail fallback)
6. otherwise -> `'other`

Matching is PCRE, case-insensitive, with a token-boundary anchor:
`(?:^|[\W_])KEYWORD`. PCRE's `\b` treats `_` as a word char, so
`\bVDD` would miss `core_VDD`; the custom boundary catches `_VDD`
while still rejecting `myVDD` / `XVDD`.

Default keyword lists are conservative -- ambiguous names like `VREF`,
`VBG`, `VBIAS`, `IBIAS` are NOT in the default power list because
they're often DC-swept analog inputs in characterization testbenches.
Add them via `[Edit Patterns...]` if your flow treats them as
untouchable. The dictionary is persisted to
`~/.skill_tools/dreg_gen.patterns` as a SKILL plist that round-trips
via `%L` + `lineread` (same shape as `dreg_gen.last`).

`[Edit Patterns...]` opens a separate form with two multi-line text
fields (one power keyword per line, one dreg keyword per line) plus a
`Reset to Defaults` button. OK saves to disk and refreshes the visible
`[PWR]`/`[DREG]` prefix labels **in place** via direct `->prompt` slot
writes — no main-form rebuild, no position/size loss. Cancel discards.

The remaining close-reopen paths (Load Pins, customVar add/del,
Select from Schematic) preserve window position and size across the
cycle: `dgenGui_deferredReopen` snapshots `hiGetFormLocation` +
`hiGetFormSize` before `hiFormCancel`, and the next `dgenOpenGUI`
applies them via `hiSetFormSize` + `hiDisplayForm` with the saved
location. So a resized + repositioned window stays put through
button clicks within a session.

## Critical ordering rules

There are two independent ordering constraints. The orchestrator
(`dgenRun`) enforces both:

```skill
dgenWriteSymbol(spec)        ; 1. first
dgenWriteVerilogA(spec)      ; 2. second
dgen_compileVerilogA(spec)   ; 3. amsUpdateTextviews + ahdlUpdateViewInfo
dgenWriteCDF(spec)           ; 4. LAST -- this matters
```

**Why symbol before V-A.** `schPinListToSymbolGen` silently creates 0
terminals if the cell already has a `veriloga` view at the time of the
call.

**Why CDF last.** `amsUpdateTextviews` and `ahdlUpdateViewInfo` rewrite
the cell's BASE CDF as a side effect — they derive parameter defaults
from the .va's `parameter integer d_X = 0` declarations, clobbering any
variable-mode defaults installed earlier AND re-adding entries for pins
the user disabled. `dgenWriteCDF` therefore runs AFTER `compileVerilogA`
so its rewrite is final.

## OSS netlister registration via simInfo

`dgenWriteCDF` builds and attaches a `simInfo` block on the base CDF (see
`dgen_buildSimInfo` in `dgenCDF.il`) of the form:

```skill
(nil
  spectre  (nil current port componentName "<cell>" namePrefix "ahdl"
                termOrder (...) instParameters (...)
                netlistProcedure ansSpectreSubcktCall)
  spectreS (nil ... netlistProcedure ansSpiceSubcktCall))
```

Without this, the OSS netlister silently treats the veriloga view as a
hierarchical "switch view", finds no sub-instances, and **skips the
cell entirely** with `WARNING (OSSHNL-117): Ignoring switch view
'veriloga' of cell '<cell>' as it does not contain any instance`. The
sim then "succeeds" but the dreg never makes it into the netlist —
silent functional drop. Reverse-engineered by diffing
`ahdlLib/trans_channel`'s base CDF (which works) against ours; see
project memory `project_dreg_gen.md` for the full debugging trail.

## CDF parameter flags for "Copy from cellview"

Each `cdfCreateParam` call in `dgenWriteCDF` sets `?parseAsCEL "yes"`
and `?parseAsNumber "yes"` so ADE/Maestro's "Copy from cellview" walks
each instance parameter value as a CDF Expression Language expression
(rather than an opaque literal string) and auto-imports the free
symbols into the design-variables table. Without these flags, Spectre
still evaluates the value at netlist time, but the user has to type
each variable into the design-variables table by hand. Per
skartistref.pdf p.959 `parseAsNumber` MUST be set when `parseAsCEL` is.

## defaultMode for CDF

The GUI exposes 4 modes via plain-English labels. Internal canonical
tokens (used in spec / lastState / cell prop) and their behavior:

| Mode (token) | GUI label | DVDD defValue | d_EN defValue | d_D (bus) defValue |
|------|------|---------------|---------------|---------------------|
| `"literal"` (or absent) | "Hard-coded number" | `"0.9"` | `"0"` | `"0"` |
| `"empty"` | "Leave empty" | `""` | `""` | `""` |
| `"variable_pin"` | "Variable = pin name" | `"DVDD"` | `"EN"` | `"D"` |
| `"custom"` + `defaultPattern="d_*"` | "Variable, custom pattern" | `"DVDD"` | `"d_EN"` | `"d_D"` |
| `"custom"` + `defaultPattern="*_ls"` | "Variable, custom pattern" | `"DVDD"` | `"EN_ls"` | `"D_ls"` |

`custom` requires `spec~>defaultPattern`; `*` is replaced by the pin name
(multiple `*` allowed). DVDD is always literal `"DVDD"` in variable-style
modes (no pin name to substitute). The pattern field defaults to `"d_*"`
in the GUI — picking custom mode + leaving the field blank produces the
same result as the legacy `"variable"` mode.

**Legacy `"variable"` token (silently migrated).** Older lastState files
or cell props may carry `defaultMode = "variable"` (= `d_<PIN>`
auto-prefix). `dgen_resolveCurrentSpec` rewrites these to `"custom"` +
pattern `"d_*"` on read. `dgen_resolveDefValue` in `dgenCDF.il` also
keeps a defensive `"variable"` branch so any spec that bypasses the GUI
(direct script use, for example) still netlists correctly.

Variable-style modes assume same-named design variables exist in the testbench
or ADE-XL; otherwise sim fails with "undefined variable".

CDF prompts: scalar pins show `d_<PIN>`; bus pins show `d_<PIN><hi:lo>` so the
user knows the field accepts a multi-bit integer (0..2^N-1).

## Loading and using in CIW

**Recommended `.cdsinit`** (single line; assumes `$WORK_ROOT2` is set in
your shell rc and points at the workarea dir):

```skill
load(strcat(getShellEnvVar("WORK_ROOT2") "/skill_tools/skill_tools.il"))
```

The umbrella derives its own install dir from `$WORK_ROOT2` and sources
MyTool + every `dgen*` module in the right order. See `mytool/README.md`
for other configuration styles (`SKILL_TOOLS_ROOT`, explicit setq, dev
fallback) and the full resolution priority order.

To load just dreg_gen without MyTool menu wire-up (the menu hook silently
no-ops when `mtRegister` is undefined):

```skill
setq( dreg_genDir "/abs/path/to/skill_tools/dreg_gen/" )
load( strcat(dreg_genDir "dreg_gen.il") )
```

Manual (if you need to skip a module):

```skill
base = "/home/yusheng/cadence_work/Test/workarea/skill_tools/dreg_gen/"
load(strcat(base "dgenPinScan.il"))
load(strcat(base "dgenStore.il"))
load(strcat(base "dgenPatterns.il"))
load(strcat(base "dgenSymbol.il"))
load(strcat(base "dgenVerilogA.il"))
load(strcat(base "dgenCDF.il"))
load(strcat(base "dgenRun.il"))
load(strcat(base "dgenGui.il"))
```

Open the GUI for a DUT (modeless; remembers last-state):

```skill
dgenOpenGUI("sim_yusheng" "Test_cell")
```

Or open DUT-less (top section only — pick a DUT via the 3 picker buttons):

```skill
dgenOpenGUI()
```

## MyTool integration

`dgenGui.il` self-registers as a MyTool plugin on load. Once `mytool` is
loaded BEFORE this plugin (the recommended `skill_tools.il` umbrella loader
takes care of the order automatically), every attached schematic / Maestro /
ADE-XL window shows a **MyTool → Dreg Generator** entry that calls
`dgenOpenGUI()` (no args — DUT-less mode; user picks the DUT in-form).

Registration uses `(when (getd 'mtRegister) (mtRegister ...))`, so dropping
the `mytool/` framework still leaves dreg_gen fully usable from the CIW —
the registration is silently skipped when `mtRegister` is undefined. See
`workarea/skill_tools/mytool/README.md` for the framework's plugin registration
pattern and behavior.

End-to-end orchestrated call (skips GUI, useful for scripting):

```skill
pins = dgenScanPins("sim_yusheng" "Test_cell" "symbol")
spec = list(nil
  'source list(nil 'lib "sim_yusheng" 'cell "Test_cell" 'view "symbol")
  'target list(nil 'lib "sim_yusheng" 'cell "dreg_va_Test_cell" 'view "veriloga")
  'dvddDefault "0.9"
  'defaultMode "literal"
  'pins (mapcar (lambda (p) (append p (list 'enabled t 'default "0"))) pins))
dgenRun(spec)        ; symbol -> .va -> CDF, fail-fast
```

Or call the three generators by hand if you need to skip a step:

```skill
dgenWriteSymbol(spec nil nil)        ; ORDER MATTERS
dgenWriteVerilogA(spec nil nil)
dgenWriteCDF(spec nil nil)
```

## Citation convention

`; Ref: <pdf> p.NNN (funcName)` comments use **physical PDF page numbers**
matching `~/.claude/skills/virtuoso-skill/assets/function_index.tsv` and the
Read-tool `pages:` argument. Page-number convention is the same across all
`.il` files in this directory.

## SKILL idiom gotchas hit during development

See `~/.claude/projects/-home-yusheng-cadence-work-Test-workarea/memory/feedback_skill_gotchas.md`
for the full list (no `let*`, no `defvar`, no `*foo*` identifiers, no prefix
arithmetic, type-template chars `t s n l g d f b ?`, `setq` can't take
subscript form).

Project-specific gotchas in
`~/.claude/projects/-home-yusheng-cadence-work-Test-workarea/memory/project_dreg_gen.md`:
- OA vs Spectre flow distinction (we target Spectre-only)
- Symbol must come before Verilog-A
- `schPinListToSymbolGen` silent-failure under write lock (mitigated in dgenSymbol.il)
- `parseString` drops empty tokens around delimiters (used char-walk in dgenCDF.il)
