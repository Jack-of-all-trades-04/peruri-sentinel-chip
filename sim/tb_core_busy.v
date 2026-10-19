// Handshake test for peruri_sentinel_core: a request that arrives while the
// core is busy must be ignored (busy = 1 tells the caller to retry), and the
// core must keep accepting requests afterwards. Found by the RTL/netlist
// co-simulation (verif/gate/tb_cosim.v): before the fix, a request during
// an operation set req_pending without starting anything, and the core then
// ignored every request until a user reset.
`timescale 1ns/1ps
module tb_core_busy;
    reg clk = 0;
    always #10 clk = ~clk;

    reg          rst_n = 0, por_n = 0, op_req = 0;
    wire [127:0] ct_out;
    wire         ct_valid, gate_blocked, lockdown, busy, key_is_zero;
    wire [3:0]   tamper_counter, round_idx;
    localparam [127:0] PT  = 128'h00112233445566778899aabbccddeeff;
    localparam [127:0] EXP = 128'h69c4e0d86a7b0430d8cdb78070b4c55a;

    // host NVM model holding a valid personalised record
    localparam integer RECW = 17 + 2*4;
    wire nvm_rd_en, nvm_rd_addr, nvm_rd_valid, nvm_wr_en, nvm_wr_addr, nvm_wr_done;
    wire [RECW-1:0] nvm_rd_data, nvm_wr_data;
    nvm_counter_model #(.CW(4), .INIT_BLANK(0)) u_nvm (
        .clk(clk), .power_ok(1'b1),
        .rd_en(nvm_rd_en), .rd_addr(nvm_rd_addr), .rd_data(nvm_rd_data), .rd_valid(nvm_rd_valid),
        .wr_en(nvm_wr_en), .wr_addr(nvm_wr_addr), .wr_data(nvm_wr_data), .wr_done(nvm_wr_done)
    );

    peruri_sentinel_core dut (
        .clk(clk), .rst_n(rst_n), .por_n(por_n), .sentinel_en(1'b1), .op_req(op_req),
        .pt(PT), .fault_en(1'b0), .fault_round(4'd0), .fault_byte(4'd0), .fault_mask(8'd0),
        .alarm_in(1'b0), .debug_unlock(1'b0), .power_warn(1'b0),
        .nvm_rd_en(nvm_rd_en), .nvm_rd_addr(nvm_rd_addr), .nvm_rd_data(nvm_rd_data),
        .nvm_rd_valid(nvm_rd_valid), .nvm_wr_en(nvm_wr_en), .nvm_wr_addr(nvm_wr_addr),
        .nvm_wr_data(nvm_wr_data), .nvm_wr_done(nvm_wr_done), .tear_count(),
        .ct_out(ct_out), .ct_valid(ct_valid),
        .gate_blocked(gate_blocked), .tamper_counter(tamper_counter), .lockdown(lockdown),
        .busy(busy), .round_idx(round_idx), .key_is_zero(key_is_zero)
    );

    integer n_ok = 0, errors = 0, k;
    always @(posedge clk) if (ct_valid && ct_out == EXP) n_ok = n_ok + 1;

    task pulse_req;
        begin
            @(negedge clk) op_req = 1;
            @(negedge clk) op_req = 0;
        end
    endtask

    task check;
        input            cond;
        input [8*60-1:0] name;
        begin
            if (!cond) begin
                $display("FAIL %0s (ok=%0d busy=%b)", name, n_ok, busy);
                errors = errors + 1;
            end else
                $display("  ok %0s", name);
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        por_n = 1; rst_n = 1;
        wait (!busy); repeat (2) @(negedge clk);   // boot: NVM record read

        // 1. a normal request completes
        pulse_req;
        repeat (90) @(negedge clk);
        check(n_ok == 1, "single request releases the ciphertext");

        // 2. requests while busy: one at the start, several in the middle
        pulse_req;
        repeat (3) @(negedge clk);
        for (k = 0; k < 4; k = k + 1) pulse_req;
        repeat (120) @(negedge clk);
        check(n_ok == 2, "requests during an operation are ignored, not queued");
        check(!busy, "core is idle afterwards (no stuck request)");

        // 3. the core still accepts new requests (before the fix: stuck here)
        for (k = 0; k < 3; k = k + 1) begin
            pulse_req;
            repeat (90) @(negedge clk);
        end
        check(n_ok == 5, "three further requests all complete");

        if (errors == 0) $display("PASS tb_core_busy");
        else             $display("FAIL tb_core_busy (%0d errors)", errors);
        $finish;
    end
endmodule
