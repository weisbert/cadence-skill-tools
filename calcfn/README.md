# calcfn

Functions for Maestro outputs and the Calculator.  Load one file (e.g. from
`.cdsinit`); it needs neither `mytool` nor a GUI:

```skill
load("/abs/path/to/skill_tools/calcfn/calcfn.il")
```

One function per file, file name = function name; `calcfn.il` lists them.
Each function also shows up in the Calculator under Function Panel ->
**Skill User Defined Functions** (that is the IC6.1.8 label; the manual
spells it "SKILL").

| function | what it measures |
|---|---|
| [`LOdelay`](#lodelay) | edge-to-edge delay between two transient signals (buffer, inverter, divider, reset release) |

## LOdelay

```skill
LOdelay(VT("/in") VT("/out"))
```

**Pairing rule.**  Every output edge is paired with the *latest reference edge
at least `?tmin` before it*; an output edge with no such reference edge is
dropped.  This removes the `Tdelay - T` that "first output edge minus first
input edge" gives when a clip window starts between an input edge and the
output edge it caused.

| case | expression | note |
|---|---|---|
| buffer | `LOdelay(VT("/in") VT("/out"))` | |
| inverting stage | `LOdelay(VT("/in") VT("/outb") ?outEdge "falling")` | |
| divider | `LOdelay(VT("/clk") VT("/div2"))` | each output edge looks back to the clk edge that triggered it |
| divider, clk->Q > T_clk | `LOdelay(VT("/clk") VT("/div2") ?tmin 150p)` | without `?tmin` the nearest clk edge is the wrong one (gives clk->Q - T_clk) |
| one-shot reset | `LOdelay(VT("/rstn") VT("/div2") ?stat "first")` | every output edge pairs with the single rstn edge; take the first |
| differential | `LOdelay(VT("/inp")-VT("/inn") VT("/outp")-VT("/outn") ?refThr 0 ?outThr 0)` | |

| key | default | meaning |
|---|---|---|
| `?refEdge` `?outEdge` | `"rising"` | `"rising"` / `"falling"` / `"either"` |
| `?refThr` `?outThr` | mid level | crossing level; default `(ymax+ymin)/2` of that signal, over `[from,to]` when given |
| `?tmin` | 0 | smallest plausible delay; only needed when the delay can exceed one reference period |
| `?from` `?to` | whole wave | measure only output edges in this window; reference edges always come from the whole waveform |
| `?skip` | 0 | drop the first N pairs |
| `?stat` | `"mean"` | `mean min max std pp first last count`, or `wave` (delay vs output-edge time) |

Crossing times come from the built-in `cross()` (linear interpolation between
time points), so ps-level results are only as good as the transient step.

The Calculator form takes both signals as text (`/net`, or any expression
such as `VT("/inp")-VT("/inn")`) and writes the finished `LOdelay(...)` call
into the Buffer -- the same line that goes into a Maestro output.

## Tests

IC6.1.8 + Spectre 18.1; the scripts expect the Cadence environment in `~/.cshrc`.

```sh
cd calcfn/test
spectre -64 -format psfxl -raw psf tb.scs          # shared test bench (in tcsh)
./run.sh LOdelay.ocn                               # 26 cases with known answers
./run_gui.sh LOdelay_gui.ocn                       # Calculator form -> Buffer (Xvfb)
./run_gui.sh mae/LOdelay_mae.ocn                   # builds calcfn_tb/LOdelay + maestro, runs it
```

`mae/` has its own `cds.lib` (analogLib from `$CDSHOME`), so the test library
stays out of your workarea `cds.lib`.
