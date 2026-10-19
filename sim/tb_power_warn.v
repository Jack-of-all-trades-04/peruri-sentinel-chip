// Subsystem test for power_warn handling (P1-1, F8):
// a droop flagged by power_warn aborts the operation, charges one tear_count
// (not alarm_count), and releases nothing (commit_done stays low). A spoofed
// power_warn in the middle of an attack still produces no output and is
// counted in M. tear_count = M leads to lockdown.
`timescale 1ns/1ps
module tb_power_warn;
    localparam integer CW = 4, N = 4, M = 8, RECW = 17 + 2*CW;
    reg clk = 0; always #5 clk = ~clk;

    reg  por_n = 0, power_ok = 1;
    reg  alarm = 0, power_warn = 0, start_req = 0, op_done = 0, du = 0;
    wire rd_en, rd_addr, wr_en, wr_addr, rd_valid, wr_done;
    wire [RECW-1:0] rd_data, wr_data;
    wire op_grant, commit_fin, commit_clean, ready, boot_busy, zreq, lock;
    wire commit_done = commit_fin & commit_clean;   // release allowed
    wire [CW-1:0] ac, tc;
    integer errors = 0, n_commit = 0;

    tamper_persist_fsm #(.N(N), .M(M), .CW(CW), .DEMO_UNLOCK(1)) u_fsm (
        .clk(clk), .por_n(por_n), .alarm(alarm), .power_warn(power_warn),
        .start_req(start_req), .op_done(op_done), .debug_unlock(du),
        .nvm_rd_en(rd_en), .nvm_rd_addr(rd_addr), .nvm_rd_data(rd_data), .nvm_rd_valid(rd_valid),
        .nvm_wr_en(wr_en), .nvm_wr_addr(wr_addr), .nvm_wr_data(wr_data), .nvm_wr_done(wr_done),
        .op_grant(op_grant), .commit_fin(commit_fin), .commit_clean(commit_clean), .ready(ready), .boot_busy(boot_busy),
        .zeroize_req(zreq), .lockdown_state(lock), .alarm_count(ac), .tear_count(tc)
    );
    nvm_counter_model #(.RECW(RECW), .RD_LAT(2), .WR_LAT(8)) u_nvm (
        .clk(clk), .power_ok(power_ok),
        .rd_en(rd_en), .rd_addr(rd_addr), .rd_data(rd_data), .rd_valid(rd_valid),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data), .wr_done(wr_done)
    );
    always @(posedge clk) if (commit_done) n_commit = n_commit + 1;

    task chk; input cond; input [8*64-1:0] nm; begin
        if (!cond) begin $display("FAIL %0s (ac=%0d tc=%0d lock=%b commits=%0d)", nm, ac, tc, lock, n_commit); errors=errors+1; end
        else $display("  ok %0s", nm); end
    endtask

    // op kinds: 0 clean, 1 alarm, 2 power_warn (droop), 3 alarm+power_warn (spoof)
    task do_op; input [1:0] kind; integer t; begin
        @(negedge clk) start_req = 1; @(negedge clk) start_req = 0;
        t = 0; while (!op_grant && !lock && t < 400) begin @(negedge clk); t = t + 1; end
        if (op_grant) begin
            if (kind == 1 || kind == 3) begin alarm = 1; repeat (2) @(negedge clk); alarm = 0; end
            repeat (2) @(negedge clk);
            if (kind == 2 || kind == 3) begin power_warn = 1; repeat (2) @(negedge clk); power_warn = 0; end
            else begin @(negedge clk) op_done = 1; @(negedge clk) op_done = 0; end
            t = 0; while (!commit_fin && !lock && t < 400) begin @(negedge clk); t = t + 1; end
        end
        repeat (4) @(negedge clk);
    end endtask

    task boot; integer t; begin
        por_n = 0; repeat (3) @(negedge clk); por_n = 1;
        t = 0; while (boot_busy && t < 600) begin @(negedge clk); t = t + 1; end
        repeat (2) @(negedge clk);
    end endtask

    integer c0, k;
    initial begin
        boot;
        @(negedge clk) du = 1; repeat (4) @(negedge clk); du = 0;
        do_op(0);
        chk(ac == 0 && tc == 0 && n_commit == 1, "clean op commits, counters 0");

        c0 = n_commit;
        do_op(2);
        chk(tc == 1 && ac == 0 && n_commit == c0, "power_warn: +1 tear, 0 alarm, no release");

        c0 = n_commit;
        do_op(3);
        chk(tc == 2 && ac == 0 && n_commit == c0, "spoofed power_warn during attack: +1 tear, no output");

        // fill tear_count to M -> lockdown (already 2; need 6 more)
        for (k = 0; k < 6 && !lock; k = k + 1) do_op(2);
        chk(lock && tc == M, "tear_count reaches M: lockdown");

        if (errors == 0) $display("PASS tb_power_warn");
        else             $display("FAIL tb_power_warn (%0d errors)", errors);
        $finish;
    end
endmodule
