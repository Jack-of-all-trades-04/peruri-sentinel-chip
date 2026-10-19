// Subsystem test for NVM write tearing (P1-1):
// a write interrupted by loss of power corrupts only the slot being written;
// the other copy still holds the last good record, so the controller recovers
// after reboot and the counters never go down.
`timescale 1ns/1ps
module tb_nvm_tearing;
    localparam integer CW = 4, N = 4, M = 8, RECW = 17 + 2*CW;
    reg clk = 0; always #5 clk = ~clk;

    reg  por_n = 0, power_ok = 1;
    reg  alarm = 0, power_warn = 0, start_req = 0, op_done = 0, du = 0;
    wire rd_en, rd_addr, wr_en, wr_addr, rd_valid, wr_done;
    wire [RECW-1:0] rd_data, wr_data;
    wire op_grant, commit_fin, commit_clean, ready, boot_busy, zreq, lock;
    wire commit_done = commit_fin & commit_clean;   // release allowed
    wire [CW-1:0] ac, tc;
    integer errors = 0;

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

    task chk; input cond; input [8*64-1:0] nm; begin
        if (!cond) begin $display("FAIL %0s (ac=%0d tc=%0d lock=%b v0=%b v1=%b)", nm, ac, tc, lock, u_nvm.mem0!=={RECW{1'b1}}, u_nvm.mem1!=={RECW{1'b1}}); errors=errors+1; end
        else $display("  ok %0s", nm); end
    endtask

    task do_op; input atk; integer t; begin
        @(negedge clk) start_req = 1; @(negedge clk) start_req = 0;
        t = 0; while (!op_grant && !lock && t < 400) begin @(negedge clk); t = t + 1; end
        if (op_grant) begin
            if (atk) begin alarm = 1; repeat (2) @(negedge clk); alarm = 0; end
            repeat (3) @(negedge clk);
            @(negedge clk) op_done = 1; @(negedge clk) op_done = 0;
            t = 0; while (!commit_fin && !lock && t < 400) begin @(negedge clk); t = t + 1; end
        end
        repeat (4) @(negedge clk);
    end endtask

    task boot; integer t; begin
        por_n = 0; repeat (3) @(negedge clk); por_n = 1;
        t = 0; while (boot_busy && t < 600) begin @(negedge clk); t = t + 1; end
        repeat (2) @(negedge clk);
    end endtask

    // start an op and cut power partway through the COMMIT write
    task op_tear_commit; integer t; begin
        @(negedge clk) start_req = 1; @(negedge clk) start_req = 0;
        t = 0; while (!op_grant && !lock && t < 400) begin @(negedge clk); t = t + 1; end
        if (op_grant) begin
            alarm = 1; repeat (2) @(negedge clk); alarm = 0;
            repeat (3) @(negedge clk);
            @(negedge clk) op_done = 1; @(negedge clk) op_done = 0;
            // wait until the commit write is in flight, then cut power
            t = 0; while (!u_nvm.wbusy && t < 50) begin @(negedge clk); t = t + 1; end
            repeat (2) @(negedge clk);
            power_ok = 0;                       // tear the write
            while (u_nvm.wbusy) @(negedge clk);
        end
    end endtask

    integer ac_before;
    initial begin
        boot;
        @(negedge clk) du = 1; repeat (4) @(negedge clk); du = 0;
        do_op(0); do_op(1); do_op(1);
        chk(ac == 2, "two alarmed ops: alarm_count 2");

        // tear the COMMIT write of the 3rd alarmed op
        ac_before = ac;
        op_tear_commit;
        // power back, reboot: the torn slot is rejected, the other copy used
        power_ok = 1;
        boot;
        chk(ac >= ac_before && !lock, "after a torn commit, a valid copy is recovered, counter not lost");
        chk(u_nvm.mem0 !== {RECW{1'b1}} && u_nvm.mem1 !== {RECW{1'b1}}, "both slots non-blank (two-copy scheme)");

        // the controller keeps working and counters never decrease
        ac_before = ac;
        do_op(0); do_op(1);
        chk(ac >= ac_before && ac <= N, "controller still works, counter monotonic");

        if (errors == 0) $display("PASS tb_nvm_tearing");
        else             $display("FAIL tb_nvm_tearing (%0d errors)", errors);
        $finish;
    end
endmodule
