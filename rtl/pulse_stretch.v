// pulse_stretch: holds q high for CYCLES clock cycles after each pulse, so a
// one-cycle event is visible on an LED.
module pulse_stretch #(
    parameter integer CYCLES = 25000000  // 0.5 s at 50 MHz
) (
    input  wire clk,
    input  wire rst_n,
    input  wire p,
    output wire q
);
    localparam integer W = (CYCLES < 2) ? 1 : $clog2(CYCLES + 1);
    reg [W-1:0] cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)     cnt <= {W{1'b0}};
        else if (p)     cnt <= CYCLES[W-1:0];
        else if (cnt != 0) cnt <= cnt - 1'b1;
    end
    assign q = (cnt != 0);
endmodule
