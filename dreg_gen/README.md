# Dreg Generator

A Cadence SKILL tool that auto-generates a "driver register" cell from a DUT
cell's pins. Each enabled pin becomes a CDF parameter on the Dreg instance;
the user fills 1/0 (digital), output voltage = `value × DVDD`. Bus pins
(`D<7:0>`) collapse to one integer parameter, bit-decomposed in Verilog-A.
A pin can be switched to **Analog** (drives its value as a voltage), and any
signal can carry **transient timing** -- timed edges on top of its DC value,
baked into the generated `.va` (see [Transient timing](#transient-timing)).

**Status:** Steps 1–5 + 7 complete and validated on IC6.1.8 / `sim_yusheng/Test_cell`,
plus Phase C plugin wiring (registers under the **MyTool** banner menu on every
schematic / Maestro / ADE-XL window), plus transient timing / Analog pins /
embedded config + Save As (2026-10-06). Step 8 (packaging, GitHub tag) is pending.

## Files and public functions

| File | Public function | Purpose |
|------|----------------|---------|
| `dgenPinScan.il` | `dgenScanPins(libName cellName viewName)` | Open source cellview, return list of pin descriptor plists. Bus parsing (`D<7:0>`, `D<3>`, `D`) and bit-decomposed merge included. |
| `dgenStore.il` | `dgenSpecToString` / `dgenStringToSpec`, `dgenSavePropOnCell` / `dgenLoadPropFromCell`, `dgen_saveConfigProp` / `dgen_dregConfigOf`, `dgenSaveLastState` / `dgenLoadLastState`, `dgen_specEmitList`, `dgen_plistPut` | Spec serialization, embedded dreg config (`dgenConfig` string prop on the dreg's symbol view -- the full spec incl. timing; `dgenViews` -- the extra timing views, see [Timing views](#timing-views-one-symbol-several-veriloga-views)), last-state file at `~/.skill_tools/dreg_gen.last`, unified emit list (enabled pins + customVars, pin `'kind` normalized). |
| `dgenTiming.il` | `dgen_tmExprNorm` / `dgen_tmExprVal` / `dgen_tmExprVA`, `dgen_validateTiming`, `dgen_tmAfterList`, `dgen_tmTimedPairs`, `dgen_tmUsedVars`, `dgen_tmEmitAnalog`, `dgen_tmFromText` / `dgen_tmToText` | Transient timing data layer: cell expressions (literals, variables, sums), timing variables, row validation (errors vs. warnings), toggle display, Verilog-A emission, text import/export. No GUI, no db writes. |
| `dgenPatterns.il` | `dgenPatternsClassify(pin pats)`, `dgenPatternsLoad`, `dgenPatternsSave`, `dgenPatternsDefault` | Pin classification engine. Returns `'power` / `'dreg` / `'other` for each DUT pin from name + direction. Keyword dictionary at `~/.skill_tools/dreg_gen.patterns` (auto-falls-back to baked-in default). |
| `dgenSymbol.il` | `dgenWriteSymbol(spec [outLib outCell])` | Generate symbol view via `schPinListToSymbolGen`, all pins as direction `"output"` (right-side placement). Includes write-lock post-condition check. |
| `dgenVerilogA.il` | `dgenWriteVerilogA(spec [outLib outCell])` | Write `veriloga.va` + `master.tag` into the cell's `veriloga/` dir, refresh lib via `ddUpdateLibList`, add cell to "dreg" category. |
| `dgenCDF.il` | `dgenWriteCDF(spec [outLib outCell])` | Build cell-level base CDF (`cdfCreateBaseCellCDF` + `cdfCreateParam` × N + `cdfSaveCDF`). 4 `defaultMode` options + a defensive legacy branch. Also the q-form extras: read-only `dgenTiming` summary + `dgenEditTiming` button (see [Editing from q](#editing-from-the-instance-properties-form-q)). |
| `dgenRun.il` | `dgenRun(spec)` | End-to-end orchestrator: calls symbol → .va → compile → CDF in mandatory order, fail-fast on any substep nil-return, then embeds the spec on the dreg (soft step). Deselects selected instances of the target first and repaints their windows afterwards (display gotcha below). No lib/cell overrides — set `spec~>target` instead. |
| `dgenTimingGui.il` | `dgenTimingEditorOpen()` | The [Timing Table...] editor: report table + edit row (Add / Update / Delete), View by signal / by time, file Import / Export. Commits to `dgen_currentTiming` and refreshes the main form's summaries in place. |
| `dgenGui.il` | `dgenOpenGUI(@optional dutLib dutCell dutView)` | Modeless form. With no args: opens "DUT-less" — top section only (Lib/Cell/View combos + 3 picker buttons), pre-filled from last-state v2. With `dutLib`+`dutCell`: opens fully rendered (legacy path). Source: 3 linked combos + `[Select from Schematic]` / `[Browse Library...]` / `[Load Pins]`. Target editable + DVDD/mode/pattern + per-pin enable/value. Buttons OK / Cancel / Defaults / Apply. Last-state remembered across sessions; pin "value" fields auto-grey when mode ≠ literal AND swap their displayed text to the resolved variable name (pin name for `variable_pin`, pattern-substituted for `custom`, `""` for `empty`) so the row reads as a faithful preview of what will be emitted. The user's literal number is preserved in `dgen_pinLiteralCache` and restored when the user toggles back to literal mode. **Self-registers as a MyTool plugin** at load time (entry "Dreg Generator"; guarded with `getd` so dgenGui.il still loads if mytool/ is absent). |
| `test_step5_auto.il` | (loadable test) | End-to-end smoke test for the GUI that bypasses display so it doesn't trap the skillbridge evaluator. Loads through `ws['load'](...)`. **Writes `sim_yusheng/dreg_Test_cell`** -- don't run it against a library you care about. |
| `test_timing.il` | `dgenTestTiming()` | Pure-function self-tests for the timing layer (incl. expressions / variables) + pin kinds + emission + the q-form extras + timing views (136 asserts, no db writes). |
| `test_patterns.il` | `dgenTestPatterns()` | Self-tests for the pin classifier (39 asserts). |

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
    list(nil 'name "VDD" 'isBus nil 'kind "analog"    'enabled t   'default "0")   ; Analog pin
    list(nil 'name "CLK" 'isBus nil                   'enabled nil))    ; skipped
  'customVars    list(                                                  ; user-added in GUI; may be absent
    list(nil 'name "XX_EN"   'kind "digital" 'isBus nil                   'default "0")
    list(nil 'name "XX_ctrl" 'kind "digital" 'isBus t   'busHi 3 'busLo 0 'default "0")
    list(nil 'name "VDD1P8"  'kind "analog"                               'default "1.8"))
  'timing        list(                                                  ; may be absent = all DC
    list(nil 'signal "EN"  'time "5n"  'edge "50p" 'value "")      ; 1-bit: toggles
    list(nil 'signal "D"   'time "30n" 'edge "50p" 'value "165")   ; bus: new integer
    list(nil 'signal "VDD" 'time "0"   'edge "10u" 'value "1.8"))   ; analog: new volts
  'timingVars    list(                                                  ; optional table
    list(nil 'name "T_1" 'default "5n")))  ; values (ordering + .va fallback)
```

`'customVars` is appended to `'pins` in the unified emit list (`dgen_specEmitList` in
`dgenStore.il`), so the symbol view gets one extra output pin per customVar, the
`.va` gets one extra port/parameter/analog-line, and the CDF gets one extra
parameter. Naming convention enforced by `dgen_emitParamName`:

| Kind    | .va parameter   | CDF parameter | Drive expression           |
|---------|-----------------|---------------|----------------------------|
| digital | `integer d_<N>` | `d_<N>`       | `V(N) <+ d_<N> * DVDD;`    |
| analog  | `real v_<N>`    | `v_<N>`       | `V(N) <+ v_<N>;` (literal) |

Pins are digital unless the GUI's per-row Digital/Analog switch set
`'kind "analog"` (scalar pins only; `dgen_specEmitList` forces bus pins
back to digital). Analog items are always scalar (the GUI doesn't expose
bus syntax for analog; the emitters defensively force scalar shape if a
buggy spec carries `'isBus t` on an analog item).

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
dgen_dropBaseCDF(spec)       ; 3a. no CDF for the text-view update to reconcile
dgen_compileVerilogA(spec)   ; 3. amsUpdateTextviews + ahdlUpdateViewInfo
dgenWriteCDF(spec)           ; 4. after compile -- this matters
dgen_saveConfigProp(spec)    ; 5. embed the spec on the symbol (soft step)
```

**Why the config prop after the symbol.** `schPinListToSymbolGen` recreates
the symbol view, which drops any property written before it.

**Why symbol before V-A.** `schPinListToSymbolGen` silently creates 0
terminals if the cell already has a `veriloga` view at the time of the
call.

**Why CDF last.** `amsUpdateTextviews` and `ahdlUpdateViewInfo` rewrite
the cell's BASE CDF as a side effect — they derive parameter defaults
from the .va's `parameter integer d_X = 0` declarations, clobbering any
variable-mode defaults installed earlier AND re-adding entries for pins
the user disabled. `dgenWriteCDF` therefore runs AFTER `compileVerilogA`
so its rewrite is final.

**Why drop the CDF before the compile.** `amsUpdateTextviews` reconciles
an EXISTING CDF with the `.va` parameters and pops a modal
**CDFParamDeleted** ("delete them from the CDF?") for every CDF parameter
the `.va` lacks -- pins dropped since the last run, and since the q-form
extras, `dgenTiming` / `dgenEditTiming` on EVERY regeneration. With no CDF
there is nothing to reconcile; `dgenWriteCDF` rebuilds it right after
anyway (verified: no prompt, CDF + simInfo complete).

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

## Transient timing

Every emitted signal (enabled pin or customVar) can carry timed edges on top
of its DC value. Signals without edges emit exactly the pre-timing Verilog-A
(byte-identical, verified), so regenerating an old dreg changes nothing.

**Model (like Cadence sources: vpulse's DC voltage vs its waveform).** The DC
value (`d_<PIN>` / `v_<NAME>`, i.e. the GUI value column or its design
variable) is what **DC analyses** (dc op / dc sweep / ac / noise / stb) see;
timers never fire there. The **transient** starts at the signal's **init
row** (`'time "init"`, one per signal, value = 0/1 / number / variable /
`DC`; the GUI adds `init 0` with a signal's first edge; a table without an
init row starts from the DC value, as before init rows existed) and then
follows the edge rows: `'time` = absolute START of the edge, `'edge` = ramp
duration (linear 0→100 %, same for rising and falling). A 1-bit row with an
empty value **toggles**; `0` / `1` / a variable / `DC` set the level. Bus rows
carry a new integer, analog rows a new voltage; `DC` (any case) in any value
cell means the DC value. Example ("RX mode" = `rx_en`): `EN init 0`,
`EN 50n 50p DC` -- DC analyses see rx_en; tran is 0 then rx_en at 50n
(so rx_en=0 gives 0 throughout). Literals: `5n`, `5ns`,
`50ps`, `1.2u`, `0`, `1e-9` (case-insensitive, one trailing `s` dropped; `M`
reads as milli); analog values accept `1.8`, `-0.5`, `900m`, `1e-3`.

**Expressions + timing variables.** Every time / edge / value cell is an
expression: terms joined by `+` / `-`, each a literal or a variable --
`T_1`, `T_1+70n` (relative timing), `TR`, `VDDH-0.1`, `BV+1`. **Any
identifier typed in a cell is a variable; nothing is declared first.** Each
variable the emitted rows use becomes

- a Verilog-A `parameter real tv_<NAME> = <fallback>;`
- a CDF parameter `tv_<NAME>` whose default is the **bare design-variable
  reference `<NAME>`** (always, whatever defaultMode says; parseAsCEL), so
  ADE / Maestro **Copy From Cellview** puts `<NAME>` into the design
  variables table, ready to set or sweep. Values arrive empty -- fill them
  in (the GUI's success dialog lists the variables).
  The `tv_` prefix keeps `.va` / CDF names clear of pins and of `d_` / `v_`
  parameters; the design variable is exactly what the user typed.

**Table values (optional).** Ordering needs numbers, so variables may carry
a table value in `spec~>timingVars` -- `(nil 'name "T_1" 'default "50n")`.
The Timing Table asks for the Time-cell ones when the user switches to
**View: By time**, and in that view also when Add / Update brings in a new
Time-cell variable without a value (each variable is asked once per editor
session -- left blank it isn't asked again; [Variable values...] reopens
the dialog). A variable without a value sorts as 0, i.e. first. Table values are used for GUI
ordering / display (`T_1+70n = 120n`) and as the `.va` fallback (else 0) --
never as the simulation value, which always comes from the design
variable. Cells with variables get syntax and reserved-name checks only
(`time`, `temp`, `tnom`, `freq`, `scale`, `scalem`, `pi`, `dvdd`, `dc`, `init`); range /
same-time / overlap checks apply to plain-literal cells.

**Emission** (one block per timed signal, `dgen_tmEmitAnalog`):

```verilog
integer lvl_EN;  real edge_EN;  integer nedge_EN;
...
@(initial_step) begin nedge_EN = 0; edge_EN = 50p; end
if (nedge_EN == 0) lvl_EN = analysis("tran") ? 0 : (d_EN != 0);   // init 0
@(timer(5n))    begin lvl_EN = !lvl_EN; edge_EN = 50p;  nedge_EN = nedge_EN + 1; end
@(timer(50n))   begin lvl_EN = !lvl_EN; edge_EN = 100p; nedge_EN = nedge_EN + 1; end
@(timer(max(tv_T1+70n, 1f))) begin lvl_EN = !lvl_EN; edge_EN = max(tv_TR, 1f); nedge_EN = nedge_EN + 1; end
V(EN) <+ transition(lvl_EN * DVDD, 0, edge_EN, edge_EN);
```

**Master switch `timing_en`.** Every view of a timed dreg declares
`parameter real timing_en = 1;` and the CDF carries `timing_en` (default
"1", parseAsCEL, in simInfo instParameters). Timer blocks are emitted as
`@(timer(t)) if (timing_en != 0) begin ... end` and the start line as
`(analysis("tran") && timing_en != 0) ? init : dc`, so 0 keeps every
signal at its DC value in transient too. A number on purpose: 0 / 1 in q,
or a design variable flipped from Maestro / corners. Verified via OCEAN on
a testbench instance with `timing_en=tm_en`: tm_en=1 -> EN 0 then 0.9 at
50n; tm_en=0 -> 0.9 throughout. A port named `timing_en` is refused.

**DC analyses see the DC value; transient starts at init.**
`analysis("tran")` is already true at the transient's t=0 operating point
and false in dc / dc sweep / ac (verified, Spectre 18.1, 2026-10-07), so
the line before the first edge picks init vs the DC parameter (init `DC`
emits just the DC parameter). Until the first edge fires
(`nedge_X == 0`) the level is re-derived on every evaluation -- not latched
at `initial_step`, which a DC sweep inside one Spectre run (`dc
param=...`) doesn't re-run: latched, a timed pin kept the first sweep
point's value (rx_en 0→1 left it at 0; fixed and verified 2026-10-07 for
1-bit, bus and analog signals). Verified end to end on a generated `.va`:
`EN init 0`, `EN 50n DC`, `d_EN=rx_en` -- rx_en=1: dc op 0.9, tran 0
then 0.9 at 50n; rx_en=0: 0 in both.

Times and edges that involve variables are wrapped in `max(..., 1f)`, so a
swept `T0 = 0` / `TR = 0` still ramps from the initial level (same reason
literal `0` becomes `timer(1f)`, below); values are emitted as-is
(`lvl_D = tv_BV;` -- a real parameter assigned to the integer state rounds).

Buses use one `transition()` per bit on `((lvl_X >> i) & 1) * DVDD` (same
hi→lo walk as the DC path); analog uses `transition(lvl_X, ...)`. The `.va`
starts with a comment table of all edges.

**Verified on Spectre 18.1 (2026-10-06)**, standalone and through the ADE
netlister (OCEAN on a testbench instance, with variable-mode defaults):

- `transition()` takes the `edge_X` assigned in the same event block, so
  every edge gets its own ramp time (50p / 100p / 110p measured exactly).
- **`timer(0)` must not be used**: Spectre fires it while solving the
  initial operating point, so the ramp collapses into a step. Rows at t=0
  are emitted as `timer(1f)` -- the DC point keeps the initial level and
  the ramp starts 1 fs later.
- An edge that starts while the previous one is still ramping reverses
  from the current level at the new slope -- legal, so validation only
  warns about it.
- Instance overrides work as expected: `d_EN=1` (or design var `EN_ls=1`)
  starts high and every edge inverts; `DVDD`, bus init and `v_VDD` init
  apply before the first edge.
- Timing variables (verified through OCEAN on a testbench instance, i.e.
  the ADE netlister): setting `T0=20n T1=80n TR=1n VDDH=1.2 BV=5` moves
  every edge as expected (`T1+70n` follows T1 to 150n, 1 ns ramps, new
  bus / analog values); `T0=0`, `TR=0` clamp cleanly. **ADE L Variables >
  Copy From Cellview** and **ADE Assembler test > Design Variables > Copy
  from Cellview** both list BV / T0 / T1 / TR / VDDH (values empty).

**Validation** (`dgen_validateTiming`): hard errors block generation (a
cell that doesn't parse, a reserved variable name, a literal time < 0 or
edge ≤ 0, a literal bus value outside 0..2^(maxbit+1)-1, two LITERAL edges
of one signal at the same time, a table value that isn't a number, an
internal `lvl_X`/`edge_X` name clashing with a port). Warnings are shown
but don't block: rows for signals that aren't enabled (kept in the table,
skipped at emit) and overlapping literal ramps.

**Text format** (Timing Table Import / Export, also the `.va` header):

```
T_1 = 5n                         # optional table value (ordering only)
EN        init    -     0        # transient start (0/1, number, variable, DC)
EN        T_1     50p            # 1-bit: value omitted / "-" / "toggle"
EN        T_1+45n 100p  DC       # relative -- no blanks inside a cell; DC = d_EN
N_ctrl    30n     50p   10       # bus (D<3:0> suffix accepted)
VDD       0       10u   1.8      # analog
```

### Embedded config, re-editing, Save / Save As

`dgenRun` ends with `dgen_saveConfigProp`: the full spec (DUT source, pin
enable/value/kind, customVars, timing) is stored as the `dgenConfig` string
property on the dreg's **symbol** view, so the definition travels with the
cell (Library Manager copy, red-zone tarball, other users). A dreg is
reopened for editing by picking it like a DUT -- Source = the dreg +
[Load Pins], [Select from Schematic] on a dreg instance, or opening the
GUI with exactly one dreg instance selected (`dgen_selectedDregInst`). The
form then shows the dreg's real DUT as Source and the dreg as Target.

`dgen_seedSpec` picks what the form opens with: (1) `dgen_pendingSpec`, the
in-flight spec carried across internal close-reopens (+Digital/+Analog/
Delete, same-DUT Load Pins, dreg picks); (2) the embedded config of the
resolved Target cell when it exists and was made from this DUT -- so
reopening the tool on a DUT brings its dreg's timing back instead of
silently regenerating it as pure DC; (3) the last-state overlay. customVars
and timing are therefore persisted with the dreg (they are its ports and
stimulus), but still never in the per-user last-state file.

OK / Apply write the Target cell ("Save"). When that would change the
timing of an existing dreg, `dgen_confirmOverwrite` asks Yes/No ("every
testbench using this cell will simulate the new timing"); No keeps the
form open (`?unmapAfterCB t` + `hiSetCallbackStatus`). Validation errors
and unexpected SKILL errors also keep the form open. [Save As...] writes a
new cell through the same path and can switch the instance the edit
started from to it (`schReplaceProperty "master"`; the schematic is left
modified for the user to save; read-only schematics are reported, not
touched).

**Open-cellview modes (gotcha, verified).** The compile step leaves the
dreg's symbol open read-only, and `schPinListToSymbolGen` silently upgrades
an already-open symbol to `"a"` and leaves it there. Both
`dgenWriteSymbol` and `dgenSavePropOnCell` therefore record the prior mode
(`dbFindOpenCellView`) and `dbReopen` back to it -- otherwise a dreg
regenerated twice in one session stays write-locked (and gets a panic file
if Virtuoso dies).

### Editing from the instance Properties form (q)

The q form groups everything about timing below the DC values (DVDD,
`d_` / `v_`): a header row `==== Timing ====` -- CDF has no separator /
label type (IC6.1.8 rejects both), so it is the read-only `dgenTiming`
parameter whose value is the summary (`8 edges on 4 signals` /
`DC (no edges)`, `?parseAsCEL "no"`, `?storeDefault "no"`) -- then the
master switch `>> timing_en: 1 = ON, 0 = OFF` first, the other timing
views, the `tv_` timing variables, and `dgenEditTiming`, a `?type
"button"` labelled **Edit timing...**. Neither is
in simInfo `instParameters`, so nothing is netlisted. The button's
`?display` / `?callback` strings are
`isCallable('dgenCdfEditTimingShow) && dgenCdfEditTimingShow()` /
`when(isCallable('dgenCdfEditTimingCB) dgenCdfEditTimingCB())` -- where
dreg_gen isn't loaded the button simply doesn't show, so those two names
are a stored contract: don't rename them. Dregs generated before this
version get the button on their next regeneration.

Flow (verified on screen, IC6.1.8): select the dreg instance → `q` →
**Edit timing...** → the Properties form closes with OK (values typed in it
are kept) → the generator opens on that dreg (as with a selected instance)
with the Timing Table on top → edit → OK, then OK (Yes to overwrite) or
Save As (optionally switching this instance) → ADE / Maestro re-netlists
the new `.va` on the next run.

Verified facts behind the code:
- In a CDF callback `cdfgData->id` is the **cell** (ddCellType); the
  instance is `cdfgForm->objId` of the Properties form
  (`cdfgForm->hiFormSym == 'schObjPropForm`). `?display` is evaluated with
  `cdfgForm` bound: `schObjPropForm` for q, `schCreateInstForm` for Add
  Instance -- the button is hidden there (no instance yet, and a
  regeneration would rewrite the CDF that form shows). The docked Property
  Editor assistant lists the button as a plain read-only row.
- `dgenOpenGUI` does **not return** while the main form is up
  (`hiDisplayForm` of a blocking app form), so anything after it runs only
  once the user closes the generator. The Timing Table is therefore
  scheduled with `hiRegTimer` BEFORE `dgenOpenGUI` (`dgen_openDregInst`).
- The q form is closed (OK) in one timer tick and the generator opened in
  the next (`dgen_cdfEditTimingDeferred` → `dgen_cdfEditTimingOpen`), so the
  form's OK handling finishes before the long blocking `dgenOpenGUI` call.
- **Display gotcha.** Regenerating a dreg while one of its instances is
  selected left that instance drawn as a bare dashed box (no body, no
  labels) in that window for good -- `hiRedraw` / `geRefresh` /
  `geRefreshCellView` don't repair it; a newly opened window draws it
  fine. `dgenRun` therefore deselects the target's instances in every
  graphic window first (selection belongs to the cellview: repaint every
  window showing it), and the windows are repainted from a timer -- the GUI
  re-arms it after its OK callback returns, because a repaint while the
  result dialog is still up (inside the callback) comes too early.
  `geGetSelSet` is only asked on windows with a cellview (`w~>cellView`):
  on the CIW / ADE / waveform windows it prints GE-2067.

### Timing views: one symbol, several veriloga views

Use case: hand someone the dreg and say "this symbol, but use view
`veriloga_RX`". [Save As...] → **Save as: New timing view of this cell**
writes `<cell>/veriloga_RX/veriloga.va` (+ netlist.oa) next to `veriloga`;
the symbol and the cell CDF are shared, so **only the timing differs** --
pins, Digital/Analog and DC values come from the main view
(`dgen_viewCompatErr` refuses anything else with a message).

- **Storage.** The main spec stays in `dgenConfig`; the timing views are the
  `dgenViews` prop on the symbol: `((nil view "veriloga_RX" timing (...)
  timingVars (...)) ...)`. Readers (`dgen_dregViewsOf`) drop entries whose
  view no longer exists, so deleting a view in the Library Manager is
  enough.
- **Generation** (`dgen_runSteps`): whatever view is saved, every view is
  rebuilt from the main spec + its own timing, all declaring the union of
  the views' timing variables (`'viewVars` → `dgen_tmUsedVars`; the extras
  read "fallback 0 (used by another timing view)" in the header). So a pin
  change in the main view reaches all timing views, and the shared CDF
  (tv_ union) fits whichever view is netlisted -- no Spectre "not a valid
  parameter" warnings. Views whose text is unchanged are neither rewritten
  nor recompiled (`dgenWriteVerilogA` returns `'same`); the symbol is only
  regenerated when the main view is saved.
- **Module name** stays the cell name in every view. One view per netlist:
  Spectre lets a second `ahdl_include` of the same module silently override
  the first (SFE-2654, verified), so don't bind two views of one dreg to
  different instances of the same design.
- **Editing.** q → [Edit timing...] (or MyTool with the instance selected)
  asks which view when there are several (`dgen_viewChooserOpen`); the
  form title, Timing Table title and overwrite question name the view.
  [Select from Schematic] / [Load Pins] on a dreg open the main view.
- **q form** shows `Timing (veriloga)` and `Other timing views:
  veriloga_RX` (`dgenViews` read-only CDF param).
- **Picking the view (the user side)** -- verified on IC6.1.8 with the same
  testbench: ADE L Setup > Environment > Switch View List
  `... schematic veriloga_RX veriloga` netlists `veriloga_RX/veriloga.va`;
  back to `... schematic veriloga` gives the main timing; a config with
  `cell <lib>.<cell> binding :veriloga_RX;` (Hierarchy Editor: View to Use)
  does the same (OCEAN `design(lib cell "config")`). Maestro: the test's
  Environment Options carry the same Switch View List.

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
load(strcat(base "dgenTiming.il"))
load(strcat(base "dgenSymbol.il"))
load(strcat(base "dgenVerilogA.il"))
load(strcat(base "dgenCDF.il"))
load(strcat(base "dgenRun.il"))
load(strcat(base "dgenTimingGui.il"))
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
