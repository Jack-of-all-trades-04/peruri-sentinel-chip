// dpa_hiding_lfsr: inserts 0..3 random dummy cycles before each operation
// (per operation, not per round), so power traces are not aligned.
// 16-bit Fibonacci LFSR, taps 16,14,13,11 (maximal length).
// This reduces CPA/DPA correlation; it does not claim absolute resistance.
module dpa_hiding_lfsr #(
    parameter [15:0] SEED   = 16'hACE1,
    parameter integer ENABLE = 1
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       req,        // operation requested (1-cycle pulse)
    output reg        go,         // start the cipher (1-cycle pulse)
    output wire [1:0] dummy_cnt
);
    reg [15:0] lfsr;
    reg [1:0]  wait_cnt;
    reg        pending;

    assign dummy_cnt = lfsr[1:0];
    wire fb = lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr     <= SEED;
            wait_cnt <= 2'd0;
            pending  <= 1'b0;
            go       <= 1'b0;
        end else begin
            lfsr <= {lfsr[14:0], fb};
            go   <= 1'b0;
            if (!pending) begin
                if (req) begin
                    if (ENABLE == 0 || lfsr[1:0] == 2'd0) begin
                        go <= 1'b1;
                    end else begin
                        pending  <= 1'b1;
                        wait_cnt <= lfsr[1:0];
                    end
                end
            end else begin
                if (wait_cnt == 2'd1) begin
                    pending <= 1'b0;
                    go      <= 1'b1;
                end
                wait_cnt <= wait_cnt - 2'd1;
            end
        end
    end
endmodule
