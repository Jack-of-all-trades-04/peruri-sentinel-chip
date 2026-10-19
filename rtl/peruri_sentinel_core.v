// peruri_sentinel_core: Tier 1 integration (single clock).
//
//   op_req -> tamper_persist_fsm (MARK: in_progress to NVM) -> op_grant
//          -> dpa_hiding_lfsr -> aes128_core -> output_release_gate
//          -> op_done -> tamper_persist_fsm (COMMIT to NVM) -> commit_fin
//          -> output_release_gate releases ct_out (clean commit only)
//   alarm -> output_release_gate (block) and -> tamper_persist_fsm (count)
//   tamper_persist_fsm -> tripwire_zeroize -> async clear of master_key_vault
//
// The tamper counters (alarm_count, tear_count) and the lockdown live in the
// host NVM through the nvm_* port (see tamper_persist_fsm), so a power cycle
// does not reset them. power_warn comes from the parent chip's supply/RF
// monitor: an operation in progress is aborted, nothing is released, and it
// is counted in tear_count.
//
// Two builds from one source:
//   DEMO_BUILD defined   board demo and demo testbenches: Sentinel enable,
//                        DFA fault hook, debug unlock, round_idx and the
//                        constant DEMO_KEY exist.
//   no define            production (yosys checks, eqy, LibreLane): Sentinel
//                        always on, no fault hook, no unlock, no round_idx,
//                        key written once per power-on through key_wr_*.
// alarm_in is the sensor interface of this core (Tier 1 has no on-core
// sensor; the TDL/RO sensors attach here when integrated). It can only
// raise alarms.
module peruri_sentinel_core #(
    parameter integer   H           = 4,
    parameter integer   N           = 4,
    parameter integer   M           = 8,
    parameter integer   CW          = 4,
    parameter integer   DPA_ENABLE  = 1,
    parameter integer   RECW        = 17 + 2*CW   // NVM record width (derived)
`ifdef DEMO_BUILD
    ,
    parameter integer   DEMO_UNLOCK = 1,
    parameter [127:0]   DEMO_KEY    = 128'h000102030405060708090a0b0c0d0e0f
`endif
) (
    input  wire            clk,
    input  wire            rst_n,          // user reset (KEY0)
    input  wire            por_n,          // power-on reset (controller sequencing)
    input  wire            op_req,         // request one encryption (pulse)
    input  wire [127:0]    pt,
    input  wire            alarm_in,       // sensor interface (Tier 1 demo: harness)
    input  wire            power_warn,     // supply/RF droop from the parent chip
`ifdef DEMO_BUILD
    input  wire            sentinel_en,    // SW0
    input  wire            fault_en,       // demo harness only
    input  wire [3:0]      fault_round,
    input  wire [3:0]      fault_byte,
    input  wire [7:0]      fault_mask,
    input  wire            debug_unlock,
    output wire [3:0]      round_idx,
`else
    input  wire            key_wr_en,      // write-only key port (once per power-on)
    input  wire [127:0]    key_wr_data,
`endif
    // host NVM holding the tamper record
    output wire            nvm_rd_en,
    output wire            nvm_rd_addr,
    input  wire [RECW-1:0] nvm_rd_data,
    input  wire            nvm_rd_valid,
    output wire            nvm_wr_en,
    output wire            nvm_wr_addr,
    output wire [RECW-1:0] nvm_wr_data,
    input  wire            nvm_wr_done,
    output wire [127:0]    ct_out,
    output wire            ct_valid,
    output wire            gate_blocked,
    output wire [CW-1:0]   tamper_counter, // = alarm_count
    output wire [CW-1:0]   tear_count,
    output wire            lockdown,
    output wire            busy,
    output wire            key_is_zero
);
    wire [127:0] key;
    wire         key_loaded;
    wire         go;
    wire         aes_done;
    wire [127:0] ct_raw;
    wire         zeroize_req;
    wire         async_zeroize_n;
    wire [1:0]   dummy_cnt;
    wire         aes_busy, gate_busy;
    wire         fsm_ready, op_grant, commit_fin, commit_clean, op_done, boot_busy;

`ifdef DEMO_BUILD
    // Alarm only counts and blocks when the Sentinel is enabled (SW0).
    wire alarm = sentinel_en & alarm_in;
    wire unlock_in = debug_unlock;
`else
    wire alarm = alarm_in;
    wire unlock_in = 1'b0;
`endif

    // A request is accepted only when the core is idle, the tamper controller
    // is ready (booted, not locked, not writing), and a key is loaded. Any
    // other request is ignored and the caller retries (busy = 1). An accepted
    // request waits in req_pending for the MARK write (op_grant) and the DPA
    // dummy cycles (go), or ends if the controller aborts it (commit_fin).
    // A user reset in the middle of an operation interrupts it like a power
    // loss would: the controller (on por_n) aborts and counts one tear.
    wire abort_in = power_warn | ~rst_n;

    reg req_pending;
    wire core_busy = aes_busy | req_pending | gate_busy;
    wire req_accept = op_req & fsm_ready & key_loaded & ~core_busy;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                 req_pending <= 1'b0;
        else if (go || commit_fin)  req_pending <= 1'b0;
        else if (req_accept)        req_pending <= 1'b1;
    end

    tamper_persist_fsm #(
        .N(N), .M(M), .CW(CW),
`ifdef DEMO_BUILD
        .DEMO_UNLOCK(DEMO_UNLOCK)
`else
        .DEMO_UNLOCK(0)
`endif
    ) u_fsm (
        .clk(clk), .por_n(por_n), .alarm(alarm), .power_warn(abort_in),
        .start_req(req_accept), .op_done(op_done), .debug_unlock(unlock_in),
        .nvm_rd_en(nvm_rd_en), .nvm_rd_addr(nvm_rd_addr), .nvm_rd_data(nvm_rd_data),
        .nvm_rd_valid(nvm_rd_valid), .nvm_wr_en(nvm_wr_en), .nvm_wr_addr(nvm_wr_addr),
        .nvm_wr_data(nvm_wr_data), .nvm_wr_done(nvm_wr_done),
        .ready(fsm_ready), .op_grant(op_grant), .commit_fin(commit_fin),
        .commit_clean(commit_clean), .boot_busy(boot_busy),
        .zeroize_req(zeroize_req), .lockdown_state(lockdown),
        .alarm_count(tamper_counter), .tear_count(tear_count)
    );

    dpa_hiding_lfsr #(.ENABLE(DPA_ENABLE)) u_dpa (
        .clk(clk), .rst_n(rst_n),
        .req(op_grant),
        .go(go), .dummy_cnt(dummy_cnt)
    );

`ifdef DEMO_BUILD
    master_key_vault #(.DEMO_KEY(DEMO_KEY)) u_vault (
        .clk(clk), .rst_n(rst_n), .por_n(por_n), .async_zeroize_n(async_zeroize_n),
        .key_to_cipher(key), .key_loaded(key_loaded)
    );
`else
    master_key_vault u_vault (
        .clk(clk), .rst_n(rst_n), .por_n(por_n), .async_zeroize_n(async_zeroize_n),
        .key_wr_en(key_wr_en), .key_wr_data(key_wr_data),
        .key_to_cipher(key), .key_loaded(key_loaded)
    );
`endif

    // The AES only starts for an operation the controller has marked and not
    // yet closed: a `go` that arrives after an abort (commit_fin before the
    // DPA dummy cycles end) is dropped.
    reg op_live;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)          op_live <= 1'b0;
        else if (commit_fin) op_live <= 1'b0;
        else if (op_grant)   op_live <= 1'b1;
        else if (go)         op_live <= 1'b0;
    end
    // `go` and an abort commit_fin can coincide: commit_fin wins (no start),
    // otherwise the gate would leave IDLE in the very cycle the commit pulse
    // is missed and wait for it forever.
    wire start = go & op_live & ~commit_fin & ~lockdown;
    aes128_core u_aes (
        .clk(clk), .rst_n(rst_n), .start(start),
        .key(key), .pt(pt),
`ifdef DEMO_BUILD
        .fault_en(fault_en), .fault_round(fault_round),
        .fault_byte(fault_byte), .fault_mask(fault_mask),
        .round_idx(round_idx),
`endif
        .ct_raw(ct_raw), .done(aes_done), .busy(aes_busy)
    );

    output_release_gate #(.H(H)) u_gate (
        .clk(clk), .rst_n(rst_n),
`ifdef DEMO_BUILD
        .enable(sentinel_en),
`endif
        .lockdown(lockdown),
        .op_start(start), .aes_done(aes_done), .ct_raw(ct_raw),
        .alarm(alarm), .commit_fin(commit_fin), .commit_clean(commit_clean),
        .ct_out(ct_out), .ct_valid(ct_valid),
        .gate_blocked(gate_blocked), .op_done(op_done), .busy(gate_busy)
    );

    tripwire_zeroize u_trip (
        .clk(clk), .por_n(por_n), .zeroize_req(zeroize_req),
        .async_zeroize_n(async_zeroize_n)
    );

    assign busy        = core_busy | ~fsm_ready;
    assign key_is_zero = (key == 128'h0);
    wire unused_ok = &{1'b0, dummy_cnt, boot_busy};
endmodule
