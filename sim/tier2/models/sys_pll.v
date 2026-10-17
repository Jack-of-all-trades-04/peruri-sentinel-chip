// Simulation-only model of the Quartus-generated sys_pll (same ports as the
// IP Catalog wrapper). Periods and phase are in ns.
`timescale 1ns/1ps
module sys_pll #(
    parameter real T0       = 12.5,   // outclk_0, CLK_sys A (80 MHz)
    parameter real T1       = 20.0,   // outclk_1, CLK_sentinel (50 MHz)
    parameter real PH2      = 8.0,    // outclk_2 = outclk_0 delayed by PH2
    parameter real LOCK_NS  = 300.0
) (
    input  wire refclk,
    input  wire rst,
    output reg  outclk_0,
    output reg  outclk_1,
    output reg  outclk_2,
    output reg  locked
);
    initial begin
        outclk_0 = 1'b0;
        forever #(T0 / 2.0) outclk_0 = ~outclk_0;
    end
    initial begin
        outclk_1 = 1'b0;
        forever #(T1 / 2.0) outclk_1 = ~outclk_1;
    end
    initial begin
        outclk_2 = 1'b0;
        #(PH2);
        forever #(T0 / 2.0) outclk_2 = ~outclk_2;
    end
    initial begin
        locked = 1'b0;
        #(LOCK_NS);
        locked = 1'b1;
    end
endmodule
