// Gate-level shim: lets the board top (de10_nano_top) and its testbench run
// on the sky130 gate netlist instead of the RTL core.
//
// The netlist module is renamed to peruri_sentinel_core_gl by run_gate.sh.
// It was synthesized (demo build) with the default parameters (H = 4, N = 4,
// M = 8, CW = 4, DEMO_UNLOCK = 1, DPA on, FIPS-197 demo key), so the
// parameters below are accepted only to keep the board top unchanged, and
// must match them.
module peruri_sentinel_core #(
    parameter integer   H           = 4,
    parameter integer   N           = 4,
    parameter integer   M           = 8,
    parameter integer   CW          = 4,
    parameter integer   DPA_ENABLE  = 1,
    parameter integer   RECW        = 17 + 2*CW,
    parameter integer   DEMO_UNLOCK = 1,
    parameter [127:0]   DEMO_KEY    = 128'h000102030405060708090a0b0c0d0e0f
) (
    input  wire            clk,
    input  wire            rst_n,
    input  wire            por_n,
    input  wire            op_req,
    input  wire [127:0]    pt,
    input  wire            alarm_in,
    input  wire            power_warn,
    input  wire            sentinel_en,
    input  wire            fault_en,
    input  wire [3:0]      fault_round,
    input  wire [3:0]      fault_byte,
    input  wire [7:0]      fault_mask,
    input  wire            debug_unlock,
    output wire [3:0]      round_idx,
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
    output wire [CW-1:0]   tamper_counter,
    output wire [CW-1:0]   tear_count,
    output wire            lockdown,
    output wire            busy,
    output wire            key_is_zero
);
    initial begin
        if (H != 4 || N != 4 || M != 8 || CW != 4 || DEMO_UNLOCK != 1 || DPA_ENABLE != 1 ||
            DEMO_KEY != 128'h000102030405060708090a0b0c0d0e0f) begin
            $display("FAIL core_gl_shim: parameters differ from the synthesized netlist");
            $finish;
        end
    end

    peruri_sentinel_core_gl u_gl (
        .clk(clk), .rst_n(rst_n), .por_n(por_n), .op_req(op_req), .pt(pt),
        .alarm_in(alarm_in), .power_warn(power_warn), .sentinel_en(sentinel_en),
        .fault_en(fault_en), .fault_round(fault_round), .fault_byte(fault_byte),
        .fault_mask(fault_mask), .debug_unlock(debug_unlock), .round_idx(round_idx),
        .nvm_rd_en(nvm_rd_en), .nvm_rd_addr(nvm_rd_addr), .nvm_rd_data(nvm_rd_data),
        .nvm_rd_valid(nvm_rd_valid), .nvm_wr_en(nvm_wr_en), .nvm_wr_addr(nvm_wr_addr),
        .nvm_wr_data(nvm_wr_data), .nvm_wr_done(nvm_wr_done),
        .ct_out(ct_out), .ct_valid(ct_valid), .gate_blocked(gate_blocked),
        .tamper_counter(tamper_counter), .tear_count(tear_count), .lockdown(lockdown),
        .busy(busy), .key_is_zero(key_is_zero)
    );
endmodule
