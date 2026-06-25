LOGIC-discipline example: digital leaf cells modeled in 4-state logic (not wreal).
Stage A auto-detects discipline=logic from the leaves and does NOT wreal-ize the struct,
so there are no wreal<->logic boundaries (no *E,CUNDCM). Mirrors the real PLL N-divider,
whose leaves are all digital logic. Run: vh_extract --netlist oa_netlist/gtop_raw.v
--cdslib cds.lib --lib llib --cell gtop --out <out>; then vh_gen --src <out>/export.
