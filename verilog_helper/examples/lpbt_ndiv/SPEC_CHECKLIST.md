# LPBT_NDIV_TOP — testbench spec & confirmation status

Mode table **confirmed from the Stage-A netlist** (clock tree traced 2026-06-26 — see
`_ref/NETLIST_NOTES.md`), except `M=ndiv−1` which is user spec.

## Pinout (all logic; supplies are top ports, don't-care in pure-digital flow)
- clock in: `fromVCO` (≈ **4.8–5 GHz**)
- bus in: `ndiv[13:0]` (only `[7:0]` used → `mmd_8bit.d_n`; `[13:8]` NC), `pwsel[5:0]` (→ `d_ndiv_pw_sel`)
- ctrl in: `ndiv_en`, `cal_en`, `en_test`, `lpbt_en` (**lpbt_en NC**)
- out: `OUT_NDIV`, `CLK2DSM`, `CLK2CNT`, `TESTCLK_300M`
- supply: VDD/VPP/VSS/VDD_VCO/VPP_VCO/VSS_VCO/psub (TB ties them; dropped from logic)

## Divide / mode truth table   (✓ netlist-confirmed · S = user spec)

| signal | **CAL** `cal_en=1` | **TEST** `ndiv_en=1,cal_en=0,en_test=1` | **NORMAL** `ndiv_en=1,cal_en=0,en_test=0` |
|---|---|---|---|
| `OUT_NDIV`     | **disabled** ✓ | `VCO/4/M` ✓ (M=ndiv−1, S) | `VCO/4/M` ✓ (M=ndiv−1, S) |
| `CLK2DSM`      | quiet ✓ | `VCO/4/M` ✓ | `VCO/4/M` ✓ |
| `CLK2CNT`      | **VCO/4** ✓ | static-high ✓ | static-high ✓ |
| `TESTCLK_300M` | low ✓ | **VCO/16** ✓ | low ✓ |

- Front-end: `fromVCO →div2→div2→ DIV4sig = VCO/4` (the /4 prescaler). `OUT_NDIV = NDIVCKIN/M`
  where `NDIVCKIN = DIV4sig` (cal_en=0) → **`OUT_NDIV = VCO/4/M`**.
- `CLK2CNT = nand(DIV4sig,cal_en)` → VCO/4 only in cal. `TESTCLK = DIV4sig→div4_tspc = VCO/16`
  (en_test=1), else pdown-low. `cal_en=1` freezes `NDIVCKIN` → OUT_NDIV/CLK2DSM stop.
- `pwsel` = duty-cycle (pwsel[0] NC, pwsel[1]=2clk step) → don't-care for period ratio.
- **CAL `CLK2CNT=VCO/4` + TEST `TESTCLK=VCO/16` do NOT pass through mmd_core** → real HARD
  checks that pass TODAY (before #28). OUT_NDIV/CLK2DSM go through mmd_8bit→mmd_core (hollow #28).

## Confirmed by sweep (2026-07-04 — real build_afterfix struct, xrun 18.03, NORM mode)
- **`M = ndiv[7:0] − 1`** — CONFIRMED (was the only non-netlist value). Swept `ndiv_var 14..127`
  (114 pts, 0 fail): divisor in NDIVCKIN(=VCO/4) cycles = `ndiv_var − 1`; full-chip = `4·(ndiv−1)`.
- **low pulse-width** — CONFIRMED: `low = 2·floor(pwsel/2) − 3` (NDIVCKIN cyc, pwsel[0] unused),
  `high = M − low`, `50% ⟺ pwsel=(ndiv+5)/2 ∧ ndiv ≡ 3 (mod 4)`.
- **pwsel is 6-bit** — raw `(ndiv+5)/2 > 63` (ndiv ≥ 123) wraps → low<0 → OUT_NDIV stalls; the sweep
  uses `pwsel = min((ndiv+5)/2, 62)` (ndiv 119..127 → pwsel=62, low=59). Charac kit + repro:
  `examples/lpbt_ndiv/charac/` (tb_ndivsweep, tb_wave, run.sh, SimVision screenshot recipe).

## Still to confirm (vh_gen extraction / red-zone pipeline only — build_afterfix already resolves these)
1. **#28 — `pll_ndiv_mmd_core` view:** vh_gen must descend the view whose interface =
   `{E_pfd,E_pfd_b,Nor,clk_to_PFD,clkb,divisor_b[2:0],lock,q1,q1b,q2,q2b,reload1/1b/2/2b/3/3b,
   reload_pe,reload_TFF2_3_4,reload_TFF5_6_7}` — NOT the `{N_div,N_div_sel,SUB,...}` one. The
   build_afterfix struct swept above already has the correct functional mmd_core.
2. **`CLK_PLL_NDIV_counter_div2_lvt`** (stubbed) — a -v / verilogams for FUNCTIONAL `out_pd`.

## Two-step verification
- **Step 1 — runs NOW (real checks).** No `+define+CHECK_NDIV`. HARD pass on CAL `CLK2CNT=VCO/4`
  + OUT_NDIV/CLK2DSM/TESTCLK quiet, TEST `TESTCLK=VCO/16` + CLK2CNT static, NORM quiet checks.
  OUT_NDIV/CLK2DSM divider = liveness **WARN** (hollow mmd_core).
- **Step 2 — after #28 + counter.** Add `+define+CHECK_NDIV`: OUT_NDIV/CLK2DSM become hard
  `VCO/4/(ndiv−1)` period-ratio asserts in TEST + NORMAL.

## Red-zone wiring
```
vh_gen ... --tb examples/lpbt_ndiv/tb_LPBT_NDIV_TOP.vams --tb-top tb_LPBT_NDIV_TOP   # NO model file
# run.sh -top=tb_LPBT_NDIV_TOP ; add +define+CHECK_NDIV only after #28 fixed
```
