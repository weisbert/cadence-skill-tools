# verilog_helper

Auto-generate testbenches for (possibly **nested**) VerilogAMS modules and verify
them under **pure-digital** `xrun` (wreal, **no Spectre license**). Sibling tool to
`dreg_gen` / `note_helper` under the **MyTool** banner.

Pattern (like `note_helper`): a thin SKILL GUI (planned) shells out to **standalone,
Cadence-independent Python CLIs** (stdlib only). The Python runs equally well on the
dev box (smoke) and the red zone (real run) — the GUI is just a launcher.

## Pipeline

```
A  read config → expand DUT hierarchy + per-instance view binding + resolve external paths
   → gather .va into a folder, emit top .v, write manifest        (needs OA: oa2verilog CLI)
B  classify analog/digital → mechanically convert analog→wreal .v for the bounded
   pattern set; FLAG anything unrecognized; never overwrite originals
C  pins (from .v) + your intent → checks/stimulus → generate TB + run.sh
D  package (airgap_deploy_template) → red-zone verify.sh runs pure-digital xrun
   manifest.json threads through all stages
```

## Files

| File | Role | Status |
|------|------|--------|
| `vh_parse.py` | VerilogA static parser (ports/dirs/disciplines/instances+connections) + graph (top/leaf/external/dups); also an inventory CLI | ✅ working |
| `vh_gen.py`   | Stage C: hierarchy → wreal stub per external + self-checking TB + run.sh + sim.tcl + manifest | ✅ working |
| `vh_extract.py` | Stage A: config (cds.lib+expand.cfg) → oa2verilog hierarchy → clean structural top + gathered `.va` leaves + external interfaces + manifest | ✅ working |
| `vh_env.py`     | tool-remembered **external HDL env** (`-v` lib files / `-y` dirs / `+incdir`); resolves externals & bakes into `run.sh` | ✅ working |
| `vh_convert.py` | Stage B: detect analog cells, convert voltage-transfer analog→wreal, skeleton the rest; writes a candidate `veriloga_wreal.va` beside each cell + a detection list | ✅ working |
| `vh_package.py` | Stage D: pack a build into a relocatable, env-agnostic air-gap bundle (sources + `setup_env.sh` + `ext_libs.list` + `verify.sh` preflight) + tar.gz/sha256 | ✅ working |
| `vh_dut.py`     | multi-DUT driver: one folder per DUT, auto-detect config/sources/test, run the whole pipeline per DUT, `run-all` with a PASS/FAIL summary | ✅ working |
| `vhGui.il`      | thin SKILL GUI: select-from-schematic + Lib/Cell/View picker + **[Scan Pins]** (cellview terminals → name/dir/bus to clipboard+file) → `system()`-shells out to the CLIs ([Extract A][Convert B][Generate C][Run xrun][Package D]) + external-`-v`-env buttons. Registers under **MyTool → Verilog Helper** | ✅ working |
| `verilog_helper.il` | single-file loader (resolves `verilog_helperDir`, sources `vhGui.il`); also loaded by the `skill_tools.il` umbrella | ✅ working |
| `examples/nested_chain/` | text-nested pure-digital example (`.va` instantiates `.va`), **verified end-to-end PASS** | ✅ |
| `examples/schem_nested/` | **schematic-nested** example: captured oa2verilog netlist + on-disk veriloga leaves, Stage A→C→xrun **verified PASS** | ✅ |
| `examples/analog_leaf/` | **Stage-B** example: an analog gain leaf, Stage A→B(convert)→C→xrun **verified PASS** (`out=3*in`) | ✅ |

## Run the examples (CLI, no GUI)

**Text-nested** (`.va` instantiates `.va`, Stage C only):
```bash
cd skill_tools/verilog_helper
python3 vh_parse.py examples/nested_chain/src                 # inventory
python3 vh_gen.py  --src examples/nested_chain/src \
                   --out examples/nested_chain/build \
                   --checks examples/nested_chain/checks.json # generate
bash examples/nested_chain/build/run.sh                       # xrun -> === TB PASS ===
```

**Schematic-nested** (Stage A → C → xrun; uses a captured oa2verilog netlist so it
runs without a live OA design):
```bash
cd skill_tools/verilog_helper/examples/schem_nested
python3 ../../vh_extract.py --config config/expand.cfg --cdslib cds.lib \
        --netlist oa_netlist/amp_top_raw.v --out build      # Stage A: clean top + .va leaves
python3 ../../vh_gen.py --src build/export --out build/sim \
        --checks checks.json                                 # Stage C: TB + stubs
bash build/sim/run.sh                                        # xrun -> === TB PASS ===
```

## GUI (vhGui.il) — one-click launcher inside Virtuoso

A thin SKILL launcher (note_helper-style): it owns no logic, it just gathers
paths and `system()`-shells out to the `vh_*.py` CLIs. Load it via the umbrella
(`skill_tools.il` already sources it) or standalone:

```
load("/abs/path/to/skill_tools/verilog_helper/verilog_helper.il")
```

Then **MyTool → Verilog Helper** opens the form:

- **Source Lib/Cell/View** combos + **[Select from Schematic]** (click an
  instance — its master lib/cell fill the combos) / **[Browse Library...]**.
- **[Scan Pins]** scans the DUT cellview's terminals → a `name + input/output/inout
  (+ bus <hi:lo>)` list, put on the **clipboard**, written to `<Output>/<cell>_pins.txt`,
  and echoed to the CIW. This pin list is the basis for writing the testbench/checks.
- **config (expand.cfg)** / **cds.lib** / **captured netlist** / **Output
  folder** / **checks.json** / **user testbench** file pickers.
- **external -v library** + **[Add -v lib]** (remembers it via `vh_env.py`) /
  **[Show env]**.
- **[Extract A] [Convert B] [Generate C] [Run xrun] [Package D]** run the
  pipeline against the Output folder (`<out>/manifest_A.json` → `<out>/export`
  → `<out>/sim` → run → package). **[Run xrun]** executes `<out>/sim/run.sh`
  (the pure-digital xrun) and shows the verdict on the Status line:
  `=== TB PASS ===` / `=== TB FAIL ===` **plus** `[SMOKE: externals stubbed]`
  vs `[functional: all ext resolved]` — so a dev smoke pass (externals stubbed
  with ideal buffers) is never mistaken for a real verification. Each button
  prints its full log to the CIW and a one-line result to the **Status** field.

> **Smoke vs real / red zone.** The dev box is a *smoke proxy* (stubbed
> externals, shell design); the authoritative run is the **red zone** against
> real `-v` models. See **[RED_ZONE.md](RED_ZONE.md)** for the dev → red handoff
> (build → package → transfer → edit `ext_libs.list` → `verify.sh`), and the
> `RUN-KIND: SMOKE/FUNCTIONAL` line every run emits.

The CLIs do the real work, so the GUI runs identically on the dev box and the
red zone. Overridable globals (set before/after load): `vh_pythonCmd`
(default `python3`), `vh_shellPrefix` (default `""`; e.g.
`"env -u LD_LIBRARY_PATH"` if Virtuoso's env ever poisons the child python),
`vh_scriptDir`, `vh_browseDir`.

## Stage A (vh_extract) usage

```bash
# from a hierarchy-editor config (drives oa2verilog on a box with IC618):
python3 vh_extract.py --config <expand.cfg> --out <dir> [--cdslib <cds.lib>]
# target the real DUT instead of a TB schematic the config points at:
python3 vh_extract.py --config <expand.cfg> --cell <DUT_cell> --out <dir>
# reuse a captured netlist (skip oa2verilog — for the red zone / tests):
python3 vh_extract.py --config <expand.cfg> --netlist <oa2verilog.v> --out <dir>
```
Stage A strips OA pin artifacts (`ipin/opin/iopin`) and analogLib TB stimulus
(`vdc/vpulse/idc/gnd/…`), warns if you are netlisting a testbench, flags a pin-only
stub DUT ("nothing to verify"), gathers veriloga leaves as `.va`, records external
modules (with oa2verilog-accurate port directions) for Stage C to stub, and writes a
wreal-normalized structural top to `<dir>/export/` plus `manifest_A.{json,txt}`.

**Passives on a signal net.** analogLib 2-terminal passives (`res/cap/ind`) are
*functionally transparent* in a pure-digital wreal check, so Stage A removes them
from the signal path: a **series** element (a net goes through it to the next cell)
is **shorted** (its two nets are merged), and a **shunt to ground** is **opened**
(dropped). This means `net → ind → next cell` is handled correctly (the signal
passes straight through), and multiple passives of the same kind no longer collide
in one shared stub. Non-2-terminal or bus-bit passives are left in place + warned.
The `PASSIVES` section of `manifest_A.{txt,json}` lists what was shorted/opened.
(If a passive is *load-bearing*/analog — a real filter or resonance — that's a
"needs spectre" case, not pure-digital; model it as wreal or keep it analog.)

## External HDL env (vh_env) — where the `-v` library files live

External cells (the design instantiates them but their bodies live in a shared HDL
library, e.g. `…/workarea/ams_models/L16_SVT_ana.v`) are normally pointed at via an AMS
testbench's *Library Files (-v)*. To avoid building an AMS TB just for that, **the tool
remembers the list itself** (user-level `~/.config/verilog_helper/env.json`):

```bash
python3 vh_env.py add-lib /path/ams_models/L16_SVT_ana.v   # remember a -v library file
python3 vh_env.py add-dir /path/some_lib                    # remember a -y library dir
python3 vh_env.py add-inc /path/includes                    # remember a +incdir dir
python3 vh_env.py show                                      # list + which modules it provides
python3 vh_env.py remove <path> | clear
```

Once remembered, `vh_extract`/`vh_gen` use it automatically: an external **found** in a
`-v` file is **resolved** (its real def is compiled by xrun via `-v`, not stubbed) and
flagged `[analog]`/`[wreal]`; anything **not** found falls back to an auto-stub. Per-run
override on either tool: `--ext-lib <file> --ext-dir <dir> --ext-inc <dir>`
(`--no-remember` to not persist, `--ext-clear` to ignore the remembered set).

## Stage B (vh_convert) — analog cell → digital, non-destructively

The ORIGINAL cell `<cell>/veriloga/veriloga.va` is what ships to the real top and may be
analog; the thing we verify must be digital. Stage B bridges that:

```bash
python3 vh_convert.py --manifest <out>/manifest_A.json     # convert Stage A's leaves
python3 vh_convert.py --src <cell>/veriloga/veriloga.va --out <dir>   # standalone
```
For each cell it prints a **detection list** (already-digital / converted / needs-manual)
and writes a candidate **`veriloga_wreal.va` right next to the original** (it never
overwrites `veriloga.va` — you review, then copy it over). Voltage-transfer analog
(`V(o[,r]) <+ expr`, incl. bus `V(bus[i])<+…` → unpacked wreal arrays) is auto-converted
to `assign`s; anything with `I(…)<+` / `ddt` / noise / temp-vars gets a **TODO skeleton**
to fill in. In `--manifest` mode the gathered `export/` copy is updated to the digital
version so the pure-digital run uses it. `--no-cell-write` keeps everything out of the lib.

## Stage D (vh_package) — relocatable air-gap bundle for the red zone

```bash
python3 vh_package.py --build <stageC_out>/sim          # -> package/ + tar.gz + sha256
# transfer to the red zone, then there:
tar xzf <top>_pkg.tar.gz && bash <top>_pkg/verify.sh     # preflight smoke, then the TB
```
The bundle is **self-contained and relocatable**: all sources are flattened in and
`run.sh` refers to them by relative name. It is **env-agnostic** — `setup_env.sh` uses
`xrun` if it's already on PATH (the red zone, verified `19.04`), else falls back to a dev
Xcelium or a `VH_SITE_ENV` you point at. External `-v` libraries are listed in
`ext_libs.list` (edit to the red-zone paths; or `export VH_EXT_LIBS=…`). `verify.sh` runs
a **pure-digital wreal preflight** first (proves xrun works here, no spectre) and only then
the design TB. The package is per-DUT user data — it goes to a work dir, not the repo.

## Many DUTs (vh_dut) — one folder per DUT

For lots of DUTs, give each its own folder and let the driver run the whole pipeline
per DUT, isolated:

```
duts/
  DUT1/  expand.cfg cds.lib [oa_netlist/*_raw.v] [checks.json|*_tb.v]   # OA-config driven
  DUT2/  foo.v bar.va  mydut_tb.v                                       # hand-dropped + own test
  DUT3/  *.va  checks.json                                             # hand-dropped + golden
```
```bash
python3 vh_dut.py list    duts/         # show what was detected per DUT
python3 vh_dut.py run     duts/DUT1     # one DUT (full A->C, +Stage D with --package)
python3 vh_dut.py run-all duts/         # every DUT -> per-DUT _vh/ + a PASS/FAIL summary
```
Per DUT it auto-detects: `expand.cfg`→Stage A (uses a captured `*_raw.v` netlist if present,
else `oa2verilog`)→B; else the folder's `.v/.va/.vams`→straight to C. A test file
(`tb*.v`/`*_tb.v`/`test*.v`) is used as your testbench (`--tb`); else `checks.json` drives a
generated TB. Everything for a DUT lands in `<dut>/_vh/` (gitignored). A per-DUT `dut.json`
can override any field (`top`, `cell`, `tb_top`, `ext_lib`, `no_convert`, …). In config mode
Stage B runs `--no-cell-write` (updates the verified copy to digital, never touches your lib).

xrun env on the dev box: `source <workarea>/Verilog_check/setup_xcelium.sh` (or let
`run.sh` set it). See **HANDOFF.md** for the full context, env recipes, and decisions.
