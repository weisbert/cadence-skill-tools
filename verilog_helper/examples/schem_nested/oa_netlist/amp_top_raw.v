// Verilog file for cell "amp_top" view "schematic"
// Language Version: 2001
//
// This is a CAPTURED oa2verilog-style structural netlist (what Stage A's NETLIST
// phase would emit on the box with OA). It is checked in so the pure-python PROCESS
// phase runs end-to-end without a live OA design:
//     vh_extract.py --config ... --netlist oa_netlist/amp_top_raw.v --out build
//
// gain2 and adder resolve to demolib veriloga leaves on disk (-> gathered as .va);
// offset1 has NO veriloga (-> recorded EXTERNAL, stubbed by Stage C as a unity buf).

module gain2 (
    i,
    o);

    input i;
    output o;

endmodule // gain2


module adder (
    a,
    b,
    y);

    input a;
    input b;
    output y;

endmodule // adder


module offset1 (
    i,
    o);

    input i;
    output o;

endmodule // offset1


module amp_top (
    in1,
    in2,
    out);

    input in1;
    input in2;
    output out;

    wire n1;
    wire n2;

    gain2 g1 (
            .i(in1),
            .o(n1));
    offset1 e1 (
            .i(in2),
            .o(n2));
    adder a1 (
            .a(n1),
            .b(n2),
            .y(out));

endmodule // amp_top
