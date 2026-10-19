// Gate-level shims for the unit testbenches (tb_output_release_gate,
// tb_tamper_persist). Each shim has the RTL module name and wraps the sky130
// netlist module that synthesis produced for the parameter values used
// inside peruri_sentinel_core (demo build: H = 4, N = 4, M = 8, CW = 4,
// DEMO_UNLOCK = 1, demo key). tripwire_zeroize has no parameters and is used
// from the netlist directly.
module output_release_gate #(parameter integer H = 4) (
    input  wire         clk, rst_n, enable, lockdown, op_start, aes_done,
    input  wire [127:0] ct_raw,
    input  wire         alarm, commit_fin, commit_clean,
    output wire [127:0] ct_out,
    output wire         ct_valid, gate_blocked, op_done, gate_fault, busy
);
    \$paramod\output_release_gate\H=s32'00000000000000000000000000000100  u_gl (
        .clk(clk), .rst_n(rst_n), .enable(enable), .lockdown(lockdown), .op_start(op_start),
        .aes_done(aes_done), .ct_raw(ct_raw), .alarm(alarm), .commit_fin(commit_fin),
        .commit_clean(commit_clean), .ct_out(ct_out), .ct_valid(ct_valid),
        .gate_blocked(gate_blocked), .op_done(op_done), .gate_fault(gate_fault), .busy(busy)
    );
endmodule

module tamper_persist_fsm #(
    parameter integer N = 4, parameter integer M = 8, parameter integer CW = 4,
    parameter integer DEMO_UNLOCK = 1, parameter integer RECW = 17 + 2*CW
) (
    input  wire            clk, por_n, alarm, power_warn, start_req, op_done, debug_unlock,
    output wire            nvm_rd_en, nvm_rd_addr,
    input  wire [RECW-1:0] nvm_rd_data,
    input  wire            nvm_rd_valid,
    output wire            nvm_wr_en, nvm_wr_addr,
    output wire [RECW-1:0] nvm_wr_data,
    input  wire            nvm_wr_done,
    output wire            ready, op_grant, commit_fin, commit_clean, boot_busy,
    output wire            zeroize_req, lockdown_state,
    output wire [CW-1:0]   alarm_count, tear_count
);
    \$paramod$15ae56df5f306deb8065ceab00e048479d9713e3\tamper_persist_fsm  u_gl (
        .clk(clk), .por_n(por_n), .alarm(alarm), .power_warn(power_warn), .start_req(start_req),
        .op_done(op_done), .debug_unlock(debug_unlock),
        .nvm_rd_en(nvm_rd_en), .nvm_rd_addr(nvm_rd_addr), .nvm_rd_data(nvm_rd_data),
        .nvm_rd_valid(nvm_rd_valid), .nvm_wr_en(nvm_wr_en), .nvm_wr_addr(nvm_wr_addr),
        .nvm_wr_data(nvm_wr_data), .nvm_wr_done(nvm_wr_done),
        .ready(ready), .op_grant(op_grant), .commit_fin(commit_fin), .commit_clean(commit_clean),
        .boot_busy(boot_busy), .zeroize_req(zeroize_req), .lockdown_state(lockdown_state),
        .alarm_count(alarm_count), .tear_count(tear_count)
    );
endmodule

module master_key_vault #(parameter [127:0] DEMO_KEY = 128'h000102030405060708090a0b0c0d0e0f) (
    input  wire         clk, rst_n, por_n, async_zeroize_n,
    output wire [127:0] key_to_cipher,
    output wire         key_loaded
);
    \$paramod$ae58273a712df0ca3b7bccd27b24cca6c054e665\master_key_vault  u_gl (
        .clk(clk), .rst_n(rst_n), .por_n(por_n), .async_zeroize_n(async_zeroize_n),
        .key_to_cipher(key_to_cipher), .key_loaded(key_loaded)
    );
endmodule
