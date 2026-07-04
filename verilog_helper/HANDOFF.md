# verilog_helper — HANDOFF / resume-here

**Read this first after a compaction.** This file = *current state + what's open*, nothing
else. Everything durable has moved out of this hot path:

- `DESIGN.md` — architecture, pipeline, stage decisions, env recipes, locked decisions (§1–§8).
- `JOURNAL.md` — session-by-session history + root-cause dossiers (LPBT/WuR bring-up), newest first.
- `README.md` — user-facing "how to run" (GUI + `vh_*.py` CLIs).
- `RED_ZONE.md` — red-zone deploy + report-run steps.
- `examples/<dut>/SPEC_CHECKLIST.md` — the authoritative per-DUT truth-table + divide/duty/pwsel laws.

Last updated: 2026-07-04. HEAD `5d3b1f7`, all pushed.

---

## Current state — WuR NDIV done; LPBT_NDIV green + divide law swept-confirmed

- **LPBT_NDIV_TOP**: green end-to-end (local xrun 18.03 + red zone 19.04). `testbenches/
  tb_LPBT_NDIV_TOP.vams` carries the CAL/TEST/NORM mode checks PLUS an **NDIV divisor-sweep
  self-check**: NORM, `ndiv 14..127 step 1` (114 pts), `pwsel=min((ndiv+5)/2,62)`, asserts
  `divisor==ndiv-1` (front /4 removed); report is an ASCII witness table (ndiv 14/51/100/127 →
  expect vs meas + duty) + aggregate RESULT (114/114, max|err|, span 13..126). Green on good-model
  AND real struct. **Divide law `M=ndiv-1` + pwl law `low=2·floor(pwsel/2)-3` are now sweep-confirmed
  14..127 on the real build_afterfix struct** (were user-spec) → `examples/lpbt_ndiv/SPEC_CHECKLIST.md`.
- **LPBT charac now TRACKED**: `examples/lpbt_ndiv/charac/` — `tb_ndivsweep.vams`, `tb_wave.vams`,
  `run.sh` (STRUCT_DIR-parameterized; default `../_ref/build_afterfix`, red zone → export dir),
  `sv_wave.tcl`+`grab_sv.sh` (headless SimVision→PNG via Xvfb+PIL), README, .gitignore. Proprietary
  netlist stays gitignored in `_ref/`. Only the divisor is asserted in-TB (good-model ignores pwsel);
  the pwl/duty law is confirmed on the real struct via the charac kit. Report kit `vh_ndiv_report.py`.
- **WuR NDIV (`NDIV_TOP_v7_svt_0p5W`)**: unchanged from 27c — locally reproduced + characterized,
  self-checking TB (5 modes), report kit `vh_wur_report.py`. Laws → `examples/wur_ndiv/SPEC_CHECKLIST.md`;
  narrative → JOURNAL §27c.

## Open

- **WuR red-zone report run** (carried from 27c; user handed the kit to another Claude): run the WuR
  kit on the red zone (real COT cells) → authoritative `report.md` + waveforms. **Confirm** OUT_ADCDIV
  @ adcdiv=165 / adcpwsel=20 → VCO/656, 50% (the +62 offset is count-driven; stub delays swept
  5..200 ps unchanged — but real `DELAD1/DELBD1` is the final word; if it stalls, real finding).
  Spec Qs for owner: (a) +62 ADCDIV offset → usable `adcdiv ≥ ~64`; (b) `cal_en` not freezing NDIV
  in WuR mode (LPBT CAL = lpbt_en=1&cal_en=1 → main+ADC frozen, only CLK2CNT=VCO/4).
- **LPBT**: nothing blocking. If the red-zone TB should also HARD-assert the pwl/duty law (not just
  divisor), it needs a pwsel-aware good-model or a real-struct-only guarded check.

## Process (locked)

Observe via `vh_diag` → CLONE the failure in a LOCAL fixture against local xrun (18.03) →
fix+verify there → red zone = final check only. Solo repo → commit+push to origin/main when done.

## Maintaining this file (so it stays one screen)

At session close, do NOT append a new block here. Instead:
1. **Overwrite** the "Current state" block above in place.
2. Move the outgoing status to the **TOP** of `JOURNAL.md`.
3. Fold any durable new fact into `DESIGN.md` (edit in place) or the per-DUT `SPEC_CHECKLIST.md`.

Only `JOURNAL.md` is allowed to grow. If this file passes ~1 screen, something above should have sunk.
