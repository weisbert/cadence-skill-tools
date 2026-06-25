# verilog_helper — HANDOFF / design context

## 0. STATUS (2026-06-25)

**The whole pipeline AND the GUI are built, verified, and pushed.** Stages:
- **A** `vh_extract.py` — OA config (cds.lib+expand.cfg) → oa2verilog hierarchy → clean
  wreal structural top + gathered `.va` leaves + `manifest_A.json`. ✅
- **B** `vh_convert.py` — analog cell → wreal (detection list + non-destructive
  `veriloga_wreal.va` candidate beside each cell). ✅
- **C** `vh_parse.py`+`vh_gen.py` — TB + stubs + `run.sh` (+ `--tb` for your own test). ✅
- **D** `vh_package.py` — relocatable, env-agnostic air-gap bundle + preflight + tar/sha256. ✅
- `vh_env.py` — remembered external `-v` library env. ✅
- `vh_dut.py` — **multi-DUT driver** (one folder per DUT, `run-all` summary). ✅
- **GUI** `vhGui.il` (+ `verilog_helper.il` loader) — thin SKILL launcher under
  **MyTool → Verilog Helper**: select-from-schematic + Lib/Cell/View picker +
  **[Scan Pins]** (terminals → name/dir/bus to a **preview popup** + clipboard +
  `<out>/<cell>_pins.txt` + CIW) + `[Extract A][Convert B][Generate C][Run xrun][Package D]`
  + **[External libraries...]** (multi-entry manager popup: several `-v`/`-y`/`+incdir`,
  Save/Reload/Clear → remembered env via `vh_env import/export`, AMS-Options-style); each
  action button `system()`-shells out to a `vh_*.py` CLI (or `bash run.sh` for Run).
  **Input simplification:** cds.lib is auto-written from the live OA lib list
  (`ddGetLibList`+readPath), and expand.cfg is optional (standalone lib+cell, or
  auto-found config view) → minimal input is **pick DUT + Output**. ✅
- **Passives** (Stage A) — analogLib 2-terminal `res/cap/ind` on a signal net are
  removed from the path: **series → shorted** (nets merged), **shunt-to-gnd → opened**;
  non-2-terminal/bus skipped+warned; listed in `manifest_A` `PASSIVES`. So `net → ind
  → next cell` is handled (signal passes through), and the old multi-passive shared-stub
  collapse is gone. ✅

Verified: `examples/{nested_chain,schem_nested,analog_leaf}` + `examples/duts/` (3/3).
**Red zone preflight PASSED** (xrun 19.04, pure-digital wreal, zero spectre license, xrun
ambient even in `bash -c`). Dev box OA design is a SHELL (PMU_top is a pin-only stub).
**GUI verified live** via skillbridge — a FULL user-flow simulation drove the real form
object (built but not displayed, the README-sanctioned scripted-form pattern): set fields,
"clicked" Extract A → Convert B → Generate C → **Run xrun → `=== TB PASS ===`** (real
xrun, ~4s) → Package D, then `hiFormCancel`. All 6 out-of-order/empty-field guards fire
clean hints; `vh_env show` confirmed read-only; registers once under MyTool. Only the
literal pixel *display* (`hiDisplayForm`) is left for the user to eyeball from the menu
(it blocks the bridge, so it can't be scripted).

**Remaining (user-owned, not code):** real red-zone `-v` lib paths (+ wreal/electrical?)
and a REAL DUT cell that actually instantiates leaves (the dev design is a shell). Full
detail below; live status also in the project memory
(`…/Verilog-check/memory/verilog-check-project.md`).

---

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
- **B:** **built & verified** — `vh_convert.py`. Detection list + bounded analog→wreal +
  non-destructive candidate beside each cell. Verified on the real leaves (dreg_Test_cell
  → CONVERTED, the LDO/bias models → FLAGGED skeleton) and end-to-end on
  `examples/analog_leaf` (Stage A→B→C→xrun = PASS, analog gain `V(o)<+k*V(i)` → `assign
  o=k*i`, `out=3*in`). Decisions in §3b.
- **C:** **built & verified** — `vh_parse.py` + `vh_gen.py`. `examples/nested_chain`
  runs end-to-end to `=== TB PASS ===` (exit 0): top `chain`→`preproc`→{scaler,summer};
  `ext_sensor` correctly classified EXTERNAL, its port dirs inferred from connectivity
  (out:output, in:input), auto-stubbed as an ideal buffer; 5 vectors checked vs golden.
- **Multi-DUT:** **built & verified** — `vh_dut.py`. One folder per DUT; auto-detects
  config-vs-hand-dropped sources and user-test-vs-checks; runs the whole pipeline per DUT
  into `<dut>/_vh/`; `run-all` gives a PASS/FAIL summary. `vh_gen --tb <file> [--tb-top]`
  added so a DUT can carry its OWN testbench (else a TB is generated from checks.json).
  Example `examples/duts/` (config / hand-dropped+checks / hand-dropped+user-test) = 3/3 PASS.
- **D:** **built & verified** — `vh_convert` aside, `vh_package.py` + an env-agnostic
  `run.sh`/`setup_env.sh` from `vh_gen`. Packs a Stage-C build into a relocatable,
  self-contained bundle (flattened sources + `setup_env.sh` + `ext_libs.list` + `verify.sh`
  preflight) + tar.gz/sha256. Verified by extracting the tarball to a fresh dir and running
  `verify.sh` in a CLEAN env (xrun resolved via fallback, preflight PASS, design TB PASS),
  incl. a `-v` external lib carried through `ext_libs.list`. Red-zone facts in §5/§7.

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

## 3b. Stage-B decisions (as built in `vh_convert.py`, 2026-06-25)

The user's two-cell-version insight: #1 = the ORIGINAL `<cell>/veriloga/veriloga.va` (may
be analog, **is what ships to the top**); #2 = the digital copy we verify. Verifying #2
isn't enough — the analog #1 must eventually be replaced. So Stage B's deliverable is:

1. **Detection list** (`manifest_B.{txt,json}`): every cell → `DIGITAL` (no action) /
   `CONVERTED` / `FLAGGED` (needs manual), with the reason.
2. **Non-destructive candidate beside the cell**: writes `<cell>/veriloga/veriloga_wreal.va`
   (chosen by user over a parallel view / `.wreal` suffix). It **never** touches
   `veriloga.va`; the user reviews + overwrites. `--no-cell-write` opts out.
3. **`export/` (the verification copy) is updated** to the converted source in `--manifest`
   mode, so the pure-digital run uses digital. FLAGGED cells leave `export/` analog and the
   list says the design isn't fully digital-verifiable until the skeleton is filled.
4. **Convertible = analog block is ONLY `V(node[,ref]) <+ expr`** with expr free of
   `I()`/`ddt`/`idt`/noise/filters/`@`/`if`/`for`/temp-var assignments. `V(a,b)`→`(a-b)`,
   `V(a)`→`a`; `V(o,r)<+e` → `assign o = e + r`. Params copied verbatim (keeps real/integer).
5. **Buses**: `wreal [msb:lsb]` is REJECTED by xrun (`*E,WRERNG Range specification not
   allowed on wreal`). Per-bit `V(bus[i])<+…` is emitted as an **unpacked wreal array**
   `wreal bus[msb:lsb];` + `assign bus[i]=…` (verified runnable). The candidate header warns
   to check the packed-wire↔unpacked-array connection in the real hierarchy.
6. Real-cell results: **dreg_Test_cell → CONVERTED** (bit-decompose control reg, bus);
   **ldo_core_pll/vco, vref_bias → FLAGGED** (temp-vars + `I()<+` + `ddt`/`white_noise`) →
   skeleton with inferred I/O directions (LHS of V/I contributions = outputs) + all params.

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
- skill_tools' own deploy (`skill_tools/deploy/{pack.ps1,deploy.sh}`) ships the TOOL to red.
- The per-DUT verification package is built by **`vh_package.py`** (DONE): a relocatable,
  env-agnostic, self-contained bundle (`<top>_pkg/` + `.tar.gz` + `.sha256`). It is **user
  data → goes to a work dir, NOT committed.** `setup_env.sh` resolves xrun env-agnostically
  (ambient on red / `VH_SITE_ENV` / dev fallback); `ext_libs.list` (or `VH_EXT_LIBS`) carries
  the red-zone `-v` paths; `verify.sh` runs a pure-digital preflight smoke then `run.sh`.
  Red `xrun` is ambient and the preflight PASSes there with zero spectre license use (§7).

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
- [x] **Stage B `vh_convert.py`** — built & verified (see §3b). Remaining: richer pattern
      coverage if real cells need it (sample/hold, dff with explicit clocks → currently
      skeleton); verify bus packed-wire↔unpacked-wreal-array connection in a real hierarchy.
- [x] **Stage D** — built & verified (`vh_package.py` + env-agnostic `run.sh`/`setup_env.sh`).
      **Red-zone facts (preflight 2026-06-25):** red `xrun = 19.04-a001`, pure-digital wreal
      smoke PASSed with **zero** spectre license errors (cleaner than dev) and no `*F,INTERR`;
      **xrun is ambient even in non-interactive `bash -c`** (`/software/cadence/xcelium/
      19.04.001/tools/bin/xrun`) — so the package needs NO env setup on red. Done: `setup_env.sh`
      uses ambient xrun else falls back; `ext_libs.list`/`VH_EXT_LIBS` carries red `-v` paths.
- [x] **GUI `vhGui.il`** — built & verified live (2026-06-25). note_helper-style thin
      launcher (`verilog_helper.il` loader + umbrella `skill_tools.il` wired). Registers
      under **MyTool → Verilog Helper**. Select-from-schematic (enterPoint + dbGetOverlaps
      hit-test, copied from `dgenGui.il`), Lib/Cell/View combos (`ddHiCreate*ComboField` +
      `ddHiLinkFields`), file pickers (config/cds.lib/netlist/checks/tb/-v lib), Output
      folder, and `[Extract A][Convert B][Generate C][Package D]` + `[Add -v lib][Show env]`.
      Each button → `vh_runCLI` builds `<prefix> python3 <dir>/vh_*.py <args> > log 2>&1`,
      `system()`s it, prints the log to CIW, surfaces a one-line result on Status.
      **Bug found & fixed live:** SKILL `cons` REQUIRES a list 2nd arg, so `(cons rc txt)`
      errored — return `(list rc txt)` instead (read with `car`/`cadr`). Verified via
      skillbridge: load, all helpers, every field builder, the real A→C→D shell-out from
      Virtuoso's env, `vh_env show` read-only, single MyTool registration.
- [ ] Get from user: the red-zone `-v` external-lib paths + whether they're wreal/electrical;
      a real DUT cell that actually instantiates leaves (the dev design is a shell).

## 8. Memory pointers (Claude Code persistent memory)
`xcelium-working-and-gotchas`, `oa2verilog-rhel8-recipe`, `verilog-check-project`,
`eda-install-layout`.
