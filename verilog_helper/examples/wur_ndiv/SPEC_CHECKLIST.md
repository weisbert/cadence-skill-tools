# NDIV_TOP_v7_svt_0p5W (WuR NDIV) — testbench spec & confirmation status

Wake-up-receiver N-divider. Same FAMILY as `LPBT_NDIV_TOP` but with a **dual divider** (a 14-bit
NDIV counter + an 8-bit ADCDIV counter) and `lpbt_en` promoted to a **real control** (prescaler
select). All laws below are **ground-truthed on the Stage-A struct** (local xcelium 18.03,
2026-06-27) by sweeping the real netlist, not just traced. Counting unit `Tclk = NDIVCKIN`.

Committed TB: `testbenches/tb_NDIV_TOP_v7_svt_0p5W.vams` (module `tb`; drops into the auto-gen
`sim/run.sh`, which uses `-top tb`). Local repro/charac (gitignored): `examples/wur_ndiv/_ref/build/`.

## Pinout (all logic; supplies are top ports, TB ties them)
- clock in: `fromVCO` (≈ **4.8 GHz** → TESTCLK_300M = VCO/16 = 300 MHz confirms VCO=4.8G)
- bus in: `ndiv[13:0]` (→ 14-bit counter `d_n`), `pwsel[5:0]`; `adcdiv[7:0]`, `adcpwsel[5:0]` (→ 8-bit)
- ctrl in: `ndiv_en` (core power-enable), `lpbt_en` (**prescaler select**), `cal_en`, `en_test`
- out: `OUT_NDIV`, `CLK2DSM`, `CLK2CNT`, `OUT_ADCDIV`, `TESTCLK_300M`
- supply: VDD/VDD_VCO/VPP/VPP_VCO/VSS/VSS_VCO/psub

## Clock tree (✓ netlist-confirmed + sim-confirmed)
```
fromVCO -div2(I7)- -div2(I9)- DIV4sig = VCO/4
mux_sel  = lpbt_en & ~cal_en           div4_en = ~lpbt_en | en_test
ADCDIVCKIN = DIV4sig & div4_en         DIV16sig  = ADCDIVCKIN / 4
NDIVCKIN   = mux_sel ? DIV4sig : DIV16sig     (=VCO/4 if lpbt_en=1, else VCO/16)
OUT_NDIV  <- 14-bit counter clk_to_PFD (NDIVCKIN)   ;  CLK2DSM <- 14-bit clk_to_DSM
OUT_ADCDIV<-  8-bit counter clk_to_PFD (ADCDIVCKIN=VCO/4)
```

## Divide / mode truth table   (✓ = netlist + sim confirmed)

| signal | **WuR-NORM** `lpbt_en=0` | **LPBT** `lpbt_en=1` | **CAL** `cal_en=1` | **TEST** `en_test=1` |
|---|---|---|---|---|
| `NDIVCKIN`     | VCO/16 ✓ | VCO/4 ✓ | VCO/16 ✓ | VCO/16 ✓ |
| `OUT_NDIV`     | **VCO/16/(ndiv−1)** ✓ | **VCO/4/(ndiv−1)** ✓ | VCO/16/(ndiv−1) ✓ | VCO/16/(ndiv−1) ✓ |
| `CLK2DSM`      | = OUT_NDIV ✓ | = OUT_NDIV ✓ | = OUT_NDIV ✓ | = OUT_NDIV ✓ |
| `CLK2CNT`      | static-high ✓ | static-high ✓ | **VCO/4** ✓ | static-high ✓ |
| `TESTCLK_300M` | low ✓ | low ✓ | low ✓ | **VCO/16** ✓ |
| `OUT_ADCDIV`   | *stall* (see below) | frozen (div4_en=0) ✓ | *stall* | *stall* |

- **`lpbt_en` is the prescaler select** — the headline difference vs LPBT. `lpbt_en=1` reproduces
  the LPBT operating point exactly (NDIVCKIN=VCO/4, ADCDIV path off).
- **`cal_en` does NOT freeze NDIV here** (it does in LPBT): with `lpbt_en=0`, `mux_sel=0` regardless
  of `cal_en`, so the NDIV divider keeps running; `cal_en=1` only turns on the `CLK2CNT=VCO/4` monitor.
- `CLK2DSM` lags `OUT_NDIV` by ~2.07 NDIVCKIN cycles (structural, ndiv-independent).

## DIVIDE LAW (confirmed M = ndiv−1 for M ∈ {10,20,34,50,98,102,300})
```
OUT_NDIV = CLK2DSM = NDIVCKIN / (ndiv−1)        => M = ndiv − 1
  WuR  (lpbt_en=0):  OUT_NDIV = VCO / (16·(ndiv−1))
  LPBT (lpbt_en=1):  OUT_NDIV = VCO / ( 4·(ndiv−1))
```

## pwsel → PULSE-WIDTH LAW (counting unit = NDIVCKIN; identical FORM to LPBT)
```
low(NDIVCKIN) = 2·floor(pwsel/2) − 3      (pwsel[0] = don't-care; odd/even collapse)
period        = M = ndiv−1                (pwsel only moves the falling edge)
high          = M − low ;  duty = high / M
50% duty  ⟺  pwsel = M/2 + 3 = (ndiv+5)/2 ;  EXACT only when M ≡ 2 (mod 4)  (ndiv ≡ 3 mod 4)
min usable pwsel = 4 (low=1) ; pwsel ≤ 3 → low ≤ −1 → OUT_NDIV stalls
corner clamp (~50% with don't-crash): pwsel = min((ndiv−1)/2 + 3, 63)
```
Operating point in the committed TB: `ndiv=51` (51 % 4 == 3 → exact 50%), `pwsel=28`.
WuR: OUT_NDIV = VCO/800 = 6 MHz @ 4.8 GHz. LPBT mode: VCO/200 = 24 MHz.

## OUT_ADCDIV — open finding (needs red-zone confirmation)
The 8-bit ADCDIV counter (`WL_PLL_Ndiv_counter_svt_CORE_v3_reload2_overlap`) **counts internally**
(q0..q7, EOC, reload1/2 all fire, divide ≈ adcdiv−1) but its **output stage latches**: `E_pfd → DFF
→ clk_to_PFD` goes high once and never returns, so `OUT_ADCDIV` produces no clock. Robust to the
`delay2`/`DELAD1`/`DELBD1` EOC timing (swept 5..200 ps locally with stub cells). The 14-bit
`reload3` core does NOT show this. → Likely a behavioral-model issue in the 8-bit core's output
stage (same class as the earlier nor4 / pdown / div2 findings), but the EOC path uses external COT
cells that were **stubbed** locally — **confirm on the red zone with the real `L20_SVT_ana` cells.**
The committed TB reports OUT_ADCDIV as **INFO/WARN, not a hard fail**, so the verdict reflects the
NDIV path regardless of how ADCDIV resolves.

## How to re-characterize (local)
```
cd examples/wur_ndiv/_ref/build
./run.sh tb_ndivlaw.vams tb     # divide law + pwsel sweep  -> grep ^LAW / ^SWEEP
./run.sh tb_modes.vams   tb     # mode matrix + divide range -> VCO/ratio per tap
./run.sh tb_NDIV_TOP_v7_svt_0p5W.vams tb   # the committed self-checking TB
```
(`run.sh` globs `export/*.vams` + `ext_stub/*.vams`; the stubs stand in for the red-zone COT cells.)
