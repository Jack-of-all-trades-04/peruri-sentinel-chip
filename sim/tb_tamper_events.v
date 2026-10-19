// Subsystem test for the alarm/abort paths of tamper_persist_fsm that the
// operation-level tests do not reach:
//   - an alarm outside any operation is committed as an EVENT (+1 alarm_count)
//   - an alarm while the controller writes a COMMIT stays pending and is
//     committed as a separate EVENT after it (the operation itself is clean)
//   - an alarm during boot stays pending and is committed after boot
//   - an alarm still pending when a request arrives is charged to that
//     operation (not released, one count, no extra EVENT)
//   - power_warn during MARK aborts before op_grant: no AES start, +1 tear
//   - every event is persistent across a power cycle
`timescale 1ns/1ps
module tb_tamper_events;
    localparam integer CW = 4, N = 10, M = 10, RECW = 17 + 2*CW;
    reg clk = 0; always #5 clk = ~clk;

    reg  por_n = 0, power_ok = 1;
    reg  alarm = 0, power_warn = 0, start_req = 0, op_done = 0;
    wire rd_en, rd_addr, wr_en, wr_addr, rd_valid, wr_done;
    wire [RECW-1:0] rd_data, wr_data;
    wire ready, op_grant, commit_fin, commit_clean, boot_busy, zreq, lock;
    wire [CW-1:0] ac, tc;
    integer errors = 0, n_grant = 0, n_clean = 0;

    tamper_persist_fsm #(.N(N), .M(M), .CW(CW), .DEMO_UNLOCK(0)) u_fsm (
        .clk(clk), .por_n(por_n), .alarm(alarm), .power_warn(power_warn),
        .start_req(start_req), .op_done(op_done), .debug_unlock(1'b0),
        .nvm_rd_en(rd_en), .nvm_rd_addr(rd_addr), .nvm_rd_data(rd_data), .nvm_rd_valid(rd_valid),
        .nvm_wr_en(wr_en), .nvm_wr_addr(wr_addr), .nvm_wr_data(wr_data), .nvm_wr_done(wr_done),
        .ready(ready), .op_grant(op_grant), .commit_fin(commit_fin), .commit_clean(commit_clean),
        .boot_busy(boot_busy), .zeroize_req(zreq), .lockdown_state(lock),
        .alarm_count(ac), .tear_count(tc)
    );
    nvm_counter_model #(.CW(CW), .RD_LAT(2), .WR_LAT(8), .INIT_BLANK(0)) u_nvm (
        .clk(clk), .power_ok(power_ok),
        .rd_en(rd_en), .rd_addr(rd_addr), .rd_data(rd_data), .rd_valid(rd_valid),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data), .wr_done(wr_done)
    );
    always @(posedge clk) begin
        if (op_grant) n_grant = n_grant + 1;
        if (commit_fin && commit_clean) n_clean = n_clean + 1;
    end

    task chk; input cond; input [8*64-1:0] nm; begin
        if (!cond) begin $display("FAIL %0s (ac=%0d tc=%0d lock=%b st=%0d)", nm, ac, tc, lock, u_fsm.st); errors=errors+1; end
        else $display("  ok %0s", nm); end
    endtask

    task wait_idle; integer t; begin
        t = 0; while (!ready && !lock && t < 600) begin @(negedge clk); t = t + 1; end
        repeat (2) @(negedge clk);
    end endtask

    task boot; begin
        por_n = 0; repeat (3) @(negedge clk); por_n = 1;
        wait_idle;
    end endtask

    task pulse_alarm; begin
        @(negedge clk) alarm = 1; @(negedge clk) alarm = 0;
    end endtask

    // clean op; if `alarm_in_commit`, an alarm pulses while COMMIT is written
    task clean_op; input alarm_in_commit; integer t; begin
        wait_idle;
        @(negedge clk) start_req = 1; @(negedge clk) start_req = 0;
        t = 0; while (!op_grant && t < 400) begin @(negedge clk); t = t + 1; end
        repeat (3) @(negedge clk);
        @(negedge clk) op_done = 1; @(negedge clk) op_done = 0;
        if (alarm_in_commit) begin repeat (3) @(negedge clk); pulse_alarm; end
        t = 0; while (!commit_fin && t < 400) begin @(negedge clk); t = t + 1; end
        wait_idle;
    end endtask

    integer ac0, tc0, g0, c0;
    initial begin
        boot;
        chk(!lock && ac == 0 && tc == 0 && ready, "personalised NVM boots to IDLE");

        // 1. alarm outside any operation -> EVENT
        ac0 = ac;
        pulse_alarm; repeat (30) @(negedge clk); wait_idle;
        chk(ac == ac0 + 1, "alarm outside an operation: EVENT, alarm_count +1");

        // 2. alarm while the COMMIT write is in flight
        ac0 = ac; c0 = n_clean;
        clean_op(1);
        chk(n_clean == c0 + 1, "operation itself stays clean (alarm came after op_done)");
        repeat (30) @(negedge clk); wait_idle;           // let the EVENT write finish
        chk(ac == ac0 + 1, "alarm during COMMIT: pending, committed as EVENT (+1)");

        // 3. alarm during boot -> pending -> EVENT after boot
        ac0 = ac;
        por_n = 0; repeat (3) @(negedge clk); por_n = 1;
        repeat (2) @(negedge clk); pulse_alarm;           // controller is reading NVM
        wait_idle; repeat (30) @(negedge clk); wait_idle; // let the EVENT write finish
        chk(ac == ac0 + 1, "alarm during boot: committed after boot (+1)");

        // 4. alarm pending when a request is taken -> charged to that op
        ac0 = ac; c0 = n_clean;
        wait_idle;
        @(negedge clk) begin alarm = 1; start_req = 1; end
        @(negedge clk) begin alarm = 0; start_req = 0; end
        while (!op_grant) @(negedge clk);
        repeat (3) @(negedge clk);
        @(negedge clk) op_done = 1; @(negedge clk) op_done = 0;
        while (!commit_fin) @(negedge clk);
        wait_idle;
        chk(ac == ac0 + 1 && n_clean == c0, "alarm with the request: op not clean, one count only");

        // 5. power_warn during MARK -> abort before op_grant
        tc0 = tc; g0 = n_grant; c0 = n_clean;
        wait_idle;
        @(negedge clk) start_req = 1; @(negedge clk) start_req = 0;
        repeat (2) @(negedge clk);                         // MARK write in flight
        power_warn = 1; repeat (2) @(negedge clk); power_warn = 0;
        while (!commit_fin) @(negedge clk);
        wait_idle;
        chk(tc == tc0 + 1 && n_grant == g0 && n_clean == c0,
            "power_warn during MARK: no op_grant, tear_count +1, not clean");

        // 6. all of it is persistent
        ac0 = ac; tc0 = tc;
        boot;
        chk(ac == ac0 && tc == tc0 && !lock, "events persist across a power cycle");

        if (errors == 0) $display("PASS tb_tamper_events");
        else             $display("FAIL tb_tamper_events (%0d errors)", errors);
        $finish;
    end
endmodule
