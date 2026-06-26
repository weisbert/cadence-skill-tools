# examples/lpbt_ndiv — real testbench for LPBT_NDIV_TOP (the PLL N-divider)

A **period-ratio** testbench for the real DUT `LPBT_NDIV_TOP`, plus a behavioral
good-model used to verify the TB's own mechanics under local xrun (18.03) before it
goes to the red zone. See `SPEC_CHECKLIST.md` for the divide/mode truth table and the
list of facts still to confirm at the circuit.

## Files
- `tb_LPBT_NDIV_TOP.vams` — **the deliverable.** Drives `fromVCO`, sets the divide word
  + enables per mode, measures `period(out)/period(fromVCO)`, asserts the expected divide.
  Instantiates `LPBT_NDIV_TOP` by the real port names → drops onto the Stage-A struct.
- `LPBT_NDIV_TOP_model.vams` — **local good-model only, do NOT ship.** Encodes the confirmed
  spec so the TB can be exercised end-to-end here.
- `run.sh` — local xrun wrapper (see header for `+define` knobs).

## What's checked  (mode behaviors confirmed from the Stage-A netlist — see `_ref/`)
| mode | check | status |
|---|---|---|
| CAL `cal_en=1`   | `CLK2CNT=VCO/4`; OUT_NDIV/CLK2DSM/TESTCLK quiet | **hard, real** (front-end tap, no mmd_core) |
| TEST `en_test=1` | `TESTCLK_300M=VCO/16`; CLK2CNT static            | **hard, real** (front-end tap, no mmd_core) |
| TEST + NORMAL    | `OUT_NDIV = CLK2DSM = VCO/4/(ndiv−1)`           | hard only with `+define+CHECK_NDIV` (post-#28); else liveness WARN |

The front-end-tap checks (VCO/4, VCO/16) are why this beats a pure smoke TB: they give
**real divide verification today**, before mmd_core (#28) and the stubbed counter are resolved.
Quiet-checks assert the outputs that should be idle in each mode really are.

## Verified locally (xrun 18.03, this box)
- good model → `=== TB PASS ===`; with `+define+CHECK_NDIV` → all incl. N pass.
- `+define+BREAK_TESTCLK` → FAIL on TESTCLK (VCO/8 vs /16); `+define+BREAK_NDIV` → FAIL on
  OUT_NDIV/CLK2DSM in both TEST+NORMAL (VCO/56 vs /36, 4 fails) — the checks have teeth.
- `+define+HOLLOW` (mimics today's dead mmd_core) → `=== TB PASS ===` via CAL+TEST, NORMAL = WARN.

## Red zone
```
vh_gen ... --tb .../tb_LPBT_NDIV_TOP.vams --tb-top tb_LPBT_NDIV_TOP   # NO model file
# run.sh -top=tb_LPBT_NDIV_TOP ; add +define+CHECK_NDIV only after #28 fixed
```
