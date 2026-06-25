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
| `vh_convert.py` | Stage B: analog `.va` → wreal `.v` (pattern catalog) | ⏳ TODO |
| `vhGui.il`      | thin SKILL GUI (select-from-schematic → config → folder → Extract) | ⏳ TODO |
| `examples/nested_chain/` | text-nested pure-digital example (`.va` instantiates `.va`), **verified end-to-end PASS** | ✅ |
| `examples/schem_nested/` | **schematic-nested** example: captured oa2verilog netlist + on-disk veriloga leaves, Stage A→C→xrun **verified PASS** | ✅ |

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

xrun env on the dev box: `source <workarea>/Verilog_check/setup_xcelium.sh` (or let
`run.sh` set it). See **HANDOFF.md** for the full context, env recipes, and decisions.
