// debounce: output follows the (already synchronized) input only after it
// has been stable for CYCLES clock cycles.
module debounce #(
    parameter integer CYCLES = 500000,   // 10 ms at 50 MHz
    parameter         INIT   = 1'b1
) (
    input  wire clk,
    input  wire rst_n,
    input  wire d,
    output reg  q
);
    localparam integer W = (CYCLES < 2) ? 1 : $clog2(CYCLES + 1);
    reg [W-1:0] cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q   <= INIT;
            cnt <= {W{1'b0}};
        end else if (d == q) begin
            cnt <= {W{1'b0}};
        end else if (cnt == CYCLES - 1) begin
            q   <= d;
            cnt <= {W{1'b0}};
        end else begin
            cnt <= cnt + 1'b1;
        end
    end
endmodule
