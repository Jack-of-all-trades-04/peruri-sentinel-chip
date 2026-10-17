// glitch_injector: demo-only clock-glitch generator for CLK_sys.
//
// Inputs are two PLL outputs with the same frequency (period T):
//   clk_a  the normal system clock
//   clk_b  clk_a shifted by PHI, with T/2 < PHI < T (set in the PLL)
// Output: clk_out = clk_a | (en & clk_b)
//
// While en = 0, clk_out is exactly clk_a. When `arm` rises, en goes high
// for exactly one clk_b period. In that period clk_b rises while clk_a is
// still low, so clk_out gets one early rising edge: one CLK_sys cycle is
// shortened from T to PHI. Every register on clk_out (AES, TDL, gate) sees
// the short cycle. The following cycle is longer (2T - PHI) and then the
// clock is normal again.
//
// en is registered on the falling edge of clk_b, when clk_b is low, so a
// change of en can never create an extra pulse on its own.
//
// This is a fault-injection harness for the demo, not part of the
// protected IP. Tie ENABLE = 0 (or leave it out) in a production build.
module glitch_injector #(
    parameter integer ENABLE = 1
) (
    input  wire clk_a,
    input  wire clk_b,
    input  wire rst_n,     // asynchronous, e.g. PLL locked
    input  wire arm,       // level; one glitch per rising edge, hold >= 2 cycles
    output wire clk_out,
    output reg  en
);
    reg [1:0] arm_s;
    reg       arm_d;
    always @(negedge clk_b or negedge rst_n) begin
        if (!rst_n) begin
            arm_s <= 2'b00;
            arm_d <= 1'b0;
            en    <= 1'b0;
        end else begin
            arm_s <= {arm_s[0], arm};
            arm_d <= arm_s[1];
            en    <= arm_s[1] & ~arm_d;
        end
    end

    generate
        if (ENABLE != 0) begin : g_on
            assign clk_out = clk_a | (en & clk_b);
        end else begin : g_off
            assign clk_out = clk_a;
        end
    endgenerate
endmodule
