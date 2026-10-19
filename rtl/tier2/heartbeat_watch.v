// heartbeat_gen / heartbeat_watch: liveness signal between the two Tier 2
// clock domains, independent of the ring-oscillator clock monitor.
//
// heartbeat_gen (source clock): flips `tgl` every K cycles of clk. The level
// is held, so the receiver cannot miss it whatever the clock ratio.
//
// heartbeat_watch (destination clock): `tgl` goes through cdc_toggle_rx (2-FF
// synchronizer + edge detect). `seen` becomes 1 at the first edge and stays
// 1 (power-on reset only): until then nothing is judged (warm-up) but the
// owner must not treat the peer as alive either. After that, TO destination
// cycles without an edge raise `dead`; `dead` is a level that falls again at
// the next edge. The owner decides what is sticky.
//
// Sizing rule: TO (destination cycles) must exceed K source cycles measured
// in destination cycles at the slowest legitimate source / fastest legitimate
// destination clock, with margin. The watcher then flags a stopped peer, and
// a peer slowed by more than about TO / K relative to the local clock.
//
// Both ends are reset by the power-on reset of their own domain, never by the
// user reset, so a user reset cannot hide or fake a missing heartbeat.
module heartbeat_gen #(
    parameter integer K = 64
) (
    input  wire clk,
    input  wire por_n,
    output reg  tgl
);
    localparam integer W = $clog2(K + 1);
    reg [W-1:0] cnt;
    always @(posedge clk or negedge por_n) begin
        if (!por_n) begin
            cnt <= {W{1'b0}};
            tgl <= 1'b0;
        end else if (cnt == K - 1) begin
            cnt <= {W{1'b0}};
            tgl <= ~tgl;
        end else begin
            cnt <= cnt + 1'b1;
        end
    end
endmodule

module heartbeat_watch #(
    parameter integer TO = 512
) (
    input  wire clk,
    input  wire por_n,
    input  wire tgl,
    output reg  seen,
    output reg  dead
);
    localparam integer W = $clog2(TO + 1);
    wire edge_p;
    cdc_toggle_rx u_rx (.clk(clk), .rst_n(por_n), .tgl(tgl), .pulse(edge_p));
    reg [W-1:0] cnt;
    always @(posedge clk or negedge por_n) begin
        if (!por_n) begin
            seen <= 1'b0;
            dead <= 1'b0;
            cnt  <= {W{1'b0}};
        end else if (edge_p) begin
            seen <= 1'b1;
            dead <= 1'b0;
            cnt  <= {W{1'b0}};
        end else if (seen && !dead) begin
            if (cnt == TO - 1) dead <= 1'b1;
            else               cnt  <= cnt + 1'b1;
        end
    end
endmodule
