// external std-cell library, supplied to xrun via -v (vh_env). The leaf ediv2
// references STDBUF from here -- it is an EXTERNAL LEAF REFERENCE, not a reason to
// descend ediv2's transistor cmos_sch.
module STDBUF ( a, y );
  input a;
  output y;
  assign y = a;
endmodule
