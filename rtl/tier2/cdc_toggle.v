// cdc_toggle_tx / cdc_toggle_rx: one-event clock-domain crossing by toggle.
//
// tx (source clock): every `pulse` flips `tgl`. The level is held until the
// next event, so the receiver cannot miss it whatever the clock ratio.
// rx (destination clock): `tgl` goes through sync_2ff; a change of the
// synchronized level is turned into a 1-cycle `pulse`.
//
// Rule for the user: two events on the same toggle must be spaced by more
// than two destination clock cycles plus one source cycle, otherwise they can
// merge. The Tier 2 core guarantees this by construction: each toggle carries
// at most one event per operation, and a new operation only starts after the
// sentinel domain has answered the previous one.
//
// Both ends are reset by the power-on reset only (never by the user reset), so
// a user reset in one domain cannot fake or hide an edge. The two power-on
// resets assert together (same arst_n), so the toggle and the receiver history
// restart from the same value, 0.
module cdc_toggle_tx (
    input  wire clk,
    input  wire rst_n,
    input  wire pulse,
    output reg  tgl
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)     tgl <= 1'b0;
        else if (pulse) tgl <= ~tgl;
    end
endmodule

module cdc_toggle_rx (
    input  wire clk,
    input  wire rst_n,
    input  wire tgl,
    output wire pulse
);
    wire s;
    reg  prev;
    sync_2ff u_sync (.clk(clk), .rst_n(rst_n), .d(tgl), .q(s));
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) prev <= 1'b0;
        else        prev <= s;
    end
    assign pulse = s ^ prev;
endmodule
