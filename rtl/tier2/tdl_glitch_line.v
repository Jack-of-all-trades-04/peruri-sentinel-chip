// tdl_glitch_line: tapped-delay-line canary on CLK_sys (after Zick et al.,
// FPGA '13). Lives in the attacked clock domain; its alert goes straight to
// output_release_gate without any clock-domain crossing.
//
// How it works
//   1. `launch` toggles on every CLK_sys edge.
//   2. The edge runs through a coarse delay and then through an L-bit carry
//      chain (an adder, so Quartus maps it to the Cyclone V fast-carry chain).
//      The coarse delay is a chain of COARSE kept inverter LUTs; a mux picks
//      the tap `cd[sel]` that feeds the carry chain, so the delay is chosen
//      at run time instead of at compile time.
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
// Calibration (after every reset): wait CAL_SETTLE cycles, then sweep `sel`
// from 0 upwards. For each `sel`, wait SEL_SETTLE cycles and record the
// minimum and maximum depth per polarity over CAL_WIN cycles. The first `sel`
// whose depths all lie in [TGT_LO, TGT_HI] is kept (strict pass). If no `sel`
// qualifies, the sweep repeats with the loose limits [K_TDL + 1, L - 1].
// Sweeping from the shortest delay means the first hit is the one where the
// edge arrives within the same period (no wrap into the next period).
// Threshold = minimum - K_TDL. If both passes fail, `cal_bad` = 1 and the
// line never alerts.
//
// Latency: the glitched edge is captured into cap1, re-registered into cap2
// (metastability guard), counted into depth_q, and `alert` is combinational
// from depth_q. The gate sees the alert 2-3 CLK_sys cycles after the
// glitched edge (target; to be confirmed on the board), inside its hold
// window of H = 4 cycles after aes_done.
//
// RTL simulation has zero delay: the edge always passes all L taps, so the
// line reports cal_bad. Testbenches force `sum` to model a depth.
module tdl_glitch_line #(
    parameter integer L          = 64,     // carry-chain taps
    parameter integer COARSE     = 63,     // kept inverter LUTs; run-time tap select 0..COARSE
    parameter integer K_TDL      = 4,      // margin below calibrated minimum
    parameter integer CAL_SETTLE = 1024,   // cycles before calibration starts
    parameter integer CAL_WIN    = 4096,   // calibration window per tap, cycles
    parameter integer SEL_SETTLE = 8,      // cycles after a tap change (pipeline is 3 deep)
    parameter integer TGT_LO     = L / 4,  // strict pass: lowest accepted depth
    parameter integer TGT_HI     = L - 4   // strict pass: highest accepted depth
) (
    input  wire                         clk,       // CLK_sys (the attacked clock)
    input  wire                         rst_n,
    input  wire                         enable,    // Sentinel ON
    output wire                         alert,     // combinational from registers
    output reg                          armed,
    output reg                          cal_bad,
    output reg  [$clog2(L+1)-1:0]       depth_q,   // last measured depth
    output reg  [$clog2(L+1)-1:0]       min_r,     // calibrated minimum, rising edge
    output reg  [$clog2(L+1)-1:0]       min_f,     // calibrated minimum, falling edge
    output reg  [$clog2(COARSE+1)-1:0]  sel        // selected coarse tap
);
    localparam integer IDXW = $clog2(L + 1);
    localparam integer SW   = $clog2(COARSE + 1);
    localparam integer CW   = $clog2(CAL_SETTLE + CAL_WIN + 2);
    localparam [IDXW-1:0] KT    = K_TDL[IDXW-1:0];        // width-exact margin
    localparam [IDXW-1:0] S_LO  = TGT_LO[IDXW-1:0];
    localparam [IDXW-1:0] S_HI  = TGT_HI[IDXW-1:0];
    localparam [IDXW-1:0] L_LO  = K_TDL + 1;
    localparam [IDXW-1:0] L_HI  = L - 1;
    localparam [SW-1:0]   SMAX  = COARSE[SW-1:0];
    localparam [CW-1:0]   C_RE  = CAL_SETTLE - SEL_SETTLE; // ccnt start after a tap change

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

    // run-time tap select; cd[sel] is launch inverted sel times
    (* keep = 1 *) wire chain_in;
    assign chain_in = cd[sel];
    reg inv;                               // polarity of the selected tap
    always @(posedge clk or negedge rst_n)
        if (!rst_n) inv <= 1'b0;
        else        inv <= sel[0];

    // ---------------- fine delay: carry chain ----------------
    // `ones` is a preserved register so synthesis cannot fold the adder
    // into constants and must build the carry chain. It is cleared by reset
    // and loads all ones on the first clock (D = constant 1). An earlier
    // version held its value (ones <= ones) and Quartus inferred 64 latches.
    // The first cycles after reset are covered by CAL_SETTLE.
    (* preserve *) reg [L-1:0] ones;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) ones <= {L{1'b0}};
        else        ones <= {L{1'b1}};
    end
    (* keep = 1 *) wire [L:0] sum;
    assign sum = {1'b0, ones} + {{L{1'b0}}, chain_in};

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
    wire        rise2   = ph2 ^ inv;
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
    localparam [1:0] C_SETTLE = 2'd0, C_RUN = 2'd1, C_EVAL = 2'd2, C_DONE = 2'd3;
    reg [1:0]      cst;
    reg [CW-1:0]   ccnt;
    reg            pass;               // 0 strict limits, 1 loose limits
    reg [IDXW-1:0] max_r, max_f, thr_r, thr_f;

    wire [IDXW-1:0] lo = pass ? L_LO : S_LO;
    wire [IDXW-1:0] hi = pass ? L_HI : S_HI;
    wire cal_good = (min_r >= lo) && (min_f >= lo) && (max_r <= hi) && (max_f <= hi) &&
                    (min_r <= max_r) && (min_f <= max_f);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cst     <= C_SETTLE;
            ccnt    <= {CW{1'b0}};
            pass    <= 1'b0;
            sel     <= {SW{1'b0}};
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
                        cst <= C_EVAL;
                    else
                        ccnt <= ccnt + 1'b1;
                end
                C_EVAL: begin
                    if (cal_good) begin
                        thr_r <= min_r - KT;
                        thr_f <= min_f - KT;
                        armed <= 1'b1;
                        cst   <= C_DONE;
                    end else if (sel == SMAX && pass) begin
                        cal_bad <= 1'b1;
                        cst     <= C_DONE;
                    end else begin
                        // next tap (or restart the sweep with loose limits)
                        if (sel == SMAX) begin
                            sel  <= {SW{1'b0}};
                            pass <= 1'b1;
                        end else
                            sel  <= sel + 1'b1;
                        min_r <= {IDXW{1'b1}};
                        min_f <= {IDXW{1'b1}};
                        max_r <= {IDXW{1'b0}};
                        max_f <= {IDXW{1'b0}};
                        ccnt  <= C_RE;
                        cst   <= C_SETTLE;
                    end
                end
                default: ;     // C_DONE: hold until reset
            endcase
        end
    end

    // ---------------- alert ----------------
    // Compare the registered depth (number of passed taps, a popcount) with
    // the threshold of the same edge polarity. A real carry chain sometimes
    // captures one or two taps out of order near the transition ("bubbles");
    // a popcount is not fooled by that, while testing the single tap
    // `threshold` was (first board run: steady false alarms). Cost: one more
    // cycle of latency, and a shorter timing path into the gate.
    wire [IDXW-1:0] thr_q = rise3 ? thr_r : thr_f;
    assign alert = enable & armed & (depth_q <= thr_q);
endmodule
