module lstop ( clk, en, VDD, VPP, VSS, o );
  input clk; input en; input VDD; input VPP; input VSS; output o;
  wire q, cq, nb;
  ctr   I0 ( .clk(clk), .VDD(VDD), .VPP(VPP), .VSS(VSS), .clkout(cq) );
  ldiv2 I1 ( .Q(q), .VDD(VDD), .VPP(VPP), .VSS(VSS), .CLK(cq) );
  lnand I2 ( .Y(nb), .A(q), .B(en), .VDD(VDD), .VPP(VPP), .VSS(VSS) );
  linv  I3 ( .ZN(o), .VDD(VDD), .VPP(VPP), .VSS(VSS), .I(nb) );
endmodule
module ldiv2 ( Q, VDD, VPP, VSS, CLK ); output Q; input VDD,VPP,VSS,CLK; endmodule
module linv ( ZN, VDD, VPP, VSS, I ); output ZN; input VDD,VPP,VSS,I; endmodule
module lnand ( Y, A, B, VDD, VPP, VSS ); output Y; input A,B,VDD,VPP,VSS; endmodule
