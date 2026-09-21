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

## WuR NDIV on red -- the concrete paths (confirmed 2026-09-21)

- Stage-A build: `…/workarea/verilogBox/WUR_NDIV/` **is itself** the `--struct` dir
  (`export/` = the 37 no-delay `.vams`, plus `external_file/`, `orig/`, `sim/`,
  `manifest_A/B.*`). There is no extra build subdirectory.
- `ext_libs.list` did not exist; the whole `-v` list is **one file** that Stage A had
  already snapshotted on red: `external_file/L20_SVT_ana.v`. So
  `ls $B/external_file/*.v > $B/ext_libs.list` is the whole Step 4 for this DUT.
- Login shell is **tcsh**; `bash` first, then paste. `xrun` was **not** ambient in that
  session (contrary to the 2026-06-25 note) -- export PATH or set `VH_SITE_ENV` before
  `repro.sh`.
- The shell there is **not** a UTF-8 locale: python3 stdout defaults to ASCII
  (`UnicodeEncodeError` on any CJK `print`) and non-ASCII filenames list as `??????`.
  Keep red-zone scripts and the filenames they create ASCII-only, and set
  `PYTHONIOENCODING=utf-8` if a tool must emit UTF-8.

## Applying delays on the red zone

The red-zone `verilogams` cellviews of the divider leaves carry **no timing** (`Q <= D;`) or
ad-hoc `#10`s. A zero-delay model hides every hold race and every ripple-accumulation effect, so
a red-zone `=== TB PASS ===` on zero-delay models is weaker than it looks. `vh_delay.py` +
a JSON delay table fixes that **without editing the design library**. Worked example and the
measured margins: `examples/wur_ndiv/DELAYS.md`.

**Recommended path = (A) then (B).** (C) exists, and is discouraged.

### (A) Ship the tool + table, inject into the red-zone `export/` copy  ← do this

`vh_delay.py` and `delays/*.json` are ordinary committed tool files, so they ride the **normal
skill_tools deploy** — nothing new crosses the air gap:

```tcsh
# yellow (Windows), after git pull:
powershell -ExecutionPolicy Bypass -File deploy\pack.ps1
# red, in .../workarea/skill_tools:
bash deploy/deploy.sh skill_tools_<shorthash>.tar.gz
```

Then, on red, inject into the **Extract-A output** (or into the unpacked `<top>_pkg/`), never
into the OA library:

```bash
cd <build>                        # the dir that has export/ (Stage A) or the unpacked <top>_pkg
python3 <skill_tools>/verilog_helper/vh_delay.py report \
        --src export --table <skill_tools>/verilog_helper/delays/wur_ndiv_delays.json
python3 <skill_tools>/verilog_helper/vh_delay.py apply \
        --table <skill_tools>/verilog_helper/delays/wur_ndiv_delays.json \
        --src export --out export_dly            # non-destructive: originals untouched
# point the run at the delayed copy, then:
bash verify.sh        # or bash run.sh
```

Properties that make this the right default:

- **Reversible.** `vh_delay.py revert --src export_dly --out export_back` restores the sources
  byte-for-byte (every injected module carries a `// VH_ORIG [...]` record of what it replaced).
  Or simply delete `export_dly/`.
- **Source cellviews untouched.** The OA `verilogams` views keep whatever the designer wrote;
  Stage A re-extracts them unchanged next time.
- **The table is the record.** One JSON holds class → ps + module → class + the rationale + the
  ad-hoc value each model had before. Review it, not a diff of 40 files.
- **Idempotent.** Re-running `apply` after editing the table updates the values; it never
  double-injects.
- **Only the functional branch is delayed** — `if (!powerOK) ...` power-fail clamps and
  `initial` blocks stay immediate, so the POWER-DOWN clean-0 checks still mean what they meant.

> **Do NOT inject into the real COT std cells.** The `-v` libraries (`INVD1/ND2D1/DELAD1/...`)
> already carry vendor timing. Inject only into `export/` (the design's own leaves). The local
> `ext_stub/` copies are injected on dev *because they are stubs*; on red they do not exist.

Packaging hook (optional, one flag): `vh_package.py` can inject while it builds the air-gap
bundle, so the tarball that crosses the gap already has timing:

```bash
python3 vh_package.py --build <stageC_out>/sim \
        --delays <skill_tools>/verilog_helper/delays/wur_ndiv_delays.json [--delay-scale 1.0]
```
It injects into the **packaged copies only** (the build inputs are not modified), copies the
table into the bundle as `delays.json`, and records every injected module in `manifest_D.json`.
(`vh_gen.py` was deliberately not hooked: it references sources by path instead of copying them,
so a delay step there would have to invent an output dir — `vh_package` is the natural seam.)

### (B) Retune on red with NO file edit at all  ← use with (A)

Every injected module reads two optional macros, so a corner sweep needs no re-injection, no
`vh_delay` re-run and no file write (handy on a read-only or slow red filesystem):

```bash
# scale every class at once (1.0 = exactly as injected)
xrun -64bit -ams -timescale 1s/1fs -amsvlog_ext .vams,.va \
     +define+VH_TPD_SCALE=2.0 \
     ${EXT[@]} export_dly/*.vams tb_<top>.vams -top tb -access +rwc -l xrun.log

# or one class only, in absolute ps (still multiplied by VH_TPD_SCALE)
xrun ... +define+VH_TPD_DFF_PS=75 +define+VH_TPD_TSPC_DIV2_PS=28
```
With the generated runner, everything after `run.sh` is passed straight to xrun:
```bash
bash run.sh +define+VH_TPD_SCALE=2.0
```
`vh_delay.py flags --table <table>` prints the exact macro names for a given table.

`+define+` was chosen over `-defparam` on purpose: these leaves are instantiated **hundreds of
times**, so a macro hits every instance while a `-defparam` would need one hierarchical path per
instance. It is core Verilog-2001 preprocessing — verified on dev xrun 18.03 and expected to
behave identically on red xrun 19.04. Verified equivalent to baking the same scale into the
files (`--scale 5` vs `+define+VH_TPD_SCALE=5.0` gave check-for-check identical results).

### (C) Patch the OA `verilogams` cellview text in place  — discouraged

```bash
python3 vh_delay.py apply --table <table> --in-place \
        --cdslib <cds.lib> --lib <LIBNAME>      # -> <libpath>/<cell>/verilogams/verilog.vams
python3 vh_delay.py revert --src <libpath>/<cell>/verilogams --in-place   # restores from .orig
```
`--in-place` always writes a `<file>.orig` backup first and `revert` puts it back.

**Why this is discouraged:** the design library is **shared**. Editing `verilog.vams` under
someone else's `<lib>/<cell>/verilogams/` changes the model for every user and every simulation
of that cell, is invisible in the schematic, survives your session, can be clobbered by (or
clobber) a designer's edit, and is not covered by the OA lock you may or may not hold. It also
puts timing that came from *your* estimate into what everyone else reads as *the* model.

**When it is OK:** a **copy library that is yours** (your own `sim_*` lib, or a checked-out
branch of the cells), where you actually want the delayed model to be the model — e.g. to hand
a timed version to an AMS testbench that binds `verilogams` directly and cannot be pointed at an
`export_dly/` folder. Even then: tell the owner, keep the `.orig` files, and re-`revert` when
you are done.

---

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

## Self-contained external snapshot (`external_file/`)

Stage A (**Extract A**) also writes an `external_file/` folder next to `export/` and copies
into it the external `-v`/`-y` model files the design actually instantiates (resolved via
the remembered ext env — `vh_env.py show`). So the build directory holds **every Verilog the
design needs**: `export/` (local cells) + `external_file/` (external deps). Only files that
define a *used* external are copied (one copy per file); externals with no `-v` match aren't
here — Stage C stubs them. The copy reflects the env where Extract A ran: point the ext env at
the real paths (`vh_env.py add-lib …`) **on the machine where they exist** so the snapshot is
complete (the manifest's `external_modules` shows which resolved vs will-be-stubbed).

## Troubleshooting

| symptom | fix |
|---|---|
| `*** PREFLIGHT FAILED` | xrun env broken on this machine — see `vh_preflight.log`; set `VH_SITE_ENV`. |
| `RUN-KIND: SMOKE` (unexpected) | an external isn't in `ext_libs.list` — add its real `-v` path (Step 4). |
| `Spectre_AMS*_Lk ... checkout failed` | **benign** for pure-digital wreal — there are no electrical nodes to solve; ignore. |
| `*E,FMUK: type of file could not be determined` | a `.va` reached xrun without `-amsvlog_ext .vams,.va` — already baked into run.sh; check you ran `run.sh`, not a hand xrun. |
| `*E,WRERNG Range ... not allowed on wreal` | a packed `wreal [n:0]` slipped in — buses must be unpacked arrays (Stage B does this). |
