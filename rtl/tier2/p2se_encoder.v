// p2se_encoder: turns RO window counts and the TDL event into a 12-bit
// spike vector (CLK_sentinel domain).
//
// RO channels (spike_bus[7:0]), on every ro_valid:
//   b_j    slow baseline of channel j, EWMA with shift EWMA_SHIFT
//   dev_j  = x_j - b_j                   (fast change of channel j)
//   cm     = mean(dev_j)  (>> LOG2_NUM)  (change shared by all channels)
//   r_j    = dev_j - cm                  (local part of the change)
//   spike_j = |r_j| >= DTH
// Slow drift is absorbed by the baseline; a fast change that hits all ROs
// together (ambient temperature, board supply) is removed by the common
// mode; a fast change on one or two ROs (local probing, local heating)
// remains and produces spikes.
//
// TDL channels (spike_bus[11:8]): bit 8 = a TDL/fast-path event was seen
// since the last tick; bits 11:9 are reserved (single TDL line in Tier 2).
//
// The first WARMUP windows only load the baseline; no spikes are produced.
// Output `tick` pulses with each new spike_bus (2 cycles after ro_valid).
module p2se_encoder #(
    parameter integer NUM        = 8,      // must be 2**LOG2_NUM
    parameter integer LOG2_NUM   = 3,
    parameter integer CNT_W      = 16,
    parameter integer EWMA_SHIFT = 3,
    parameter integer DTH        = 8,      // spike threshold, counts per window
    parameter integer WARMUP     = 4       // windows
) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire [NUM*CNT_W-1:0] ro_counts,
    input  wire                 ro_valid,
    input  wire                 tdl_event,   // level/pulse in this domain
    output reg  [11:0]          spike_bus,
    output reg                  tick
);
    localparam integer BW = CNT_W + EWMA_SHIFT;   // baseline with fraction
    localparam integer DW = CNT_W + 2;            // signed deviation width

    reg [BW-1:0]          base   [0:NUM-1];
    reg signed [DW-1:0]   dev    [0:NUM-1];
    reg [3:0]             wcount;
    reg                   s1;          // stage-1 valid
    reg                   tdl_seen;

    wire spikes_on = (wcount >= WARMUP);

    integer k;

    // stage 1: deviation from baseline, baseline update
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (k = 0; k < NUM; k = k + 1) begin
                base[k] <= {BW{1'b0}};
                dev[k]  <= {DW{1'b0}};
            end
            wcount <= 4'd0;
            s1     <= 1'b0;
        end else begin
            s1 <= 1'b0;
            if (ro_valid) begin
                s1 <= 1'b1;
                if (wcount != 4'hf) wcount <= wcount + 4'd1;
                for (k = 0; k < NUM; k = k + 1) begin
                    if (wcount == 4'd0) begin
                        base[k] <= {ro_counts[k*CNT_W +: CNT_W], {EWMA_SHIFT{1'b0}}};
                        dev[k]  <= {DW{1'b0}};
                    end else begin
                        dev[k]  <= $signed({2'b00, ro_counts[k*CNT_W +: CNT_W]})
                                 - $signed({2'b00, base[k][BW-1:EWMA_SHIFT]});
                        // base += x - base/2^S   (in fixed point)
                        base[k] <= base[k] + ro_counts[k*CNT_W +: CNT_W]
                                           - base[k][BW-1:EWMA_SHIFT];
                    end
                end
            end
        end
    end

    // stage 2: common-mode removal and threshold
    reg signed [DW+LOG2_NUM-1:0] sum_dev;
    reg signed [DW-1:0]          cm;
    reg signed [DW-1:0]          r;
    reg [NUM-1:0]                sp;
    always @(*) begin
        sum_dev = {(DW+LOG2_NUM){1'b0}};
        for (k = 0; k < NUM; k = k + 1)
            sum_dev = sum_dev + dev[k];
        cm = sum_dev >>> LOG2_NUM;
        for (k = 0; k < NUM; k = k + 1) begin
            r     = dev[k] - cm;
            sp[k] = (r >= DTH) || (r <= -DTH);
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spike_bus <= 12'h000;
            tick      <= 1'b0;
            tdl_seen  <= 1'b0;
        end else begin
            tick <= 1'b0;
            if (tdl_event) tdl_seen <= 1'b1;
            if (s1) begin
                tick      <= 1'b1;
                spike_bus <= {3'b000, tdl_seen | tdl_event, spikes_on ? sp : {NUM{1'b0}}};
                tdl_seen  <= 1'b0;
            end
        end
    end
endmodule
