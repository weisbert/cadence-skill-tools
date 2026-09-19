# NDIV_TOP_v7_svt_0p5W — realistic leaf delays, regression and timing margin

**Tool:** `vh_delay.py` · **Table:** `delays/wur_ndiv_delays.json` (v1) · **Dev box**, xrun 18.03,
pure-digital `-ams` (wreal, no spectre). Local repro dir (gitignored): `examples/wur_ndiv/_ref/build_dly/`.

The red-zone `verilogams` cellviews of this block carry **no timing at all** for 10 of the
leaves, and ad-hoc `#10`/`#15`/`#20` for the rest. A zero-delay model hides every hold race
and every ripple-accumulation effect, so a PASS proves less than it looks. This page records
(a) what was injected, (b) that the design still passes with realistic timing at 4.8/5.0/5.8 GHz,
and (c) **how much delay margin there is before it breaks, and which mechanism breaks first**.

---

## 1. The delay table (1× values)

All values are **typical intrinsic cell delays** for "0p5W" SVT cells at 0.8 V nominal. They are
plausible engineering placeholders, **not characterized silicon data** — the table is the record,
and it is a single JSON file you edit when real numbers arrive.

| class | ps (1×) | modules | current ad-hoc value in the source | rationale |
|---|---|---|---|---|
| `inv` | 12 | `WL_PLL_Ndiv_inv_svt_x{2,4,8}_0p5W` | `#10` | SVT inverter, 0.8 V, moderate fan-out |
| `inv_pdiv` | 10 | `WL_PLL_PDIV_{lvt_x2,lvt_x4,svt_x2,svt_x2_0p5W,svt_x4,svt_x4_emir,svt_x8}` | `#10` | prescaler/clock-tree inverter, up-sized, runs at 4.8–5.8 GHz |
| `nand2` | 18 | `WL_PLL_Ndiv_nand2_{lvt_x2,svt_x2,svt_x2_0p5W,svt_x4_0p5W,svt_x8_0p5W}` | `#10` | 2-high NMOS stack |
| `nand3` | 28 | `WL_PLL_Ndiv_nand3_{svt_0p5W,svt_x2_0p5W,svt_x8_0p5W}` | `#10` | 3-high stack |
| `nor2` | 20 | `WL_PLL_Ndiv_nor2_svt_x4_0p5W`, `NR2D2_COT_…_SVT_ana` | `#10`, `#(10e-12)` (file is `1s/1fs`) | 2-high PMOS stack |
| `nor3` | 26 | `WL_PLL_Ndiv_nor3_svt_x4_0p5W` | `#10` | 3-input NOR |
| `nor4` | 32 | `WL_PLL_Ndiv_nor4_svt_x2_0p5W` | `#10` | 4-high PMOS stack — slowest static gate (EOC detect) |
| `mux` | 25 | `WL_PLL_Ndiv_mux2_1_svt_0p5W`, `Mux_2to1_v5_lvt` | `#15` | TG pair + output inverter |
| `mux_delay` | 30 | `WL_PLL_Ndiv_mux2_1_delay_svt_0p5W` | `#5` | the deliberately slower reload-path mux |
| `buf` | 30 | `BUFFD2_COT_…_SVT_ana` | **none** | two-stage buffer |
| `dff` | 50 | `WL_PLL_Ndiv_DFF_dif_svt_goodDesign_0p5W` + `_Counter14bits`, `_CNT14bits_b`, `_Counter8bits`, `_Counter8bits_b` | **none** | static master-slave clk→Q at 0.8 V |
| `tff` | 50 | `WL_PLL_Ndiv_TFF_gateinv_svt_x{2,8}_goodDesign_0p5W` | `q<=#20 ~q; qb<=#10 q;` (load branch `#10`) | same core as the DFF; see note below |
| `tspc_div2` | 30 | `WL_PLL_PDIV_TSPCDIV2_pilot` | **none** | front-end ÷2 at 4.8–5.8 GHz: dynamic, ratioed, 2–3 stages |
| `power_sw` | 80 | `pll_ndiv_power_sw` | **none** (blocking `=`) | big header device, non-critical enable path |
| `pdown` | 60 | `WL_PLL_Ndiv_pdown` | **none** (blocking `=`, const RHS) | output clamp / release-to-Z, static path |
| `ext_inv` | 12 | `INVD1_COT_…`, `INVD8_COT_…` (ext_stub) | `#(10e-12)` | stand-in for the red-zone COT cell |
| `ext_nand2` | 18 | `ND2D1_COT_…` (ext_stub) | `#(10e-12)` | stand-in |
| `ext_nor2` | 20 | `NR2D1_COT_…` (ext_stub) | `#(10e-12)` | stand-in |
| `delay_cell_a` | 40 | `DELAD1_COT_…` (ext_stub) | `#(40e-12)` | a **delay cell** — its delay *is* its function; value kept |
| `delay_cell_b` | 30 | `DELBD1_COT_…` (ext_stub) | `#(30e-12)` | idem |

**42 modules, 47 delay sites** (`vh_delay.py report`). The structural top
`NDIV_TOP_v7_svt_0p5W_struct.vams` has no behavioural statement → nothing to inject.

### Decisions baked into the injection

1. **The power-fail / async-clear branch is never delayed.** `if (!powerOK) Q <= 1'b0;` and the
   `initial` blocks stay immediate. A supply collapse must clamp instantly; delaying it would
   inject phantom edges after power removal and would weaken the POWER-DOWN clean-0 check for
   the wrong reason. Only the *functional* branch of each model gets a delay.
2. **TFF q/qb skew removed.** The source had `q <= #20 ~q; qb <= #10 q;` — an artificial 10 ps
   q-vs-qb skew that no real TFF has, and that biases exactly the hold race this study is about.
   Both outputs (and both the toggle and the `ld` reload branch) now use one `VH_TPD_TFF`.
3. **Blocking → non-blocking at delayed sites.** `pll_ndiv_power_sw` and `WL_PLL_Ndiv_pdown`
   used blocking `=` inside `always @(*)`; `x = #d expr` would *suspend the process* for `d` and
   can swallow an input event, so delayed sites are normalised to `x <= #d expr`.
4. **Timescale is honoured per file.** `1ps/1ps` files get `50.0`, `1s/1fs` files get `5e-11`.
   Note the `1ps/1ps` files round a delay to whole ps, so a fractional scale (e.g. 0.5×) is
   rounded there — irrelevant at the scales used below.
5. **ext_stub is injected too** so the local sweep scales the *whole* design uniformly. On the
   red zone those six cells come from the real COT `-v` library and must **not** be injected.

---

## 2. Regression with the 1× table — committed TB, all 5 modes

`testbenches/tb_NDIV_TOP_v7_svt_0p5W.vams` (ndiv=51, pwsel=28, adcdiv=165, adcpwsel=20),
unmodified except for the `TVCO` line in the 5.0/5.8 GHz copies.

| VCO | WuR-NORM | LPBT | CAL | TEST | POWER-DOWN | ADCDIV | verdict |
|---|---|---|---|---|---|---|---|
| **4.8 GHz** | PASS | PASS | PASS | PASS | PASS | PASS | `=== TB PASS  (top=NDIV_TOP_v7_svt_0p5W) ===` |
| **5.0 GHz** | PASS | PASS | PASS | PASS | PASS | PASS | `=== TB PASS  (top=NDIV_TOP_v7_svt_0p5W) ===` |
| **5.8 GHz** | PASS | PASS | PASS | PASS | PASS | PASS | `=== TB PASS  (top=NDIV_TOP_v7_svt_0p5W) ===` |

30 individual checks PASS per run (divide law ×2 modes, duty, X-guards, quiet/clamped-0 in
power-down, ADCDIV divide + duty + X). Zero-delay baseline (original `export/`) also PASSes —
so **the 1× table costs no functional coverage**: every law in `SPEC_CHECKLIST.md` survives.

Reproduce:
```bash
cd examples/wur_ndiv/_ref/build_dly
./run.sh tb_wur48.vams tb          # also tb_wur50.vams / tb_wur58.vams
```

---

## 3. Delay-scale margin sweep @ 5.8 GHz (the worst corner)

Scale is applied **without re-injecting** via `+define+VH_TPD_SCALE=<x>` (proved equivalent to a
re-injected `--scale`, §5). `dff/tff clk→Q = 50 ps × scale`; `tspc_div2 = 30 ps × scale`.

### 3a. Committed 5-mode TB (mode transitions included)

| scale | DFF clk→Q | WuR | LPBT | ADCDIV | CAL | TEST | PDN | first failing check |
|---|---|---|---|---|---|---|---|---|
| 0.5× | 25 ps | PASS | PASS | PASS | PASS | PASS | PASS | — |
| 1× | 50 ps | PASS | PASS | PASS | PASS | PASS | PASS | — |
| 2× | 100 ps | PASS | PASS | PASS | PASS | PASS | PASS | — |
| 3× | 150 ps | PASS | PASS | PASS | PASS | PASS | PASS | — |
| **4×** | 200 ps | PASS | PASS | PASS | **FAIL** | **FAIL** | PASS | `OUT_NDIV still = VCO/16/(ndiv-1): no edges` |
| **5×** | 250 ps | PASS | **FAIL** | PASS | PASS | PASS | PASS | `OUT_NDIV = VCO/4/(ndiv-1): measured VCO/208, expected VCO/200` |
| **6×** | 300 ps | **FAIL** | FAIL | **FAIL** | FAIL | FAIL | PASS | `OUT_NDIV = VCO/16/(ndiv-1): measured VCO/1600, expected VCO/800` |
| 8× | 400 ps | FAIL | FAIL | FAIL | FAIL | FAIL | PASS | idem |

### 3b. Single-mode probe `tb_dly.vams` (no mode transition, per-cycle period check)

| scale | DFF clk→Q | WuR (NDIVCKIN = VCO/16 = 2.76 ns) | LPBT (NDIVCKIN = VCO/4 = 690 ps) |
|---|---|---|---|
| 0.5× | 25 ps | PASS VCO/800 | PASS VCO/200 |
| 1× | 50 ps | PASS VCO/800 | PASS VCO/200 |
| 2× | 100 ps | PASS VCO/800 | PASS VCO/200 |
| 3× | 150 ps | PASS VCO/800 | PASS VCO/200 |
| 4× | 200 ps | PASS VCO/800 | PASS VCO/200 |
| **5×** | 250 ps | PASS VCO/800 | **FAIL VCO/208** (+2 NDIVCKIN counts) |
| **6×** | 300 ps | **FAIL VCO/1600** (2×) | FAIL VCO/400 (2×) |
| 8× | 400 ps | FAIL VCO/1600 | FAIL VCO/400 |

### 3c. The three failure mechanisms, isolated

The per-class override makes the isolation a one-liner — no file is touched.

**(i) 6× — the front-end ÷2, not the counter.** `WL_PLL_PDIV_TSPCDIV2_pilot` is
`Q <= #(T) ~Q` on `posedge CLK`. When `T ≥ TVCO` two consecutive VCO edges sample the *same*
`Q`, the divider loses an edge and the whole chain gains a factor 2 — which is exactly the
observed VCO/1600 (WuR) and VCO/400 (LPBT).

```
# pin the TSPC back to 30 ps while everything else runs at 6x  -> PASSES
./run.sh tb_dly.vams tb +define+FGHZ=5.8 +define+VH_TPD_SCALE=6 +define+VH_TPD_TSPC_DIV2_PS=5
   HOLD meas: edges=41 avg=VCO/800.000 ... === TB PASS ===
# force ONLY the TSPC to 180 ps while everything else stays 1x -> reproduces the 2x failure
./run.sh tb_dly.vams tb +define+FGHZ=5.8 +define+VH_TPD_SCALE=1 +define+VH_TPD_TSPC_DIV2_PS=180
   HOLD meas: edges=21 avg=VCO/1600.000 ... === TB FAIL (2 mismatches) ===
```
The law is `tspc_div2 clk→Q < T_VCO`, confirmed at all three frequencies:

| VCO | T_VCO | 6× = 180 ps | 7× = 210 ps |
|---|---|---|---|
| 4.8 GHz | 208.3 ps | PASS | **FAIL** |
| 5.0 GHz | 200.0 ps | PASS | **FAIL** |
| 5.8 GHz | 172.4 ps | **FAIL** | FAIL |

So the front-end ÷2 has ≈ **5.7× margin at 5.8 GHz** (172/30) and ≈ **6.9× at 4.8 GHz**.

**(ii) 5× LPBT — EOC→reload path late (ripple accumulation), not the front end.** With the
TSPC pinned at 30 ps, LPBT at 5× still divides by 52 instead of 50:
```
./run.sh tb_dly.vams tb +define+FGHZ=5.8 +define+LPBTEN=1 +define+VH_TPD_SCALE=5 +define+VH_TPD_TSPC_DIV2_PS=6
   FAIL divide law: avg VCO/208.000, expected VCO/200  (off by 2.00 NDIVCKIN count(s))
```
At 6× (TSPC pinned) it is `VCO/212` = **+3 counts** — the error grows with delay, the signature
of a reload pulse that arrives progressively later relative to the counter clock. The budget is
one `NDIVCKIN` period = **690 ps** in LPBT mode (VCO/4 @5.8 GHz); the EOC chain is
`nand3 → nor4 → mux_delay → TFF ld` ≈ (28+32+30+50) ps = 140 ps at 1×, i.e. ≈ **4.9× margin**,
matching the observed first break at 5×. WuR mode clocks the same counter at VCO/16 (2.76 ns),
4× more budget, so it never hits this limit before the front-end ÷2 gives out.

**(iii) 4× CAL/TEST in the 5-mode TB — an `lpbt_en` 1→0 *mode-switch* hazard, not a
steady-state limit.** The CAL and TEST sections of the committed TB run *after* the LPBT
section. The single-mode probe shows the difference cleanly:
```
+define+VH_TPD_SCALE=4                      -> === TB PASS ===        (WuR, never left WuR)
+define+VH_TPD_SCALE=4 +define+PRELPBT=1    -> FAIL: 0 edges (stalled) (after lpbt_en 0->1->0)
+define+VH_TPD_SCALE=3 +define+PRELPBT=1    -> === TB PASS ===
```
Switching the prescaler mux while the counter is mid-count produces a runt on `NDIVCKIN`; at
≥4× the reload/EOC state machine latches into a state it never leaves — **OUT_NDIV stops
permanently** (0 edges, no recovery). This is a *glitch-free-mux* issue in the clock select,
and it is the **first thing to break** in the real 5-mode sequence. It is 4× away at 5.8 GHz,
but it is a hard hang, not a graceful degradation, so it is the one worth a design look.

**(iv) ADCDIV.** `adcdiv=165 / adcpwsel=20` → `OUT_ADCDIV = VCO/656`, exact 50 % duty, PASS at
every scale up to 5×. At 6× (TSPC pinned, so the front end is healthy) it reads `VCO/660`
= `M_adc` 165 instead of 164 → **+1 count**: the same late-reload mechanism as (ii), on the
8-bit counter, which also clocks at `ADCDIVCKIN = VCO/4 = 690 ps`. The `+62` `adcpwsel` offset
from `SPEC_CHECKLIST.md` is unchanged by the delays (it is count-driven, not delay-driven).

### Margin conclusion

At the nominal table the WuR NDIV has **≈4× delay margin at 5.8 GHz before anything breaks**
(mode-switch hazard), **≈5× before the divide law degrades** (LPBT reload), and **≈5.7× before
the front-end ÷2 fails**. In plain numbers: DFF/TFF clk→Q may be as slow as ~200 ps and the
TSPC ÷2 as slow as ~170 ps before the block misbehaves at 5.8 GHz. Realistic 0.8 V SVT numbers
(40–60 ps / 25–35 ps) sit comfortably inside that, and **no check regressed** at 1×.

---

## 4. Hold-race / period-law probe (`tb_dly.vams`, 1× table)

The 14-bit counter is a ripple chain of TFFs, each clocked from the previous `q`. With zero
delay, xrun's event ordering hides the races; with delays a stage can genuinely double-count or
swallow a count. The probe therefore checks the period **cycle by cycle** (a `min`/`max` spread
of less than one `NDIVCKIN` count), not just on average — an average would hide a ±1 count.

| VCO | mode | ndiv | M = ndiv−1 | expected | measured (avg = min = max) | spread | verdict |
|---|---|---|---|---|---|---|---|
| 4.8 GHz | WuR | 51 | 50 | VCO/800 | VCO/800.000 | 0.0 ps | PASS |
| 4.8 GHz | WuR | 300 | 299 | VCO/4784 | VCO/4784.000 | 0.0 ps | PASS |
| **4.8 GHz** | **WuR** | **9155** | **9154** | **VCO/146464** | **VCO/146464.000** | **0.0 ps** | **PASS** |
| 5.8 GHz | WuR | 51 | 50 | VCO/800 | VCO/800.000 | 0.0 ps | PASS |
| 5.8 GHz | WuR | 300 | 299 | VCO/4784 | VCO/4784.000 | 0.0 ps | PASS |
| 5.8 GHz | LPBT | 51 | 50 | VCO/200 | VCO/200.000 | 0.0 ps | PASS |
| 5.8 GHz | LPBT | 300 | 299 | VCO/1196 | VCO/1196.000 | 0.0 ps | PASS |

**No stage double-counts.** `M = ndiv − 1` is exact on every single period, including the
14-bit extreme `ndiv = 9155` (8 output periods of 30.5 µs each — the run takes ~3 s). `CLK2DSM`
tracks `OUT_NDIV` at every point. `pwsel` is clamped to 63 for ndiv ≥ 122 per the
`SPEC_CHECKLIST.md` corner rule, giving duty 80.3 % at ndiv=300 and 99.4 % at ndiv=9155 — as
the pulse-width law predicts, not a defect.

```bash
cd examples/wur_ndiv/_ref/build_dly
./run.sh tb_dly.vams tb +define+FGHZ=4.8 +define+NDIVW=9155 +define+NPER=8 +define+VH_TPD_SCALE=1.0
```

---

## 5. Command-line override — the exact line, and the proof it works

The injected models define `VH_TPD_<CLASS>` from two optional macros, so **nothing has to be
re-injected to retune**:

```bash
# scale every class (1.0 = exactly as injected)
xrun ... +define+VH_TPD_SCALE=2.0
# one class only, absolute ps (still multiplied by VH_TPD_SCALE)
xrun ... +define+VH_TPD_DFF_PS=75  +define+VH_TPD_TSPC_DIV2_PS=28
```
With the local runner:
```bash
cd examples/wur_ndiv/_ref/build_dly
./run.sh tb_wur58.vams tb +define+VH_TPD_SCALE=2.0
```
`+define+` was chosen over `-defparam` because these leaves are instantiated hundreds of times:
a macro hits every instance, a `-defparam` needs one hierarchical path per instance. It is core
Verilog-2001 preprocessing, so it carries from xrun 18.03 to 19.04 unchanged.

**Proof (same TB, same frequency, scale 5):**

| how | result |
|---|---|
| files injected with `vh_delay.py apply --scale 5` (baked), no `+define` | `FAIL OUT_NDIV = VCO/4/(ndiv-1): measured VCO/208.00` → `=== TB FAIL (2 mismatches) ===` |
| files injected at 1×, `+define+VH_TPD_SCALE=5.0` | `FAIL OUT_NDIV = VCO/4/(ndiv-1): measured VCO/208.00` → `=== TB FAIL (2 mismatches) ===` |

Identical, check for check.

---

## 6. How to regenerate this locally

```bash
cd <verilog_helper>
python3 vh_delay.py report --src examples/wur_ndiv/_ref/build/export \
                           --src examples/wur_ndiv/_ref/build/ext_stub \
                           --table delays/wur_ndiv_delays.json
B=examples/wur_ndiv/_ref/build_dly
python3 vh_delay.py apply --table delays/wur_ndiv_delays.json --src $B/export   --out $B/export_dly
python3 vh_delay.py apply --table delays/wur_ndiv_delays.json --src $B/ext_stub --out $B/ext_stub_dly
cd $B && ./run.sh tb_wur58.vams tb +define+VH_TPD_SCALE=1.0
```
The probe TB is committed as `testbenches/tb_NDIV_TOP_v7_svt_0p5W_dly.vams` (copy it into the
build dir as `tb_dly.vams`, or point `run.sh` at it directly).

`run.sh` globs `export_dly/*.vams` + `ext_stub_dly/*.vams` (override with `VH_SRC`/`VH_EXT`) and
runs each simulation in its own `VH_RUNDIR`, so it never collides with a sibling build.
`examples/wur_ndiv/_ref/build/` and `_ref/build_sdm/` are never touched.

---

## 7. What is NOT covered

- **The numbers are placeholders.** No cell was characterized; the classes are engineering
  estimates for 0.8 V SVT. The *shape* of the result (which mechanism breaks first, and at what
  multiple of nominal) is robust, the absolute ps are not. Replace the JSON when real
  `.lib`/spectre numbers exist and re-run §2–§4.
- **One delay per cell, not per arc.** No separate rise/fall, no input-pin-dependent delay, no
  load or slew dependence, no setup/hold *checks* (`$setup`/`$hold` are not inserted, so a true
  setup violation is modelled as a late data edge, not flagged as a violation). No SDF.
- **No corner/PVT spread and no on-chip variation.** The global scale moves *every* cell
  together; real OCV would skew a ripple chain against its own clock. A per-class scale is
  available (`+define+VH_TPD_<CLASS>_PS`) and was used for the isolation in §3c, but there is no
  random per-instance jitter.
- **The COT cells are stubs here.** `DELAD1/DELBD1/INVD1/INVD8/ND2D1/NR2D1` are hand-written
  stand-ins; the red zone resolves the real models via `-v`. Their delays therefore scale in this
  sweep but will not on red — see `RED_ZONE.md` § "Applying delays on the red zone".
- **The mode-switch hazard (§3c iii) is not diagnosed down to a net.** It is reproduced,
  bracketed (passes at 3×, hangs at 4×) and attributed to the `lpbt_en` prescaler mux, but the
  exact stuck node in the reload/EOC logic was not traced.
- **Power-down and the ADCDIV pulse-width law were only spot-checked**, at the committed
  operating point (`adcdiv=165/adcpwsel=20`), not swept again under delay.

## 7 GHz margin sweep (added 2026-09-19, `tb_NDIV_TOP_v7_svt_0p5W_dly.vams +define+FGHZ=7.0`)

| scale | DFF clk→Q | TSPC ÷2 clk→Q | WuR | LPBT | lpbt_en 1→0 excursion |
|---|---|---|---|---|---|
| 1× | 50 ps | 30 ps | PASS | PASS | — |
| 2× | 100 | 60 | PASS | PASS | — |
| 3× | 150 | 90 | PASS | PASS | PASS |
| 4× | 200 | 120 | PASS | PASS | **FAIL (hang)** |
| 5× | 250 | 150 | **FAIL** | **FAIL** | — |

At 7 GHz T_VCO = 142.9 ps, so the front-end ÷2 limit moves from ≈5.7× (5.8 GHz) to ≈4.8×
(150 ps > 142.9 ps at 5×) and becomes the first steady-state failure in BOTH modes; the
`lpbt_en` mode-switch hang stays at 4×, unchanged. With the 1× placeholder table the block has
≥4× margin at 7 GHz. Committed 5-mode TB at 7 GHz on 1× delays: TB PASS.
