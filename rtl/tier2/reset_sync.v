// reset_sync: asynchronous assert, synchronous release of an active-low
// reset into the clk domain. Every Tier 2 clock domain gets its own copy.
module reset_sync (
    input  wire clk,
    input  wire arst_n,
    output wire rst_n
);
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [1:0] s;
    always @(posedge clk or negedge arst_n) begin
        if (!arst_n) s <= 2'b00;
        else         s <= {s[0], 1'b1};
    end
    assign rst_n = s[1];
endmodule
