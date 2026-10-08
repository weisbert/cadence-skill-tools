// Captured oa2verilog-style structural netlist for cell "lvl_top".
module ana_gain (
    i,
    o);
    input i;
    output o;
endmodule // ana_gain

module lvl_top (
    in,
    out);
    input in;
    output out;

    ana_gain g1 (
            .i(in),
            .o(out));
endmodule // lvl_top
