// sync_2ff: two flip-flop synchronizer for a single-bit level signal
// crossing into the clk domain (or an asynchronous board input).
module sync_2ff #(
    parameter RESET_VAL = 1'b0
) (
    input  wire clk,
    input  wire rst_n,
    input  wire d,
    output wire q
);
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [1:0] s;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) s <= {2{RESET_VAL}};
        else        s <= {s[0], d};
    end
    assign q = s[1];
endmodule
