// tripwire_zeroize: drives the asynchronous clear of master_key_vault.
// Output comes straight from a register so it cannot glitch. It stays low
// while zeroize_req is held, so the key stays zero through LOCKDOWN.
module tripwire_zeroize (
    input  wire clk,
    input  wire por_n,
    input  wire zeroize_req,
    output wire async_zeroize_n
);
    reg z;
    always @(posedge clk or negedge por_n) begin
        if (!por_n) z <= 1'b0;
        else        z <= zeroize_req;
    end
    assign async_zeroize_n = ~z;
endmodule
