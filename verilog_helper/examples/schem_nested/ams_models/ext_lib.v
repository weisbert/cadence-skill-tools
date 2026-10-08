// External HDL library file (the kind that lives under .../workarea/ams_models/ and is
// listed in an AMS testbench's "Library Files (-v)"). Here it provides the REAL behavior
// of offset1 (a +1.0 offset), so Stage A resolves it instead of stubbing, and xrun
// compiles it via -v. With this lib:  out = 2*in1 + (in2 + 1).
`include "disciplines.vams"
`timescale 1s/1fs
module offset1(i, o);
  input  i;
  output o;
  wreal  i, o;
  assign o = i + 1.0;
endmodule
