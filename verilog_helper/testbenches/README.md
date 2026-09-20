# testbenches/ — the design-TB library (what the GUI "Design TB" dropdown lists)

Put **one hand-written testbench per real DUT** here, named **`tb_<CellName>.vams`** (the
`<CellName>` is the DUT cell, e.g. `tb_LPBT_NDIV_TOP.vams` for cell `LPBT_NDIV_TOP`). That is
all it takes — the GUI:

- lists every `tb_*.vams` here in the **Design TB (Stage C)** dropdown, and
- **auto-selects `tb_<DUT>.vams`** when you pick that DUT (Source Cell / Select from Schematic),
  so the right TB is wired without choosing anything.

A TB is DUT-specific (it knows the DUT's ports, modes, expected divide/levels), so it is
authored once per design and lives here. As the project grows this directory grows with it; to
share TBs across a team, point `vh_tbDir` at a shared/SVN path in your `.cdsinit`:

```scheme
(setq vh_tbDir "/path/to/shared/verilog_tbs")
```

## Not to be confused with `examples/`
`examples/` holds the **tool's own regression fixtures** (synthetic cells like `wreal_prediv`,
`wreal_monitor` that prove/regress Stage A/B/C). Those are NOT design TBs and do **not** appear
in the dropdown.

## The TB contract (so Stage C can wire it)
- Instantiate the DUT by its real module name with named ports (`.fromVCO(fromVCO), ...`).
- Top module named `tb_<DUT>` (auto-detected) or `tb`.
- Print `=== TB PASS ===` / `=== TB FAIL ===` for the verdict (Status line greps these).
- Optional knobs via `+define+...` reach xrun (the generated `run.sh` forwards `"$@"`):
  e.g. `tb_LPBT_NDIV_TOP.vams` gates its exact-N check behind `+define+CHECK_NDIV` and a
  SimVision dump behind `+define+WAVES`.
- `tb_NDIV_TOP_v7_svt_0p5W.vams` takes `+define+FGHZ=<GHz>` (default **4.8**, i.e. unchanged
  without the macro) — that is how the 5.0 / 5.8 / 7.0 GHz runs are made; no `sed` on `TVCO`.

## Margin / hold-race probes (`tb_<DUT>_dly.vams`)

A `tb_<DUT>_dly.vams` is a **single-mode, `+define+`-parameterised timing probe** that goes with
the `vh_delay.py` delay tables (`delays/*.json`). It stays in one mode for the whole run (so a
failure is attributable to that mode and not to a mode-switch glitch) and checks the divide law
**cycle by cycle** rather than on average, which is what catches a ripple stage that
double-counts. It appears in the dropdown but is never auto-selected (auto-select is an exact
`tb_<DUT>.vams` match).

`tb_NDIV_TOP_v7_svt_0p5W_dly.vams` knobs:
`+define+FGHZ=5.8` `+define+NDIVW=9155` `+define+LPBTEN=1` `+define+NPER=40`
`+define+CALEN=1` `+define+ENTEST=1` `+define+PRELPBT=1`, plus the delay knobs
`+define+VH_TPD_SCALE=<x>` / `+define+VH_TPD_<CLASS>_PS=<ps>`.
Results and the measured margins: `examples/wur_ndiv/DELAYS.md`.
