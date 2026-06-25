module gtop ( i0, i1, o );
  input  i0;
  input  i1;
  output o;
  wire   n1;
  glog I0 ( .a(i0), .b(i1), .y(n1), .VDD(vdd), .VSS(vss) );
  gbuf I1 ( .a(n1), .y(o), .VDD(vdd), .VSS(vss) );
endmodule
module glog ( a, b, y, VDD, VSS ); input a,b,VDD,VSS; output y; endmodule
module gbuf ( a, y, VDD, VSS ); input a,VDD,VSS; output y; endmodule
