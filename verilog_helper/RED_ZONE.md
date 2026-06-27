# Red-zone operation guide (verilog_helper)

The **authoritative** verification runs in the **red zone** (air-gapped Linux7,
`xrun 19.04`). The dev box (`eda`, `xrun 18.03`) is only a **smoke proxy**:
on dev, external HDL is *stubbed* (ideal buffers) and the OA design is a shell,
so a dev `=== TB PASS ===` proves the tool + wiring + digital logic — **not** your
real design against the real models. This guide is the dev → red handoff.

> **SMOKE vs FUNCTIONAL.** Every run prints a `RUN-KIND:` line.
> - `RUN-KIND: SMOKE` — one or more externals were **stubbed** (ideal buffers,
>   not the real models). Wiring/logic checked; **not** a real verification.
> - `RUN-KIND: FUNCTIONAL` — every external resolved via `-v` (real models
>   compiled). This is the real thing.
> A red-zone run is only authoritative when it says **FUNCTIONAL** *and*
> `=== TB PASS ===`. If red still says SMOKE, you forgot to point `ext_libs.list`
> at the real `-v` libraries (Step 4).

---

## Step 0 — what crosses the air gap

Only the **per-DUT package** (`<top>_pkg.tar.gz` + `.sha256`). It is *user data*,
NOT part of the tool repo — it travels via your normal air-gap path
(dev → GitHub/yellow Windows → red work dir), same as any other payload. The tool
itself (the `vh_*.py` / `vhGui.il`) is deployed separately via `skill_tools/deploy`.

## Step 1 — build + package (on dev)

GUI: **MyTool → Verilog Helper**, set Output folder, then
`[Extract A] → [Convert B] → [Generate C] → [Package D]`.
(Optionally `[Run xrun]` first for a dev smoke — expect `[SMOKE: externals stubbed]`.)

CLI equivalent:
```bash
python3 vh_extract.py --config <expand.cfg> --cdslib <cds.lib> --out <out>
python3 vh_convert.py --manifest <out>/manifest_A.json        # if any analog leaf
python3 vh_gen.py     --src <out>/export --out <out>/sim --checks <checks.json>
python3 vh_package.py --build <out>/sim                        # -> <out>/package/<top>_pkg.tar.gz
```
Result: `<top>_pkg.tar.gz` + `<top>_pkg.tar.gz.sha256`.

## Step 2 — transfer to the red zone

Move both files to a red work dir, e.g.
`/data/RFIC3/Hi1108V100_Pilot_C1Xplus/w84368867/workarea/<somewhere>/`.

## Step 3 — verify + unpack (on red)

```bash
sha256sum -c <top>_pkg.tar.gz.sha256     # must say: OK
tar xzf <top>_pkg.tar.gz
cd <top>_pkg
```

## Step 4 — point at the REAL external libraries  ← the key red-zone step

Edit `ext_libs.list` to the red-zone `-v` paths (this is the "AMS Options →
Include Option Settings → Library Files (-v)" list — the tool owns it instead of
an AMS TB). One entry per line:
```
/.../workarea/ams_models/L16_SVT_ana.v       # plain path  => -v <path>
-y /.../some_lib_dir                          # a -y search dir
+incdir+/.../includes                         # an include dir
```
(The seeded contents are the *dev* paths — they will differ on red.)
Equivalent one-off: `export VH_EXT_LIBS="/path/a.v /path/b.v"`.

> If an external is **electrical/analog** (needs Spectre to solve), do NOT try to
> run it pure-digital — Stage B flags it "needs spectre". Pure-digital handles
> wreal externals; analog ones stay out of the functional check.

## Step 5 — run

```bash
bash verify.sh
```
`verify.sh` first runs a **pure-digital preflight** (proves xrun works here, no
spectre license) then `run.sh` (your design TB).

## Step 6 — read the result

```
================ PREFLIGHT ================
[preflight] OK -- pure-digital xrun works, no spectre license needed.
================ DESIGN RUN ===============
================= RESULT =================
=== TB PASS  (top=<top>) ===
xrun exit code: 0
RUN-KIND: FUNCTIONAL -- all externals resolved (no stubs)     <-- want this
xrun-bin: /software/cadence/xcelium/19.04.001/tools/bin/xrun
```
**Authoritative pass = `=== TB PASS ===` AND `RUN-KIND: FUNCTIONAL`.**
`RUN-KIND: SMOKE` on red ⇒ go back to Step 4 (an external is still stubbed).

---

## Red-zone facts (verified preflight 2026-06-25)

- `xrun = 19.04-a001`, **ambient** even in non-interactive `bash -c`
  (`/software/cadence/xcelium/19.04.001/tools/bin/xrun`) → **no env setup needed**;
  `setup_env.sh`'s ambient branch covers it. (Override with `VH_SITE_ENV` only if
  it ever isn't on PATH.)
- Pure-digital wreal `-ams` smoke passes with **zero** spectre license errors and
  no `*F,INTERR` (cleaner than dev). No spectre license is consumed.
- PDK auto-includes `…/affirma_ams/etc/connect_lib/cds.lib`.
- Work area: `/data/RFIC3/Hi1108V100_Pilot_C1Xplus/w84368867/workarea`,
  lib `sim_1108_yusheg`.

## Verification report + waveform screenshots (`vh_ndiv_report.py`)

For a presentation-ready summary (what was checked, PASS/FAIL, and genuine SimVision
waveform screenshots) run, from the generated sim dir (the one with `run.sh`):

```
python3 <skill_tools>/verilog_helper/vh_ndiv_report.py --sim .
```

It (1) runs `bash run.sh +define+WAVES` (xrun + `ndiv.shm`), (2) prints + writes a
per-mode check table to `report/report.md`, and (3) captures real **SimVision**
screenshots **headless** (own Xvfb display — no GUI session needed): `wave_overview`
(CAL/TEST/NORM mode bands), `wave_cal` (CLK2CNT=VCO/4), `wave_test` (TESTCLK=VCO/16),
`wave_norm` (OUT_NDIV + CLK2DSM, 50% duty + phase). Pure stdlib + the Cadence tools
already on the box.

Screenshot deps degrade gracefully: needs `simvision` (always present) plus EITHER
`Xvfb` (headless) OR a live `$DISPLAY` (interactive session), plus python `PIL`
(else ImageMagick `import`). If none are available it still writes `report.md` +
`report/layout_*.tcl`, and you capture by hand:
`simvision ndiv.shm -input report/layout_norm.tcl` then screenshot.

## Collect the external libs into the build (`vh_collect_ext.py`)

To get a **self-contained snapshot** — one folder with every Verilog the design needs,
local cells *and* the external `-v` PDK models actually used — run this on the red zone
(the external files live only here) after `ext_libs.list` points at the real paths:

```
python3 <skill_tools>/verilog_helper/vh_collect_ext.py --sim .            # copy into ../export
python3 <skill_tools>/verilog_helper/vh_collect_ext.py --sim . --rewrite  # + repoint the run at the copies
```

It resolves the external list with the **same precedence run.sh uses** (`$VH_EXT_LIBS`
→ `ext_libs.list` → the baked `EXT=(…)` in run.sh), copies each `-v` file (and `-y` /
`+incdir+` dir) into `--dest` (default: the sibling `export/`, else `<sim>/ext_collected`),
and skips any path that doesn't exist (reports it — invents nothing). With `--rewrite`
it (re)writes `<sim>/ext_libs.list` to the local copies (relative, so `bash run.sh` uses
them next run) and backs the original up as `ext_libs.list.bak`.

> Fix `ext_libs.list` to the real red-zone paths **first** (Step 4) — a MISSING entry is
> skipped, so a self-contained copy is only complete once every external resolves.

## Troubleshooting

| symptom | fix |
|---|---|
| `*** PREFLIGHT FAILED` | xrun env broken on this machine — see `vh_preflight.log`; set `VH_SITE_ENV`. |
| `RUN-KIND: SMOKE` (unexpected) | an external isn't in `ext_libs.list` — add its real `-v` path (Step 4). |
| `Spectre_AMS*_Lk ... checkout failed` | **benign** for pure-digital wreal — there are no electrical nodes to solve; ignore. |
| `*E,FMUK: type of file could not be determined` | a `.va` reached xrun without `-amsvlog_ext .vams,.va` — already baked into run.sh; check you ran `run.sh`, not a hand xrun. |
| `*E,WRERNG Range ... not allowed on wreal` | a packed `wreal [n:0]` slipped in — buses must be unpacked arrays (Stage B does this). |
