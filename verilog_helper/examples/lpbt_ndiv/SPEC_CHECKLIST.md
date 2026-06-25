# LPBT_NDIV_TOP — testbench spec & office-confirmation checklist

Captured 2026-06-25 from the user. **Take this to the circuit tomorrow** and fill the
`?` / TODO rows; each maps to a `localparam` or a gated check in `tb_LPBT_NDIV_TOP.vams`,
so confirming a value is a one-line edit, not a rewrite.

## Pinout (all logic; supplies don't-care in pure-digital flow)
- clock in: `fromVCO` (≈ **4.8–5 GHz**)
- bus in: `ndiv[13:0]` (only `[7:0]` used; `[13:8]` NC), `pwsel[5:0]`
- ctrl in: `ndiv_en`, `cal_en`, `en_test`, `lpbt_en` (**lpbt_en NC** — floating)
- out: `OUT_NDIV`, `CLK2DSM`, `CLK2CNT`, `TESTCLK_300M`
- supply (dropped): VDD/VPP/VSS/VDD_VCO/VPP_VCO/VSS_VCO/psub

## Divide / mode truth table   (✓ confirmed · ~ tentative · ? to-confirm)

| signal | **CAL** `cal_en=1` | **TEST** `ndiv_en=1,cal_en=0,en_test=1` | **NORMAL** `ndiv_en=1,cal_en=0,en_test=0` |
|---|---|---|---|
| `OUT_NDIV`     | **disabled** ✓ | VCO/4/(ndiv−1) ? | **VCO / 4 / (ndiv[7:0]−1)** ~ |
| `CLK2CNT`      | **VCO/4** ✓ | ? | VCO/4/(ndiv−1), = freq(CLK2DSM) ~ |
| `CLK2DSM`      | ? | ? | VCO/4/(ndiv−1); **offset vs CLK2CNT = few clk (?)** |
| `TESTCLK_300M` | ? | **VCO/16** ✓ | off ? |

- `N` (MMD divisor) `= ndiv[7:0] − 1`; total divide `D = 4·(ndiv−1)` (the /4 is the
  high-speed prescaler — same one that yields CLK2CNT=VCO/4 in cal and the VCO/16 test tap).
- `pwsel[5:0]` = **duty-cycle** control, not N. `pwsel[0]` NC; `pwsel[1]` = smallest step
  (2 clk). → don't-care for a period-ratio check (could add a duty check later).

## To confirm at the office tomorrow
1. **`N = ndiv[7:0] − 1` exactly?** (user "if I remember right"). → `NDIV_TEST`/`D_GOLD` in TB.
2. **`OUT_NDIV = VCO/4/(ndiv−1)` — is the /4 prescaler really in this path?** (vs OUT_NDIV = VCO/(ndiv−1)).
3. **CLK2DSM ↔ CLK2CNT exact edge offset** in NORMAL ("a few clk" — how many VCO or prescaler cycles?).
4. **CLK2DSM in CAL** — quiet, or VCO/4, or other?
5. **OUT_NDIV / CLK2CNT in TEST** — still divide, or held?
6. **TESTCLK_300M when en_test=0** — quiet?
7. **Are CLK2CNT(cal)=VCO/4 and TESTCLK=VCO/16 truly front-end taps** (independent of mmd_core)?
   This is the assumption that lets those two be *real* checks before #28 is fixed.

## Two-step verification plan
- **Step 1 — runs NOW (SMOKE + 2 real divides).** No `+define+CHECK_NDIV`.
  Hard checks: `CLK2CNT=VCO/4` (cal), `OUT_NDIV` disabled (cal), `TESTCLK_300M=VCO/16` (test).
  NORMAL `OUT_NDIV/CLK2DSM/CLK2CNT` = liveness **WARN only** (don't fail — they sit behind the
  hollow mmd_core #28 + stubbed counter).
- **Step 2 — after #28 + counter resolved.** Add `+define+CHECK_NDIV`: NORMAL becomes a hard
  `OUT_NDIV = CLK2DSM = VCO/4/(ndiv−1)` period-ratio assert + CLK2DSM/CLK2CNT freq-match.

## Wiring into the real flow (red zone)
```
vh_gen ... --tb examples/lpbt_ndiv/tb_LPBT_NDIV_TOP.vams --tb-top tb_LPBT_NDIV_TOP
# run.sh -top=tb_LPBT_NDIV_TOP ; add +define+CHECK_NDIV only after #28 is fixed
```
The TB instantiates `LPBT_NDIV_TOP` by the exact port names above, so it drops onto the real
Stage-A struct. `LPBT_NDIV_TOP_model.vams` is the LOCAL good-model only — do **not** ship it.
