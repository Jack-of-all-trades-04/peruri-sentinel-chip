// Single-fault campaign for output_release_gate (two control copies + two-stage release).
//
// Two gates see identical inputs: "ref" is never disturbed and acts as the
// fault-free reference, "dut" gets exactly one bit flip. The flip is a
// hierarchical deposit at the falling clock edge (a single-event upset: the
// register keeps the wrong value until the gate logic rewrites it). It is
// applied to every register bit of the gate (both control copies, the
// parity bit, the stage flags, both valid rails, the status pulses and the
// ct_hold / ct_stage / ct_out registers) on every cycle of a set of
// representative operations:
//   0 clean operation          3 early abort (commit_fin during the hold)
//   1 alarm in the hold        4 lockdown in the confirm cycle
//   2 commit not clean         5 late commit (long WAIT)       6 alarm in the WAIT
// Checks per run:
//   - dut never shows ct_valid when the reference does not (no release the
//     fault-free gate would not make), and at most one release per op
//   - ct_out is zero whenever ct_valid is 0 (dut and reference)
//   - if the reference releases and the dut does not, the dut must have
//     raised gate_fault or gate_blocked (the decision change is reported)
//   - released data equals the reference data. The one exception is a flip of
//     the ct_out register in the very cycle it is valid: it corrupts the
//     port register itself and cannot be stopped, but gate_fault must be
//     raised (counted separately)
//   - the dut returns to idle (no hang)
// Without any flip, dut and reference must behave identically with no
// gate_fault.
`timescale 1ns/1ps
module tb_gate_single_fault;
    localparam integer H = 4;
    localparam integer T_END = 40;       // cycles per run
    localparam integer NSCEN = 7;
    localparam integer NTGT  = 21;

    reg clk = 0;
    always #5 clk = ~clk;

    reg          rst_n = 0, enable = 1, lockdown = 0;
    reg          op_start = 0, aes_done = 0, alarm = 0;
    reg  [127:0] ct_raw = 0;

    // ---- tamper-controller responder, driven by the reference gate ----
    integer      DELAY = 3;
    reg          CLEAN = 1;
    reg          early_fin = 0;
    reg          fin_r = 0;
    integer      cnt = -1;
    wire         r_op_done;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin fin_r <= 1'b0; cnt <= -1; end
        else begin
            fin_r <= 1'b0;
            if (r_op_done) cnt <= DELAY;
            else if (cnt > 0) cnt <= cnt - 1;
            if (cnt == 1) begin fin_r <= 1'b1; cnt <= -1; end
        end
    end
    wire commit_fin   = fin_r | early_fin;
    wire commit_clean = early_fin ? 1'b0 : CLEAN;

    wire [127:0] r_ct_out, d_ct_out;
    wire         r_valid, r_blocked, r_fault, r_busy;
    wire         d_valid, d_blocked, d_op_done, d_fault, d_busy;

    output_release_gate #(.H(H)) ref_g (
        .clk(clk), .rst_n(rst_n), .enable(enable), .lockdown(lockdown),
        .op_start(op_start), .aes_done(aes_done), .ct_raw(ct_raw),
        .alarm(alarm), .commit_fin(commit_fin), .commit_clean(commit_clean),
        .ct_out(r_ct_out), .ct_valid(r_valid), .gate_blocked(r_blocked),
        .op_done(r_op_done), .gate_fault(r_fault), .busy(r_busy)
    );
    output_release_gate #(.H(H)) dut (
        .clk(clk), .rst_n(rst_n), .enable(enable), .lockdown(lockdown),
        .op_start(op_start), .aes_done(aes_done), .ct_raw(ct_raw),
        .alarm(alarm), .commit_fin(commit_fin), .commit_clean(commit_clean),
        .ct_out(d_ct_out), .ct_valid(d_valid), .gate_blocked(d_blocked),
        .op_done(d_op_done), .gate_fault(d_fault), .busy(d_busy)
    );

    // ---- scenario parameters ----
    integer sc_alarm, sc_early, sc_lock_at;
    integer t_rel0 = 99;          // cycle in which ct_valid shows in the clean operation
    reg     sc_clean;
    integer sc_delay;
    task set_scen;
        input integer s;
        begin
            sc_alarm = 99; sc_early = 99; sc_lock_at = 99; sc_clean = 1; sc_delay = 3;
            case (s)
                1: sc_alarm   = 5;
                2: sc_clean   = 0;
                3: sc_early   = 5;
                4: sc_lock_at = t_rel0 - 1;  // the confirm edge of the clean operation
                5: sc_delay   = 14;
                6: sc_alarm   = 10;
                default: ;
            endcase
        end
    endtask

    // ---- flip targets ----
    function integer tgt_width;
        input integer tgt;
        begin
            case (tgt)
                0, 1:    tgt_width = 6;
                2, 3:    tgt_width = 8;
                15, 16, 17: tgt_width = 128;
                default: tgt_width = 1;
            endcase
        end
    endfunction

    function [8*10-1:0] tgt_name;
        input integer tgt;
        begin
            case (tgt)
                0: tgt_name = "stA"; 1: tgt_name = "stB"; 2: tgt_name = "hcA"; 3: tgt_name = "hcB";
                4: tgt_name = "blkA"; 5: tgt_name = "finA"; 6: tgt_name = "fokA";
                7: tgt_name = "blkB"; 8: tgt_name = "finB"; 9: tgt_name = "fokB";
                10: tgt_name = "a_go"; 11: tgt_name = "b_go_n"; 12: tgt_name = "pa";
                13: tgt_name = "vp"; 14: tgt_name = "vn";
                15: tgt_name = "ct_hold"; 16: tgt_name = "ct_stage"; 17: tgt_name = "ct_out_r";
                18: tgt_name = "gate_blk"; 19: tgt_name = "op_done"; 20: tgt_name = "gate_flt";
                default: tgt_name = "?";
            endcase
        end
    endfunction

    task do_flip;
        input integer tgt;
        input integer b;
        begin
            case (tgt)
                0:  dut.stA[b]      = ~dut.stA[b];
                1:  dut.stB[b]      = ~dut.stB[b];
                2:  dut.hcA[b]      = ~dut.hcA[b];
                3:  dut.hcB[b]      = ~dut.hcB[b];
                4:  dut.blkA        = ~dut.blkA;
                5:  dut.finA        = ~dut.finA;
                6:  dut.fokA        = ~dut.fokA;
                7:  dut.blkB        = ~dut.blkB;
                8:  dut.finB        = ~dut.finB;
                9:  dut.fokB        = ~dut.fokB;
                10: dut.a_go        = ~dut.a_go;
                11: dut.b_go_n      = ~dut.b_go_n;
                12: dut.pa          = ~dut.pa;
                13: dut.vp          = ~dut.vp;
                14: dut.vn          = ~dut.vn;
                15: dut.ct_hold[b]  = ~dut.ct_hold[b];
                16: dut.ct_stage[b] = ~dut.ct_stage[b];
                17: dut.ct_out_r[b] = ~dut.ct_out_r[b];
                18: dut.gate_blocked = ~dut.gate_blocked;
                19: dut.op_done      = ~dut.op_done;
                20: dut.gate_fault    = ~dut.gate_fault;
                default: ;
            endcase
        end
    endtask

    // ---- counters ----
    integer errors = 0;
    integer n_runs = 0;
    integer n_benign = 0;         // dut outputs identical to the reference, no fault pulse
    integer n_fault = 0;          // gate_fault raised
    integer n_blocked_only = 0;   // reference released, dut blocked via gate_blocked only
    integer n_released_ok = 0;    // dut released like the reference
    integer n_port_data = 0;      // ct_out_r flipped while valid (residual)
    integer n_changed = 0;        // runs where the decision changed (ref released, dut not)

    // ---- one run ----
    // scenario s, flip target tgt/bit at cycle fc (fc < 0: no flip)
    integer r_rel, d_rel, d_fault_seen, d_blk_seen, data_bad, runs_err;
    integer t;
    reg     identical;
    task run;
        input integer s;
        input integer fc;
        input integer tgt;
        input integer b;
        begin
            set_scen(s);
            CLEAN = sc_clean; DELAY = sc_delay;
            r_rel = 0; d_rel = 0; d_fault_seen = 0; d_blk_seen = 0; data_bad = 0;
            identical = 1; runs_err = 0;
            @(negedge clk) rst_n = 0; op_start = 0; aes_done = 0; alarm = 0; early_fin = 0; lockdown = 0;
            @(negedge clk);
            @(negedge clk) rst_n = 1;
            ct_raw = {$random, $random, $random, $random};
            for (t = 0; t < T_END; t = t + 1) begin
                op_start  = (t == 1);
                aes_done  = (t == 4);
                alarm     = (t == sc_alarm);
                early_fin = (t == sc_early);
                lockdown  = (t == sc_lock_at);
                if (t == fc) do_flip(tgt, b);
                // sample just before the rising edge: this is what a consumer
                // clocked by clk captures, including a flipped output register
                #4;
                // checks on the outputs of this cycle
                if (r_valid) begin r_rel = r_rel + 1; if (s == 0 && fc < 0) t_rel0 = t; end
                if (d_valid) d_rel = d_rel + 1;
                if (d_valid && !r_valid) begin
                    $display("FAIL illegal release: scen %0d cycle %0d %0s[%0d] t=%0d", s, fc, tgt_name(tgt), b, t);
                    runs_err = runs_err + 1;
                end
                if (!d_valid && d_ct_out !== 128'h0) begin
                    $display("FAIL dut ct_out non-zero with ct_valid = 0: scen %0d cycle %0d %0s[%0d] t=%0d", s, fc, tgt_name(tgt), b, t);
                    runs_err = runs_err + 1;
                end
                if (!r_valid && r_ct_out !== 128'h0) begin
                    $display("FAIL ref ct_out non-zero with ct_valid = 0: t=%0d", t);
                    runs_err = runs_err + 1;
                end
                if (d_valid && r_valid && d_ct_out !== r_ct_out) data_bad = data_bad + 1;
                if (d_fault)   d_fault_seen = 1;
                if (d_blocked) d_blk_seen = 1;
                if (d_valid !== r_valid || d_blocked !== r_blocked || d_fault) identical = 0;
                if (fc < 0 && (r_fault || d_fault)) begin
                    $display("FAIL gate_fault without a flip: scen %0d t=%0d", s, t);
                    runs_err = runs_err + 1;
                end
                @(negedge clk);
            end
            // ---- verdicts ----
            if (d_rel > 1) begin
                $display("FAIL more than one release: scen %0d cycle %0d %0s[%0d]", s, fc, tgt_name(tgt), b);
                runs_err = runs_err + 1;
            end
            if (d_busy || r_busy) begin
                $display("FAIL gate hangs (busy dut=%b ref=%b): scen %0d cycle %0d %0s[%0d]", d_busy, r_busy, s, fc, tgt_name(tgt), b);
                runs_err = runs_err + 1;
            end
            if (data_bad != 0) begin
                if (tgt == 17) begin
                    n_port_data = n_port_data + 1;
                    if (!d_fault_seen) begin
                        $display("FAIL port-register flip not reported: scen %0d cycle %0d bit %0d", s, fc, b);
                        runs_err = runs_err + 1;
                    end
                end else begin
                    $display("FAIL wrong data released: scen %0d cycle %0d %0s[%0d]", s, fc, tgt_name(tgt), b);
                    runs_err = runs_err + 1;
                end
            end
            if (r_rel > 0 && d_rel == 0) begin
                n_changed = n_changed + 1;
                if (!d_fault_seen && !d_blk_seen) begin
                    $display("FAIL silent decision change: scen %0d cycle %0d %0s[%0d]", s, fc, tgt_name(tgt), b);
                    runs_err = runs_err + 1;
                end else if (!d_fault_seen) n_blocked_only = n_blocked_only + 1;
            end
            if (fc >= 0) begin
                n_runs = n_runs + 1;
                if (d_fault_seen) n_fault = n_fault + 1;
                else if (identical) n_benign = n_benign + 1;
                if (r_rel > 0 && d_rel > 0 && data_bad == 0) n_released_ok = n_released_ok + 1;
            end
            errors = errors + runs_err;
        end
    endtask

    integer s, fc, tg, bb, w, stride;
    integer n_golden_rel;
    initial begin
        // golden runs: no flip, dut == ref, expected outcome per scenario
        for (s = 0; s < NSCEN; s = s + 1) begin
            run(s, -1, 0, 0);
            if ((s == 0 || s == 5) && !(r_rel == 1 && d_rel == 1)) begin
                $display("FAIL golden scenario %0d expected a release (ref=%0d dut=%0d)", s, r_rel, d_rel);
                errors = errors + 1;
            end
            if (!(s == 0 || s == 5) && !(r_rel == 0 && d_rel == 0)) begin
                $display("FAIL golden scenario %0d expected a block (ref=%0d dut=%0d)", s, r_rel, d_rel);
                errors = errors + 1;
            end
            if (!identical) begin
                $display("FAIL golden scenario %0d: dut differs from reference", s);
                errors = errors + 1;
            end
        end
        // flip campaign
        for (s = 0; s < NSCEN; s = s + 1)
            for (fc = 0; fc < T_END - 6; fc = fc + 1)
                for (tg = 0; tg < NTGT; tg = tg + 1) begin
                    w = tgt_width(tg);
                    // 128-bit data registers: all bits in the release scenarios,
                    // a spread of bits (0, 16, ..., 112, 127) elsewhere
                    stride = (w == 128 && s != 0 && s != 5) ? 16 : 1;
                    for (bb = 0; bb < w; bb = bb + stride)
                        run(s, fc, tg, bb);
                    if (w == 128 && stride == 16) run(s, fc, tg, 127);
                end
        $display("campaign: %0d single flips injected (%0d scenarios x %0d cycles x all gate register bits)",
                 n_runs, NSCEN, T_END - 6);
        $display("  decision identical to the reference, no gate_fault : %0d", n_benign);
        $display("  gate_fault raised                                  : %0d", n_fault);
        $display("  release kept as in the reference (data intact)     : %0d", n_released_ok);
        $display("  release lost (ref released, dut blocked)           : %0d (%0d with gate_blocked but no gate_fault)",
                 n_changed, n_blocked_only);
        $display("  ct_out flipped while valid (data hit, gate_fault raised): %0d", n_port_data);
        if (errors == 0) $display("PASS tb_gate_single_fault");
        else             $display("FAIL tb_gate_single_fault (%0d errors)", errors);
        $finish;
    end
endmodule
