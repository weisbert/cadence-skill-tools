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
