// ro_sensor_mesh: NUM ring oscillators with frequency counters (slow path,
// CLK_sentinel domain).
//
// Per oscillator:
//   ro_cell -> ripple divider (2^DIV_BITS) -> Gray counter in the divided
//   RO clock -> 2-FF synchronizer into clk -> binary.
// Every WINDOW clk cycles the module outputs, for each RO, how many divided
// RO cycles happened in the window (ro_counts) and pulses `valid`.
// Gray code makes the multi-bit crossing safe (at most +/-1 count error).
//
// ro_cell is the only vendor-specific part. Quartus uses
// rtl/tier2/fpga/ro_cell.v (a kept LUT loop); simulation uses a behavioral
// model whose frequency the testbench can change.
module ro_sensor_mesh #(
    parameter integer NUM      = 8,
    parameter integer STAGES   = 13,     // odd, ring length
    parameter integer DIV_BITS = 3,
    parameter integer CNT_W    = 16,
    parameter integer WINDOW   = 256     // clk cycles per measurement
) (
    input  wire                 clk,     // CLK_sentinel
    input  wire                 rst_n,
    input  wire                 en,
    output reg  [NUM*CNT_W-1:0] ro_counts,
    output reg                  valid
);
    localparam integer WW = $clog2(WINDOW + 1);

    function [CNT_W-1:0] g2b;
        input [CNT_W-1:0] g;
        integer k;
        begin
            g2b[CNT_W-1] = g[CNT_W-1];
            for (k = CNT_W - 2; k >= 0; k = k - 1)
                g2b[k] = g2b[k + 1] ^ g[k];
        end
    endfunction

    // window timer
    reg [WW-1:0] wcnt;
    wire         wend = (wcnt == WINDOW - 1);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)    wcnt <= {WW{1'b0}};
        else if (wend) wcnt <= {WW{1'b0}};
        else           wcnt <= wcnt + 1'b1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) valid <= 1'b0;
        else        valid <= wend;
    end

    genvar i, j;
    generate
        for (i = 0; i < NUM; i = i + 1) begin : g_ro
            wire osc;
            ro_cell #(.STAGES(STAGES)) u_cell (.en(en), .osc(osc));

            // ripple divider
            reg [DIV_BITS-1:0] div;
            always @(posedge osc or negedge rst_n)
                if (!rst_n) div[0] <= 1'b0;
                else        div[0] <= ~div[0];
            for (j = 1; j < DIV_BITS; j = j + 1) begin : g_div
                always @(negedge div[j - 1] or negedge rst_n)
                    if (!rst_n) div[j] <= 1'b0;
                    else        div[j] <= ~div[j];
            end
            wire dclk = div[DIV_BITS - 1];

            // Gray counter in the divided RO clock domain
            reg [CNT_W-1:0] bin, gray;
            always @(posedge dclk or negedge rst_n) begin
                if (!rst_n) begin
                    bin  <= {CNT_W{1'b0}};
                    gray <= {CNT_W{1'b0}};
                end else begin
                    bin  <= bin + 1'b1;
                    gray <= (bin + 1'b1) ^ ((bin + 1'b1) >> 1);
                end
            end

            // synchronize into clk
            (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
            reg [CNT_W-1:0] gs1, gs2;
            reg [CNT_W-1:0] prev;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    gs1  <= {CNT_W{1'b0}};
                    gs2  <= {CNT_W{1'b0}};
                    prev <= {CNT_W{1'b0}};
                    ro_counts[i*CNT_W +: CNT_W] <= {CNT_W{1'b0}};
                end else begin
                    gs1 <= gray;
                    gs2 <= gs1;
                    if (wend) begin
                        ro_counts[i*CNT_W +: CNT_W] <= g2b(gs2) - prev;
                        prev <= g2b(gs2);
                    end
                end
            end
        end
    endgenerate
endmodule
