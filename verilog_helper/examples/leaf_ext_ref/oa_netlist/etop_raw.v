// captured oa2verilog -view schematic netlist. ediv2 comes out as an empty interface
// (its schematic is cmos_sch). ediv2 is a genuine LEAF that happens to reference an
// external -v std cell (STDBUF).
module etop ( clk, qo );
  input clk;
  output qo;
  ediv2 U ( .clk(clk), .q(qo) );
endmodule

module ediv2 ( clk, q );
  input clk;
  output q;
endmodule
