// peruri_sentinel_core: Tier 1 integration (single clock).
//
//   op_req -> dpa_hiding_lfsr -> aes128_core -> output_release_gate -> ct_out
//                                     ^ key            ^ alarm
//                              master_key_vault        |
//                                     ^ async clear    |
//                              tripwire_zeroize <- graduated_tamper_fsm <- alarm
//
// Tier 1 runs CLK_sys and CLK_sentinel on the same clock, so no CDC is
// needed yet. Tier 2 splits the domains and adds sync_2ff on the slow path;
// the TDL alert will keep going straight into the gate without CDC.
module peruri_sentinel_core #(
    parameter integer   H           = 4,
    parameter integer   N           = 4,
    parameter integer   DEMO_UNLOCK = 1,
    parameter integer   DPA_ENABLE  = 1,
    parameter [127:0]   DEMO_KEY    = 128'h000102030405060708090a0b0c0d0e0f
) (
    input  wire         clk,
    input  wire         rst_n,          // user reset (KEY0)
    input  wire         por_n,          // power-on reset (persistent state)
    input  wire         sentinel_en,    // SW0
    input  wire         op_req,         // request one encryption (pulse)
    input  wire [127:0] pt,
    input  wire         fault_en,       // demo harness only
    input  wire [3:0]   fault_round,
    input  wire [3:0]   fault_byte,
    input  wire [7:0]   fault_mask,
    input  wire         alarm_in,       // Tier 1: harness alarm; Tier 2: TDL/RO
    input  wire         debug_unlock,
    output wire [127:0] ct_out,
    output wire         ct_valid,
    output wire         gate_blocked,
    output wire [3:0]   tamper_counter,
    output wire         lockdown,
    output wire         busy,
    output wire [3:0]   round_idx,
    output wire         key_is_zero
);
    wire [127:0] key;
    wire         go;
    wire         aes_done;
    wire [127:0] ct_raw;
    wire         zeroize_req;
    wire         async_zeroize_n;
    wire [1:0]   dummy_cnt;
    wire         aes_busy;

    // Alarm only counts when the Sentinel is enabled (SW0).
    wire alarm = sentinel_en & alarm_in;

    // While a request waits for its dummy cycles, treat the core as busy.
    reg req_pending;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)      req_pending <= 1'b0;
        else if (go)     req_pending <= 1'b0;
        else if (op_req && !lockdown) req_pending <= 1'b1;
    end

    dpa_hiding_lfsr #(.ENABLE(DPA_ENABLE)) u_dpa (
        .clk(clk), .rst_n(rst_n),
        .req(op_req & ~lockdown & ~aes_busy & ~req_pending),
        .go(go), .dummy_cnt(dummy_cnt)
    );

    master_key_vault #(.DEMO_KEY(DEMO_KEY)) u_vault (
        .clk(clk), .rst_n(rst_n), .async_zeroize_n(async_zeroize_n),
        .key_to_cipher(key)
    );

    aes128_core u_aes (
        .clk(clk), .rst_n(rst_n), .start(go & ~lockdown),
        .key(key), .pt(pt),
        .fault_en(fault_en), .fault_round(fault_round),
        .fault_byte(fault_byte), .fault_mask(fault_mask),
        .ct_raw(ct_raw), .done(aes_done), .busy(aes_busy),
        .round_idx(round_idx)
    );

    output_release_gate #(.H(H)) u_gate (
        .clk(clk), .rst_n(rst_n), .enable(sentinel_en), .lockdown(lockdown),
        .op_start(go & ~lockdown), .aes_done(aes_done), .ct_raw(ct_raw),
        .alarm(alarm), .ct_out(ct_out), .ct_valid(ct_valid),
        .gate_blocked(gate_blocked)
    );

    graduated_tamper_fsm #(.N(N), .DEMO_UNLOCK(DEMO_UNLOCK)) u_fsm (
        .clk(clk), .por_n(por_n), .alarm(alarm), .debug_unlock(debug_unlock),
        .tamper_counter(tamper_counter), .zeroize_req(zeroize_req),
        .lockdown_state(lockdown)
    );

    tripwire_zeroize u_trip (
        .clk(clk), .por_n(por_n), .zeroize_req(zeroize_req),
        .async_zeroize_n(async_zeroize_n)
    );

    assign busy        = aes_busy | req_pending;
    assign key_is_zero = (key == 128'h0);
endmodule
