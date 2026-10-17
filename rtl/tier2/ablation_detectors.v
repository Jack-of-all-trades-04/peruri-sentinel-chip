// ablation_detectors: the two reference detectors for the three-way
// ablation (fixed threshold vs EWMA vs LIF), on the same RO window counts.
//
//   fixed_alarm  any |x_j - ref_j| >= FTH, where ref_j is the count of
//                window WARMUP after reset (static reference)
//   ewma_alarm   any |x_j - b_j| >= ETH, b_j = EWMA baseline (shift S),
//                no common-mode removal and no temporal integration
//
// Both are one-cycle pulses on the window strobe. Only one detector drives
// the tamper FSM in a given build (DETECTOR_SEL in peruri_sentinel_core_t2);
// all three are always computed so the board can log them side by side.
module ablation_detectors #(
    parameter integer NUM        = 8,
    parameter integer CNT_W      = 16,
    parameter integer EWMA_SHIFT = 3,
    parameter integer FTH        = 12,
    parameter integer ETH        = 8,
    parameter integer WARMUP     = 4
) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire [NUM*CNT_W-1:0] ro_counts,
    input  wire                 ro_valid,
    output reg                  fixed_alarm,
    output reg                  ewma_alarm
);
    localparam integer BW = CNT_W + EWMA_SHIFT;
    localparam integer DW = CNT_W + 2;

    reg [CNT_W-1:0] refv [0:NUM-1];
    reg [BW-1:0]    base [0:NUM-1];
    reg [3:0]       wcount;

    integer k;
    reg signed [DW-1:0] dfix, dewm;
    reg                 af, ae;

    always @(*) begin
        af = 1'b0;
        ae = 1'b0;
        for (k = 0; k < NUM; k = k + 1) begin
            dfix = $signed({2'b00, ro_counts[k*CNT_W +: CNT_W]}) - $signed({2'b00, refv[k]});
            dewm = $signed({2'b00, ro_counts[k*CNT_W +: CNT_W]}) - $signed({2'b00, base[k][BW-1:EWMA_SHIFT]});
            if (dfix >= FTH || dfix <= -FTH) af = 1'b1;
            if (dewm >= ETH || dewm <= -ETH) ae = 1'b1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (k = 0; k < NUM; k = k + 1) begin
                refv[k] <= {CNT_W{1'b0}};
                base[k] <= {BW{1'b0}};
            end
            wcount      <= 4'd0;
            fixed_alarm <= 1'b0;
            ewma_alarm  <= 1'b0;
        end else begin
            fixed_alarm <= 1'b0;
            ewma_alarm  <= 1'b0;
            if (ro_valid) begin
                if (wcount != 4'hf) wcount <= wcount + 4'd1;
                for (k = 0; k < NUM; k = k + 1) begin
                    if (wcount == 4'd0)
                        base[k] <= {ro_counts[k*CNT_W +: CNT_W], {EWMA_SHIFT{1'b0}}};
                    else
                        base[k] <= base[k] + ro_counts[k*CNT_W +: CNT_W]
                                           - base[k][BW-1:EWMA_SHIFT];
                    if (wcount == WARMUP)
                        refv[k] <= ro_counts[k*CNT_W +: CNT_W];
                end
                if (wcount > WARMUP) begin
                    fixed_alarm <= af;
                    ewma_alarm  <= ae;
                end
            end
        end
    end
endmodule
