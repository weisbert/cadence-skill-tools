# examples/wur_ndiv/charac — WuR NDIV 32.768 kHz + sigma-delta characterization

Open-loop verification of the **real 32.768 kHz PLL reference path** of
`NDIV_TOP_v7_svt_0p5W` and of a **3rd-order MASH 1-1-1** driving its 14-bit divide word,
in pure-digital Xcelium (no Spectre, no Virtuoso).

These TBs drive the **real Stage-A struct** (gate-level behavioral cells). That netlist is
proprietary and is **not** in version control — it lives in the gitignored
`../_ref/build_sdm/`. Point `STRUCT_DIR` at any build dir holding
`export/*.vams` + `ext_stub/*.vams` (on the red zone: the export dir).

Everything is measured at **top-level ports only** (`OUT_NDIV`, `CLK2DSM`, `fromVCO`);
hierarchical probes across the AMS connect boundary proved unreliable.

## Files
| file | what |
|---|---|
| `tb_wur32k.vams`  | STATIC divide law at the real 32.768 kHz operating points (4.8/5.0/5.8 GHz) plus bit-12/13 witness words (8191/8192/8193/12288/16383). Per point: `period(OUT_NDIV)/Tclk == ndiv-1`, same for `CLK2DSM`, CLK2DSM lag, low-pulse law, X-guard, and `f_OUT_NDIV` in Hz vs 32768 Hz. |
| `mash111.vams`    | behavioral, synthesizable-style 3rd-order MASH 1-1-1 (20-bit accumulators, `y ∈ [-3,+4]`, optional 1-LSB LFSR dither). Clocked by the chip's own `CLK2DSM` pin. |
| `tb_wur_sdm.vams` | dynamic (SDM-modulated) divide word. Phases: per-cycle law + alignment + average + period dump (`+PHLAT=0`), update-latency sweep referred to CLK2DSM (`+PHLAT=1`), and a deterministic **setup** sweep referred to the OUT_NDIV reload edge (`+PHLAT=3`). |
| `sdm_psd.py`      | PSD of the dumped period-error sequence; fits the low-frequency slope over one decade and checks it against +60 dB/dec (3rd order). numpy only. |
| `run.sh`          | runner: `./run.sh <tb_module> [+plusargs] [xrun args]`; private per-TB run dir under `STRUCT_DIR`, so parallel runs never share an `xcelium.d`; retries on license contention. |

## Run
```bash
cd examples/wur_ndiv/charac
./run.sh tb_wur32k                                                   # static 32.768 kHz law
./run.sh tb_wur_sdm +NINT=300 +FNUM=773094 +KCYC=8192 +ALLY=1 +TAG=w300_f7373
./run.sh tb_wur_sdm +FVCO_MHZ=5000 +NINT=9537 +FNUM=779264 +KCYC=256 +TAG=w32k_5g0
./run.sh tb_wur_sdm +LPBT=1 +NINT=51 +FNUM=773094 +KCYC=512 +TAG=lpbt51
./run.sh tb_wur_sdm +PHLAT=1 +LPBT=1 +NINT=51  +NODUMP=1             # latency sweep vs CLK2DSM
./run.sh tb_wur_sdm +PHLAT=3 +LPBT=0 +NINT=300 +NODUMP=1             # setup sweep vs the reload edge
python3 sdm_psd.py ../_ref/build_sdm/run_*/perr_*.txt                # noise-shaping check
```
`STRUCT_DIR=/path/to/build ./run.sh ...` to point at a different netlist build.
`RUNDIR=/path ./run.sh ...` to force the run directory.

### tb_wur_sdm plusargs
`+PHLAT=0|1|3` phase · `+LPBT=0|1` mode · `+FVCO_MHZ=` · `+NINT=` · `+FNUM=` (fraction in
units of 2^-20) · `+KCYC=` cycles · `+LATC=`/`+LATF=` bus-update latency (Tclk / milli-Tclk)
· `+DITH=1` · `+ALLY=1` require all 8 y values · `+TAG=` dump-file suffix · `+NODUMP=1`.

## Confirmed laws (real struct, xcelium 18.03)
- `period(OUT_NDIV) = period(CLK2DSM) = (ndiv-1)·Tclk` holds across the whole 14-bit range,
  including `ndiv > 8192` (bit 13) — verified at 8191/8192/8193/9155/9537/11063/12288/16383.
- **Dynamic word:** `period_k = ndiv_applied - 1` **exactly, every cycle**, for all 8 MASH
  output values, at M ≈ 50, 300 and 9.2k–11k.
- **Alignment:** a word placed on `ndiv` at time T governs the **first OUT_NDIV period that
  starts after T**. Because `CLK2DSM` trails `OUT_NDIV` by ~2.07 Tclk, `y_k` (issued on
  CLK2DSM edge k) sets the period between OUT_NDIV edges k+1 and k+2 — **one full divider
  period of latency (z⁻¹)** between the SDM word and the period it produces.
- **Update timing:** the word must be stable on `ndiv` **≥ 1 NDIVCKIN cycle before the
  OUT_NDIV rising edge** (the counter reload). Equivalently, measured from the CLK2DSM
  rising edge, the SDM may take up to `M_min − 3` NDIVCKIN cycles.
- **Noise shaping:** the period-error PSD rises at ≈ +60 dB/decade (3rd order).

Full numbers: `../SDM_32K_RESULTS.md`.
