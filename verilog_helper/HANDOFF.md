# verilog_helper — HANDOFF / design context

- **Date:** 2026-06-25
- **Dev box:** `eda` (Rocky 8.10 / RHEL8 = "linux8"), the dev/green zone.
- **Goal:** given veriloga `.va`/`.vams` files, auto-generate a testbench, run it under
  `xrun` in **pure-digital** mode (wreal, **no Spectre**), and verify. Hard case =
  **nested** DUTs; must support text-nesting (.va instantiates .va) AND schematic+config
  nesting (OA top, leaves bound to veriloga).

---

## 1. Why this lives in skill_tools (not a standalone repo)

The user wants a **usage-layer** convenience: in the schematic, *Select from Schematic →
pick cell → pick config_ams → one click → extracted into a folder*, with a one-click GUI
like `note_helper`. That UX is Virtuoso-integrated, so the tool rides skill_tools'
**MyTool** banner + the existing **air-gap deploy** pipeline.

Follow the **note_helper pattern**: a *thin* SKILL GUI shells out (`system()`) to
**standalone, Cadence-independent Python** and exchanges data via temp files —
**no skillbridge at runtime**. The Python must stay stdlib-only and CLI-invokable so it
(a) is developed/tested on dev without a GUI, (b) runs on the red zone for the xrun stage.
**Rule: all logic in Python; the .il is only a launcher.**

The select-from-schematic + Lib/Cell/View picker can be copied from `dreg_gen/dgenGui.il`
(it already has `[Select from Schematic]` / `[Browse Library]` and 3 linked combos).
Pin scan from a live cellview: reuse `dreg_gen/dgenPinScan.il :: dgenScanPins(lib cell view)`.

---

## 2. Pipeline (manifest-centric)

```
A  read config(.cdslib + expand.cfg) → expand DUT hierarchy + per-instance view binding
   + resolve EXTERNAL file paths → gather .va into export/ + oa2verilog top .v + manifest   [needs OA]
B  classify analog/digital (+ why) → mechanically convert analog→wreal for the bounded
   pattern set; FLAG unrecognized; originals READ-ONLY, converted files written separately    [pure python]
C  pins (from .v) + user intent → checks.json/stimulus → vh_gen bakes TB + run.sh             [pure python]
D  package via airgap_deploy_template → red-zone verify.sh runs pure-digital xrun             [template ready]
   one manifest.json is created by A, annotated by B/C, consumed by D
```

### Current state
- **A:** **built & verified** — `vh_extract.py`. Two decoupled phases:
  *netlist* (drives `oa2verilog`, skippable with `--netlist`) + *process* (pure python:
  parse `cds.lib`+`expand.cfg`, classify masters, strip artifacts, gather `.va`, emit a
  clean wreal-normalized structural top + `manifest_A.json`). Verified on the real
  `sim_yusheng/Test_PMU` config (TB-stimulus stripped & warned, `--cell PMU_top` flags
  the pin-only stub) and end-to-end on `examples/schem_nested` (Stage A→C→xrun = PASS).
  See §3a for the decisions this surfaced.
- **B:** not built. Pattern catalog locked (§3).
- **C:** **built & verified** — `vh_parse.py` + `vh_gen.py`. `examples/nested_chain`
  runs end-to-end to `=== TB PASS ===` (exit 0): top `chain`→`preproc`→{scaler,summer};
  `ext_sensor` correctly classified EXTERNAL, its port dirs inferred from connectivity
  (out:output, in:input), auto-stubbed as an ideal buffer; 5 vectors checked vs golden.
- **D:** not built. `airgap_deploy_template/` in the workarea is the reusable pipeline.

---

## 3a. Stage-A decisions (learned from the real OA design on the dev box)

The live OA design is currently a **shell**: `PMU_top`/`Test_cell` schematics are
**pin-only stubs** and the veriloga leaves (`ldo_core_pll/vco/vref_bias`) are orphaned
(no schematic instantiates them). So Stage A was built to be honest about that and was
proven runnable via a captured-netlist fixture. Decisions baked into `vh_extract.py`:

1. **`oa2verilog` has no `-config` flag** (IC618 22.60) — only `-view`. With
   `-recursive -noStopping` it descends `schematic` views and emits an **empty interface
   module** for every master with no schematic (veriloga leaves, externals, pin cells).
   That naturally "stops at the veriloga leaf" — no config needed for the descent.
2. **TB-vs-DUT**: the config's `design` often points at a **testbench** schematic
   (`Test_PMU` is full of `vpulse/vdc/idc/gnd` + the DUT `PMU_top`). Stage A strips that
   analogLib stimulus, **warns**, and lists DUT candidates; `--cell <DUT>` retargets.
   A TB top also has **no ports** (all nets internal) → useless for TB-gen → another
   reason to target the DUT cell.
3. **Master classification**: structural (kept) / veriloga-leaf (empty + `.va` on disk →
   gathered, interface dropped) / external (empty + no `.va` → recorded with
   oa2verilog-accurate port dirs for Stage C to stub) / pin artifact `ipin/opin/iopin`
   (dropped) / stimulus (dropped+warned). The **targeted top itself**, if empty, is a
   **pin-only stub → "nothing to verify"** flag, not an external.
4. **wreal normalization**: oa2verilog emits `wire`; the pure-digital flow is wreal, so
   Stage A rewrites scalar `wire`→`wreal` and merges port decls to `input wreal x;`.
   Buses are left + warned (scalar-only, consistent with Stage C).
5. **Two-phase decouple** (`--netlist`): the OA-dependent netlist step is split from the
   portable pure-python processing, so the red zone / CI / tests reprocess a captured
   netlist without OA. This is how `examples/schem_nested` runs end-to-end here.
6. **cds.lib** parsed recursively (DEFINE + INCLUDE + SOFTINCLUDE) → lib→path map; leaf
   `.va` resolved at `<libpath>/<cell>/veriloga/veriloga.va`.
7. **External HDL resolution (`vh_env.py`)**: the tool owns a remembered list of `-v`
   library files / `-y` dirs / `+incdir` (user-level `~/.config/verilog_helper/env.json`,
   per-run `--ext-lib/--ext-dir/--ext-inc` override). Stage A parses those files; an
   external **found** there is RESOLVED (real def compiled by xrun via `-v`, not stubbed)
   and flagged analog/wreal; **not found** → Stage C stubs it. `vh_gen` skips stubbing
   resolved externals and bakes the `-v/-y/+incdir` (and `+libext+.v`) into `run.sh`.
   This replaces the earlier (wrong) `.scs ahdl_include` plan — see §6.4.
- Side fixes this surfaced: `vh_parse` now tolerates combined port decls
  (`input wreal x;`); `vh_gen.gen_stub` multi-output `_const` bug fixed.

## 3. Stage-B conversion pattern catalog (LOCKED — voltage only, no current)

User's circuits are exactly these (no complex analog; LDO-style models are for
spectre-accelerated modeling and are NOT brought into functional checks):

| analog source pattern | digital (wreal/logic) form |
|---|---|
| ideal V source `V(p)<+ c` | `wreal p; assign p = c;` |
| constant reference | same |
| simple gain `V(o)<+ k*V(i)` | `assign o = k*i;` |
| threshold / comparator `(V(i)>vth)?VH:VL` | `assign o = (i>vth)?VH:VL;` (also power-OK detect) |
| sample / hold | `always @(posedge clk) h<=i; assign o=h;` |
| DAC code→level (bus) | bit-weighted sum — **reuse dreg_gen bit-decompose** |
| buffer | `assign o=i;` |
| dff | `always @(posedge clk) q<=d;` |

- **No current quantities** on the functional-check path (user confirmed) → no need to
  map `I(...)<+` (which has no clean pure-wreal equivalent). If that ever changes, revisit.
- **Unrecognized pattern → FLAG, never guess-convert.**
- **Never overwrite originals.** The "binding" (existing-source vs converted vs stub) is
  recorded in the manifest; converted files are separate artifacts. (No `_bk` overwrite.)

---

## 4. Environment recipes (dev box)

### xrun (Xcelium 18.03-s001) — bash
`~/.cshrc` only helps tcsh; automation runs in bash, set env manually:
```bash
export XCELIUM_HOME=/home/yusheng/Program/eda/cadence/XCELIUM1803
export CDS_LIC_FILE=/home/yusheng/Program/eda/cadence/license/license.dat
export PATH="$XCELIUM_HOME/tools/bin:$PATH"
```
- **Pure-digital wreal + `-ams` needs NO spectre.** The lines
  `Spectre_AMSD_Lk / Spectre_AMS_MMSIM_Lk ... license checkout failed` are **BENIGN**
  (pure wreal has no electrical nodes to solve; sim runs digital-only, exit 0).
- **`-amsvlog_ext .vams,.va`** is REQUIRED: xrun decides language by extension and does
  not know `.va` (only `.vams`). Without it: `*E,FMUK: type of file could not be determined`.
  The option overrides the map, so list both. (Baked into `vh_gen.py`'s run.sh.)
- SELinux Enforcing; `selinuxuser_execheap` already ON (-P) — required or `xmsim` crashes
  with `*F,INTERR` at run.
- Full install story: `<workarea>/Verilog_check/Xcelium_安装交接.md`.

### oa2verilog (schematic → structural .v) — IC618 on RHEL8
```bash
source <workarea>/LDO_modeling/cadence/env.sh        # CDSHOME=IC618, etc.
export OA_UNSUPPORTED_PLAT=linux_rhel60               # else sysname=unknown, OA tools die on RHEL8
export CDS_ENABLE_EXP_PCELL=1                         # else analogLib pcell sources: OAVLG-10055
oa2verilog -lib <lib> -cell <cell> -view schematic -verilog out.v \
  -libDefFile <workarea>/cds.lib -recursive -noStopping -logFile out.log
```
Leaf cells with only symbol+veriloga come out as empty interface modules (bodies live in
the `.va`). Gotcha: a cell's `schematic/data.dm` may list STALE master deps — trust the
netlist from `sch.oa`, not data.dm grep hits. **Netlist the DUT cell, not a TB schematic**
(a TB schematic pulls in vdc/vpulse/idc stimulus you'd discard).

---

## 5. Zone / deploy model (red-zone runs the real verification)

```
dev(linux8, this box) ──git push──▶ GitHub ──git pull──▶ yellow(Windows, pack.ps1) ──upload──▶ red(linux7, deploy.sh)
   write + smoke (xrun 18.03)                              git-free tar+sha256              air-gap, no net/git, in-place swap+backup
```
- **Red zone xrun = 19.04** (ICADVM18.1; from the original reference prompt). Dev = 18.03.
  `-ams` / `-amsvlog_ext` / wreal exist in both; dev smoke is a valid proxy. **Add a
  preflight smoke on red** before trusting a run.
- skill_tools' own deploy (`skill_tools/deploy/{pack.ps1,deploy.sh}`) ships the repo to red.
- `airgap_deploy_template/` is the reusable pipeline for Stage-D per-DUT verification packages.
- The generated per-DUT package (`.v`+stubs+TB+verify.sh) is **user data → goes to a work
  dir, NOT committed into the repo.** Stage-D `run.sh`/`verify.sh` must be **env-agnostic**
  (red paths differ) — current `vh_gen.py` hardcodes dev paths; make it source a site env. (TODO)

---

## 6. Locked decisions
1. **Pure-digital only, no spectre.** Verified achievable for wreal designs.
2. **Voltage-only** functional checks (no current).
3. **config scope = the DUT only** (not a full TB).
4. **External binding** = some cells reference a std/external HDL file. The REAL place
   this path lives (user-confirmed 2026-06-25, correcting an earlier `.scs ahdl_include`
   guess) is **AMS Options -> Include Option Settings -> Library Files (`-v`)** in an AMS
   testbench, e.g. `…/workarea/ams_models/L16_SVT_ana.v` (= xrun `-v`). BUT the user runs
   ordinary (non-AMS) analyses and will NOT build an AMS TB just to hold these paths.
   **Decision: the TOOL owns the external include list** — user sets `-v` files / `-y`
   dirs / `+incdir` once, the tool remembers them (user-level `~/.config/verilog_helper/
   env.json`, per-run override) and bakes them into the generated `run.sh`. Stage A parses
   the `-v` files to report which externals are covered (and flags analog ones), falling
   back to a stub for anything unresolved. (`vh_env.py` manages this; see §3a.)
5. **Analog DUT** (electrical/analog begin) → **FLAG "needs spectre"**, do NOT digitize to
   "verify" it (circular). Digitize only *neighbors*, and an **ideal stub** usually suffices.
6. Conversion is **assisted/bounded + non-destructive** (§3), never blind.

## 7. Open items / next steps
- [x] **Stage A `vh_extract.py`** — built & verified (see §3a).
- [x] **External HDL resolution `vh_env.py`** — built & verified: remembered `-v`/`-y`/
      `+incdir` env; externals resolved-or-stubbed; flags analog; baked into `run.sh`.
      (Replaces the wrong `.scs` plan — real location is AMS Options Library Files; §6.4.)
      Remaining Stage-A refinements: (a) honor `cell … binding :veriloga` *when the cell
      also has a schematic* (coded, untested — dev-box design has no such conflict);
      (b) bus/vector ports flow through as-is + warn (scalar-wreal only end-to-end).
- [ ] **Stage B `vh_convert.py`**: pattern-matching analog→wreal per §3. (The real leaves
      `ldo_core_pll/vco/vref_bias` are analog `electrical`/`analog begin` → prime B input.)
- [ ] **Stage D**: make `run.sh` env-agnostic; wire `airgap_deploy_template`; red preflight.
- [ ] **GUI `vhGui.il`**: note_helper-style launcher (select-from-schematic + config picker).
- [ ] Get from user: a real external-binding config + its sim file; red-zone XCELIUM
      path/version/license + air-gap transfer specifics.

## 8. Memory pointers (Claude Code persistent memory)
`xcelium-working-and-gotchas`, `oa2verilog-rhel8-recipe`, `verilog-check-project`,
`eda-install-layout`.
