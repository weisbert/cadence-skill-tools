# Dreg Generator

A Cadence SKILL tool that auto-generates a "driver register" cell from a DUT
cell's pins. Each enabled pin becomes a CDF parameter on the Dreg instance;
the user fills 1/0 (digital), output voltage = `value × DVDD`. Bus pins
(`D<7:0>`) collapse to one integer parameter, bit-decomposed in Verilog-A.

**Status:** Steps 1–4 + 7 complete and validated on IC6.1.8 / `sim_yusheng/Test_cell`.
Steps 5 (GUI dialog), 6 (Ctrl+Shift+D bindkey), 8 (packaging) are pending.

## Files and public functions

| File | Public function | Purpose |
|------|----------------|---------|
| `dgenPinScan.il` | `dgenScanPins(libName cellName viewName)` | Open source cellview, return list of pin descriptor plists. Bus parsing (`D<7:0>`, `D<3>`, `D`) and bit-decomposed merge included. |
| `dgenStore.il` | `dgenSpecToString` / `dgenStringToSpec`, `dgenSavePropOnCell` / `dgenLoadPropFromCell`, `dgenSaveLastState` / `dgenLoadLastState` | Spec serialization, cell-property round-trip (`dgenConfig` prop), last-state file at `~/.skill_tools/dreg_gen.last`. |
| `dgenSymbol.il` | `dgenWriteSymbol(spec [outLib outCell])` | Generate symbol view via `schPinListToSymbolGen`, all pins as direction `"output"` (right-side placement). Includes write-lock post-condition check. |
| `dgenVerilogA.il` | `dgenWriteVerilogA(spec [outLib outCell])` | Write `veriloga.va` + `master.tag` into the cell's `veriloga/` dir, refresh lib via `ddUpdateLibList`, add cell to "dreg" category. |
| `dgenCDF.il` | `dgenWriteCDF(spec [outLib outCell])` | Build cell-level base CDF (`cdfCreateBaseCellCDF` + `cdfCreateParam` × N + `cdfSaveCDF`). 5 `defaultMode` options. |
| `dgenRun.il` | `dgenRun(spec)` | End-to-end orchestrator: calls symbol → .va → CDF in mandatory order, fail-fast on any substep nil-return. No lib/cell overrides — set `spec~>target` instead. |

## Spec plist format

```skill
spec = list(nil
  'source        list(nil 'lib "L" 'cell "C" 'view "symbol")
  'target        list(nil 'lib "TL" 'cell "TC" 'view "veriloga")
  'dvddDefault   "0.9"
  'defaultMode   "literal"      ; or "empty" / "variable" / "variable_pin" / "custom"
  'defaultPattern "*_ls"        ; only used when defaultMode="custom"
  'pins          list(
    list(nil 'name "D"   'isBus t   'busHi 7 'busLo 0 'enabled t   'default "0")
    list(nil 'name "EN"  'isBus nil                   'enabled t   'default "0")
    list(nil 'name "CLK" 'isBus nil                   'enabled nil)))    ; skipped
```

`outputLib` / `outputCell` args, when non-nil, override `spec~>target~>lib` /
`spec~>target~>cell` for that single call.

## Critical ordering rule

**Symbol must be generated before the Verilog-A.** `schPinListToSymbolGen`
silently creates 0 terminals if the cell already has a `veriloga` view at
the time of the call. The orchestrator (step 7) must enforce:

```skill
dgenWriteSymbol(spec)        ; first
dgenWriteVerilogA(spec)      ; second
dgenWriteCDF(spec)           ; third (CDF works regardless of order, but keep it
                             ;  last for the natural symbol -> source -> params flow)
```

## defaultMode for CDF

| Mode | DVDD defValue | d_EN defValue | d_D (bus) defValue |
|------|---------------|---------------|---------------------|
| `"empty"` | `""` | `""` | `""` |
| `"literal"` (or absent) | `"0.9"` | `"0"` | `"0"` |
| `"variable"` | `"DVDD"` | `"d_EN"` | `"d_D"` |
| `"variable_pin"` | `"DVDD"` | `"EN"` | `"D"` |
| `"custom"` + `defaultPattern="*_ls"` | `"DVDD"` | `"EN_ls"` | `"D_ls"` |
| `"custom"` + `defaultPattern="d_*"` | `"DVDD"` | `"d_EN"` | `"d_D"` |

`custom` requires `spec~>defaultPattern`; `*` is replaced by the pin name
(multiple `*` allowed). DVDD is always literal `"DVDD"` in variable-style
modes (no pin name to substitute).

Variable-style modes assume same-named design variables exist in the testbench
or ADE-XL; otherwise sim fails with "undefined variable".

CDF prompts: scalar pins show `d_<PIN>`; bus pins show `d_<PIN><hi:lo>` so the
user knows the field accepts a multi-bit integer (0..2^N-1).

## Loading and using in CIW

```skill
base = "/home/yusheng/cadence_work/Test/workarea/skill_tools/dreg_gen/"
load(strcat(base "dgenPinScan.il"))
load(strcat(base "dgenStore.il"))
load(strcat(base "dgenSymbol.il"))
load(strcat(base "dgenVerilogA.il"))
load(strcat(base "dgenCDF.il"))
load(strcat(base "dgenRun.il"))
```

End-to-end orchestrated call:

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
