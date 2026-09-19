# WuR NDIV — 32.768 kHz reference path + 3rd-order SDM (open-loop verification)

DUT: `NDIV_TOP_v7_svt_0p5W` Stage-A struct (gate-level behavioral cells), pure-digital
Xcelium 18.03, `-ams` wreal (Spectre licence errors are benign). All measurements are taken
at **top-level ports only** (`OUT_NDIV`, `CLK2DSM`), counting unit `Tclk = NDIVCKIN`
(= VCO/16 in WuR mode, VCO/4 in LPBT mode).

Sources: `charac/{tb_wur32k.vams, mash111.vams, tb_wur_sdm.vams, sdm_psd.py, run.sh}`.
Netlist build used: `_ref/build_sdm/` (gitignored, private to this session).
**Everything below is simulated, not derived.** Total simulation cost: **13 xrun runs,
143 s wall, ≈ 96 ms of simulated time** (≈ 0.6 s wall per simulated ms at fVCO = 4.8 GHz).

---

## 0. Motivation — the reference is 32.768 kHz, so the divide ratio is fractional

WuR mode: `OUT_NDIV = VCO/16/(ndiv-1)`, so locking to 32.768 kHz needs
`ndiv-1 = f_VCO/524288`, which is **not an integer** at any real band:

| band | `ndiv-1` needed | nearest integer `ndiv` | static `f_OUT_NDIV` (ideal) | error vs 32768 Hz |
|---|---|---|---|---|
| 4.8 GHz | 9155.2734 | 9155 | 32772.558 Hz | **+139.1 ppm** |
| 5.0 GHz | 9536.7432 | 9537 | 32770.554 Hz | **+77.9 ppm** |
| 5.8 GHz | 11062.6221 | 11063 | 32769.843 Hz | **+56.2 ppm** |

→ an SDM **must** modulate `ndiv`; that is what §2 verifies.

---

## 1. Static 32.768 kHz law — `./run.sh tb_wur32k` (6 s wall, 3.1 ms sim, **TB PASS**)

WuR mode (`lpbt_en=0`), `pwsel = 62` (the widest legal low pulse: `low = 2·floor(62/2)-3 = 59`
NDIVCKIN cycles). `M = ndiv-1` asserted per point, together with `period(CLK2DSM) == period(OUT_NDIV)`,
the CLK2DSM lag, the low-pulse law and an X-guard (every rising edge must be a clean logic 1).

| fVCO | ndiv | expected M | measured period (Tclk) | CLK2DSM period | low | duty | CLK2DSM lag | X | verdict |
|---|---|---|---|---|---|---|---|---|---|
| 4.8 GHz | 9155  | 9154  | 9154.029  | 9154.029  | 59 | 99.355 % | 2.066 | 0 | **PASS** |
| 5.0 GHz | 9537  | 9536  | 9536.000  | 9536.000  | 59 | 99.381 % | 2.069 | 0 | **PASS** |
| 5.8 GHz | 11063 | 11062 | 11062.013 | 11062.013 | 59 | 99.467 % | 2.080 | 0 | **PASS** |
| 4.8 GHz | 8191  | 8190  | 8190.026  | 8190.026  | 59 | 99.280 % | 2.066 | 0 | **PASS** |
| 4.8 GHz | 8192  | 8191  | 8191.026  | 8191.026  | 59 | 99.280 % | 2.066 | 0 | **PASS** |
| 4.8 GHz | 8193  | 8192  | 8192.026  | 8192.026  | 59 | 99.280 % | 2.066 | 0 | **PASS** |
| 4.8 GHz | 12288 | 12287 | 12287.039 | 12287.039 | 59 | 99.520 % | 2.066 | 0 | **PASS** |
| 4.8 GHz | 16383 | 16382 | 16382.052 | 16382.052 | 59 | 99.640 % | 2.066 | 0 | **PASS** |

- `M = ndiv-1` now confirmed over the **full 14-bit range**, including bit 12 and bit 13
  (8191→8192→8193, 12288, 16383). The previous confirmation stopped at M ≤ 300.
- The `+0.026 … +0.052 Tclk` excess is a **TB artifact, not the DUT**: it is exactly
  +3.2 ppm of the period at 4.8 GHz and +1.2 ppm at 5.8 GHz, i.e. the rounding of the
  `#(TVCO/2)` half-period to the 1 fs precision (`TVCO = 208.3333… ps`). At 5.0 GHz
  (`TVCO = 200 ps` exactly) the measured period is **exactly** 9536.000 Tclk.
- **Duty:** 50 % is **unreachable** at these ratios. The 50 % law needs `pwsel = M/2 + 3`,
  i.e. ≈ 4580 at M ≈ 9.2 k, but `pwsel` is 6-bit (max 63). With the widest setting
  (`pwsel = 62`, `low = 59 Tclk`) `OUT_NDIV` is a **narrow ~59-cycle low pulse**, duty
  99.3–99.6 % (196 ns low at 4.8 GHz). The PFD must be edge-triggered on the rising edge.
- CLK2DSM lag is **2.066–2.080 Tclk**, ndiv-independent (matches the known ~2.07).

---

## 2. MASH 1-1-1 driving `ndiv` — `./run.sh tb_wur_sdm …`

`charac/mash111.vams`: three cascaded 20-bit accumulators chained combinationally inside one
clock, error-cancellation network `y = C1 + Δ·C2 + Δ²·C3` ⇒ `y = F − (1−z⁻¹)³·E3`,
`y ∈ [−3,+4]`; optional 1-LSB LFSR dither. Clocked by **`CLK2DSM`** (the pin the chip
provides for exactly this), driving `ndiv = N_int + y`.

### (a) per-cycle law with a dynamic word, and the alignment rule

**Alignment finding (measured, not assumed).** For every recorded OUT_NDIV period the TB
searches the offset `g` in `period_i == word[katE[i-1]-1-g] - 1` and also measures the time
from the governing word's arrival to the reload it feeds. Result at every operating point:
**`g = 0` with 100 % match**, and the governing word arrives `M − 2.07` Tclk before its reload.

> **A word placed on `ndiv` at time T governs the FIRST OUT_NDIV period that STARTS after T**
> (the counter reloads `d_n` on the OUT_NDIV rising edge).
> Since `CLK2DSM` trails `OUT_NDIV` by ~2.07 Tclk, the word issued on CLK2DSM edge *k* has
> already missed the reload at OUT_NDIV edge *k*, so `y_k` sets the period between OUT_NDIV
> edges **k+1 and k+2** — i.e. **one full divider period of latency (z⁻¹)** between the SDM
> output and the period it produces. The loop model must carry that z⁻¹.

| run | mode / fVCO | N_int | F | cycles | per-cycle law | y values seen | X-guard |
|---|---|---|---|---|---|---|---|
| `w300_f7373` | WuR 4.8 GHz | 300 | 0.7372799 | 8190 | **8190/8190 exact** | all 8 (−3:5 … +4:54) | clean |
| `w300_f05`   | WuR 4.8 GHz | 300 | 0.5000067 | 8190 | **8190/8190 exact** | all 8 (−3:1 … +4:1)  | clean |
| `w300_dith`  | WuR 4.8 GHz, dither | 300 | 0.7372799 | 8190 | **8190/8190 exact** | all 8 | clean |
| `w32k_4g8`   | WuR 4.8 GHz | 9156 | 0.2734375 | 254 | **254/254 exact** | 7 of 8 (no +4) | clean |
| `w32k_5g0`   | WuR 5.0 GHz | 9537 | 0.7431641 | 254 | **254/254 exact** | 7 of 8 (no −3) | clean |
| `w32k_5g8`   | WuR 5.8 GHz | 11063 | 0.6220703 | 254 | **254/254 exact** | 8 of 8 | clean |
| `lpbt51`     | LPBT 4.8 GHz | 51 | 0.7372799 | 510 | **510/510 exact** | 7 of 8 (no −3) | clean |

No glitch, no double-load, no dropped or duplicated period anywhere. All 8 `y` values are
exercised in the 8192-cycle runs; the short 32 kHz runs miss one extreme value simply because
`|y|=3,4` is rare for those fractions (2 occurrences of −3 in 254 cycles at 4.8 GHz).

### (b) average divide ratio

| run | cycles K | measured mean(period) [Tclk] | expected `N_int−1+F` | error | tol (≈10/K) | verdict |
|---|---|---|---|---|---|---|
| `w300_f7373` | 8191 | 299.738110 | 299.737280 | +8.30e-4 | 3.2e-3 | **PASS** |
| `w300_f05`   | 8191 | 299.501142 | 299.500007 | +1.14e-3 | 3.2e-3 | **PASS** |
| `w300_dith`  | 8191 | 299.738110 | 299.737280 | +8.30e-4 | 3.2e-3 | **PASS** |
| `w32k_4g8`   | 255  | 9155.307728 | 9155.273438 | +3.43e-2 | 4.1e-2 | **PASS** |
| `w32k_5g0`   | 255  | 9536.733333 | 9536.743164 | −9.83e-3 | 4.1e-2 | **PASS** |
| `w32k_5g8`   | 255  | 11062.636805 | 11062.622070 | +1.47e-2 | 4.1e-2 | **PASS** |
| `lpbt51`     | 511  | 50.735974 | 50.737280 | −1.31e-3 | 2.2e-2 | **PASS** |

(The MASH mean error over a finite record is a telescoped boundary term bounded by ≈ 4/K;
the tolerance used is 10/K + 0.002.)

**Resulting OUT_NDIV frequency at the three real bands** (mean over 255 SDM cycles, after
removing the TB clock-quantization artifact of §1):

| band | N_int | F | f_OUT_NDIV measured | error vs 32768 Hz | (static, no SDM) |
|---|---|---|---|---|---|
| 4.8 GHz | 9156  | 0.2734375  | 32767.982 Hz | **−0.018 Hz (−0.55 ppm)** | +139.1 ppm |
| 5.0 GHz | 9537  | 0.7431641  | 32768.034 Hz | **+0.034 Hz (+1.03 ppm)** | +77.9 ppm |
| 5.8 GHz | 11063 | 0.6220703  | 32767.996 Hz | **−0.004 Hz (−0.13 ppm)** | +56.2 ppm |

The residual is the finite-record averaging error (≤ 4/255 cycles ⇒ ≤ 1.7 ppm), **not** a
systematic offset: the SDM removes the 56–139 ppm static error entirely.

### (c) noise shaping — `sdm_psd.py`

PSD of `e_k = period_k − mean(period)`, slope fitted over one decade, expected `20·order =
+60 dB/dec` for `(1−z⁻¹)³` shaping, tolerance ±12 dB/dec.

| dump | N | window | fit band `f/fs` | slope | implied order | verdict |
|---|---|---|---|---|---|---|
| `perr_w300_f7373.txt` | 8191 | Kaiser β=24 | 2.0e-3 … 2.0e-2 | **+59.2 dB/dec** | 2.96 | **PASS** |
| `perr_w300_f05.txt`   | 8191 | Kaiser β=24 | 2.0e-3 … 2.0e-2 | +56.5 dB/dec | 2.82 | PASS |
| `perr_w300_dith.txt`  | 8191 | Kaiser β=24 | 2.0e-3 … 2.0e-2 | +65.1 dB/dec | 3.25 | PASS |
| `perr_lpbt51.txt`     | 511  | Blackman-Harris | 1.2e-2 … 1.2e-1 | +62.6 dB/dec | 3.13 | PASS |
| `perr_w32k_4g8.txt`   | 255  | Blackman-Harris | 2.4e-2 … 2.4e-1 | +55.8 dB/dec | 2.79 | PASS |
| `perr_w32k_5g0.txt`   | 255  | Blackman-Harris | 2.4e-2 … 2.4e-1 | +53.7 dB/dec | 2.68 | PASS |
| `perr_w32k_5g8.txt`   | 255  | Blackman-Harris | 2.4e-2 … 2.4e-1 | +51.1 dB/dec | 2.56 | PASS |

**Trap worth recording:** a 3rd-order spectrum spans ~160 dB from `f/fs = 1e-3` to Nyquist.
With a Blackman-Harris window (−92 dB sidelobes) the high-frequency energy leaks into the
low-frequency bins and the fitted slope collapses to **+39 dB/dec — a convincing but false
"2nd order" reading**. A Kaiser β=24 window (~−230 dB sidelobes) restores +59 dB/dec.
`sdm_psd.py` picks Kaiser for N ≥ 2048 and keeps the fit band ≥ 16 bins above DC.

### (d) SDM update-timing margin — the number the loop designer needs

Two independent sweeps:

**(d1) latency referred to the CLK2DSM rising edge** (`+PHLAT=1`, 40 cycles per point):

| mode | N_int | M | last all-pass latency | first BROKEN | min setup seen at the last all-pass point | setup of the failing cycles |
|---|---|---|---|---|---|---|
| LPBT (VCO/4)  | 51  | 50  | 44 Tclk  | 45 Tclk (3 of 39 cycles bad)  | 1.74 Tclk | ~0.9 Tclk |
| WuR (VCO/16)  | 300 | 299 | 293 Tclk | 294 Tclk (1 of 39 cycles bad) | 1.94 Tclk | 0.94 Tclk |

Only the cycles preceded by a **short** period fail (`setup = period_prev − 2.07 − latency`),
which is why the failure appears on a handful of cycles rather than all of them. Each sweep
point only records 40 cycles, so the rare `y = −3` period (≈1 % of cycles) is under-sampled
and the measured "last all-pass" value is one cycle optimistic. The **guaranteed** bound uses
the shortest period the MASH can request, `M_min = N_int − 4`:

> `latency_max = M_min − 2.07 − 1.0 = M_min − 3.07` NDIVCKIN cycles after the CLK2DSM rising edge.

**(d2) deterministic setup sweep referred to the reload edge** (`+PHLAT=3`: the TB places the
word a fixed time *S* before the next OUT_NDIV rising edge, so *S* is jitter-free):

| mode | N_int | Tclk | 1.010 Tclk | 1.000 Tclk | 0.990 Tclk | 0.975 Tclk | 0.950 Tclk | ≤0.9 Tclk |
|---|---|---|---|---|---|---|---|---|
| LPBT | 51   | 0.8333 ns | SAFE | SAFE | BROKEN | BROKEN | BROKEN | BROKEN |
| WuR  | 300  | 3.3333 ns | SAFE | SAFE | BROKEN | BROKEN | BROKEN | BROKEN |
| WuR  | 9156 | 3.3333 ns | SAFE | SAFE | SAFE | SAFE | BROKEN | BROKEN |

> **RULE: the `ndiv` word must be stable ≥ 1 NDIVCKIN cycle before the `OUT_NDIV` rising edge.**
> The requirement is **mode- and ratio-independent** (boundary measured between 0.95 and
> 1.00 Tclk at M = 50, 299 and 9155): the counter samples `d_n` about one NDIVCKIN cycle
> before the reload becomes visible on `OUT_NDIV`. Inside that window the word is applied
> one period late on a data-dependent subset of cycles (12–17 of 39) — not a clean failure,
> exactly the kind of intermittent divide error that would look like PLL noise.

Translated to the three bands (`Tclk = 16/f_VCO`, `M_min = N_int − 4`):

| band | Tclk | required setup before OUT_NDIV↑ | max SDM latency after CLK2DSM↑ |
|---|---|---|---|
| 4.8 GHz (N_int=9156)  | 3.3333 ns | **3.33 ns** | 9148.9 Tclk = **30.496 µs** |
| 5.0 GHz (N_int=9537)  | 3.2000 ns | **3.20 ns** | 9529.9 Tclk = **30.496 µs** |
| 5.8 GHz (N_int=11063) | 2.7586 ns | **2.76 ns** | 11055.9 Tclk = **30.499 µs** |
| LPBT 4.8 GHz (ndiv=51)| 0.8333 ns | **0.83 ns** | 43.9 Tclk = **36.6 ns** (44 measured) |

Practically: the SDM has **essentially the whole 32.768 kHz reference period (30.50 µs)** to
produce the next word; it only must not land within ~3.3 ns of the OUT_NDIV rising edge.

**Zero-delay case (`LATC = 0`, update right at the CLK2DSM edge): no race.** The CLK2DSM edge
is already ~2.07 Tclk *past* the reload, so a word issued there has `M − 2.07 ≈ 9153 Tclk`
(30.51 µs) of setup. Measured setup at LATC=0: 297.7 Tclk (N_int=300), 9153.2 Tclk (4.8 GHz),
9534.7 Tclk (5.0 GHz), 11060.6 Tclk (5.8 GHz) — all 100 % correct.

### (e) LPBT mode (the mode the existing FDR used)

`lpbt_en=1`, NDIVCKIN = VCO/4, `ndiv = 51 + y`, F = 0.7372799, **512 cycles**:
per-cycle law **510/510 exact**, alignment g = 0, mean period 50.735974 vs 50.737280
(err −1.3e-3), PSD slope +62.6 dB/dec, X-guard clean → **PASS**.

---

## 3. Runtime

~0.6 s wall per simulated ms at fVCO = 4.8 GHz (whole struct + connect modules); ~3 s of that
is compile + elaborate, which every run repeats (`run.sh` does `rm -rf xcelium.d`).

| run | wall | run | wall |
|---|---|---|---|
| `tb_wur32k` | 6 s | `lpbt51` (512 cyc) | 3 s |
| `w300_f7373` (8192 cyc) | 12 s | `lat_lpbt` (45 pts) | 3 s |
| `w300_f05` (8192 cyc) | 11 s | `lat_w300` (297 pts) | 18 s |
| `w300_dith` (8192 cyc) | 15 s | `setup_lpbt` (20 pts) | 2 s |
| `w32k_4g8/5g0/5g8` (256 cyc) | 11 / 12 / 13 s | `setup_w300` / `setup_w9k` | 4 s / 33 s |

**Total 13 runs, 143 s.** Budget (≤ 20 min/run, ≤ 2 h total) beaten by ~50×.

---

## 4. NOT covered (honest list)

1. **Closed loop.** Everything here is open-loop: `fromVCO` is an ideal square wave and the
   SDM is free-running. No PFD/CP/LF, no lock behaviour, no phase-noise-to-jitter transfer.
2. **Real SDM clock skew / metastability.** The MASH is behavioral with zero clk→q (a 1 fs
   read offset). Real flop delays and setup/hold on `d_n` are not modelled; the 1-Tclk rule
   of §2(d) is therefore a *model* bound — silicon must add its own setup margin on top.
3. **Cell delays.** The leaf models carry ad-hoc `#10` (ps) or zero delays; the 2.07-Tclk
   CLK2DSM lag and the 1-Tclk reload setup both depend on those. A delay-injection sweep
   (sibling work in `_ref/build_dly/`) is needed before quoting these as silicon numbers.
4. **The 32 kHz points ran 254 cycles, not thousands.** The PSD slope at ndiv ≈ 9.2k–11k is
   from a 255-point record (fit band 2.4e-2…2.4e-1 f/fs) — it confirms shaping is present and
   3rd-order-consistent, but the quantitative +60 dB/dec claim rests on the 8192-cycle
   N_int = 300 run. Low-frequency (in-band, < 1 kHz offset) shaping at the real ratio is
   **not** measured; that would need ≥ 10⁵ cycles ≈ 3 s of simulated time (~30 min wall).
5. **Dither.** The 1-LSB dither is injected into accumulator 1, so it appears at `y`
   *unshaped*. At 2⁻²⁰ it is invisible here (mean and slope unchanged within noise), but for
   a real in-band noise budget it should be re-examined or moved to a shaped injection point.
6. **`OUT_ADCDIV` under SDM.** Not re-checked — it is not SDM-modulated and does not close
   the loop (confirmed separately in `SPEC_CHECKLIST.md`).
7. **pwsel during modulation.** `pwsel` was held at 62 (WuR) / 28 (LPBT). The interaction of a
   *changing* `pwsel` with the reload was not swept.
8. **Red zone.** All runs used the stubbed COT cells in `ext_stub/`. Re-run on the real
   library before sign-off.

## 5. Cross-check on the DELAY-INJECTED models (added 2026-09-19 by the integrating session)

The four headline runs were repeated with `STRUCT_DIR` pointing at a copy of the 1× table build
(`_ref/build_dly/export_dly` + `ext_stub_dly`, 72 injected sites — see `DELAYS.md`), so the
numbers above no longer ride only on the ad-hoc `#10` leaf delays:

| run | delayed-model result |
|---|---|
| `tb_wur32k` (8 static points, all bands) | **TB PASS** |
| `tb_wur_sdm +FVCO_MHZ=5800 +NINT=11063 +FNUM=629146 +KCYC=256` | **TB PASS**, ALIGN g=0 254/254, mean 11062.613 vs 11062.600 (+0.013 Tclk, within tol) |
| `tb_wur_sdm +PHLAT=3 +LPBT=0 +NINT=300` (setup sweep) | **TB PASS**, smallest SAFE setup = **1.000 Tclk** (unchanged) |
| `tb_wur_sdm +NINT=300 +FNUM=773094 +KCYC=8192 +ALLY=1` + `sdm_psd.py` | **TB PASS**, 8190/8190, PSD **+59.2 dB/dec** (order 2.96) |

Alignment rule (z⁻¹), 1-Tclk setup and the noise-shaping slope are therefore delay-independent
at 1×; the delay-scale margin itself (5×/6× break points) is in `DELAYS.md`.
