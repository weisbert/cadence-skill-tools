# verilog_helper — HANDOFF / design context

## 0b. SESSION HANDOFF (2026-06-26)  — HEAD = `0c3f48f`+, all pushed

**ROOT CAUSE FOUND + FIXED (real run, red zone xcelium 19.04): the whole NDIV clock tree was
DEAD** — even the front-end taps `CLK2CNT=VCO/4` and `TESTCLK=VCO/16` (which do NOT touch
mmd_core) showed `no edges`. Cause: `pll_ndiv_div2_tspc` (the /2 TSPC prescaler, instances I7/I9
feeding DIV4sig) is a flop **gated by a wreal supply-headroom check** `((VDD-VSS)>k)&&((VPP-VSS)>k)`,
and the struct netlist instantiates it with **no supply connection** (`I7 (.CLK(fromVCO),.Q(net058))`
— rails are global/inherited, `oa2verilog` drops them). Wreal rails float → `power_on=0` → `Q` stuck
→ DIV4sig dead → everything hanging off it dead. **NOT #28.** Fix: Stage B now recognizes the
supply-DIFFERENCE / headroom threshold form (`(SUP±SUP)<cmp>k → 1'b1`, was only `(SUP<cmp>k)`), so
div2_tspc converts to a clean `always @(posedge CLK) Q<=~Q;` /2 divider. Reproduced + verified in
`examples/wreal_prediv/` (`./run.sh`=PASS CLKOUT=VCO/4, `./run.sh raw`=dead).

**NEXT FOCUS (resume here): re-run the real export through Stage B → C → Run.** On the GUI:
**Convert B** (now converts div2_tspc) → **Generate C** (Example TB dropdown =
`lpbt_ndiv/tb_LPBT_NDIV_TOP.vams`) → **Run** blank → expect CAL `CLK2CNT=VCO/4` + TEST
`TESTCLK=VCO/16` **HARD PASS** and `OUT_NDIV/CLK2DSM` now **WARN-live**; then defines
`+define+CHECK_NDIV` → `OUT_NDIV=VCO/4/(ndiv−1)`. (Watch `nor4 D`-drop perturbing exact N.) The
real div2_tspc + full struct are saved in gitignored `examples/lpbt_ndiv/_ref/`.

The real design `Hi1108_BT_LP_PLL_ANA.LPBT_NDIV_TOP` extracts CLEAN and ELABORATES (mmd_core fixed,
counter no longer stubbed). The hand-written real TB is verified locally vs the good-model
(`./run.sh` and `+define+CHECK_NDIV` → both `=== TB PASS ===`, VCO/4 + VCO/16 + VCO/36). Wiring it
to the real netlist is a **GUI click-flow** (no CLI). Open Verilog Helper and:
1. **Output folder** = the extract dir (the one with `export/`; pointing straight at an `export/`
   dir also works — Stage C falls back from `<out>/export` to `<out>`).
2. **Example TB (Stage C)** dropdown → `lpbt_ndiv/tb_LPBT_NDIV_TOP.vams` (auto-discovered from
   `examples/<x>/tb_*.vams`; grows by itself). Leave "user testbench" blank (it overrides the dropdown).
3. **Generate C** → builds `<out>/sim/` (real TB + run.sh wired to the real `export/` netlist).
4. **Run xrun** with the **xrun defines (Run)** box BLANK → generic smoke; expect CAL `CLK2CNT=VCO/4`
   + TEST `TESTCLK=VCO/16` **HARD PASS**. Read RUN-KIND + whether `OUT_NDIV/CLK2DSM` are WARN-live
   (should be live now that mmd_core is connected) vs WARN-dead.
5. Then put `+define+CHECK_NDIV` (and `+define+WAVES` for SimVision) in that box → functional N check
   `OUT_NDIV = VCO/4/(ndiv[7:0]−1)`. Waves land at `<out>/sim/ndiv.shm` → `simvision <out>/sim/ndiv.shm &`.
   Watch the `pll_ndiv_nor4_svt_x2` `D`-drop (could perturb the exact N); `M=ndiv−1` is user spec.

**How the defines reach xrun:** the generated `run.sh` now forwards `"$@"`; the GUI [Run] appends the
defines field; `./run.sh +define+...` works from the CLI too. Blank field = the generic completeness
smoke run (unchanged default — top auto-detected, `-access +rwc` always on so WAVES probes work).
The example's own `examples/lpbt_ndiv/run.sh` (vs the **good-model**, for TB mechanics) takes the same
`+define+...` args: `./run.sh +define+CHECK_NDIV +define+WAVES`, `+define+BREAK_NDIV` for negative self-test.

TB design (all CONFIRMED from the real struct's clock tree): front-end `fromVCO→div2→div2 =
VCO/4` prescaler; CAL `cal_en=1`→`CLK2CNT=VCO/4`, OUT_NDIV/CLK2DSM/TESTCLK quiet; TEST
`en_test=1`→`TESTCLK=VCO/16`; NORM→`OUT_NDIV=CLK2DSM=VCO/4/M`, `M=ndiv−1`. `pwsel`=duty (NC bit0),
`lpbt_en` NC. Spec in `examples/lpbt_ndiv/SPEC_CHECKLIST.md`; netlist notes in gitignored
`examples/lpbt_ndiv/_ref/`.

**This session's commits (all real-design-driven, each cloned+verified locally first):**
- `1b05f23` LPBT TB netlist-exact (period-ratio; CAL/TEST taps are real checks pre-#28).
- `e8f3223` vh_diag **SUSPECTED WRONG-VIEW** section (reads manifest reconciled_ports + per-lib views).
- `b903ad6` **#28 SOLVED = cross-LIBRARY collision**: `pll_ndiv_mmd_core` exists in BT_LP (design)
  AND `Hi1107c_GNSS_PLL_ANA`; Stage A grabbed GNSS. Fix: descend/gather by config-bound
  `(lib,view)` + `_lib_pref` (config liblist → design lib → rest). `config_bindings` now keeps the
  lib (was discarded). Works even w/o config (design lib preferred).
- `10836da` reconcile flags **FUNCTIONAL pin drops** loudly (real: `div2_tspc.en`, `nor4.D` = your
  model/symbol mismatch, tool can't invent the logic).
- `beaeb87` `vh_gen` **auto-detects the --tb top module** (GUI passes no --tb-top) → real TB runs from GUI.
- `ae13ccd` a **config view in --view redirects** to its design schematic + adopts its expand.cfg
  (oa2verilog can't open a config cellview → OAVLG-1007). `--view` is only the top-netlist view.
- `9da84e5` export layout: **`orig/`** (pristine copies, diff vs export/) + **`_work/`** (the `_sub_*.v`
  descend intermediates, out of the build root).
- `8dfd219` Stage B converts a **wreal supply/enable MONITOR → logic** (WuR_XO_output_driver:
  `OUT=(supplies_ok&&en_high)?IN:0` with wreal `en` → CUNDCM; → `OUT=en?IN:0`). Fixture
  `examples/wreal_monitor/`.
- `04ad553` NDIV TB **`+define+WAVES`** gate → `$shm_open/$shm_probe("AS")` → `ndiv.shm` (SimVision);
  example `run.sh` adds `-access +rwc` only when WAVES set (default path byte-identical).
- `4da6194` **generated `run.sh` forwards `"$@"`** to xrun → real-design builds take
  `+define+CHECK_NDIV` / `+define+WAVES` (GUI [Run] passes none → unchanged); also cleans `*.shm`.
- `0c3f48f` **GUI no-CLI workflow**: `vh_exampleTBs()` auto-discovers `examples/<x>/tb_*.vams` →
  "Example TB (Stage C)" dropdown (resolved via `vh_exTbMap` → `--tb`); Stage C src falls back
  `<out>/export`→`<out>`; new "xrun defines (Run)" field forwarded to `run.sh`. Live-verified on
  the running Virtuoso (instantiate only, no hiDisplayForm).

**SIDE THREAD — WuR_DIG_REFBUF_TOP_H1 (paused):** extracts clean now (config-view fix). Was
blocked on the wreal `en` CUNDCM → Stage B monitor conversion (8dfd219) is the fix. **WuR NEXT:**
run Convert B → Generate C → Run, confirm CUNDCM gone; check `manifest_B.txt` for any other
FLAGGED wreal cells on the XO path (wreal used as a value → not auto-converted, needs your semantics).

**Process (locked, followed all session):** observe via vh_diag → CLONE the failure in a LOCAL
fixture against local xrun (18.03) → fix+verify there → red zone = final check only. Regression =
9 examples + 3 duts (scratchpad `regress.sh`, drives Stage A/B/C+xrun). Solo repo → commit+push when done.

---

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
  action button `system()`-shells out to a `vh_*.py` CLI (or `bash run.sh` for Run),
  **in the BACKGROUND** (button returns at once, Virtuoso stays responsive, Status shows
  a live `running Ns…` counter + final result via a poll timer — no frozen-UI/looks-hung).
  **Input simplification:** cds.lib is auto-written from the live OA lib list
  (`ddGetLibList`+readPath), and expand.cfg is optional (standalone lib+cell, or
  auto-found config view) → minimal input is **pick DUT + Output**. ✅
- **Passives** (Stage A) — analogLib 2-terminal `res/cap/ind` on a signal net are
  removed from the path: **series → shorted** (nets merged), **shunt-to-gnd → opened**;
  non-2-terminal/bus skipped+warned; listed in `manifest_A` `PASSIVES`. So `net → ind
  → next cell` is handled (signal passes through), and the old multi-passive shared-stub
  collapse is gone. ✅
- **Real config-based hierarchy** (Stage A) — validated on a REAL design
  (`Hi1108_BT_LP_PLL_ANA/LPBT_NDIV_TOP`, a PLL N-divider): gathers behavioral leaves from
  `veriloga`/**`verilogams`**/`ahdl` view dirs (file may be `verilog.vams`), **recursively
  descends** sub-blocks whose schematic is a `cmos_sch`/nested-config view that
  `oa2verilog -view schematic` won't follow (`expand_hierarchy`, ordered by config
  viewlist), resolves std cells via the remembered `-v` libs, drops `noConn` + parasitic
  diodes (`DEVICE_DROP`), dedups, handles array instances `I[1:0]`, and gathers leaves
  **across multiple libraries**. Real result: **33 verilogams leaves gathered, externals =
  only the 5 real std cells (all -v-resolved), 0 bogus externals.** ✅

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

- **Bus / array support** (Stage C, DONE 2026-06-25) — the real design is heavily
  bus-based; the TB generator is now **bus-aware**. KEY INSIGHT that shrank the scope:
  slices `ndiv[7:0]`, concatenations `{a,b}` and array instances `I119[1:0]` all live
  **inside Stage A's `<top>_struct.vams`** (the oa2verilog netlist) — Stage C only emits
  the **TB + stubs** and instantiates the top, so for **packed-logic buses** (which is
  what `wrealize` leaves them as: it only converts *scalar* `wire→wreal`) those constructs
  are **native Verilog — xrun handles them with zero expansion**. So the work was making
  the TB/stub *match* the struct's bus port types, per-port:
    - scalar (`width==''`) → `real drv; wreal net; assign` (unchanged);
    - logic bus (sized + ntype `wire`/`reg`/none) → `reg [m:l]`(in)/`wire [m:l]`(out),
      integer-vector stimulus (`ndiv`/`pwsel`/`N_div` control words);
    - real bus (sized + ntype `wreal`) → **unpacked wreal array** `wreal x[m:l]` + per-bit
      drive (Stage-B convention; `*E,WRERNG` only if you *packed* a wreal).
  Stubs are bus-aware too: width inferred from connection slices/concats (÷ array-instance
  count), and **logic-vs-wreal chosen from the connected net's type** — a wreal stub on a
  logic net (or vice-versa) needs a connect module (`*E,CUNDCM`), so the stub net type
  mirrors what it's wired to. Golden checks stay scalar-output (bus bits referencable as
  `name[i]` in checks.json, e.g. `sel[0]`); bus outputs are displayed.
  Verified end-to-end under xrun on `examples/bus_div` (logic bus in/out, slices, concat,
  `dbuf Ub[3:0]` array instance, scalar wreal path → **TB PASS**) + a wreal-unpacked-array
  fixture + a stubbed-external (logic) + a wide-bus external (passthrough). All prior
  examples still PASS (3/3 duts, nested_chain, schem_nested, analog_leaf). ✅

- **Structural-verilogams sub-cell gather** (Stage A, DONE 2026-06-25, from the FIRST real
  red-zone Stage-C run) — a gathered verilogams leaf can itself be **structural** (it
  instantiates further cells). The real `pll_ndiv_delay_reload`'s verilogams instantiates
  `WL_PLL_Ndiv_inv_lvt_x8`/`nor2_lvt_x4`, which the oa2verilog *schematic* descent never
  sees (they live in the `.vams` text, not a schematic) → xrun `*E,CUVMUR` unresolved.
  FIX: after gathering leaves, `extract()` parses each gathered `.vams`, and for every
  sub-master not already defined/gathered/`-v`/pin/device/passive it gathers that cell's
  own veriloga/verilogams (recursively, to a fixpoint); anything still undefined is left
  for Stage C to `-v`-resolve or stub. New manifest field `gathered_subcells`. Verified on
  `examples/struct_va` (delaycell → subgain+subadd gathered → xrun TB PASS, FUNCTIONAL).
  Note: oa2verilog emits ports as the direction decl only (no separate `wire`) — the
  fixture mirrors that (a double `input a; wire a;` would trip wrealize into `*E,DUPIDN`).

- **Real-design bring-up of `LPBT_NDIV_TOP` — the whole error-class sweep (DONE 2026-06-25,
  HEAD 8728c8e).** Iterating on the real design surfaced (and fixed, each reproduced in a
  LOCAL fixture first) a chain of real-world failure classes:
  1. `*E,CUVMUR` (unresolved `WL_PLL_Ndiv_*`) — caused by (a) the **AMS netlister's
     `(* integer library_binding="LIB"; *)` attribute** between master & instance names
     defeating the parser → fixed by stripping `(\*..\*)` in `vp.strip_comments`; (b) a
     **stale verilogams** for `pll_ndiv_delay_reload` bound to another chip's lib — fixed by
     **honoring the config viewlist** (descend the schematic for a cell whose verilogams is
     structural; gather verilogams only for *behavioral* leaves — `verilogams_is_behavioral`).
  2. `*E,CUVPOM` (port mismatch, `.en`/`.VPP`/`.D`) — `reconcile_ports()` drops instance
     connections to ports the known child lacks (overlap-guarded; zero-overlap ⇒ wrong-view
     warn).
  3. `*E,CUNDCM` (wreal↔logic, 512×) — **the design is logic** (32 logic leaves + 1 cell,
     `pll_ndiv_div2_tspc`, that only declares its **supply** pins wreal). Fixes: discipline
     **auto-detect** (logic vs wreal by *functional* leaf discipline — supply-only-wreal = a
     logic leaf), **don't wrealize a logic design**, **drop wreal SUPPLY pins** in a logic
     design (`drop_wreal_supply`, `SUPPLY_RE`), and **stubs default to the design discipline**
     (`gen_stub default_logic`). All proven on `examples/logic_supply` (faithful clone:
     logic cells + wreal-supply divider + stubbed counter on shared VDD/VPP/VSS → 0
     boundaries, xrun TB PASS).
  **`vh_diag` is now the ground-truth instrument** — sections: SUMMARY (incl. discipline +
  wreal/logic leaf counts), DISCIPLINE BOUNDARIES (per-net wreal/logic mix = static CUNDCM
  predictor, with which masters are on each side) + **INTERFACES of boundary cells** (ports
  + discipline, bodies omitted = a sanitized clone-able spec), PARSE GAPS, UNRESOLVED (with
  `library_binding`), PORT MISMATCHES, xrun.log digest. **Process lesson (locked):** observe
  via vh_diag → clone the failure in a LOCAL fixture against local xrun → fix+verify there;
  red zone = final check only. CUNDCM is about disciplines+wiring, NOT bodies, so interfaces
  suffice to clone.

- **Config-binding priority + leaf-decision blind spots (DONE 2026-06-25, from a user design
  review of how Stage A decides leaf-vs-descend).** Three fixes, each cloned + verified on a
  new local fixture (no red zone), regression 9 examples + 3 duts green:
  1. **config binding WINS over the heuristic.** Old `forced_va` honored only `binding
     :veriloga`; the behavioral heuristic could override an explicit config binding. NEW
     `config_bindings(cfg)` → forced_leaf (bound to veriloga/verilogams/ahdl → gather even a
     STRUCTURAL verilogams) + forced_descend (bound to a schematic view → never gather its
     verilogams). Honors the user's rule "config 定 verilogams = 终点." Fixture
     `examples/cfg_binding`.
  2. **a real leaf may reference an EXTERNAL .v.** `verilogams_is_behavioral` now takes
     `ext_index` and excludes `-v`-resolvable / same-file refs from the structural test, so a
     leaf that instantiates a std cell isn't wrongly descended into its cmos_sch. Fixture
     `examples/leaf_ext_ref`.
  3. **NESTED config_ams.** Verified live (hdbOpen/hdbSaveAs round-trip): a `:config` binding
     is a NAMED REFERENCE, child bindings live in the child's own expand.cfg (NOT flattened).
     `resolve_nested_configs()` recurses into `<cell>/config/expand.cfg` + folds bindings in
     by name (+ warns); missing child → warn + heuristic. Fixture `examples/nested_cfg`. Also
     confirmed the real AMS viewlist ranks `cmos_sch` above `schematic` (the #28 root).
  Manifest gained `config.{nested_configs,forced_leaf,forced_descend}`. Reusable regression
  sweep: scratchpad `regress.sh`.

**NEXT (the immediate thing):** user must **redeploy 8728c8e to the red zone, re-run
Extract A → Generate C → Run xrun → Diagnose.** EXPECTED: `0` CUNDCM → the design
**elaborates + runs for the first time** (RUN-KIND **SMOKE**, since `CLK_PLL_NDIV_counter_
div2_lvt` is stubbed). Look for `=== TB PASS/FAIL ===` and DISCIPLINE-BOUNDARY = 0.
Remaining, in priority order:
  - **#28 `pll_ndiv_mmd_core` wrong-view** (warnings `*W,CUVWSP/CUVWSI`, NOT a hard error):
    its descended `cmos_sch` interface `{N_div,clk,out_dsm,rstn,...}` ≠ how the parent
    instantiates it `{E_pfd,reload,q1,q2,divisor_b,...}` → its real signal ports float →
    functionally hollow. Fix = descend the view whose interface MATCHES the parent
    instantiation (need `ls .../pll_ndiv_mmd_core/` view list). Until then the run is
    "elaborates but mmd_core does nothing".
  - **FUNCTIONAL run** (vs SMOKE): resolve `CLK_PLL_NDIV_counter_div2_lvt` (it's stubbed;
    its `library_binding` / a `-v` or verilogams is needed).
  - **Real testbench** (DONE 2026-06-26 — `examples/lpbt_ndiv/`): period-ratio TB
    `tb_LPBT_NDIV_TOP.vams` drives `fromVCO`+`ndiv`+`pwsel`+enables per MODE. **Mode table
    CONFIRMED FROM THE REAL STAGE-A NETLIST** (clock tree traced from `LPBT_NDIV_TOP_struct.vams`,
    notes in gitignored `_ref/NETLIST_NOTES.md`): front-end `fromVCO→div2→div2→DIV4sig=VCO/4`
    (the /4 prescaler); CAL `cal_en=1`→`CLK2CNT=VCO/4` + OUT_NDIV/CLK2DSM frozen (NDIVCKIN
    stops) + TESTCLK low; TEST `en_test=1`→`TESTCLK_300M=VCO/16` (DIV4sig→div4_tspc); NORMAL/TEST
    →`OUT_NDIV=CLK2DSM=VCO/4/M`, `M=ndiv[7:0]−1` (only this is user spec, not netlist). `CLK2CNT
    =nand(DIV4sig,cal_en)` so it's VCO/4 ONLY in cal, static-high else (corrected the user's
    "CLK2DSM/CLK2CNT same-freq" recollection — they're active in different modes). `pwsel`=duty
    (pwsel[0] NC), `lpbt_en` NC. **TB port match to the real struct = exact** (18 ports incl.
    supplies, named conns → no CUVPOM). CAL `VCO/4` + TEST `VCO/16` are FRONT-END TAPS that do
    NOT pass through mmd_core → **real HARD checks that pass TODAY**; OUT_NDIV/CLK2DSM go through
    mmd_8bit→mmd_core (hollow #28) → gated behind `+define+CHECK_NDIV` (smoke→WARN). Verified
    locally (xrun 18.03) vs a behavioral good-model `LPBT_NDIV_TOP_model.vams` (LOCAL-ONLY,
    never shipped): good→PASS, `+CHECK_NDIV`→full PASS, `BREAK_TESTCLK`/`BREAK_NDIV`→FAIL (teeth),
    `+define+HOLLOW`(dead mmd_core)→PASS via CAL+TEST. Red zone: `vh_gen --tb
    examples/lpbt_ndiv/tb_LPBT_NDIV_TOP.vams --tb-top tb_LPBT_NDIV_TOP` (NO model file).
  - **Generality gap**: a genuine **functional** wreal↔logic boundary (not supply) is
    diagnosed by vh_diag but NOT auto-fixed (would need generated connect modules — not
    built). All decisions/details in the project memory
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
