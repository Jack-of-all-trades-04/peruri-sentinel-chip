// clock_monitor: watches a clock using a LOCAL ring oscillator as the time
// base (P2-1 / F9-3A / B1-5). The attack it closes: stopping or strongly
// slewing CLK_sentinel so the slow-path sensors (RO mesh, LIF) stop producing
// windows and therefore stop raising alarms. A ratio monitor between the two
// PLL outputs is blind to that, because on an FPGA both come from one PLL and
// keep their ratio when the source is slowed; a local free-running oscillator
// does not, so it is the independent time base.
//
// ro_clk is a free-running oscillator (on the FPGA a kept LUT ring, same cell
// as ro_sensor_mesh; in an ASIC an internal oscillator that cannot be reached
// from outside). clk_mon is counted in its OWN domain with a Gray counter;
// the Gray value crosses into ro_clk through a 2-FF synchronizer (at most +-1
// count error). Over each window of WINDOW ro_clk cycles the monitor takes the
// difference of the counter = how many clk_mon cycles happened. Zero (stopped)
// or <= LO (too slow) or >= HI (too fast) raises alarm. Bounds are wide on
// purpose: small PVT drift is the TDL's job, this only catches gross tamper.
module clock_monitor #(
    parameter integer WINDOW = 256,
    parameter integer LO     = 25,
    parameter integer HI     = 205,
    parameter integer CW     = 12
) (
    input  wire ro_clk,
    input  wire rst_n,
    input  wire en,
    input  wire clk_mon,
    output reg  alarm,
    output reg  valid
);
    // ---- free-running Gray counter in the monitored clock domain ----
    reg [CW-1:0] bin_m, gray_m;
    always @(posedge clk_mon or negedge rst_n) begin
        if (!rst_n) begin
            bin_m  <= {CW{1'b0}};
            gray_m <= {CW{1'b0}};
        end else begin
            bin_m  <= bin_m + 1'b1;
            gray_m <= (bin_m + 1'b1) ^ ((bin_m + 1'b1) >> 1);
        end
    end

    // ---- cross into ro_clk, convert to binary ----
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [CW-1:0] gs1, gs2;
    function [CW-1:0] g2b;
        input [CW-1:0] g; integer k;
        begin
            g2b[CW-1] = g[CW-1];
            for (k = CW-2; k >= 0; k = k - 1) g2b[k] = g2b[k+1] ^ g[k];
        end
    endfunction

    localparam integer WW = $clog2(WINDOW + 1);
    reg [WW-1:0] wcnt;
    reg [CW-1:0] prev;
    wire [CW-1:0] cur = g2b(gs2);
    wire [CW-1:0] edges = cur - prev;
    wire wend = (wcnt == WINDOW - 1);

    always @(posedge ro_clk or negedge rst_n) begin
        if (!rst_n) begin
            gs1 <= {CW{1'b0}}; gs2 <= {CW{1'b0}};
            wcnt <= {WW{1'b0}}; prev <= {CW{1'b0}};
            alarm <= 1'b0; valid <= 1'b0;
        end else begin
            gs1   <= gray_m;
            gs2   <= gs1;
            alarm <= 1'b0;
            valid <= 1'b0;
            if (!en) begin
                wcnt <= {WW{1'b0}};
                prev <= cur;
            end else if (wend) begin
                valid <= 1'b1;
                if (edges <= LO[CW-1:0] || edges >= HI[CW-1:0])
                    alarm <= 1'b1;
                wcnt <= {WW{1'b0}};
                prev <= cur;
            end else
                wcnt <= wcnt + 1'b1;
        end
    end
endmodule
