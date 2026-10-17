// ro_cell (Quartus build only): ring oscillator of STAGES kept LUTs.
// One NAND (enable) plus STAGES-1 inverters; STAGES must be odd.
//
// This is a deliberate combinational loop. It is excluded from RTL
// simulation (sim/tier2/models/ro_cell.v replaces it) and from the yosys
// loop check (treated as a black box). Quartus reports a combinational-loop
// warning for each instance; that warning is expected. Confirm in the
// Technology Map Viewer that every instance still has STAGES LUTs.
module ro_cell #(
    parameter integer STAGES = 13
) (
    input  wire en,
    output wire osc
);
    (* keep = 1 *) wire [STAGES-1:0] n;
    assign n[0] = ~(n[STAGES-1] & en);
    genvar i;
    generate
        for (i = 1; i < STAGES; i = i + 1) begin : g_inv
            assign n[i] = ~n[i - 1];
        end
    endgenerate
    assign osc = n[STAGES-1];
endmodule
