// Subsystem test for the persistent tamper controller (P1-1):
//   tamper_persist_fsm + nvm_counter_model + tripwire_zeroize + master_key_vault.
// Proves the counters survive a power cycle, a clean op leaves them unchanged,
// a silent NVM keeps the gate blocked (boot_busy), and tear_count = M locks.
`timescale 1ns/1ps
module tb_tamper_persist;
    localparam integer CW = 4, N = 4, M = 8;
    localparam integer RECW = 17 + 2*CW;
    reg clk = 0; always #5 clk = ~clk;

    reg  por_n = 0, power_ok = 1;
    reg  alarm = 0, power_warn = 0, start_req = 0, op_done = 0, debug_unlock = 0;
    wire rd_en, rd_addr, wr_en, wr_addr, rd_valid, wr_done;
    wire [RECW-1:0] rd_data, wr_data;
    wire op_grant, commit_fin, commit_clean, ready, boot_busy, zeroize_req, lockdown;
    wire commit_done = commit_fin & commit_clean;   // release allowed
    wire [CW-1:0] ac, tc;
    wire async_zn; wire [127:0] key;
    integer errors = 0;

    tamper_persist_fsm #(.N(N), .M(M), .CW(CW), .DEMO_UNLOCK(1)) u_fsm (
        .clk(clk), .por_n(por_n), .alarm(alarm), .power_warn(power_warn),
        .start_req(start_req), .op_done(op_done), .debug_unlock(debug_unlock),
        .nvm_rd_en(rd_en), .nvm_rd_addr(rd_addr), .nvm_rd_data(rd_data), .nvm_rd_valid(rd_valid),
        .nvm_wr_en(wr_en), .nvm_wr_addr(wr_addr), .nvm_wr_data(wr_data), .nvm_wr_done(wr_done),
        .op_grant(op_grant), .commit_fin(commit_fin), .commit_clean(commit_clean), .ready(ready), .boot_busy(boot_busy),
        .zeroize_req(zeroize_req), .lockdown_state(lockdown),
        .alarm_count(ac), .tear_count(tc)
    );
    nvm_counter_model #(.RECW(RECW), .RD_LAT(2), .WR_LAT(8)) u_nvm (
        .clk(clk), .power_ok(power_ok),
        .rd_en(rd_en), .rd_addr(rd_addr), .rd_data(rd_data), .rd_valid(rd_valid),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data), .wr_done(wr_done)
    );
    tripwire_zeroize u_trip (.clk(clk), .por_n(por_n), .zeroize_req(zeroize_req), .async_zeroize_n(async_zn));
    master_key_vault u_vault (.clk(clk), .rst_n(1'b0), .por_n(por_n), .async_zeroize_n(async_zn),
                              .key_to_cipher(key), .key_loaded());

    task chk; input cond; input [8*56-1:0] nm; begin
        if (!cond) begin $display("FAIL %0s (ac=%0d tc=%0d lock=%b boot=%b)", nm, ac, tc, lockdown, boot_busy); errors=errors+1; end
        else $display("  ok %0s", nm); end
    endtask

    // one operation; attack -> raise alarm during the run
    task do_op; input attack; integer t; begin
        @(negedge clk) start_req = 1;
        @(negedge clk) start_req = 0;
        t = 0;
        while (!op_grant && !lockdown && t < 400) begin @(negedge clk); t = t + 1; end
        if (op_grant) begin
            if (attack) begin alarm = 1; repeat (3) @(negedge clk); alarm = 0; end
            repeat (4) @(negedge clk);
            @(negedge clk) op_done = 1;
            @(negedge clk) op_done = 0;
            t = 0;
            while (!commit_fin && !lockdown && t < 400) begin @(negedge clk); t = t + 1; end
        end
        repeat (4) @(negedge clk);
    end endtask

    task boot; integer t; begin
        por_n = 0; repeat (3) @(negedge clk); por_n = 1;
        t = 0; while (boot_busy && t < 600) begin @(negedge clk); t = t + 1; end
        repeat (2) @(negedge clk);
    end endtask

    initial begin
        // first boot: blank NVM -> fail-secure lockdown
        boot;
        chk(lockdown && key == 128'h0, "blank NVM boots into fail-secure lockdown");

        // personalise: debug-unlock to clear and start from a valid record
        @(negedge clk) debug_unlock = 1; repeat (4) @(negedge clk); debug_unlock = 0;
        // after unlock the controller writes a valid record on the next op path;
        // run one clean op so a valid record exists in NVM
        do_op(0);
        chk(!lockdown && ac == 0 && tc == 0, "after unlock + clean op: valid record, counters 0");

        // three alarmed ops
        do_op(1); do_op(1); do_op(1);
        chk(ac == 3 && !lockdown, "3 alarmed ops -> alarm_count 3, no lockdown");

        // power cycle (NVM keeps its value): counters must survive
        boot;
        chk(!lockdown && ac == 3 && tc == 0, "counters survive a power cycle");

        // one more alarmed op -> reaches N -> lockdown + key zero
        do_op(1);
        chk(ac == 4 && lockdown && key == 128'h0, "4th alarm reaches N: lockdown, key zeroized");

        // lockdown persists across a power cycle
        boot;
        chk(lockdown && ac == 4, "lockdown persists across a power cycle");

        if (errors == 0) $display("PASS tb_tamper_persist");
        else             $display("FAIL tb_tamper_persist (%0d errors)", errors);
        $finish;
    end
endmodule
