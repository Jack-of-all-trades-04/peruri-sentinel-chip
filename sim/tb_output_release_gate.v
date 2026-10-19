// Self-checking testbench for output_release_gate with the commit handshake.
// A responder plays the tamper controller: DELAY cycles after the gate's
// op_done it pulses commit_fin with commit_clean = CLEAN.
// Checks:
//   - no alarm + clean commit -> exactly one release, the right data, and
//     never before the commit (release waits for the NVM write)
//   - alarm mid-op, at aes_done, at done+1..done+H -> block
//   - alarm while waiting for the commit -> block
//   - alarm after the release -> no effect on that release
//   - commit not clean -> block; no commit at all -> never released
//   - early commit_fin (operation aborted before the decision) -> block
//   - Sentinel OFF ignores alarms (commit still required); lockdown blocks
//   - ct_out is zero whenever ct_valid = 0
//   - two-copy gate: the release comes one cycle after the single-copy gate
//     (decision D, confirm D+1, ct_valid D+2); lockdown at the confirm blocks;
//     gate_fault never pulses in a fault-free run; ct_valid is one cycle wide
`timescale 1ns/1ps
module tb_output_release_gate;

`ifndef NO_DUMP
    initial begin
        $dumpfile("sim_build/tb_output_release_gate.vcd");
        $dumpvars(0, tb_output_release_gate);
    end
`endif
    localparam integer H = 4;
    reg clk = 0;
    always #5 clk = ~clk;

    reg          rst_n = 0, enable = 1, lockdown = 0, lock_hold = 0;
    reg          op_start = 0, aes_done = 0, alarm = 0;
    reg  [127:0] ct_raw = 0;
    wire [127:0] ct_out;
    wire         ct_valid, gate_blocked, op_done, gate_fault, busy;
    integer      errors = 0;

    // ---- tamper-controller responder ----
    integer      DELAY = 3;          // cycles from op_done to commit_fin
    reg          CLEAN = 1;          // commit_clean value
    reg          RESP  = 1;          // 0: never answer
    reg          early_fin = 0;      // testbench-forced commit_fin (abort)
    reg          fin_r = 0;
    integer      cnt = -1;
    always @(posedge clk) begin
        fin_r <= 1'b0;
        if (op_done && RESP) cnt <= DELAY;
        else if (cnt > 0)    cnt <= cnt - 1;
        if (cnt == 1) begin fin_r <= 1'b1; cnt <= -1; end
    end
    wire commit_fin   = fin_r | early_fin;
    wire commit_clean = early_fin ? 1'b0 : CLEAN;

    output_release_gate #(.H(H)) dut (
        .clk(clk), .rst_n(rst_n), .enable(enable), .lockdown(lockdown),
        .op_start(op_start), .aes_done(aes_done), .ct_raw(ct_raw),
        .alarm(alarm), .commit_fin(commit_fin), .commit_clean(commit_clean),
        .ct_out(ct_out), .ct_valid(ct_valid), .gate_blocked(gate_blocked),
        .op_done(op_done), .gate_fault(gate_fault), .busy(busy)
    );

    always @(posedge clk)
        if (rst_n && !ct_valid && ct_out !== 128'h0) begin
            $display("FAIL ct_out non-zero while ct_valid = 0");
            errors = errors + 1;
        end

    always @(posedge clk)
        if (rst_n && gate_fault) begin
            $display("FAIL gate_fault in a fault-free run");
            errors = errors + 1;
        end

    // ct_valid is a single-cycle pulse
    reg valid_d = 0;
    always @(posedge clk) begin
        if (rst_n && ct_valid && valid_d) begin
            $display("FAIL ct_valid longer than one cycle");
            errors = errors + 1;
        end
        valid_d <= ct_valid;
    end

    // one operation: aes_done at t = 0; alarm_at = cycle offset of a one-cycle
    // alarm relative to aes_done (99 = none); early = cycle of a forced abort
    // commit_fin (99 = none). Returns the outcome and the cycle of the commit.
    integer rel, blk, t_dec, t_fin;
    integer lock_at = 99;            // cycle of a one-cycle lockdown (99 = none)
    task op;
        input integer alarm_at;
        input integer early;
        integer t;
        begin
            rel = 0; blk = 0; t_dec = -1; t_fin = -1;
            ct_raw = {$random, $random, $random, $random};
            @(negedge clk) op_start = 1;
            @(negedge clk) op_start = 0;
            for (t = -9; t <= 40 && t_dec < 0; t = t + 1) begin
                aes_done  = (t == 0);
                alarm     = (t == alarm_at);
                early_fin = (t == early);
                lockdown  = lock_hold | (t == lock_at);
                @(posedge clk); #1;
                if (commit_fin && t_fin < 0) t_fin = t;
                if (ct_valid) begin
                    rel = rel + 1; t_dec = t;
                    if (ct_out !== ct_raw) begin
                        $display("FAIL released wrong data"); errors = errors + 1;
                    end
                end
                if (gate_blocked) begin blk = blk + 1; t_dec = t; end
                @(negedge clk);
            end
            aes_done = 0; alarm = 0; early_fin = 0; lockdown = lock_hold;
            repeat (3) @(negedge clk);
        end
    endtask

    task want;
        input            want_release;
        input [8*56-1:0] name;
        begin
            if (want_release && (rel != 1 || blk != 0)) begin
                $display("FAIL %0s: expected release (rel=%0d blk=%0d)", name, rel, blk); errors = errors + 1;
            end else if (!want_release && (rel != 0 || blk != 1)) begin
                $display("FAIL %0s: expected block (rel=%0d blk=%0d)", name, rel, blk); errors = errors + 1;
            end else
                $display("  ok %0s", name);
        end
    endtask

    integer k, t_rel;
    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;

        op(99, 99); want(1, "no alarm + clean commit -> release");
        t_rel = t_dec;
        if (t_dec <= t_fin || t_fin < H) begin
            $display("FAIL release must come after the commit (fin=%0d rel=%0d)", t_fin, t_dec); errors = errors + 1;
        end else $display("  ok release waits for the commit (commit t=%0d, release t=%0d)", t_fin, t_dec);

        op(-5, 99); want(0, "alarm mid-op -> block");
        for (k = 0; k <= H; k = k + 1) begin
            op(k, 99); want(0, "alarm at done..done+H -> block");
        end
        op(H + 2, 99); want(0, "alarm while waiting for the commit -> block");
        // t_rel is the cycle ct_valid shows: decision edge t_rel-1, confirm edge t_rel
        op(t_rel - 1, 99); want(0, "alarm in the decision cycle -> block");
        op(t_rel, 99);     want(1, "alarm in the confirm cycle -> released");
        op(t_rel + 1, 99); want(1, "alarm after the release -> released");
        lock_at = t_rel - 1; op(99, 99); want(0, "lockdown in the decision cycle -> block");
        lock_at = t_rel;     op(99, 99); want(0, "lockdown in the confirm cycle -> block");
        lock_at = t_rel + 1; op(99, 99); want(1, "lockdown after the release -> released");
        lock_at = 99;

        CLEAN = 0; op(99, 99); want(0, "commit not clean -> block"); CLEAN = 1;
        op(99, -3); want(0, "early abort commit_fin during the op -> block");
        op(99, 2);  want(0, "early abort commit_fin during the hold -> block");
        DELAY = 20; op(99, 99); want(1, "late commit (20 cycles) -> release after it"); DELAY = 3;

        enable = 0; op(-5, 99); want(1, "Sentinel OFF ignores alarm (commit still needed)"); enable = 1;
        lock_hold = 1; op(99, 99); want(0, "lockdown suppresses release"); lock_hold = 0;

        // no commit at all: the result is never released, the gate stays busy
        RESP = 0; op(99, 99);
        if (rel != 0 || !busy) begin
            $display("FAIL no commit: released=%0d busy=%b", rel, busy); errors = errors + 1;
        end else $display("  ok no commit -> never released, gate waits");
        rst_n = 0; repeat (2) @(negedge clk); rst_n = 1; RESP = 1;

        if (errors == 0) $display("PASS tb_output_release_gate");
        else             $display("FAIL tb_output_release_gate (%0d errors)", errors);
        $finish;
    end
endmodule
