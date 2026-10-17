// tdl_glitch_line: tapped-delay-line canary on CLK_sys (after Zick et al.,
// FPGA '13). Lives in the attacked clock domain; its alert goes straight to
// output_release_gate without any clock-domain crossing.
//
// How it works
//   1. `launch` toggles on every CLK_sys edge.
//   2. The edge runs through a coarse delay (COARSE kept inverter LUTs) and
//      then through an L-bit carry chain (an adder, so Quartus maps it to the
//      Cyclone V fast-carry chain).
//   3. The carry-chain taps are captured on the next CLK_sys edge. The number
//      of taps the edge has passed ("depth") measures how much time the
//      period left after the coarse delay.
//   4. A shortened clock period (clock glitch) or a slower logic (supply
//      droop) lowers the depth. If depth drops to or below a calibrated
//      threshold, `alert` is raised.
//
// Rising and falling launch edges travel at different speeds, so each
// polarity has its own calibration and threshold.
//
// Calibration (after every reset): wait CAL_SETTLE cycles, then record the
// minimum and maximum depth per polarity over CAL_WIN cycles. Threshold =
// minimum - K_TDL. The line is armed only if the calibration is usable:
// minimum > K_TDL (edge reaches the chain) and maximum < L (chain not
// saturated). Otherwise `cal_bad` = 1 and the line never alerts; change
// COARSE and rebuild (see quartus/tier2/README.md).
//
// Latency: the glitched edge is captured into cap1, re-registered into cap2
// (metastability guard), and `alert` is combinational from cap2. The gate
// therefore sees the alert on the first edge after cap2, i.e. 1-2 CLK_sys
// cycles after the glitched edge (target; to be confirmed on the board).
//
// RTL simulation has zero delay: the edge always passes all L taps, so the
// line reports cal_bad. Testbenches force `sum` to model a depth.
module tdl_glitch_line #(
    parameter integer L          = 64,     // carry-chain taps
    parameter integer COARSE     = 24,     // kept inverter LUTs before the chain (tune on board)
    parameter integer K_TDL      = 4,      // margin below calibrated minimum
    parameter integer CAL_SETTLE = 1024,   // cycles before calibration starts
    parameter integer CAL_WIN    = 4096    // calibration window, cycles
) (
    input  wire                         clk,       // CLK_sys (the attacked clock)
    input  wire                         rst_n,
    input  wire                         enable,    // Sentinel ON
    output wire                         alert,     // combinational from registers
    output reg                          armed,
    output reg                          cal_bad,
    output reg  [$clog2(L+1)-1:0]       depth_q,   // last measured depth
    output reg  [$clog2(L+1)-1:0]       min_r,     // calibrated minimum, rising edge
    output reg  [$clog2(L+1)-1:0]       min_f      // calibrated minimum, falling edge
);
    localparam integer IDXW = $clog2(L + 1);
    localparam integer INV  = COARSE % 2;          // polarity of the coarse chain
    localparam integer CW   = $clog2(CAL_SETTLE + CAL_WIN + 2);

    // ---------------- launch ----------------
    reg launch;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) launch <= 1'b0;
        else        launch <= ~launch;
    end

    // ---------------- coarse delay: kept inverter LUTs ----------------
    (* keep = 1 *) wire [COARSE:0] cd;
    assign cd[0] = launch;
    genvar gi;
    generate
        for (gi = 0; gi < COARSE; gi = gi + 1) begin : g_cd
            assign cd[gi + 1] = ~cd[gi];
        end
    endgenerate

    // ---------------- fine delay: carry chain ----------------
    // `ones` is a preserved register (all ones after reset) so synthesis
    // cannot fold the adder into constants and must build the carry chain.
    (* preserve *) reg [L-1:0] ones;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) ones <= {L{1'b1}};
        else        ones <= ones;
    end
    (* keep = 1 *) wire [L:0] sum;
    assign sum = {1'b0, ones} + {{L{1'b0}}, cd[COARSE]};

    // ---------------- capture ----------------
    (* preserve *) reg [L-1:0] cap1;   // may sample mid-transition
    reg [L-1:0] cap2;
    reg         ph1, ph2;              // launch value that cap1/cap2 belong to
    always @(posedge clk) begin
        cap1 <= sum[L-1:0];
        cap2 <= cap1;
        ph1  <= launch;
        ph2  <= ph1;
    end

    // passed[i] = 1 when the edge reached tap i. Rising edge at the chain
    // input turns taps from 1 to 0; falling edge turns them from 0 to 1.
    wire        rise2   = ph2 ^ (INV != 0);
    wire [L-1:0] passed2 = rise2 ? ~cap2 : cap2;

    function [IDXW-1:0] popcnt;
        input [L-1:0] v;
        integer k;
        begin
            popcnt = {IDXW{1'b0}};
            for (k = 0; k < L; k = k + 1)
                popcnt = popcnt + v[k];
        end
    endfunction

    reg rise3;
    always @(posedge clk) begin
        depth_q <= popcnt(passed2);
        rise3   <= rise2;
    end

    // ---------------- calibration ----------------
    localparam [1:0] C_SETTLE = 2'd0, C_RUN = 2'd1, C_DONE = 2'd2;
    reg [1:0]      cst;
    reg [CW-1:0]   ccnt;
    reg [IDXW-1:0] max_r, max_f, thr_r, thr_f;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cst     <= C_SETTLE;
            ccnt    <= {CW{1'b0}};
            min_r   <= {IDXW{1'b1}};
            min_f   <= {IDXW{1'b1}};
            max_r   <= {IDXW{1'b0}};
            max_f   <= {IDXW{1'b0}};
            thr_r   <= {IDXW{1'b0}};
            thr_f   <= {IDXW{1'b0}};
            armed   <= 1'b0;
            cal_bad <= 1'b0;
        end else begin
            case (cst)
                C_SETTLE: begin
                    if (ccnt == CAL_SETTLE - 1) begin
                        cst  <= C_RUN;
                        ccnt <= {CW{1'b0}};
                    end else
                        ccnt <= ccnt + 1'b1;
                end
                C_RUN: begin
                    if (rise3) begin
                        if (depth_q < min_r) min_r <= depth_q;
                        if (depth_q > max_r) max_r <= depth_q;
                    end else begin
                        if (depth_q < min_f) min_f <= depth_q;
                        if (depth_q > max_f) max_f <= depth_q;
                    end
                    if (ccnt == CAL_WIN - 1)
                        cst <= C_DONE;
                    else
                        ccnt <= ccnt + 1'b1;
                end
                C_DONE: begin
                    if (!armed && !cal_bad) begin
                        if (min_r <= K_TDL || min_f <= K_TDL || max_r >= L || max_f >= L ||
                            min_r > max_r || min_f > max_f)
                            cal_bad <= 1'b1;
                        else begin
                            thr_r <= min_r - K_TDL;
                            thr_f <= min_f - K_TDL;
                            armed <= 1'b1;
                        end
                    end
                end
                default: cst <= C_SETTLE;
            endcase
        end
    end

    // ---------------- alert ----------------
    // depth <= threshold  <=>  tap `threshold` not passed.
    wire tap_ok = rise2 ? passed2[thr_r] : passed2[thr_f];
    assign alert = enable & armed & ~tap_ok;
endmodule
