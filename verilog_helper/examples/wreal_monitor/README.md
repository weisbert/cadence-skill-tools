# examples/wreal_monitor — Stage B converts a wreal supply/enable monitor to logic

Covers the genuine **functional wreal↔logic boundary** case (not supply-only). `wmon_buf` is a
buffer that passes `IN→OUT` only when the supplies are nominal AND `en` is high — but `en` and
the supplies are declared `wreal` (read as analog *levels* via threshold comparisons). On a
logic design that wreal `en` meets a logic net → `*E,CUNDCM` (no connect module).

Stage B (`vh_convert`) recognizes the pattern and converts it to the pure-digital functional
core: supply thresholds → assumed-OK (`1'b1`), the signal threshold `(en > k)` → the logic
enable `en`, i.e. **`OUT = en ? IN : 1'b0`**. Result is pure logic → boundary gone.

## Files
- `wmon_buf.vams` — the wreal supply/enable monitor (synthetic; mirrors a real XO output driver).
- `wmon_top.vams` — logic top; its logic `en` meets `wmon_buf`'s wreal `en` (the boundary).
- `tb_wmon.vams` — drives `en`/`IN`, asserts `OUT = en ? IN : 0`.

## Run
```
./run.sh        # Stage B converts -> xrun -> === TB PASS (OUT = en ? IN : 0) ===
./run.sh raw    # original wreal driver -> shows the *E,CUNDCM boundary it fixes
```
(`vh_convert` writes the converted candidate `veriloga_wreal.va` beside the cell — non-
destructive; in a real build, Stage B also updates the `export/` copy used for verification.)
