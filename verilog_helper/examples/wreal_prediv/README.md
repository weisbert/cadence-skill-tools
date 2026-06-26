# examples/wreal_prediv — Stage B revives a supply-gated TSPC prescaler

The case that killed the **real LPBT_NDIV_TOP clock tree**. `pll_ndiv_div2_tspc` (mirrored
here as `sdiv2`) is a divide-by-2 flop gated by a wreal supply **headroom** check:

```verilog
wreal VDD, VSS, VPP;
assign power_on = ((VDD-VSS)>0.8*0.9)&&((VPP-VSS)>0.8*0.9);
always @(posedge CLK) if (power_on) Q <= ~Q; else Q <= 0;
```

In the schematic the rails come in on **global/inherited** nets, so `oa2verilog` emits the
divider instances with **no supply connection** (`sdiv2 I7 (.CLK(fromVCO), .Q(net1));`). Under
pure-digital xrun the wreal rails float to `0`, `power_on` is false, `Q` is stuck — and the
**entire** prescaler/divider chain hanging off it is dead (zero edges everywhere, including the
CAL `VCO/4` and TEST `VCO/16` taps).

## Why the earlier Stage B missed it
The detector only accepted a wreal net **immediately** followed by a comparator (`(VDD>k)`).
The headroom form `(VDD-VSS)>k` has a `-` after `VDD`, so the cell was waved through as
"already digital" and shipped unchanged → dead. Stage B now recognizes the
**supply-difference / headroom** form too: `(SUP ± SUP) <cmp> const → 1'b1` (rail nominal).
Result: `power_on = (1'b1)&&(1'b1)` → a clean `always @(posedge CLK) Q<=~Q;` /2 divider.

## Run
```
./run.sh        # Stage B converts -> xrun -> === TB PASS === (CLKOUT = VCO/4)
./run.sh raw    # original wreal prediv -> CLKOUT dead (the failure it fixes)
```
(`vh_convert` writes the converted candidate `veriloga_wreal.va`; `run.sh` converts a COPY so
the example dir stays clean. Note the `rm -rf xcelium.d` — a stale worklib will silently reuse
the old raw module and hide the fix.)
