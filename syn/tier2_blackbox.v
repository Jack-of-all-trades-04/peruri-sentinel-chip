// Black-box declarations for the yosys check of the Tier 2 top.
// sys_pll is a Quartus IP and ro_cell is a deliberate combinational loop;
// neither can go through the generic loop check.
(* blackbox *)
module sys_pll (
    input  wire refclk,
    input  wire rst,
    output wire outclk_0,
    output wire outclk_1,
    output wire outclk_2,
    output wire locked
);
endmodule

(* blackbox *)
module ro_cell #(
    parameter integer STAGES = 13
) (
    input  wire en,
    output wire osc
);
endmodule
