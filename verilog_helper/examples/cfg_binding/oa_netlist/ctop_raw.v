// captured oa2verilog -view schematic netlist (cdelay/cinv come out as empty
// interfaces because their schematic is cmos_sch / config picks verilogams).
module ctop ( in, en, out );
  input in, en;
  output out;
  wire mid;
  cdelay D ( .a(in), .en(en), .z(mid) );
  cinv I ( .i(mid), .zn(out) );
endmodule

module cdelay ( a, en, z );
  input a, en;
  output z;
endmodule

module cinv ( i, zn );
  input i;
  output zn;
endmodule
