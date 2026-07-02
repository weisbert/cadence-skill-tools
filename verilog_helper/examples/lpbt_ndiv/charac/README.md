# examples/lpbt_ndiv/charac — LPBT_NDIV characterization testbenches

Standalone charac TBs that drive the **real** `LPBT_NDIV_TOP` Stage-A struct (gate-level
behavioral cells) in NORMAL mode and measure the divider law directly, in NDIVCKIN (=VCO/4)
cycles — i.e. the front /4 prescaler is removed. These complement the self-checking mode TB
`testbenches/tb_LPBT_NDIV_TOP.vams` (which also carries a summary divisor-sweep check).

The struct netlist is proprietary and is **not** in version control (it lives in the gitignored
`../_ref/build_afterfix/export/`). These files are just source; point `STRUCT_DIR` at any build
that has `export/*.vams` + `ext_libs/*.vams` (default = the local `_ref` build; on the red zone,
set it to the export dir).

## Files
| file | what |
|---|---|
| `tb_ndivsweep.vams` | sweep `ndiv_var = 14..127`, `pwsel = min((ndiv_var+5)/2, 62)`; per-point `SWEEP` line + `SUMMARY`. Confirms `divisor = ndiv_var-1` and `low = 2*floor(pwsel/2)-3`. |
| `tb_wave.vams`      | short capture at the nominal point (ndiv=51, pwsel=28) → `ndiv51.shm` for SimVision. |
| `run.sh`            | run a TB against the real struct: `./run.sh tb_ndivsweep` \| `./run.sh tb_wave`. |
| `sv_wave.tcl`       | SimVision command script: open the SHM, add NDIVCKIN/OUT_NDIV/CLK2DSM, zoom. |
| `grab_sv.sh`        | headless: run tb_wave → SimVision under Xvfb → PNG screenshot (needs Xvfb + PIL). |

## Run
```
cd examples/lpbt_ndiv/charac
./run.sh tb_ndivsweep     # divisor / pulse-width sweep  (grep ^SWEEP / ^SUMMARY)
./run.sh tb_wave          # -> ndiv51.shm ; view: simvision ndiv51.shm &
./grab_sv.sh              # -> simvision_ndiv51.png (headless xrun waveform screenshot)
```
`STRUCT_DIR=/path/to/export ./run.sh tb_ndivsweep` to point at a different build (e.g. red zone).

## Confirmed laws (real struct, xrun 18.03)
- divisor (front /4 removed) = `ndiv_var − 1`  (exact, 14..127)
- low pulse width = `2·floor(pwsel/2) − 3`  (NDIVCKIN cycles; pwsel bit0 unused)
- `pwsel = min((ndiv_var+5)/2, 62)` — the `min(.,62)` keeps pwsel inside the 6-bit field;
  the raw `(ndiv_var+5)/2` exceeds 63 for `ndiv_var ≥ 123`, wraps, and stalls OUT_NDIV.
