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
| `OUT_ADCDIV`   | **VCO/4/(adcdiv−1)** ✓ | frozen (div4_en=0) ✓ | = NORM (div4_en=1) | = NORM (div4_en=1) |

- **`lpbt_en` is the prescaler select** — the headline difference vs LPBT. `lpbt_en=1` reproduces
  the LPBT operating point exactly (NDIVCKIN=VCO/4, ADCDIV path off).
- **`cal_en` does NOT freeze NDIV here** (it does in LPBT): with `lpbt_en=0`, `mux_sel=0` regardless
  of `cal_en`, so the NDIV divider keeps running; `cal_en=1` only turns on the `CLK2CNT=VCO/4` monitor.
- `CLK2DSM` lags `OUT_NDIV` by ~2.07 NDIVCKIN cycles (structural, ndiv-independent).
- **POWER-DOWN** (`ndiv_en=0`): `power_en_b=1` → the four pdown clamps + `net082=0` unpower the
  buffers → all five chip outputs settle to a **clean logic 0** (✓ TB-checked: quiet AND level 0,
  via `CKLO` which catches a stuck-X that an edge-count alone would miss — the old pdown X-bug class).

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

## OUT_ADCDIV LAW (8-bit ADCDIV counter) — RESOLVED (it was a programming constraint, NOT a bug)
`OUT_ADCDIV` is clocked by `ADCDIVCKIN = VCO/4` whenever `lpbt_en=0` (div4_en=1). Divide law same
family (`M_adc = adcdiv−1`), but **adcpwsel has a big +62 offset** vs the NDIV's −3, because the
8-bit `EOC_low_short = nor3(nand12, d_low, nand(q6,q7b))` requires the count to reach **q6=1 (≥64),
q7=0** to fire the falling edge (the 14-bit instead needs the high bits =0). Confirmed by sweep:
```
OUT_ADCDIV     = VCO / (4·(adcdiv−1))              (lpbt_en=0)
low(ADCDIVCKIN)= 2·floor(adcpwsel/2) + 62          (adcpwsel[0] don't-care; +62 offset)
period         = M_adc = adcdiv − 1 ;  high = M_adc − low
TOGGLES only when M_adc > low  ⟺  adcdiv ≥ 2·floor(adcpwsel/2) + 64   (min adcdiv ≈ 64)
50% duty  ⟺  adcpwsel = (adcdiv−1)/2 − 62
```
Measured: adcdiv=165,adcpwsel=20 → M=164,low=82,high=82 → **exact 50%, OUT_ADCDIV=VCO/656**;
adcdiv=64,adcpwsel=0 → just toggles (high≈2); adcdiv≤63 → no q6 → stall; adcpwsel is 6-bit so 65
wraps to 1. **The earlier "stall" was simply adcdiv<64 / low≥M (I had adcdiv=51,adcpwsel=28) — not a
model bug.** The committed TB now hard-checks OUT_ADCDIV (divide + X-guard + 50% duty) at
adcdiv=165/adcpwsel=20. (Local repro used stubbed COT cells in the EOC `delay2`, but the +62 offset
is structural, count-driven — independent of those delays, swept 5..200 ps — so it carries to the
red zone; the divide is fully robust.)

## How to re-characterize (local)
```
cd examples/wur_ndiv/_ref/build
./run.sh tb_ndivlaw.vams tb     # NDIV divide law + pwsel sweep  -> grep ^LAW / ^SWEEP
./run.sh tb_modes.vams   tb     # mode matrix + divide range     -> VCO/ratio per tap
./run.sh tb_adc4.vams    tb     # ADCDIV adcpwsel->low sweep (+62 offset) -> grep ^ADCSWEEP
./run.sh tb_adc5.vams    tb     # ADCDIV operating point + toggle boundary -> grep ^ADC
./run.sh tb_NDIV_TOP_v7_svt_0p5W.vams tb   # the committed self-checking TB
```
Report (PASS/FAIL table + SimVision PNGs + report.md), like LPBT's:
```
python3 ../../../vh_wur_report.py --sim <simdir>   # runs run.sh +WAVES, writes <simdir>/report/
```
(`run.sh` globs `export/*.vams` + `ext_stub/*.vams`; the stubs stand in for the red-zone COT cells.)

---

## 32.768 kHz REFERENCE / SDM-MODULATED DIVIDE WORD  (✓ = simulated on the Stage-A struct, 2026-09-19)

Sources `examples/wur_ndiv/charac/` (`tb_wur32k.vams`, `mash111.vams`, `tb_wur_sdm.vams`,
`sdm_psd.py`, `run.sh`); full numbers + "not covered" list in `examples/wur_ndiv/SDM_32K_RESULTS.md`.
Local build (gitignored): `examples/wur_ndiv/_ref/build_sdm/`. 13 runs, 143 s wall total.

### Static law at the real reference
- ✓ `M = ndiv − 1` now confirmed over the **full 14-bit range**, not just M ≤ 300:
  swept ndiv = 8191, 8192, 8193, 9155, 9537, 11063, 12288, 16383 (bit-12/bit-13 witnesses),
  `period(OUT_NDIV) = period(CLK2DSM) = M·Tclk` exactly, clean-1 edges, no X.
- ✓ `CLK2DSM` lag = **2.066–2.080 Tclk**, ndiv-independent (was quoted as ~2.07).
- ✓ WuR locking to 32.768 kHz needs `ndiv−1 = f_VCO/524288`, which is **fractional at every
  band** → an SDM is mandatory. Static (integer-ndiv) error:
  | band | best ndiv | f_OUT_NDIV | err |
  |---|---|---|---|
  | 4.8 GHz | 9155 | 32772.558 Hz | +139.1 ppm |
  | 5.0 GHz | 9537 | 32770.554 Hz | +77.9 ppm |
  | 5.8 GHz | 11063 | 32769.843 Hz | +56.2 ppm |
- ✓ **50 % duty is UNREACHABLE at M ≈ 9 k**: the 50 % law needs `pwsel = M/2 + 3 ≈ 4580` but
  `pwsel` is 6-bit. Widest legal setting `pwsel = 62` → `low = 59 Tclk` (196 ns @4.8 GHz),
  duty 99.3–99.6 %. `OUT_NDIV` is a narrow low pulse — the PFD must use the **rising** edge.

### Dynamic (MASH 1-1-1) divide word
- ✓ **Per-cycle law with a changing word:** `period_k = ndiv_applied_k − 1` **exactly, every
  cycle**, with all 8 MASH outputs `y ∈ [−3,+4]` exercised. 8190/8190 at N_int = 300 (two
  fractions + dithered), 254/254 at each real 32 kHz point (N_int = 9156/9537/11063),
  510/510 in LPBT at ndiv = 51. No glitch, no double load, no dropped period.
- ✓ **LOAD ALIGNMENT (new):** a word placed on `ndiv` at time T governs the **first OUT_NDIV
  period that STARTS after T** (the counter reloads `d_n` on the OUT_NDIV rising edge).
  Because `CLK2DSM` trails `OUT_NDIV` by ~2.07 Tclk, the word issued on CLK2DSM edge *k*
  sets the period between OUT_NDIV edges **k+1 and k+2** →
  **one full divider period of latency (z⁻¹) from SDM word to period.** Put it in the loop model.
- ✓ **SDM UPDATE TIMING (new):** the `ndiv` word must be stable **≥ 1 NDIVCKIN cycle before
  the OUT_NDIV rising edge**. Boundary measured between 0.95 and 1.00 Tclk and found
  **mode- and ratio-independent** (M = 50, 299, 9155). Inside that window the word is applied
  one period late on a data-dependent subset of cycles — intermittent, looks like PLL noise.
  ```
  setup_required = 1 Tclk  ->  3.33 ns @4.8G, 3.20 ns @5.0G, 2.76 ns @5.8G (WuR)
                               0.83 ns @4.8G (LPBT)
  latency_max after CLK2DSM rising edge = M_min - 3.07 Tclk,  M_min = N_int - 4
        = 30.50 us at all three WuR bands  (i.e. ~a whole reference period)
  LATC=0 (update right at the CLK2DSM edge) has NO race: it already has M-2.07 Tclk of setup.
  ```
- ✓ **Average ratio:** `mean(period) = N_int − 1 + F` within the finite-record bound (≈4/K).
  With the SDM the 32.768 kHz error collapses from +56…+139 ppm to **≤ 1.1 ppm**
  (4.8 GHz −0.55 ppm, 5.0 GHz +1.03 ppm, 5.8 GHz −0.13 ppm over 255 cycles).
- ✓ **Noise shaping:** PSD of the period error rises **+59.2 dB/dec** (implied order 2.96)
  over `f/fs = 2e-3…2e-2`, 8191 cycles at N_int = 300 — consistent with `(1−z⁻¹)³`.
  (Analysis trap: a Blackman-Harris window leaks and reports a false +39 dB/dec; the 160 dB
  spectral span needs a Kaiser β≈24 window — `sdm_psd.py` handles this.)
- ✓ **LPBT mode** (`lpbt_en=1`, NDIVCKIN = VCO/4, ndiv = 51 + y, 512 cycles): same per-cycle
  law, same alignment, PSD +62.6 dB/dec → the FDR's operating mode is unaffected.

### Not confirmed here
Closed loop, real flop/cell delays (the 2.07 Tclk lag and the 1 Tclk reload setup both depend
on the ad-hoc leaf delays), in-band (<1 kHz offset) shaping at ndiv ≈ 9 k (needs ≥10⁵ cycles),
changing `pwsel` during modulation, and the red-zone COT library (runs used `ext_stub/`).
