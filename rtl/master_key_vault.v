// master_key_vault: 128 D-FF key register with asynchronous active-low clear.
// async_zeroize_n has priority over everything, including the clock.
// The key is loaded from DEMO_KEY while rst_n is low (demo build only; a
// production build loads it through a write-only CSR).
module master_key_vault #(
    parameter [127:0] DEMO_KEY = 128'h000102030405060708090a0b0c0d0e0f
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         async_zeroize_n,
    output reg  [127:0] key_to_cipher
);
    always @(posedge clk or negedge async_zeroize_n) begin
        if (!async_zeroize_n)
            key_to_cipher <= 128'h0;
        else if (!rst_n)
            key_to_cipher <= DEMO_KEY;
    end
endmodule
