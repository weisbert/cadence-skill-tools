# verilog_helper — HANDOFF / design context

## SESSION CLOSE 2026-06-27c — WuR NDIV fully characterized + self-checking TB + report kit (all sim-verified)

**Task done: `NDIV_TOP_v7_svt_0p5W` (WuR NDIV) reproduced locally from the user's red-zone debug
dump and fully characterized; self-checking TB committed → `testbenches/tb_NDIV_TOP_v7_svt_0p5W.vams`.**
Local repro (gitignored): `examples/wur_ndiv/_ref/build/` (reconstructed `export/` via the dump,
`ext_stub/` for the COT cells, charac TBs). Truth table + laws: `examples/wur_ndiv/SPEC_CHECKLIST.md`.

**Reproduction method (reusable for the next red-zone dump):** the dump is NOT self-contained — it
carries `export/` (local cells) but leaves the red-zone COT std cells (`INVD1/ND2D1/NR2D1/INVD8/
DELAD1/DELBD1_COT_...`) to the `-v` libs. Wrote behavioral `ext_stub/*.vams` for them (port names
read straight off the struct instantiations; powerOK style copied from the provided BUFFD2/NR2D2).
xrun elaboration is the faithfulness check on the hand-reconstructed struct (undefined-net / port
mismatch fails loudly). `run.sh` globs `ext_stub/*.vams` + `export/*.vams`.

**WuR vs LPBT — same family, key differences (all sim-confirmed, VCO=4.8 GHz):**
- **`lpbt_en` is now a real control = the PRESCALER SELECT** for the 14-bit NDIV counter clock:
  `NDIVCKIN = mux_sel ? DIV4sig : DIV16sig`, `mux_sel = lpbt_en & ~cal_en`. So `lpbt_en=1`
  → NDIVCKIN=**VCO/4** (reproduces LPBT exactly, ADCDIV path off); `lpbt_en=0` (WuR) → **VCO/16**.
- **Divide law unchanged in form:** `OUT_NDIV = CLK2DSM = NDIVCKIN/(ndiv−1)`, `M=ndiv−1` (confirmed
  M=10..300). ⇒ WuR `OUT_NDIV = VCO/(16·(ndiv−1))`; LPBT-mode `VCO/(4·(ndiv−1))`.
- **pwsel/pulse-width law IDENTICAL in form to LPBT**, only the counting unit changed (NDIVCKIN, now
  VCO/16): `low = 2·floor(pwsel/2)−3` (NDIVCKIN cyc, pwsel[0] don't-care), `period=M`, `50% ⟺
  pwsel=(ndiv+5)/2` exact only `ndiv≡3 (mod4)`, `pwsel≥4` else stall. So the LPBT clamp carries over.
- **`cal_en` does NOT freeze NDIV here** (it did in LPBT): only turns on the `CLK2CNT=VCO/4` monitor.
- `TESTCLK_300M=VCO/16` when `en_test=1` (300 MHz). `CLK2DSM` lags `OUT_NDIV` ~2.07 NDIVCKIN cyc.

**OUT_ADCDIV — RESOLVED (programming constraint, NOT a bug; user's hunt nailed it).** First pass I
thought the 8-bit core output latched. User said "大概率是EOC_low没生效，检查 adcsel 怎么搞" — exactly
right. The 8-bit `EOC_low_short = nor3(nand12,d_low, nand(q6,q7b))` needs the count to reach **q6=1
(≥64), q7=0** to fire the falling edge (the 14-bit's EOC needs the high bits =0 — opposite polarity).
So `OUT_ADCDIV` only toggles when the count is big enough AND adcpwsel small enough. Swept law:
```
OUT_ADCDIV = VCO/(4·(adcdiv−1))                (lpbt_en=0; ADCDIVCKIN=VCO/4)
low(ADCDIVCKIN) = 2·floor(adcpwsel/2) + 62     (adcpwsel[0] don't-care; +62 offset vs NDIV's −3)
toggles ⟺ adcdiv ≥ 2·floor(adcpwsel/2)+64  (min adcdiv≈64) ; 50% ⟺ adcpwsel=(adcdiv−1)/2−62
```
adcdiv=165,adcpwsel=20 → M=164,low=82 → exact 50%, VCO/656 (verified). My earlier "stall" was just
adcdiv=51,adcpwsel=28 → low(=25+62=87) ≥ M(=50). The +62 offset is structural/count-driven (swept
the EOC delay cells 5..200 ps — unchanged), so it carries to the red zone; divide is fully robust.
The committed TB now **hard-checks OUT_ADCDIV** (divide + X-guard + 50% duty) at adcdiv=165/adcpwsel=20.

**Red-zone wiring (user owns):** drop `testbenches/tb_NDIV_TOP_v7_svt_0p5W.vams` (module `tb`) into
the build's `sim/` (replacing the trivial auto-gen TB) and `./run.sh` — its baked `-top tb` + `-v`
libs resolve the real COT cells; the TB references only top ports (no internal hier refs), so it is
netlist-robust. `+define+WAVES` for a SimVision dump. Expect all checks (NDIV/CLK2DSM/CLK2CNT/
TESTCLK/OUT_ADCDIV) PASS → `=== TB PASS ===`.

**Power-down covered:** added a `ndiv_en=0` MODE — asserts all five outputs are quiet AND clamped to
a clean logic 0 (`CKLO` macro: level `!== 1'b0` fails; catches a stuck-X that the edge-count `CKQ`
would miss — the old pdown tri-state-clamp X-bug class). PASS locally.

**TB final shape (5 modes, all hard-checked, local TB PASS 0-fail):** WuR-NORMAL / LPBT / CAL / TEST /
POWER-DOWN. The TB also emits `RPTINFO` (fvco + divide consts) and per-mode `MODEWIN <key> <start>
<end>` (ps) markers — consumed by the report tool to auto-zoom each mode. Op point: ndiv=51,pwsel=28
(OUT_NDIV 50%); adcdiv=165,adcpwsel=20 (OUT_ADCDIV 50%).

**Report kit shipped → `vh_wur_report.py`** (committed, the WuR analog of `vh_ndiv_report.py`): runs
`run.sh +define+WAVES`, parses the PASS/FAIL table per mode, captures 6 headless SimVision PNGs
(overview + the 5 modes) via Xvfb+PIL, writes `report/report.md` + path map + laws. Validated
end-to-end locally (TB PASS, 6 real screenshots, report.md). A self-contained kit
(`wur_ndiv_report_kit.tar.gz` = TB + tool + README_REPORT.md + SPEC + a dev-box sample report) was
handed to the user to run on the **red zone** (real COT cells) for the authoritative report — the
README spells out the steps + flags OUT_ADCDIV as the one thing to confirm with real cells.

**Open / next time:**
- **Pending: red-zone report run** (user is handing the kit to another Claude). Authoritative
  report.md + waveforms come from there. The ONE thing to confirm: OUT_ADCDIV toggles at
  adcdiv=165/adcpwsel=20 → VCO/656, 50% (should — the +62 offset is count-driven, swept stub delays
  5..200 ps unchanged — but real `DELAD1/DELBD1` is the final word). If it stalls there, real finding.
- Spec questions for the design owner (not TB issues): (a) +62 ADCDIV offset → usable `adcdiv ≥ ~64`;
  (b) `cal_en` not freezing NDIV in WuR mode, unlike LPBT.
- Commits this session: `147fc55` (TB+SPEC), `98cb311` (ADCDIV law), `ea26427` (power-down),
  `f415e44` (report tool + TB markers). Local mirror (gitignored): `examples/wur_ndiv/_ref/build/`.

---

## SESSION CLOSE 2026-06-27b — LPBT_NDIV pwsel↔Tclkin pulse-width law (sim-verified) → NEXT: WuR NDIV

**NEXT TASK (user, next conversation): verify a SIMILAR divider — "WuR NDIV" (wake-up-receiver
N-divider).** Expect the same shape of question (divide law + pulse-width/duty law) but DIFFERENT
constants/bit-widths — re-characterize, do NOT assume LPBT's numbers carry over. The method + a ready
harness are saved (see bottom of this section).

**What got nailed this session: the full `pwsel` → pulse-width mapping for LPBT_NDIV, ground-truthed
by sweeping the REAL struct (local xcelium 18.03), not just traced.** Counting unit
**Tclkin = NDIVCKIN = VCO/4** (the prescaler clock; the same unit `ndiv_var` counts in).
Define `ndiv_var = sim_ndiv_var − 1 = M` (= OUT_NDIV period in Tclkin). Then:

```
OUT_NDIV low  = pwsel − 3   (Tclkin)        [pwsel even]
OUT_NDIV high = (ndiv_var) − (pwsel − 3)
period        = ndiv_var     (independent of pwsel — pwsel only moves the falling edge)
duty(high)    = (ndiv_var + 2 − pwsel) / ndiv_var
50% duty      ⟺  pwsel = ndiv_var/2 + 3   (== (sim_ndiv_var+5)/2)
```
Verified exact on real netlist for M ∈ {10,34,50,98} → 50.00%; operating point M=50 → pwsel=28. ✅

**Quantization — `pwsel[0]` (LSB) is don't-care (悬空):** only `pwsel[5:1]` feed the decode muxes
(`mux2_q5..q1 .S(d_ndiv_pw_sel[5..1])`). So every even/odd pair collapses: `{4,5}→low1, {6,7}→3,
{8,9}→5,…` — achievable low is **odd only**, step 2 Tclk. Exact form: `low = 2·floor(pwsel/2) − 3`.
Consequence: exact 50% only when `(ndiv_var)/2` is an **odd** integer, i.e. **`ndiv_var ≡ 2 (mod 4)`**
(= register `ndiv ≡ 3 mod 4`); else nearest, off by `1/ndiv_var` (M=48→52.08%, verified).

**Low-end stall:** `pwsel ≤ 3 → low ≤ −1` → OUT_NDIV does not toggle (no edges). Min usable `pwsel=4`
(low=1). So formula needs `ndiv_var ≥ 2`.

**Corner-tab expression (ADE/SKILL), for ~50% with a clamp:**
```
pwsel = min( ndiv_var/2 + 3, 63 )
```
- `ndiv_var` = the `sim_ndiv_var − 1` variable. SKILL `/` is integer-truncating → result is integer;
  `round(ndiv_var/2.0)+3` if you want it parse-robust. `min()` is a SKILL builtin (OK in corners).
- **Upper limits (two distinct ones, both verified):** `pwsel` is `[5:0]` → 0–63. (a) **6-bit overflow**
  at `M/2+3 ≥ 64` ⟺ `M ≥ 122`: e.g. ndiv=127 → formula 66, `66&0x3F=2` → **STALL** (no edges) if not
  clamped. (b) **Earlier physical saturation**: low maxes at **59** (pwsel 62/63), so 50% is
  **unreachable for M > 118**. Clamp prevents the stall but does NOT hold 50%: M=120→50.8%,
  M=126→53.2%, M=254→76.8% (all measured). So: to keep ~50% across a sweep, **cap the ndiv sweep at
  ndiv≤119, not just clamp pwsel** — the clamp is a don't-crash net, not a duty fix.

**Decode mechanism (for re-deriving WuR's law):** in `pll_ndiv_mmd_8bit`, `EOC_low_short =
NOR3( nand(q2sel,q1sel), nand3(q3sel,q4sel,q5sel), nand(q6b,q7b) )`, where `qNsel = mux(qN, qNb,
S=pwsel[N])`. So `pwsel` bit-matches the prescaler counter `q1..q5` (needs `q6=q7=0`); the match count
is where the output's falling edge fires → `low` is linear in `pwsel`, and the counter-bit count (5
here) sets the saturation ceiling (`2·(2^5−1)−3 = 59`). WuR will have its own widths → its own
offset/ceiling; trace the analogous `EOC` NOR and the pw-sel mux fan-in.

**Reusable harness saved (local, gitignored):**
`examples/lpbt_ndiv/_ref/build_afterfix/charac/` — `tb_pwsweep.vams` (consecutive pwsel sweep, shows
even/odd collapse), `tb_dutylaw.vams` (validates `pwsel=ndiv_var/2+3` across divide words),
`tb_clamp.vams` (large-M overflow/saturation), `run_charac.sh <tb_name>` (globs `../export/*.vams` +
`../ext_libs/*.vams`, NORM-mode, measures OUT_NDIV low/high in Tclkin). Clone the dir next to WuR's
build, drop in WuR's struct, re-point, re-run. Method: drive NORM, sweep, measure low/high vs the
input (prescaler) clock period — read the offset/ceiling straight off the table.

**Open / next time (nothing blocking):**
- WuR NDIV: re-characterize divide + pwsel/duty law (don't reuse LPBT constants). Harness above.
- (optional) fold `pwsel = min(ndiv_var/2+3,63)` + the `ndiv≤119` caveat into the committed
  `testbenches/tb_LPBT_NDIV_TOP.vams` header (currently only documents the single 50% point).

---

## SESSION CLOSE 2026-06-27 — pdown X-bug found+fixed, Stage A `external_file/`

**Headline: a real DESIGN model bug was caught by the waveform.** The user saw `OUT_NDIV`,
`CLK2CNT`, `TESTCLK_300M` render **red/X on their active phase** in SimVision while the TB still
said `=== TB PASS ===`. Root cause = the `pll_ndiv_pdown` power-down CLAMP model. Each chip output
is driven by TWO things on one net: the real inverter buffer **and** a `pdown` clamp (instances
I151/I71/I153/I152, `.IN(power_en_b)` / `enb_test`). A shared-net clamp MUST be **tri-state**:
pull `0` only while clamping, else release to **high-Z**. The model instead did `reg Z; initial
Z=1'bx;` and on the `IN==0` branch (all of normal operation, since `power_en_b=0` — probed) **never
reassigned Z** → it drove a constant `1'bx` onto the shared net forever → the real buffer could not
win → output = X. The timing checks PASS anyway because `@(posedge)` fires on `0→x` too, so period/
duty still measure — **the waveform exposed it, the PASS line hid it.**

**FIX (verified, local xcelium 18.03, probed 4-state levels before/after):** make `Z` tri-state —
```
always@(*) begin
  if (!powerOK)        Z = 1'bx;   // bad supply
  else if (IN==1'b1)   Z = 1'b0;   // clamp ACTIVE -> pull low
  else                 Z = 1'bz;   // clamp RELEASED -> high-Z, real driver wins   <-- the fix
end
```
After: `OUT_NDIV=1`, `CLK2CNT=1`, `CLK2DSM` toggles, no X; `=== TB PASS ===` unchanged. Scanned all
gathered cells — **`pll_ndiv_pdown` is the ONLY one with this "init-x, never-release" anti-pattern**
(`power_sw` etc. are single-driver, fully assigned, fine). This is the cell's own behavioral model
(Stage A gathers it as-is; `vh_convert` does NOT generate it — it would flag `if/always/#delay`), so
it is a **design-model bug, NOT a tool bug** — same class as the earlier nor4 fix.
- Local mirror updated: `examples/lpbt_ndiv/_ref/build_afterfix/export/pll_ndiv_pdown.vams` (gitignored).
- **RED-ZONE TODO (user owns):** apply the same tri-state fix to `pll_ndiv_pdown`'s verilogams view in OA.
- Refreshed report package (4 clean SimVision PNGs, no X + table + verdict) was regenerated on the
  FIXED build and handed to the user as a tar.

**Tool change shipped (commit `2b88403`): Stage A writes `external_file/`.** Extract A now creates
`external_file/` next to `export/` and copies in the external `-v`/`-y` model sources the design
actually instantiates (resolved via the remembered ext env). One copy per source file; unresolved
externals are skipped with a warning (Stage C still stubs them). Recorded in `manifest_A.json`
(`external_files`) + the Stage A summary. Built into `extract()`, not a post-step (the earlier
bolt-on `vh_collect_ext.py` was removed). So a build dir now holds every Verilog the design needs:
`export/` (local) + `external_file/` (external). Snapshot reflects the machine where Extract A runs —
point the ext env (`vh_env.py add-lib`) at real paths where they exist for a complete copy.

**TB X-guard ADDED (this session).** `testbenches/tb_LPBT_NDIV_TOP.vams` now has a `CKX` check:
every rising edge of an active clock must land on a clean logic `1` (`xc[i]` counts edges whose
new level `!== 1'b1`, reset per window by `RST`). Run for the active clock in each mode (CAL:
CLK2CNT; TEST: TESTCLK/OUT_NDIV/CLK2DSM; NORM: OUT_NDIV/CLK2DSM). Validated BOTH ways: fixed build →
all `CKX PASS`, `=== TB PASS ===`; broken (held-X) pdown → all 6 `CKX FAIL`, `=== TB FAIL (6) ===`
(the bug that used to pass silently now fails). Note: targets the X-HIGH-on-active-clock failure
mode; a constant-X *quiet* signal is still only covered by `CKQ` (edge count), a known limitation.

**Open / next time (nothing blocking):**
- Red-zone: apply the pdown tri-state fix in OA, re-run, regenerate authoritative screenshots.
  (The TB X-guard will now hard-FAIL there too if any output is still X.)

---

## SESSION CLOSE 2026-06-26 — HEAD `a3634da`, all pushed + deployed-ready

**Where we are (LPBT_NDIV is GREEN).** The div2 wreal-supply fix is validated end-to-end on the
REAL netlist (local xcelium 18.03) AND confirmed on the red zone (xcelium 19.04): default
`bash run.sh` → `=== TB PASS ===`, FUNCTIONAL. The user fixed the `nor4_svt_x2` model (added the
4th input). The TB now runs at the real operating point and HARD-checks everything (details in §00):
- VCO **4.8 GHz**, `ndiv=51`, `pwsel=28` → OUT_NDIV/CLK2DSM = **24 MHz**, OUT_NDIV **50% duty**.
- CAL `CLK2CNT=VCO/4` (1.2 GHz), TEST `TESTCLK_300M=VCO/16` (300 MHz). All PASS.
- 50%-duty law: `pwsel=(ndiv+5)/2` with `ndiv≡3 (mod4)`. SDMOUT lags OUT_NDIV a fixed 8.5 VCO.

**Tools added this session:** `vh_ndiv_report.py` (per-mode PASS/FAIL table + path map + 4 genuine
SimVision waveform screenshots, headless via Xvfb+PIL; red-zone usage in RED_ZONE.md).
`vh_dump_debug.sh`/`vh_undump_debug.py` (air-gap text round-trip — how the real design got mirrored
locally at `examples/lpbt_ndiv/_ref/` (gitignored): `real_dump_afterfix.txt` + `build_afterfix/`).

**A report package was handed off** (tar with CONTEXT + table + sim results + 4 PNGs) for an external
AI to write the verification report.

**Open / next time (nothing blocking):**
- To get *authoritative* (red-zone, real-model) waveform screenshots, deploy and run
  `python3 vh_ndiv_report.py --sim .` in the red-zone sim dir. The local mirror uses 2 synthesized
  stand-in cells (inv_lvt_x2 = copy of inv_lvt_x4; INVD1 = `assign ZN=~I`); on the red zone these
  are the real PDK cells. Verdict + waveforms were confirmed identical local↔red for the divide path.
- If the report needs more operating points, sweep `NDIV_TEST` (keep `ndiv≡3 mod4` for exact 50%);
  `vh_ndiv_report.py` zoom windows auto-scale to VCO freq + divide.
- The local `build_afterfix/sim2` has a duty/phase-instrumented TB copy; the *committed*
  `testbenches/tb_LPBT_NDIV_TOP.vams` is the clean source of truth.

---


## 00. VALIDATED END-TO-END ON THE REAL DESIGN (2026-06-26) ✅ — RED ZONE CONFIRMS LOCAL

**CONFIRMED ON THE RED ZONE (2026-06-26 18:32, xcelium 19.04): default `bash run.sh` →
`=== TB PASS ===`, FUNCTIONAL, 0 errors — BIT-FOR-BIT the same verdict, the same WARNs, and the
same `CLK2DSM live (111 edges)` as the local xcelium-18.03 repro. The local mirror is faithful
(xcelium 18.03 vs 19.04 and the local `INVD1` stub vs the real `ideal_model` make no difference
to this result). Expected/harmless red-zone warnings: `*W,CUVWSI` ×4 (div2 I7/I9 VDD/VPP/VSS
unconnected — CORRECT, converted div2 is supply-less/always-on) and `*W,LIBNOU` ×5 (only
`L20_SVT_ana`'s INVD1 is used of the 6 `-v` libs).**

**ROOT CAUSE of the OUT_NDIV "no edges" FOUND + FIXED IN SIM (2026-06-26, in-module $display probe
on the real after-fix netlist):** it is a **TB `pwsel` (`d_ndiv_pw_sel`) stimulus bug**, not div2 /
nor4 / the tool / the PLL loop. Chain: `OUT_NDIV = clk_to_PFD` (buffered) = `mmd_core.DFF_out.Q`,
`D=E_pfd`. `E_pfd` is held at 1 because `E_b = nor(EOC_low, lock)` is stuck at 1: `lock=~clk_to_PFD`
is a slave, and **`EOC_low` (end-of-count → PFD) never pulses**. `EOC_low_short = nor(nand12, d_low,
B)` fires only at ONE counter state, and WHICH state is selected by `pwsel` (each `qNsel =
mux(qN,qNb,pwsel[N])`). The TB hard-coded a GUESS `pwsel=6'b000010`, which decodes counter state
`0000001` (q1=1 alone) — but with `ndiv=10` the modulus counter cycles `5→4→3→2→reload→5` and
**never visits state 1** → EOC never fires → `clk_to_PFD` latches at 1 → OUT_NDIV stuck high.
**FIX (proven):** set `pwsel` so the decoded state IS visited for that `ndiv`. `pwsel=6'b001010`
(decodes state 5) → `clk_to_PFD` toggles, and `+define+CHECK_NDIV` → `OUT_NDIV = VCO/36 (measured
VCO/36.00)`, `=== TB PASS ===` (strict, all green). OPEN: `pwsel` is a real chip input that must
pair with `ndiv`; `001010` is a verified-valid value for ndiv=10, but the TB should use the chip's
ACTUAL pwsel↔ndiv mapping (ask the designer). Once known: bake it into
`testbenches/tb_LPBT_NDIV_TOP.vams` and promote OUT_NDIV/CLK2DSM from CKWARN to hard CKR.

**OUT_NDIV DUTY-CYCLE LAW (derived from structure, confirmed by sweep 2026-06-26):** OUT_NDIV =
`clk_to_PFD` reclocked on NDIVCKIN(=VCO/4); output period = `(ndiv-1)` NDIVCKIN cycles. `pwsel`
sets which counter state fires EOC = the FALLING edge position; the 3 `reload` pulses hold it high
a fixed ~3-cycle tail. Empirical fit (exact at every point):
  low(NDIVCKIN)  = pwsel - 3
  high           = (ndiv-1) - (pwsel-3) = ndiv+2 - pwsel
  duty           = (ndiv+2 - pwsel) / (ndiv-1)
  => 50% duty  <=>  **pwsel = (ndiv+5)/2  AND  ndiv % 4 == 3**
pwsel bit0 is UNUSED so low quantizes to ODD NDIVCKIN counts (low=2*floor(pwsel/2)-3); exact 50%
needs (ndiv-1)/2 to be an odd integer => ndiv == 3 (mod 4). (Earlier "odd ndiv" was too loose:
ndiv=13,17,21 give 55-58%, NOT 50%; ndiv=11,23,43,83 give exactly 50%.) VERIFIED: ndiv=83->pwsel44
->50.0%, ndiv=11->pwsel8->50.0%. User's first guess pwsel=ndiv/2 divides right but gives 60-89%
duty (the +2.5 reload-tail offset is why).
PHASE: CLK2DSM(SDMOUT) rising edge lags OUT_NDIV rising edge by a FIXED **8.5 VCO = 2.125 NDIVCKIN
cycles** (1700ps), zero jitter, independent of ndiv (23/43/83 all 8.5 VCO) -- structural, set by
the reload tail.
DONE: `testbenches/tb_LPBT_NDIV_TOP.vams` defaults to the real operating point: **VCO=4.8 GHz**
(TVCO=1000/4.8 ps, timescale 1ps/1fs), **ndiv=51 -> D=200 -> OUT_NDIV=24 MHz**, pwsel=(ndiv+5)/2=28
(51==3 mod4 -> exact 50% duty). HARD-checks (unconditional, no +CHECK_NDIV / no CKWARN): CLK2CNT=
VCO/4 (1.2 GHz), TESTCLK_300M=VCO/16 (300 MHz, matches cell name), OUT_NDIV/CLK2DSM=VCO/200,
OUT_NDIV duty 50%+/-3pp; prints a FREQ line. SETTLE/WIN scale with D_GOLD. Validated: `bash run.sh`
-> all PASS, FREQ "VCO=4.800 GHz -> OUT_NDIV=24.000 MHz", `=== TB PASS ===`.
REPORT TOOL: `vh_ndiv_report.py` -> report/report.md (per-mode table + path map) + 4 genuine
SimVision screenshots captured headless (Xvfb+PIL); zoom windows auto-scale to VCO freq + divide.

**CORRECTION to an earlier claim in this section (do not trust the struck-through line below):**
the user fixed the `nor4_svt_x2` model (added the 4th input `D`; `I281.D(reload1)` now connected;
red-zone `nor4_svt_x2` compiles 0/0) — but that fix did **NOT** make `OUT_NDIV` toggle. Under
`+define+CHECK_NDIV`, `OUT_NDIV` is STILL "no edges" on BOTH the red zone (WARN) and locally
(2 FAIL). So `OUT_NDIV`'s deadness is **not** the nor4 dropped pin: it is the mmd `clk_to_PFD`
(PFD-feedback DFF `DFF_out`) simply not running under a *standalone divider* stimulus with no real
PLL loop / reset sequence. The TB already classifies OUT_NDIV/CLK2DSM as soft WARN, which is why
the default run PASSES. Making OUT_NDIV a HARD pass is a separate effort (drive the PFD/reload
loop or change the stimulus) — it is NOT a div2, nor4, or verilog_helper issue.

**The full pipeline (A-output → Convert B → Generate C → xrun) was run locally on the REAL
LPBT_NDIV netlist and the div2 fix is PROVEN. Canonical verdict (no defines): `=== TB PASS ===`,
RUN-KIND FUNCTIONAL (all externals resolved, zero stubs).** After-fix design saved local-only at
`examples/lpbt_ndiv/_ref/real_dump_afterfix.txt` (+ reconstructed `build_afterfix/`).

~~fixing the nor4 model is what will let `+define+CHECK_NDIV` go fully green on OUT_NDIV~~ ← WRONG, see correction above.

How it was reproduced off-site (recipe, repeatable):
1. The real build was dumped on the red zone with `vh_dump_debug.sh` → one .txt (28 files: 25
   leaves + struct + sim glue). That .txt is in the session transcript; reconstruct with
   `python3 vh_undump_debug.py <dump.txt> <build>` → `<build>/export/` + `<build>/sim/`.
2. Two cells the *minimal* dump omitted were supplied locally (both trivial inverters):
   `pll_ndiv_inv_lvt_x2` = copy of `inv_lvt_x4` renamed (a design leaf Stage A would have
   gathered); `INVD1_COT_H462SDB_L20P108_SVT_ana` = `assign ZN=~I` in a local `-v` lib
   (`ext_libs/ideal_model.vams`), mirroring Common_verilog/. Then design = 32 modules, 100
   instances, FULLY resolved.
3. Synthesized a `manifest_A.json` (each `export/*.vams` leaf: src=gathered=itself) so Convert B
   overwrites in place exactly like the GUI pipeline, then ran B → C → `bash sim/run.sh`.

Results (XCELIUM1803):
- **Stage B**: `pll_ndiv_div2_tspc` → CONVERTED, `power_on = (1'b1)&&(1'b1)`. All 24 std cells →
  DIGITAL (logic supplies, no wreal → correctly left untouched). Exactly right.
- **Stage C**: FUNCTIONAL — `INVD1` resolved via `-v`, **zero auto-stubs**.
- **xrun, default (no `+define+CHECK_NDIV`) → `=== TB PASS ===`:**
  - CAL `CLK2CNT = VCO/4` **HARD PASS** (was "no edges" before the div2 fix).
  - TEST `TESTCLK_300M = VCO/16` **HARD PASS** (was "no edges" before).
  - `CLK2DSM` **LIVE, 111 edges**; under `+define+CHECK_NDIV` it measures **VCO/36 exactly**
    (ndiv=10 → VCO/4/9) → the mmd divider core works.
  - `OUT_NDIV` soft **WARN** (not toggling) — the only remaining gap.

**The lone remaining gap (`OUT_NDIV` no edges) is NOT div2 and NOT the converter.** OUT_NDIV taps
the mmd `clk_to_PFD` output = `mmd_core.DFF_out` with `.D(E_pfd) .Q(clk_to_PFD) .clk(clk)`. E_pfd
is built via `E_pfd_b = nor4_svt_x2 I281(.A(E_b),.B(reload3),.C(reload2), <BLANK>)`. The model
`pll_ndiv_nor4_svt_x2(Y,A,B,C,…)` is only **3-input** (`Y = ~(A|B|C)`), and the instance's **4th
input pin is DROPPED** — struct line ~253 is a literal blank inside the port map (the ONLY
dropped pin in the entire netlist, and it sits squarely in OUT_NDIV's enable path). This is a
**cell-model / oa2verilog extraction-fidelity defect on the user's side**: the `nor4_svt_x2`
verilogams model needs its 4th input `D` (`Y = ~(A|B|C|D)`) so the symbol's 4th pin stops being
dropped. The TB already classifies OUT_NDIV/CLK2DSM as soft WARN (front-end VCO/4 & VCO/16 are
the HARD checks), so the run PASSES today. [SUPERSEDED: I originally guessed fixing the nor4
model would make `+define+CHECK_NDIV` green on OUT_NDIV — it did NOT; see the CORRECTION at the
top of §00. The dropped pin was a real model defect worth fixing, but it is not why OUT_NDIV is
quiet.]

Caveat noted for whoever continues: hierarchical `always @(dut.<net>)` probes INTO the AMS DUT
proved unreliable (connect-boundary; `dut.CLK2DSM` showed 1 toggle while the TB's own top-level
`CLK2DSM` wire correctly saw 111). Trust TB-port-level measurements, not deep hier probes, in
`-ams`.

**NEXT:** (a) On the red zone, run the SAME thing the GUI does — Extract A → Convert B → Generate
C → Run — and confirm `=== TB PASS ===` (default). The earlier red-zone DEAD result was the
Convert-B-not-run process gap (see §0a), now closed by validation here. (b) To close OUT_NDIV,
fix the `nor4_svt_x2` cell model's missing 4th input. (c) Optional UX: have Generate C auto-run
Convert B (or warn) when `export/` still holds an unconverted wreal-monitor leaf.

---

## 0a. (SUPERSEDED by §00 — kept for history) RESUME HERE (2026-06-26 late) — HEAD = `582e6ca`, all pushed + DEPLOYED to red zone

**State: the real NDIV elaborates clean & FUNCTIONAL, but the clock is still DEAD because
`div2_tspc` in `export/` is STILL RAW — Stage B (Convert B) did not run/take this round.**
The code is proven correct: running `vh_convert.py` on the EXACT real `pll_ndiv_div2_tspc.vams`
(verbatim in `examples/lpbt_ndiv/_ref/real_dump.txt`, gitignored) → `CONVERTED`,
`power_on = (1'b1)&&(1'b1)`. So this is a PROCESS gap, not a code bug.

**NEXT STEP (next session):** make sure Stage B actually runs in the GUI pipeline:
**Extract A → Convert B → Generate C → Run** (the user likely skipped B, or it didn't overwrite
export/). Verify after B: `grep power_on <build>/export/pll_ndiv_div2_tspc.vams` must show
`(1'b1)&&(1'b1)`, not `(VDD-VSS)`. Then expect CAL `CLK2CNT=VCO/4` + TEST `TESTCLK=VCO/16` HARD
PASS. Consider a UX fix: have **Generate C auto-run Convert B** (or warn) when export/ still has
an unconverted wreal-monitor leaf — converting is REQUIRED for correctness here, not optional.

**Full real design is captured** (the user dumped it via `vh_dump_debug.sh`, VERSION 582e6ca):
the 25 leaf cells + struct + TB are in the conversation transcript; key analysis + div2 verbatim
in `examples/lpbt_ndiv/_ref/real_dump.txt`. Findings:
- **Only `div2_tspc` is the problem**: it is the ONLY wreal-supply cell, and its supplies are
  UNCONNECTED at the instances (`I7 (.CLK(fromVCO),.Q(net058))`) → wreal floats to 0 → gate
  false → dead. Convert it → clean /2.
- **Every std cell (inv/nand/nor/tff/dff/mux/delay/pdown/power_sw) also power-gates** on
  `(VDD-VSS)>=k`, BUT with LOGIC supplies (no wreal) that ARE connected → `(1-0)>=k=1` → they
  work. NOT a problem; do NOT touch them.
- **2nd worklib `div2_tspc` def** = a `-v` lib twin: run.sh passes `-v ideal_model.vams` (+ 5
  more Common_verilog libs); `ideal_model.vams` likely also defines `pll_ndiv_div2_tspc`. The
  instances bind export's (raw) div2, so the twin is harmless noise — but TO CONFIRM, ask the
  user: `grep -l pll_ndiv_div2_tspc <Common_verilog>/ideal_model.vams`. (vh_gen dedups within
  --src only, not vs -v libs; a cross-`-v` dedup/warn could be a follow-up.)
- mmd_core interface now matches mmd_8bit (#28 fixed) → mmd path should run once NDIVCKIN
  toggles. `nor4_svt_x2 I281` drops pin `D` → may perturb the EXACT N (watch under +CHECK_NDIV).
- Externals: lone resolved `-v` = `INVD1_COT_H462SDB_L20P108_SVT_ana` (power_en_b=INVD1(ndiv_en)).
- Air-gap debug round-trip is now scripted: `vh_dump_debug.sh` (red zone, files→one .txt into
  the build dir, minimal repro set) + `vh_undump_debug.py` (here, .txt→files). Both DEPLOYED.

## 0b. SESSION HANDOFF (2026-06-26)  — HEAD = `0c3f48f`+, all pushed

**ROOT CAUSE FOUND + FIXED (real run, red zone xcelium 19.04): the whole NDIV clock tree was
DEAD** — even the front-end taps `CLK2CNT=VCO/4` and `TESTCLK=VCO/16` (which do NOT touch
mmd_core) showed `no edges`. Cause: `pll_ndiv_div2_tspc` (the /2 TSPC prescaler, instances I7/I9
feeding DIV4sig) is a flop **gated by a wreal supply-headroom check** `((VDD-VSS)>k)&&((VPP-VSS)>k)`,
and the struct netlist instantiates it with **no supply connection** (`I7 (.CLK(fromVCO),.Q(net058))`
— rails are global/inherited, `oa2verilog` drops them). Wreal rails float → `power_on=0` → `Q` stuck
→ DIV4sig dead → everything hanging off it dead. **NOT #28.** Fix: Stage B now recognizes the
supply-DIFFERENCE / headroom threshold form (`(SUP±SUP)<cmp>k → 1'b1`, was only `(SUP<cmp>k)`), so
div2_tspc converts to a clean `always @(posedge CLK) Q<=~Q;` /2 divider. Reproduced + verified in
`examples/wreal_prediv/` (`./run.sh`=PASS CLKOUT=VCO/4, `./run.sh raw`=dead).

**NEXT FOCUS (resume here): re-run the real export through Stage B → C → Run.** On the GUI:
**Convert B** (now converts div2_tspc) → **Generate C** (Example TB dropdown =
`lpbt_ndiv/tb_LPBT_NDIV_TOP.vams`) → **Run** blank → expect CAL `CLK2CNT=VCO/4` + TEST
`TESTCLK=VCO/16` **HARD PASS** and `OUT_NDIV/CLK2DSM` now **WARN-live**; then defines
`+define+CHECK_NDIV` → `OUT_NDIV=VCO/4/(ndiv−1)`. (Watch `nor4 D`-drop perturbing exact N.) The
real div2_tspc + full struct are saved in gitignored `examples/lpbt_ndiv/_ref/`.

The real design `Hi1108_BT_LP_PLL_ANA.LPBT_NDIV_TOP` extracts CLEAN and ELABORATES (mmd_core fixed,
counter no longer stubbed). The hand-written real TB is verified locally vs the good-model
(`./run.sh` and `+define+CHECK_NDIV` → both `=== TB PASS ===`, VCO/4 + VCO/16 + VCO/36). Wiring it
to the real netlist is a **GUI click-flow** (no CLI). Open Verilog Helper and:
1. **Output folder** = the extract dir (the one with `export/`; pointing straight at an `export/`
   dir also works — Stage C falls back from `<out>/export` to `<out>`).
2. **Example TB (Stage C)** dropdown → `lpbt_ndiv/tb_LPBT_NDIV_TOP.vams` (auto-discovered from
   `examples/<x>/tb_*.vams`; grows by itself). Leave "user testbench" blank (it overrides the dropdown).
3. **Generate C** → builds `<out>/sim/` (real TB + run.sh wired to the real `export/` netlist).
4. **Run xrun** with the **xrun defines (Run)** box BLANK → generic smoke; expect CAL `CLK2CNT=VCO/4`
   + TEST `TESTCLK=VCO/16` **HARD PASS**. Read RUN-KIND + whether `OUT_NDIV/CLK2DSM` are WARN-live
   (should be live now that mmd_core is connected) vs WARN-dead.
5. Then put `+define+CHECK_NDIV` (and `+define+WAVES` for SimVision) in that box → functional N check
   `OUT_NDIV = VCO/4/(ndiv[7:0]−1)`. Waves land at `<out>/sim/ndiv.shm` → `simvision <out>/sim/ndiv.shm &`.
   Watch the `pll_ndiv_nor4_svt_x2` `D`-drop (could perturb the exact N); `M=ndiv−1` is user spec.

**How the defines reach xrun:** the generated `run.sh` now forwards `"$@"`; the GUI [Run] appends the
defines field; `./run.sh +define+...` works from the CLI too. Blank field = the generic completeness
smoke run (unchanged default — top auto-detected, `-access +rwc` always on so WAVES probes work).
The example's own `examples/lpbt_ndiv/run.sh` (vs the **good-model**, for TB mechanics) takes the same
`+define+...` args: `./run.sh +define+CHECK_NDIV +define+WAVES`, `+define+BREAK_NDIV` for negative self-test.

TB design (all CONFIRMED from the real struct's clock tree): front-end `fromVCO→div2→div2 =
VCO/4` prescaler; CAL `cal_en=1`→`CLK2CNT=VCO/4`, OUT_NDIV/CLK2DSM/TESTCLK quiet; TEST
`en_test=1`→`TESTCLK=VCO/16`; NORM→`OUT_NDIV=CLK2DSM=VCO/4/M`, `M=ndiv−1`. `pwsel`=duty (NC bit0),
`lpbt_en` NC. Spec in `examples/lpbt_ndiv/SPEC_CHECKLIST.md`; netlist notes in gitignored
`examples/lpbt_ndiv/_ref/`.

**This session's commits (all real-design-driven, each cloned+verified locally first):**
- `1b05f23` LPBT TB netlist-exact (period-ratio; CAL/TEST taps are real checks pre-#28).
- `e8f3223` vh_diag **SUSPECTED WRONG-VIEW** section (reads manifest reconciled_ports + per-lib views).
- `b903ad6` **#28 SOLVED = cross-LIBRARY collision**: `pll_ndiv_mmd_core` exists in BT_LP (design)
  AND `Hi1107c_GNSS_PLL_ANA`; Stage A grabbed GNSS. Fix: descend/gather by config-bound
  `(lib,view)` + `_lib_pref` (config liblist → design lib → rest). `config_bindings` now keeps the
  lib (was discarded). Works even w/o config (design lib preferred).
- `10836da` reconcile flags **FUNCTIONAL pin drops** loudly (real: `div2_tspc.en`, `nor4.D` = your
  model/symbol mismatch, tool can't invent the logic).
- `beaeb87` `vh_gen` **auto-detects the --tb top module** (GUI passes no --tb-top) → real TB runs from GUI.
- `ae13ccd` a **config view in --view redirects** to its design schematic + adopts its expand.cfg
  (oa2verilog can't open a config cellview → OAVLG-1007). `--view` is only the top-netlist view.
- `9da84e5` export layout: **`orig/`** (pristine copies, diff vs export/) + **`_work/`** (the `_sub_*.v`
  descend intermediates, out of the build root).
- `8dfd219` Stage B converts a **wreal supply/enable MONITOR → logic** (WuR_XO_output_driver:
  `OUT=(supplies_ok&&en_high)?IN:0` with wreal `en` → CUNDCM; → `OUT=en?IN:0`). Fixture
  `examples/wreal_monitor/`.
- `04ad553` NDIV TB **`+define+WAVES`** gate → `$shm_open/$shm_probe("AS")` → `ndiv.shm` (SimVision);
  example `run.sh` adds `-access +rwc` only when WAVES set (default path byte-identical).
- `4da6194` **generated `run.sh` forwards `"$@"`** to xrun → real-design builds take
  `+define+CHECK_NDIV` / `+define+WAVES` (GUI [Run] passes none → unchanged); also cleans `*.shm`.
- `0c3f48f` **GUI no-CLI workflow**: `vh_exampleTBs()` auto-discovers `examples/<x>/tb_*.vams` →
  "Example TB (Stage C)" dropdown (resolved via `vh_exTbMap` → `--tb`); Stage C src falls back
  `<out>/export`→`<out>`; new "xrun defines (Run)" field forwarded to `run.sh`. Live-verified on
  the running Virtuoso (instantiate only, no hiDisplayForm).

**SIDE THREAD — WuR_DIG_REFBUF_TOP_H1 (paused):** extracts clean now (config-view fix). Was
blocked on the wreal `en` CUNDCM → Stage B monitor conversion (8dfd219) is the fix. **WuR NEXT:**
run Convert B → Generate C → Run, confirm CUNDCM gone; check `manifest_B.txt` for any other
FLAGGED wreal cells on the XO path (wreal used as a value → not auto-converted, needs your semantics).

**Process (locked, followed all session):** observe via vh_diag → CLONE the failure in a LOCAL
fixture against local xrun (18.03) → fix+verify there → red zone = final check only. Regression =
9 examples + 3 duts (scratchpad `regress.sh`, drives Stage A/B/C+xrun). Solo repo → commit+push when done.

---

## 0. STATUS (2026-06-25)

**The whole pipeline AND the GUI are built, verified, and pushed.** Stages:
- **A** `vh_extract.py` — OA config (cds.lib+expand.cfg) → oa2verilog hierarchy → clean
  wreal structural top + gathered `.va` leaves + `manifest_A.json`. ✅
- **B** `vh_convert.py` — analog cell → wreal (detection list + non-destructive
  `veriloga_wreal.va` candidate beside each cell). ✅
- **C** `vh_parse.py`+`vh_gen.py` — TB + stubs + `run.sh` (+ `--tb` for your own test). ✅
- **D** `vh_package.py` — relocatable, env-agnostic air-gap bundle + preflight + tar/sha256. ✅
- `vh_env.py` — remembered external `-v` library env. ✅
- `vh_dut.py` — **multi-DUT driver** (one folder per DUT, `run-all` summary). ✅
- **GUI** `vhGui.il` (+ `verilog_helper.il` loader) — thin SKILL launcher under
  **MyTool → Verilog Helper**: select-from-schematic + Lib/Cell/View picker +
  **[Scan Pins]** (terminals → name/dir/bus to a **preview popup** + clipboard +
  `<out>/<cell>_pins.txt` + CIW) + `[Extract A][Convert B][Generate C][Run xrun][Package D]`
  + **[External libraries...]** (multi-entry manager popup: several `-v`/`-y`/`+incdir`,
  Save/Reload/Clear → remembered env via `vh_env import/export`, AMS-Options-style); each
  action button `system()`-shells out to a `vh_*.py` CLI (or `bash run.sh` for Run),
  **in the BACKGROUND** (button returns at once, Virtuoso stays responsive, Status shows
  a live `running Ns…` counter + final result via a poll timer — no frozen-UI/looks-hung).
  **Input simplification:** cds.lib is auto-written from the live OA lib list
  (`ddGetLibList`+readPath), and expand.cfg is optional (standalone lib+cell, or
  auto-found config view) → minimal input is **pick DUT + Output**. ✅
- **Passives** (Stage A) — analogLib 2-terminal `res/cap/ind` on a signal net are
  removed from the path: **series → shorted** (nets merged), **shunt-to-gnd → opened**;
  non-2-terminal/bus skipped+warned; listed in `manifest_A` `PASSIVES`. So `net → ind
  → next cell` is handled (signal passes through), and the old multi-passive shared-stub
  collapse is gone. ✅
- **Real config-based hierarchy** (Stage A) — validated on a REAL design
  (`Hi1108_BT_LP_PLL_ANA/LPBT_NDIV_TOP`, a PLL N-divider): gathers behavioral leaves from
  `veriloga`/**`verilogams`**/`ahdl` view dirs (file may be `verilog.vams`), **recursively
  descends** sub-blocks whose schematic is a `cmos_sch`/nested-config view that
  `oa2verilog -view schematic` won't follow (`expand_hierarchy`, ordered by config
  viewlist), resolves std cells via the remembered `-v` libs, drops `noConn` + parasitic
  diodes (`DEVICE_DROP`), dedups, handles array instances `I[1:0]`, and gathers leaves
  **across multiple libraries**. Real result: **33 verilogams leaves gathered, externals =
  only the 5 real std cells (all -v-resolved), 0 bogus externals.** ✅

Verified: `examples/{nested_chain,schem_nested,analog_leaf}` + `examples/duts/` (3/3).
**Red zone preflight PASSED** (xrun 19.04, pure-digital wreal, zero spectre license, xrun
ambient even in `bash -c`). Dev box OA design is a SHELL (PMU_top is a pin-only stub).
**GUI verified live** via skillbridge — a FULL user-flow simulation drove the real form
object (built but not displayed, the README-sanctioned scripted-form pattern): set fields,
"clicked" Extract A → Convert B → Generate C → **Run xrun → `=== TB PASS ===`** (real
xrun, ~4s) → Package D, then `hiFormCancel`. All 6 out-of-order/empty-field guards fire
clean hints; `vh_env show` confirmed read-only; registers once under MyTool. Only the
literal pixel *display* (`hiDisplayForm`) is left for the user to eyeball from the menu
(it blocks the bridge, so it can't be scripted).

- **Bus / array support** (Stage C, DONE 2026-06-25) — the real design is heavily
  bus-based; the TB generator is now **bus-aware**. KEY INSIGHT that shrank the scope:
  slices `ndiv[7:0]`, concatenations `{a,b}` and array instances `I119[1:0]` all live
  **inside Stage A's `<top>_struct.vams`** (the oa2verilog netlist) — Stage C only emits
  the **TB + stubs** and instantiates the top, so for **packed-logic buses** (which is
  what `wrealize` leaves them as: it only converts *scalar* `wire→wreal`) those constructs
  are **native Verilog — xrun handles them with zero expansion**. So the work was making
  the TB/stub *match* the struct's bus port types, per-port:
    - scalar (`width==''`) → `real drv; wreal net; assign` (unchanged);
    - logic bus (sized + ntype `wire`/`reg`/none) → `reg [m:l]`(in)/`wire [m:l]`(out),
      integer-vector stimulus (`ndiv`/`pwsel`/`N_div` control words);
    - real bus (sized + ntype `wreal`) → **unpacked wreal array** `wreal x[m:l]` + per-bit
      drive (Stage-B convention; `*E,WRERNG` only if you *packed* a wreal).
  Stubs are bus-aware too: width inferred from connection slices/concats (÷ array-instance
  count), and **logic-vs-wreal chosen from the connected net's type** — a wreal stub on a
  logic net (or vice-versa) needs a connect module (`*E,CUNDCM`), so the stub net type
  mirrors what it's wired to. Golden checks stay scalar-output (bus bits referencable as
  `name[i]` in checks.json, e.g. `sel[0]`); bus outputs are displayed.
  Verified end-to-end under xrun on `examples/bus_div` (logic bus in/out, slices, concat,
  `dbuf Ub[3:0]` array instance, scalar wreal path → **TB PASS**) + a wreal-unpacked-array
  fixture + a stubbed-external (logic) + a wide-bus external (passthrough). All prior
  examples still PASS (3/3 duts, nested_chain, schem_nested, analog_leaf). ✅

- **Structural-verilogams sub-cell gather** (Stage A, DONE 2026-06-25, from the FIRST real
  red-zone Stage-C run) — a gathered verilogams leaf can itself be **structural** (it
  instantiates further cells). The real `pll_ndiv_delay_reload`'s verilogams instantiates
  `WL_PLL_Ndiv_inv_lvt_x8`/`nor2_lvt_x4`, which the oa2verilog *schematic* descent never
  sees (they live in the `.vams` text, not a schematic) → xrun `*E,CUVMUR` unresolved.
  FIX: after gathering leaves, `extract()` parses each gathered `.vams`, and for every
  sub-master not already defined/gathered/`-v`/pin/device/passive it gathers that cell's
  own veriloga/verilogams (recursively, to a fixpoint); anything still undefined is left
  for Stage C to `-v`-resolve or stub. New manifest field `gathered_subcells`. Verified on
  `examples/struct_va` (delaycell → subgain+subadd gathered → xrun TB PASS, FUNCTIONAL).
  Note: oa2verilog emits ports as the direction decl only (no separate `wire`) — the
  fixture mirrors that (a double `input a; wire a;` would trip wrealize into `*E,DUPIDN`).

- **Real-design bring-up of `LPBT_NDIV_TOP` — the whole error-class sweep (DONE 2026-06-25,
  HEAD 8728c8e).** Iterating on the real design surfaced (and fixed, each reproduced in a
  LOCAL fixture first) a chain of real-world failure classes:
  1. `*E,CUVMUR` (unresolved `WL_PLL_Ndiv_*`) — caused by (a) the **AMS netlister's
     `(* integer library_binding="LIB"; *)` attribute** between master & instance names
     defeating the parser → fixed by stripping `(\*..\*)` in `vp.strip_comments`; (b) a
     **stale verilogams** for `pll_ndiv_delay_reload` bound to another chip's lib — fixed by
     **honoring the config viewlist** (descend the schematic for a cell whose verilogams is
     structural; gather verilogams only for *behavioral* leaves — `verilogams_is_behavioral`).
  2. `*E,CUVPOM` (port mismatch, `.en`/`.VPP`/`.D`) — `reconcile_ports()` drops instance
     connections to ports the known child lacks (overlap-guarded; zero-overlap ⇒ wrong-view
     warn).
  3. `*E,CUNDCM` (wreal↔logic, 512×) — **the design is logic** (32 logic leaves + 1 cell,
     `pll_ndiv_div2_tspc`, that only declares its **supply** pins wreal). Fixes: discipline
     **auto-detect** (logic vs wreal by *functional* leaf discipline — supply-only-wreal = a
     logic leaf), **don't wrealize a logic design**, **drop wreal SUPPLY pins** in a logic
     design (`drop_wreal_supply`, `SUPPLY_RE`), and **stubs default to the design discipline**
     (`gen_stub default_logic`). All proven on `examples/logic_supply` (faithful clone:
     logic cells + wreal-supply divider + stubbed counter on shared VDD/VPP/VSS → 0
     boundaries, xrun TB PASS).
  **`vh_diag` is now the ground-truth instrument** — sections: SUMMARY (incl. discipline +
  wreal/logic leaf counts), DISCIPLINE BOUNDARIES (per-net wreal/logic mix = static CUNDCM
  predictor, with which masters are on each side) + **INTERFACES of boundary cells** (ports
  + discipline, bodies omitted = a sanitized clone-able spec), PARSE GAPS, UNRESOLVED (with
  `library_binding`), PORT MISMATCHES, xrun.log digest. **Process lesson (locked):** observe
  via vh_diag → clone the failure in a LOCAL fixture against local xrun → fix+verify there;
  red zone = final check only. CUNDCM is about disciplines+wiring, NOT bodies, so interfaces
  suffice to clone.

- **Config-binding priority + leaf-decision blind spots (DONE 2026-06-25, from a user design
  review of how Stage A decides leaf-vs-descend).** Three fixes, each cloned + verified on a
  new local fixture (no red zone), regression 9 examples + 3 duts green:
  1. **config binding WINS over the heuristic.** Old `forced_va` honored only `binding
     :veriloga`; the behavioral heuristic could override an explicit config binding. NEW
     `config_bindings(cfg)` → forced_leaf (bound to veriloga/verilogams/ahdl → gather even a
     STRUCTURAL verilogams) + forced_descend (bound to a schematic view → never gather its
     verilogams). Honors the user's rule "config 定 verilogams = 终点." Fixture
     `examples/cfg_binding`.
  2. **a real leaf may reference an EXTERNAL .v.** `verilogams_is_behavioral` now takes
     `ext_index` and excludes `-v`-resolvable / same-file refs from the structural test, so a
     leaf that instantiates a std cell isn't wrongly descended into its cmos_sch. Fixture
     `examples/leaf_ext_ref`.
  3. **NESTED config_ams.** Verified live (hdbOpen/hdbSaveAs round-trip): a `:config` binding
     is a NAMED REFERENCE, child bindings live in the child's own expand.cfg (NOT flattened).
     `resolve_nested_configs()` recurses into `<cell>/config/expand.cfg` + folds bindings in
     by name (+ warns); missing child → warn + heuristic. Fixture `examples/nested_cfg`. Also
     confirmed the real AMS viewlist ranks `cmos_sch` above `schematic` (the #28 root).
  Manifest gained `config.{nested_configs,forced_leaf,forced_descend}`. Reusable regression
  sweep: scratchpad `regress.sh`.

**NEXT (the immediate thing):** user must **redeploy 8728c8e to the red zone, re-run
Extract A → Generate C → Run xrun → Diagnose.** EXPECTED: `0` CUNDCM → the design
**elaborates + runs for the first time** (RUN-KIND **SMOKE**, since `CLK_PLL_NDIV_counter_
div2_lvt` is stubbed). Look for `=== TB PASS/FAIL ===` and DISCIPLINE-BOUNDARY = 0.
Remaining, in priority order:
  - **#28 `pll_ndiv_mmd_core` wrong-view** (warnings `*W,CUVWSP/CUVWSI`, NOT a hard error):
    its descended `cmos_sch` interface `{N_div,clk,out_dsm,rstn,...}` ≠ how the parent
    instantiates it `{E_pfd,reload,q1,q2,divisor_b,...}` → its real signal ports float →
    functionally hollow. Fix = descend the view whose interface MATCHES the parent
    instantiation (need `ls .../pll_ndiv_mmd_core/` view list). Until then the run is
    "elaborates but mmd_core does nothing".
  - **FUNCTIONAL run** (vs SMOKE): resolve `CLK_PLL_NDIV_counter_div2_lvt` (it's stubbed;
    its `library_binding` / a `-v` or verilogams is needed).
  - **Real testbench** (DONE 2026-06-26 — `examples/lpbt_ndiv/`): period-ratio TB
    `tb_LPBT_NDIV_TOP.vams` drives `fromVCO`+`ndiv`+`pwsel`+enables per MODE. **Mode table
    CONFIRMED FROM THE REAL STAGE-A NETLIST** (clock tree traced from `LPBT_NDIV_TOP_struct.vams`,
    notes in gitignored `_ref/NETLIST_NOTES.md`): front-end `fromVCO→div2→div2→DIV4sig=VCO/4`
    (the /4 prescaler); CAL `cal_en=1`→`CLK2CNT=VCO/4` + OUT_NDIV/CLK2DSM frozen (NDIVCKIN
    stops) + TESTCLK low; TEST `en_test=1`→`TESTCLK_300M=VCO/16` (DIV4sig→div4_tspc); NORMAL/TEST
    →`OUT_NDIV=CLK2DSM=VCO/4/M`, `M=ndiv[7:0]−1` (only this is user spec, not netlist). `CLK2CNT
    =nand(DIV4sig,cal_en)` so it's VCO/4 ONLY in cal, static-high else (corrected the user's
    "CLK2DSM/CLK2CNT same-freq" recollection — they're active in different modes). `pwsel`=duty
    (pwsel[0] NC), `lpbt_en` NC. **TB port match to the real struct = exact** (18 ports incl.
    supplies, named conns → no CUVPOM). CAL `VCO/4` + TEST `VCO/16` are FRONT-END TAPS that do
    NOT pass through mmd_core → **real HARD checks that pass TODAY**; OUT_NDIV/CLK2DSM go through
    mmd_8bit→mmd_core (hollow #28) → gated behind `+define+CHECK_NDIV` (smoke→WARN). Verified
    locally (xrun 18.03) vs a behavioral good-model `LPBT_NDIV_TOP_model.vams` (LOCAL-ONLY,
    never shipped): good→PASS, `+CHECK_NDIV`→full PASS, `BREAK_TESTCLK`/`BREAK_NDIV`→FAIL (teeth),
    `+define+HOLLOW`(dead mmd_core)→PASS via CAL+TEST. Red zone: `vh_gen --tb
    examples/lpbt_ndiv/tb_LPBT_NDIV_TOP.vams --tb-top tb_LPBT_NDIV_TOP` (NO model file).
  - **Generality gap**: a genuine **functional** wreal↔logic boundary (not supply) is
    diagnosed by vh_diag but NOT auto-fixed (would need generated connect modules — not
    built). All decisions/details in the project memory
    (`…/Verilog-check/memory/verilog-check-project.md`).

---

- **Date:** 2026-06-25
- **Dev box:** `eda` (Rocky 8.10 / RHEL8 = "linux8"), the dev/green zone.
- **Goal:** given veriloga `.va`/`.vams` files, auto-generate a testbench, run it under
  `xrun` in **pure-digital** mode (wreal, **no Spectre**), and verify. Hard case =
  **nested** DUTs; must support text-nesting (.va instantiates .va) AND schematic+config
  nesting (OA top, leaves bound to veriloga).

---

## 1. Why this lives in skill_tools (not a standalone repo)

The user wants a **usage-layer** convenience: in the schematic, *Select from Schematic →
pick cell → pick config_ams → one click → extracted into a folder*, with a one-click GUI
like `note_helper`. That UX is Virtuoso-integrated, so the tool rides skill_tools'
**MyTool** banner + the existing **air-gap deploy** pipeline.

Follow the **note_helper pattern**: a *thin* SKILL GUI shells out (`system()`) to
**standalone, Cadence-independent Python** and exchanges data via temp files —
**no skillbridge at runtime**. The Python must stay stdlib-only and CLI-invokable so it
(a) is developed/tested on dev without a GUI, (b) runs on the red zone for the xrun stage.
**Rule: all logic in Python; the .il is only a launcher.**

The select-from-schematic + Lib/Cell/View picker can be copied from `dreg_gen/dgenGui.il`
(it already has `[Select from Schematic]` / `[Browse Library]` and 3 linked combos).
Pin scan from a live cellview: reuse `dreg_gen/dgenPinScan.il :: dgenScanPins(lib cell view)`.

---

## 2. Pipeline (manifest-centric)

```
A  read config(.cdslib + expand.cfg) → expand DUT hierarchy + per-instance view binding
   + resolve EXTERNAL file paths → gather .va into export/ + oa2verilog top .v + manifest   [needs OA]
B  classify analog/digital (+ why) → mechanically convert analog→wreal for the bounded
   pattern set; FLAG unrecognized; originals READ-ONLY, converted files written separately    [pure python]
C  pins (from .v) + user intent → checks.json/stimulus → vh_gen bakes TB + run.sh             [pure python]
D  package via airgap_deploy_template → red-zone verify.sh runs pure-digital xrun             [template ready]
   one manifest.json is created by A, annotated by B/C, consumed by D
```

### Current state
- **A:** **built & verified** — `vh_extract.py`. Two decoupled phases:
  *netlist* (drives `oa2verilog`, skippable with `--netlist`) + *process* (pure python:
  parse `cds.lib`+`expand.cfg`, classify masters, strip artifacts, gather `.va`, emit a
  clean wreal-normalized structural top + `manifest_A.json`). Verified on the real
  `sim_yusheng/Test_PMU` config (TB-stimulus stripped & warned, `--cell PMU_top` flags
  the pin-only stub) and end-to-end on `examples/schem_nested` (Stage A→C→xrun = PASS).
  See §3a for the decisions this surfaced.
- **B:** **built & verified** — `vh_convert.py`. Detection list + bounded analog→wreal +
  non-destructive candidate beside each cell. Verified on the real leaves (dreg_Test_cell
  → CONVERTED, the LDO/bias models → FLAGGED skeleton) and end-to-end on
  `examples/analog_leaf` (Stage A→B→C→xrun = PASS, analog gain `V(o)<+k*V(i)` → `assign
  o=k*i`, `out=3*in`). Decisions in §3b.
- **C:** **built & verified** — `vh_parse.py` + `vh_gen.py`. `examples/nested_chain`
  runs end-to-end to `=== TB PASS ===` (exit 0): top `chain`→`preproc`→{scaler,summer};
  `ext_sensor` correctly classified EXTERNAL, its port dirs inferred from connectivity
  (out:output, in:input), auto-stubbed as an ideal buffer; 5 vectors checked vs golden.
- **Multi-DUT:** **built & verified** — `vh_dut.py`. One folder per DUT; auto-detects
  config-vs-hand-dropped sources and user-test-vs-checks; runs the whole pipeline per DUT
  into `<dut>/_vh/`; `run-all` gives a PASS/FAIL summary. `vh_gen --tb <file> [--tb-top]`
  added so a DUT can carry its OWN testbench (else a TB is generated from checks.json).
  Example `examples/duts/` (config / hand-dropped+checks / hand-dropped+user-test) = 3/3 PASS.
- **D:** **built & verified** — `vh_convert` aside, `vh_package.py` + an env-agnostic
  `run.sh`/`setup_env.sh` from `vh_gen`. Packs a Stage-C build into a relocatable,
  self-contained bundle (flattened sources + `setup_env.sh` + `ext_libs.list` + `verify.sh`
  preflight) + tar.gz/sha256. Verified by extracting the tarball to a fresh dir and running
  `verify.sh` in a CLEAN env (xrun resolved via fallback, preflight PASS, design TB PASS),
  incl. a `-v` external lib carried through `ext_libs.list`. Red-zone facts in §5/§7.

---

## 3a. Stage-A decisions (learned from the real OA design on the dev box)

The live OA design is currently a **shell**: `PMU_top`/`Test_cell` schematics are
**pin-only stubs** and the veriloga leaves (`ldo_core_pll/vco/vref_bias`) are orphaned
(no schematic instantiates them). So Stage A was built to be honest about that and was
proven runnable via a captured-netlist fixture. Decisions baked into `vh_extract.py`:

1. **`oa2verilog` has no `-config` flag** (IC618 22.60) — only `-view`. With
   `-recursive -noStopping` it descends `schematic` views and emits an **empty interface
   module** for every master with no schematic (veriloga leaves, externals, pin cells).
   That naturally "stops at the veriloga leaf" — no config needed for the descent.
2. **TB-vs-DUT**: the config's `design` often points at a **testbench** schematic
   (`Test_PMU` is full of `vpulse/vdc/idc/gnd` + the DUT `PMU_top`). Stage A strips that
   analogLib stimulus, **warns**, and lists DUT candidates; `--cell <DUT>` retargets.
   A TB top also has **no ports** (all nets internal) → useless for TB-gen → another
   reason to target the DUT cell.
3. **Master classification**: structural (kept) / veriloga-leaf (empty + `.va` on disk →
   gathered, interface dropped) / external (empty + no `.va` → recorded with
   oa2verilog-accurate port dirs for Stage C to stub) / pin artifact `ipin/opin/iopin`
   (dropped) / stimulus (dropped+warned). The **targeted top itself**, if empty, is a
   **pin-only stub → "nothing to verify"** flag, not an external.
4. **wreal normalization**: oa2verilog emits `wire`; the pure-digital flow is wreal, so
   Stage A rewrites scalar `wire`→`wreal` and merges port decls to `input wreal x;`.
   Buses are left + warned (scalar-only, consistent with Stage C).
5. **Two-phase decouple** (`--netlist`): the OA-dependent netlist step is split from the
   portable pure-python processing, so the red zone / CI / tests reprocess a captured
   netlist without OA. This is how `examples/schem_nested` runs end-to-end here.
6. **cds.lib** parsed recursively (DEFINE + INCLUDE + SOFTINCLUDE) → lib→path map; leaf
   `.va` resolved at `<libpath>/<cell>/veriloga/veriloga.va`.
7. **External HDL resolution (`vh_env.py`)**: the tool owns a remembered list of `-v`
   library files / `-y` dirs / `+incdir` (user-level `~/.config/verilog_helper/env.json`,
   per-run `--ext-lib/--ext-dir/--ext-inc` override). Stage A parses those files; an
   external **found** there is RESOLVED (real def compiled by xrun via `-v`, not stubbed)
   and flagged analog/wreal; **not found** → Stage C stubs it. `vh_gen` skips stubbing
   resolved externals and bakes the `-v/-y/+incdir` (and `+libext+.v`) into `run.sh`.
   This replaces the earlier (wrong) `.scs ahdl_include` plan — see §6.4.
- Side fixes this surfaced: `vh_parse` now tolerates combined port decls
  (`input wreal x;`); `vh_gen.gen_stub` multi-output `_const` bug fixed.

## 3. Stage-B conversion pattern catalog (LOCKED — voltage only, no current)

User's circuits are exactly these (no complex analog; LDO-style models are for
spectre-accelerated modeling and are NOT brought into functional checks):

| analog source pattern | digital (wreal/logic) form |
|---|---|
| ideal V source `V(p)<+ c` | `wreal p; assign p = c;` |
| constant reference | same |
| simple gain `V(o)<+ k*V(i)` | `assign o = k*i;` |
| threshold / comparator `(V(i)>vth)?VH:VL` | `assign o = (i>vth)?VH:VL;` (also power-OK detect) |
| sample / hold | `always @(posedge clk) h<=i; assign o=h;` |
| DAC code→level (bus) | bit-weighted sum — **reuse dreg_gen bit-decompose** |
| buffer | `assign o=i;` |
| dff | `always @(posedge clk) q<=d;` |

- **No current quantities** on the functional-check path (user confirmed) → no need to
  map `I(...)<+` (which has no clean pure-wreal equivalent). If that ever changes, revisit.
- **Unrecognized pattern → FLAG, never guess-convert.**
- **Never overwrite originals.** The "binding" (existing-source vs converted vs stub) is
  recorded in the manifest; converted files are separate artifacts. (No `_bk` overwrite.)

## 3b. Stage-B decisions (as built in `vh_convert.py`, 2026-06-25)

The user's two-cell-version insight: #1 = the ORIGINAL `<cell>/veriloga/veriloga.va` (may
be analog, **is what ships to the top**); #2 = the digital copy we verify. Verifying #2
isn't enough — the analog #1 must eventually be replaced. So Stage B's deliverable is:

1. **Detection list** (`manifest_B.{txt,json}`): every cell → `DIGITAL` (no action) /
   `CONVERTED` / `FLAGGED` (needs manual), with the reason.
2. **Non-destructive candidate beside the cell**: writes `<cell>/veriloga/veriloga_wreal.va`
   (chosen by user over a parallel view / `.wreal` suffix). It **never** touches
   `veriloga.va`; the user reviews + overwrites. `--no-cell-write` opts out.
3. **`export/` (the verification copy) is updated** to the converted source in `--manifest`
   mode, so the pure-digital run uses digital. FLAGGED cells leave `export/` analog and the
   list says the design isn't fully digital-verifiable until the skeleton is filled.
4. **Convertible = analog block is ONLY `V(node[,ref]) <+ expr`** with expr free of
   `I()`/`ddt`/`idt`/noise/filters/`@`/`if`/`for`/temp-var assignments. `V(a,b)`→`(a-b)`,
   `V(a)`→`a`; `V(o,r)<+e` → `assign o = e + r`. Params copied verbatim (keeps real/integer).
5. **Buses**: `wreal [msb:lsb]` is REJECTED by xrun (`*E,WRERNG Range specification not
   allowed on wreal`). Per-bit `V(bus[i])<+…` is emitted as an **unpacked wreal array**
   `wreal bus[msb:lsb];` + `assign bus[i]=…` (verified runnable). The candidate header warns
   to check the packed-wire↔unpacked-array connection in the real hierarchy.
6. Real-cell results: **dreg_Test_cell → CONVERTED** (bit-decompose control reg, bus);
   **ldo_core_pll/vco, vref_bias → FLAGGED** (temp-vars + `I()<+` + `ddt`/`white_noise`) →
   skeleton with inferred I/O directions (LHS of V/I contributions = outputs) + all params.

---

## 4. Environment recipes (dev box)

### xrun (Xcelium 18.03-s001) — bash
`~/.cshrc` only helps tcsh; automation runs in bash, set env manually:
```bash
export XCELIUM_HOME=/home/yusheng/Program/eda/cadence/XCELIUM1803
export CDS_LIC_FILE=/home/yusheng/Program/eda/cadence/license/license.dat
export PATH="$XCELIUM_HOME/tools/bin:$PATH"
```
- **Pure-digital wreal + `-ams` needs NO spectre.** The lines
  `Spectre_AMSD_Lk / Spectre_AMS_MMSIM_Lk ... license checkout failed` are **BENIGN**
  (pure wreal has no electrical nodes to solve; sim runs digital-only, exit 0).
- **`-amsvlog_ext .vams,.va`** is REQUIRED: xrun decides language by extension and does
  not know `.va` (only `.vams`). Without it: `*E,FMUK: type of file could not be determined`.
  The option overrides the map, so list both. (Baked into `vh_gen.py`'s run.sh.)
- SELinux Enforcing; `selinuxuser_execheap` already ON (-P) — required or `xmsim` crashes
  with `*F,INTERR` at run.
- Full install story: `<workarea>/Verilog_check/Xcelium_安装交接.md`.

### oa2verilog (schematic → structural .v) — IC618 on RHEL8
```bash
source <workarea>/LDO_modeling/cadence/env.sh        # CDSHOME=IC618, etc.
export OA_UNSUPPORTED_PLAT=linux_rhel60               # else sysname=unknown, OA tools die on RHEL8
export CDS_ENABLE_EXP_PCELL=1                         # else analogLib pcell sources: OAVLG-10055
oa2verilog -lib <lib> -cell <cell> -view schematic -verilog out.v \
  -libDefFile <workarea>/cds.lib -recursive -noStopping -logFile out.log
```
Leaf cells with only symbol+veriloga come out as empty interface modules (bodies live in
the `.va`). Gotcha: a cell's `schematic/data.dm` may list STALE master deps — trust the
netlist from `sch.oa`, not data.dm grep hits. **Netlist the DUT cell, not a TB schematic**
(a TB schematic pulls in vdc/vpulse/idc stimulus you'd discard).

---

## 5. Zone / deploy model (red-zone runs the real verification)

```
dev(linux8, this box) ──git push──▶ GitHub ──git pull──▶ yellow(Windows, pack.ps1) ──upload──▶ red(linux7, deploy.sh)
   write + smoke (xrun 18.03)                              git-free tar+sha256              air-gap, no net/git, in-place swap+backup
```
- **Red zone xrun = 19.04** (ICADVM18.1; from the original reference prompt). Dev = 18.03.
  `-ams` / `-amsvlog_ext` / wreal exist in both; dev smoke is a valid proxy. **Add a
  preflight smoke on red** before trusting a run.
- skill_tools' own deploy (`skill_tools/deploy/{pack.ps1,deploy.sh}`) ships the TOOL to red.
- The per-DUT verification package is built by **`vh_package.py`** (DONE): a relocatable,
  env-agnostic, self-contained bundle (`<top>_pkg/` + `.tar.gz` + `.sha256`). It is **user
  data → goes to a work dir, NOT committed.** `setup_env.sh` resolves xrun env-agnostically
  (ambient on red / `VH_SITE_ENV` / dev fallback); `ext_libs.list` (or `VH_EXT_LIBS`) carries
  the red-zone `-v` paths; `verify.sh` runs a pure-digital preflight smoke then `run.sh`.
  Red `xrun` is ambient and the preflight PASSes there with zero spectre license use (§7).

---

## 6. Locked decisions
1. **Pure-digital only, no spectre.** Verified achievable for wreal designs.
2. **Voltage-only** functional checks (no current).
3. **config scope = the DUT only** (not a full TB).
4. **External binding** = some cells reference a std/external HDL file. The REAL place
   this path lives (user-confirmed 2026-06-25, correcting an earlier `.scs ahdl_include`
   guess) is **AMS Options -> Include Option Settings -> Library Files (`-v`)** in an AMS
   testbench, e.g. `…/workarea/ams_models/L16_SVT_ana.v` (= xrun `-v`). BUT the user runs
   ordinary (non-AMS) analyses and will NOT build an AMS TB just to hold these paths.
   **Decision: the TOOL owns the external include list** — user sets `-v` files / `-y`
   dirs / `+incdir` once, the tool remembers them (user-level `~/.config/verilog_helper/
   env.json`, per-run override) and bakes them into the generated `run.sh`. Stage A parses
   the `-v` files to report which externals are covered (and flags analog ones), falling
   back to a stub for anything unresolved. (`vh_env.py` manages this; see §3a.)
5. **Analog DUT** (electrical/analog begin) → **FLAG "needs spectre"**, do NOT digitize to
   "verify" it (circular). Digitize only *neighbors*, and an **ideal stub** usually suffices.
6. Conversion is **assisted/bounded + non-destructive** (§3), never blind.

## 7. Open items / next steps
- [x] **Stage A `vh_extract.py`** — built & verified (see §3a).
- [x] **External HDL resolution `vh_env.py`** — built & verified: remembered `-v`/`-y`/
      `+incdir` env; externals resolved-or-stubbed; flags analog; baked into `run.sh`.
      (Replaces the wrong `.scs` plan — real location is AMS Options Library Files; §6.4.)
      Remaining Stage-A refinements: (a) honor `cell … binding :veriloga` *when the cell
      also has a schematic* (coded, untested — dev-box design has no such conflict);
      (b) bus/vector ports flow through as-is + warn (scalar-wreal only end-to-end).
- [x] **Stage B `vh_convert.py`** — built & verified (see §3b). Remaining: richer pattern
      coverage if real cells need it (sample/hold, dff with explicit clocks → currently
      skeleton); verify bus packed-wire↔unpacked-wreal-array connection in a real hierarchy.
- [x] **Stage D** — built & verified (`vh_package.py` + env-agnostic `run.sh`/`setup_env.sh`).
      **Red-zone facts (preflight 2026-06-25):** red `xrun = 19.04-a001`, pure-digital wreal
      smoke PASSed with **zero** spectre license errors (cleaner than dev) and no `*F,INTERR`;
      **xrun is ambient even in non-interactive `bash -c`** (`/software/cadence/xcelium/
      19.04.001/tools/bin/xrun`) — so the package needs NO env setup on red. Done: `setup_env.sh`
      uses ambient xrun else falls back; `ext_libs.list`/`VH_EXT_LIBS` carries red `-v` paths.
- [x] **GUI `vhGui.il`** — built & verified live (2026-06-25). note_helper-style thin
      launcher (`verilog_helper.il` loader + umbrella `skill_tools.il` wired). Registers
      under **MyTool → Verilog Helper**. Select-from-schematic (enterPoint + dbGetOverlaps
      hit-test, copied from `dgenGui.il`), Lib/Cell/View combos (`ddHiCreate*ComboField` +
      `ddHiLinkFields`), file pickers (config/cds.lib/netlist/checks/tb/-v lib), Output
      folder, and `[Extract A][Convert B][Generate C][Package D]` + `[Add -v lib][Show env]`.
      Each button → `vh_runCLI` builds `<prefix> python3 <dir>/vh_*.py <args> > log 2>&1`,
      `system()`s it, prints the log to CIW, surfaces a one-line result on Status.
      **Bug found & fixed live:** SKILL `cons` REQUIRES a list 2nd arg, so `(cons rc txt)`
      errored — return `(list rc txt)` instead (read with `car`/`cadr`). Verified via
      skillbridge: load, all helpers, every field builder, the real A→C→D shell-out from
      Virtuoso's env, `vh_env show` read-only, single MyTool registration.
- [ ] Get from user: the red-zone `-v` external-lib paths + whether they're wreal/electrical;
      a real DUT cell that actually instantiates leaves (the dev design is a shell).

## 8. Memory pointers (Claude Code persistent memory)
`xcelium-working-and-gotchas`, `oa2verilog-rhel8-recipe`, `verilog-check-project`,
`eda-install-layout`.
