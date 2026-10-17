// Simulation-only model of ro_cell: an oscillator whose half period (ns)
// the testbench can change at run time through `half_ns`.
`timescale 1ns/1ps
module ro_cell #(
    parameter integer STAGES = 13
) (
    input  wire en,
    output reg  osc
);
    real half_ns;
    initial begin
        half_ns = 2.0;
        osc     = 1'b0;
        forever begin
            #(half_ns);
            if (en) osc = ~osc;
            else    osc = 1'b0;
        end
    end
endmodule
