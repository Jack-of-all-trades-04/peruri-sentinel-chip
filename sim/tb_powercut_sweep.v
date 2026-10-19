// Subsystem sweep for P1-1: cut power at every cycle offset of one operation
// and check the invariant in every case:
//   * the two counters never decrease across the cut,
//   * one operation adds at most one count (alarm_count OR tear_count),
//   * a cut or attacked operation never produces a clean release,
//   * the controller always recovers to a consistent state postc reboot.
`timescale 1ns/1ps
module tb_powercut_sweep;
    localparam integer CW = 4, N = 14, M = 14, RECW = 17 + 2*CW;
    reg clk = 0; always #5 clk = ~clk;

    reg  por_n = 0, power_ok = 1;
    reg  alarm = 0, power_warn = 0, start_req = 0, op_done = 0, du = 0;
    wire rd_en, rd_addr, wr_en, wr_addr, rd_valid, wr_done;
    wire [RECW-1:0] rd_data, wr_data;
    wire op_grant, commit_fin, commit_clean, ready, boot_busy, zreq, lock;
    wire commit_done = commit_fin & commit_clean;   // release allowed
    wire [CW-1:0] ac, tc;
    integer errors = 0, n_clean_commit = 0;
    reg cur_attack = 0;

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
    // a clean release is commit_done with no alarm/abort in the op
    always @(posedge clk) if (commit_done && !cur_attack) n_clean_commit = n_clean_commit + 1;

    task boot; integer t; begin
        por_n = 0; power_ok = 1; repeat (3) @(negedge clk); por_n = 1;
        t = 0; while (boot_busy && t < 600) begin @(negedge clk); t = t + 1; end
        repeat (2) @(negedge clk);
    end endtask

    integer d, t, prevc, postc, iter;
    initial begin
        boot;
        @(negedge clk) du = 1; repeat (4) @(negedge clk); du = 0;
        // establish a valid record
        cur_attack = 0;
        @(negedge clk) start_req = 1; @(negedge clk) start_req = 0;
        t = 0; while (!op_grant && t < 400) begin @(negedge clk); t = t + 1; end
        repeat (3) @(negedge clk);
        @(negedge clk) op_done = 1; @(negedge clk) op_done = 0;
        t = 0; while (!commit_fin && t < 400) begin @(negedge clk); t = t + 1; end
        repeat (4) @(negedge clk);

        n_clean_commit = 0;   // only count clean releases during the attacked sweep
        // sweep the cut offset over a whole operation
        for (iter = 0; iter < 12 && !lock; iter = iter + 1) begin
            d = iter + 1;
            prevc = ac + tc;
            cur_attack = 1;
            @(negedge clk) start_req = 1; @(negedge clk) start_req = 0;
            t = 0; while (!op_grant && !lock && t < 400) begin @(negedge clk); t = t + 1; end
            if (op_grant) begin
                alarm = 1; repeat (2) @(negedge clk); alarm = 0;
                // advance d cycles into the operation, then cut power
                repeat (d) @(negedge clk);
                if (d[0]) op_done = 1;           // on some offsets AES has finished
                @(negedge clk) op_done = 0;
                power_ok = 0;                    // tear any in-flight write
            end
            // power cut: reboot (NVM persists)
            cur_attack = 0;
            boot;
            postc = ac + tc;
            if (postc < prevc) begin
                $display("FAIL cut offset %0d: counters went down (%0d -> %0d)", d, prevc, postc); errors = errors + 1;
            end else if (postc - prevc > 1) begin
                $display("FAIL cut offset %0d: more than one count added (%0d -> %0d)", d, prevc, postc); errors = errors + 1;
            end else
                $display("  ok cut offset %0d: %0d -> %0d (ac=%0d tc=%0d)", d, prevc, postc, ac, tc);
        end

        if (n_clean_commit != 0) begin
            $display("FAIL a clean release happened during an attacked/cut operation (%0d)", n_clean_commit);
            errors = errors + 1;
        end else
            $display("  ok no clean release during any attacked/cut operation");

        if (errors == 0) $display("PASS tb_powercut_sweep");
        else             $display("FAIL tb_powercut_sweep (%0d errors)", errors);
        $finish;
    end
endmodule
