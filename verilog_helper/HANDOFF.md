# verilog_helper — HANDOFF / resume-here

**Read this first after a compaction.** This file = *current state + what's open*, nothing
else. Everything durable has moved out of this hot path:

- `DESIGN.md` — architecture, pipeline, stage decisions, env recipes, locked decisions (§1–§8).
- `JOURNAL.md` — session-by-session history + root-cause dossiers (LPBT/WuR bring-up), newest first.
- `README.md` — user-facing "how to run" (GUI + `vh_*.py` CLIs).
- `RED_ZONE.md` — red-zone deploy + report-run steps.
- `examples/<dut>/SPEC_CHECKLIST.md` — the authoritative per-DUT truth-table + divide/duty/pwsel laws.

Last updated: 2026-09-19.

---

## Current state — WuR 32.768 kHz + MASH-111 SDM verified (open loop); delay injection tool shipped

- **WuR NDIV 32.768 kHz path** (`NDIV_TOP_v7_svt_0p5W`, `lpbt_en=0`, NDIVCKIN=VCO/16): `M=ndiv−1`
  confirmed over the FULL 14-bit range (bit-12/13 witnesses 8191..16383 + real points 9155/9537/
  11063 @ 4.8/5.0/5.8 GHz). Integer-ndiv error vs 32768 Hz = +139/+78/+56 ppm → SDM mandatory.
  50 % duty unreachable at M≈9k (pwsel 6-bit → duty 99.3–99.6 %, PFD must be rising-edge).
- **MASH 1-1-1 on CLK2DSM**: per-cycle law exact with a dynamic word (8190/8190 @N=300, 254/254 at
  each real band, 510/510 LPBT ndiv=51); mean ratio → <1.1 ppm; PSD +59.2 dB/dec (order 2.96).
  **Alignment = z⁻¹**: word issued at CLK2DSM edge k governs the period [edge k+1 → k+2].
  **Setup**: word stable ≥1 NDIVCKIN before the OUT_NDIV rising edge (3.33/3.20/2.76 ns); max
  latency after CLK2DSM ≈ M−3.07 Tclk ≈ 30.5 µs. Inside the window → word applied one period late
  on a data-dependent subset (looks like PLL noise, no hang). All re-confirmed on the 1× delay
  models. Kit: `examples/wur_ndiv/charac/` (+ `sdm_psd.py`), results `examples/wur_ndiv/SDM_32K_RESULTS.md`.
- **Delay injection** `vh_delay.py` + `delays/wur_ndiv_delays.json` (20 classes/42 modules/47
  sites; DFF/TFF 50 ps, TSPC÷2 30 ps, gates 12–32 ps; powerOK/initial branches never delayed;
  `+define+VH_TPD_SCALE=` / `+define+VH_TPD_<CLASS>_PS=` runtime override; 30 unit tests;
  `vh_package.py --delays T`). Committed TB PASS at 4.8/5.0/5.8 GHz with 1×. Margin @5.8 GHz:
  LPBT reload law breaks at 5×, WuR front-end ÷2 at 6× (TSPC clk→Q > T_VCO), **`lpbt_en` 1→0
  mode-switch hangs the counter at 4×** (prescaler mux not glitch-free — design question).
  Results `examples/wur_ndiv/DELAYS.md`; red-zone recipe in `RED_ZONE.md` "Applying delays".
- **LPBT_NDIV_TOP**: unchanged, green (divide + pwl laws sweep-confirmed 14..127; charac kit tracked).

## Open

- **Red zone**: (1) run the WuR report kit + the new charac kit on real COT cells (`RUN-KIND:
  FUNCTIONAL`); (2) inject delays there via `vh_delay.py apply` on `export/` (RED_ZONE.md path A)
  — the JSON values are placeholders until replaced by characterized .lib/spectre numbers.
- **Design questions for the owner**: (a) `lpbt_en` prescaler-mux switch mid-count hangs at 4×
  delay — is the mux glitch-free in silicon? (b) +62 ADCDIV offset / `cal_en` not freezing NDIV
  (carried). (c) SDM must tolerate z⁻¹ word latency + 99 % duty OUT_NDIV.
- **Not covered**: closed-loop PLL (needs wreal PFD/CP/LPF/VCO wrapper — next capability);
  in-band (<1 kHz) shaping at ndiv≈9k (≥1e5 cycles); pwsel change during modulation; dither is
  unshaped (acc1); per-arc rise/fall, slew, $setup/$hold, SDF.

## Process (locked)

Observe via `vh_diag` → CLONE the failure in a LOCAL fixture against local xrun (18.03) →
fix+verify there → red zone = final check only. Solo repo → commit+push to origin/main when done.

## Maintaining this file (so it stays one screen)

At session close, do NOT append a new block here. Instead:
1. **Overwrite** the "Current state" block above in place.
2. Move the outgoing status to the **TOP** of `JOURNAL.md`.
3. Fold any durable new fact into `DESIGN.md` (edit in place) or the per-DUT `SPEC_CHECKLIST.md`.

Only `JOURNAL.md` is allowed to grow. If this file passes ~1 screen, something above should have sunk.
