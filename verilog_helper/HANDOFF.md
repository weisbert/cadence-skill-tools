# verilog_helper — HANDOFF / resume-here

**Read this first after a compaction.** This file = *current state + what's open*, nothing
else. Everything durable has moved out of this hot path:

- `DESIGN.md` — architecture, pipeline, stage decisions, env recipes, locked decisions (§1–§8).
- `JOURNAL.md` — session-by-session history + root-cause dossiers (LPBT/WuR bring-up), newest first.
- `README.md` — user-facing "how to run" (GUI + `vh_*.py` CLIs).
- `RED_ZONE.md` — red-zone deploy + report-run steps.
- `examples/<dut>/SPEC_CHECKLIST.md` — the authoritative per-DUT truth-table + divide/duty/pwsel laws.

Last updated: 2026-06-27 (session-close 27c). HEAD `bd8f2c5`, all pushed + deployed-ready.

---

## Current state — WuR NDIV done, LPBT_NDIV green

- **LPBT_NDIV_TOP**: validated end-to-end on the REAL netlist, local (xrun 18.03) AND red zone
  (19.04) → `=== TB PASS ===`. `testbenches/tb_LPBT_NDIV_TOP.vams` hard-checks the real op point
  (VCO 4.8 GHz, ndiv=51, pwsel=28 → OUT_NDIV/CLK2DSM 24 MHz, 50% duty). Report kit
  `vh_ndiv_report.py`. Duty/pwsel-law derivation → JOURNAL §00 / §27b + `examples/lpbt_ndiv/SPEC_CHECKLIST.md`.
- **WuR NDIV (`NDIV_TOP_v7_svt_0p5W`)**: reproduced locally from the red-zone dump + fully
  characterized. Self-checking TB `testbenches/tb_NDIV_TOP_v7_svt_0p5W.vams` (5 modes:
  WuR-NORMAL / LPBT / CAL / TEST / POWER-DOWN → local TB PASS, 0 fail). Report kit
  `vh_wur_report.py` (+ handoff tarball `wur_ndiv_report_kit.tar.gz`). Laws in
  `examples/wur_ndiv/SPEC_CHECKLIST.md`; full narrative → JOURNAL §27c. Commits this arc:
  `147fc55` `98cb311` `ea26427` `f415e44`.

## The one open thing — red-zone report run (user handing the kit to another Claude)

The authoritative `report.md` + waveforms come from running the WuR kit on the red zone (real
COT cells). **Confirm:** OUT_ADCDIV toggles at adcdiv=165 / adcpwsel=20 → VCO/656, 50%. It
should (the +62 offset is count-driven; stub delays swept 5..200 ps unchanged) — but real
`DELAD1/DELBD1` is the final word. If it stalls there, that's a real finding.

Spec questions for the design owner (not TB bugs): (a) the +62 ADCDIV offset → usable
`adcdiv ≥ ~64`; (b) `cal_en` not freezing NDIV in WuR mode, unlike LPBT.

## Process (locked)

Observe via `vh_diag` → CLONE the failure in a LOCAL fixture against local xrun (18.03) →
fix+verify there → red zone = final check only. Solo repo → commit+push to origin/main when done.

## Maintaining this file (so it stays one screen)

At session close, do NOT append a new block here. Instead:
1. **Overwrite** the "Current state" block above in place.
2. Move the outgoing status to the **TOP** of `JOURNAL.md`.
3. Fold any durable new fact into `DESIGN.md` (edit in place) or the per-DUT `SPEC_CHECKLIST.md`.

Only `JOURNAL.md` is allowed to grow. If this file passes ~1 screen, something above should have sunk.
