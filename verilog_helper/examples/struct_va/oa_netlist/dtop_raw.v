// mimics oa2verilog output: ports get only the direction decl (no separate wire),
// internal nets get `wire`; a cell with a verilogams view comes out as an empty
// interface (delaycell) -- which Stage A then gathers + descends into.
module dtop (a, z);
  input  a;
  output z;
  delaycell I0 ( .din(a), .dout(z) );
endmodule
module delaycell (din, dout);
  input  din;
  output dout;
endmodule
