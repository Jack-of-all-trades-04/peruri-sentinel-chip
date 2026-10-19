// master_key_vault: 128 D-FF key register with asynchronous active-low clear.
// async_zeroize_n has priority over everything, including the clock.
//
// Demo build (DEMO_BUILD defined): the key is loaded from DEMO_KEY while
// rst_n is low, as on the board.
// Production build: there is no key constant. The key is written once per
// power-on session through the write-only port key_wr_en / key_wr_data
// (personalization, or the host loading the per-chip key from its NVM at
// boot). The first write seals the vault until the next power-on reset; a
// user reset does not reopen it. There is no read path: the key only goes
// to the cipher.
// key_loaded = 1 when a key is present and not zeroized.
module master_key_vault #(
    parameter integer KEY_W = 128
`ifdef DEMO_BUILD
    ,
    parameter [127:0] DEMO_KEY = 128'h000102030405060708090a0b0c0d0e0f
`endif
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         por_n,
    input  wire         async_zeroize_n,
`ifndef DEMO_BUILD
    input  wire         key_wr_en,
    input  wire [127:0] key_wr_data,
`endif
    output reg  [127:0] key_to_cipher,
    output wire         key_loaded
);
`ifdef DEMO_BUILD
    always @(posedge clk or negedge async_zeroize_n) begin
        if (!async_zeroize_n)
            key_to_cipher <= 128'h0;
        else if (!rst_n)
            key_to_cipher <= DEMO_KEY;
    end
    assign key_loaded = async_zeroize_n;
    wire unused_ok = &{1'b0, por_n};
`else
    (* keep *) reg sealed;
    always @(posedge clk or negedge por_n) begin
        if (!por_n)        sealed <= 1'b0;
        else if (key_wr_en) sealed <= 1'b1;
    end
    always @(posedge clk or negedge async_zeroize_n) begin
        if (!async_zeroize_n)
            key_to_cipher <= 128'h0;
        else if (key_wr_en && !sealed)
            key_to_cipher <= key_wr_data;
    end
    assign key_loaded = sealed & async_zeroize_n;
    wire unused_ok = &{1'b0, rst_n};
`endif
endmodule
