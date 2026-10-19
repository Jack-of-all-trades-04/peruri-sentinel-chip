// Formal harness for the Sentinel security controller:
//   output_release_gate + graduated_tamper_fsm + tripwire_zeroize + master_key_vault
// wired as in peruri_sentinel_core, production build (compiled without
// DEMO_BUILD: no Sentinel enable, no unlock port, key from the write port).
//
// The gate is proven with a WD-bit data path (parameter W of the gate). The
// data bits only pass through registers and one XOR parity tree and never
// influence the control flow, so the control, release, parity and
// fault-detection logic is identical for WD = 128. The reason for the
// reduction: the unbounded proof (IC3/PDR) cannot learn the parity
// invariants of a wide XOR tree; the 128-bit data path is covered by the
// simulation tests (tb_output_release_gate, tb_gate_single_fault, the core
// testbenches) and by synthesis equivalence of the per-bit structure.
//
// The AES core is NOT in the harness: aes_done, ct_raw and op_start are free
// inputs, so every property holds for ANY behaviour of the cipher, including
// a faulted one. rst_n (user reset) and alarm are free as well; por_n is low
// in the first cycle only.
//
// The checks compare the design against an independent reference model of
// the specification (written here from the spec, not copied from the RTL),
// using only the module ports. Checked with SymbiYosys (sec_ctrl.sby),
// engine abc pdr: an unbounded proof, not a bounded search.
//
// Defines:
//   (none)          safety properties S1-S10 (task "prove")
//   REACH_RELEASE   asserts that a release never happens; must FAIL (task reach_release)
//   REACH_LOCKDOWN  asserts that lockdown never happens;  must FAIL (task reach_lockdown)
module sec_ctrl_formal #(
    parameter integer   H        = 4,
    parameter integer   N        = 4,
    parameter integer   WD       = 8     // data width of the gate under proof (see below)
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         alarm,
    input  wire         op_start,
    input  wire         aes_done,
    input  wire [WD-1:0] ct_raw,
    input  wire         commit_fin,    // tamper controller commit (free input)
    input  wire         commit_clean,
    input  wire         key_wr_en,     // production key port, free input
    input  wire [127:0] key_wr_data
);
    // ---------------- power-on reset: low in cycle 0 only ----------------
    reg init_done = 1'b0;
    always @(posedge clk) init_done <= 1'b1;
    wire por_n = init_done;

    // ---------------- design under test ----------------
    wire         lockdown, zeroize_req, async_zeroize_n, ct_valid, gate_blocked, op_done, gate_busy, gate_fault;
    wire [3:0]   tamper_counter;
    wire [WD-1:0] ct_out;
    wire [127:0] key;

    output_release_gate #(.H(H), .W(WD)) u_gate (
        .clk(clk), .rst_n(rst_n), .lockdown(lockdown),
        .op_start(op_start), .aes_done(aes_done), .ct_raw(ct_raw),
        .alarm(alarm), .commit_fin(commit_fin), .commit_clean(commit_clean),
        .ct_out(ct_out), .ct_valid(ct_valid), .gate_blocked(gate_blocked),
        .op_done(op_done), .gate_fault(gate_fault), .busy(gate_busy)
    );
    graduated_tamper_fsm #(.N(N), .DEMO_UNLOCK(0)) u_fsm (
        .clk(clk), .por_n(por_n), .alarm(alarm),
        .tamper_counter(tamper_counter), .zeroize_req(zeroize_req), .lockdown_state(lockdown)
    );
    tripwire_zeroize u_trip (
        .clk(clk), .por_n(por_n), .zeroize_req(zeroize_req), .async_zeroize_n(async_zeroize_n)
    );
    master_key_vault u_vault (
        .clk(clk), .rst_n(rst_n), .por_n(por_n), .async_zeroize_n(async_zeroize_n),
        .key_wr_en(key_wr_en), .key_wr_data(key_wr_data),
        .key_to_cipher(key), .key_loaded()
    );

    // ---------------- reference model of the gate specification ----------------
    // An operation is accepted when the gate is idle and op_start is high.
    // After aes_done and H hold cycles the gate waits for the tamper
    // controller's commit. The decision is taken in the cycle the commit is
    // known (commit_fin now, or one remembered from earlier in the op). The
    // result is released if and only if no alarm was seen from the accept
    // cycle up to and including the decision cycle, lockdown was low at the
    // end of the hold and in the decision cycle, and the commit was clean.
    // The two-copy gate stages the release in the cycle after the decision
    // and confirms it one cycle later (ct_valid at decision + 2): lockdown
    // must also be low in the confirm cycle, otherwise the release becomes a
    // gate_blocked pulse. r_release / r_block below are the decision-time
    // pulses (cycle decision + 1); r_release2 / r_lockblk are the delayed ones.
    localparam [1:0] R_IDLE = 2'd0, R_OP = 2'd1, R_HOLD = 2'd2, R_WAIT = 2'd3;
    reg         r_fin, r_ok;
    reg [1:0]   r_st;
    reg [7:0]   r_cnt;
    reg         r_alarm;      // alarm seen in the current window
    reg [WD-1:0] r_ct;         // ciphertext delivered at aes_done
    reg         r_release;    // decision + 1: release staged
    reg         r_block;      // decision + 1: expected gate_blocked
    reg         r_release2;   // decision + 2: expected ct_valid
    reg         r_lockblk;    // decision + 2: expected gate_blocked (lockdown at the confirm)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_st <= R_IDLE; r_cnt <= 8'd0; r_alarm <= 1'b0;
            r_ct <= {WD{1'b0}}; r_release <= 1'b0; r_block <= 1'b0;
            r_release2 <= 1'b0; r_lockblk <= 1'b0;
            r_fin <= 1'b0; r_ok <= 1'b0;
        end else begin
            r_release <= 1'b0;
            r_block   <= 1'b0;
            r_release2 <= r_release & !lockdown;
            r_lockblk  <= r_release & lockdown;
            case (r_st)
                R_IDLE: if (op_start) begin
                    r_st <= R_OP; r_alarm <= alarm; r_fin <= 1'b0; r_ok <= 1'b0;
                end
                R_OP: begin
                    r_alarm <= r_alarm | alarm;
                    if (commit_fin) begin r_fin <= 1'b1; r_ok <= commit_clean; end
                    if (aes_done) begin r_ct <= ct_raw; r_cnt <= 8'd0; r_st <= R_HOLD; end
                end
                R_HOLD: begin
                    r_alarm <= r_alarm | alarm;
                    if (commit_fin) begin r_fin <= 1'b1; r_ok <= commit_clean; end
                    if (r_cnt == H - 1) begin
                        if (lockdown) r_alarm <= 1'b1;
                        r_st <= R_WAIT;
                    end else
                        r_cnt <= r_cnt + 8'd1;
                end
                default: begin   // R_WAIT
                    if (r_fin | commit_fin) begin
                        r_st      <= R_IDLE;
                        r_release <= !(r_alarm | alarm | lockdown) && (r_fin ? r_ok : commit_clean);
                        r_block   <= !(!(r_alarm | alarm | lockdown) && (r_fin ? r_ok : commit_clean));
                        r_alarm   <= 1'b0;
                        r_fin     <= 1'b0;
                    end else
                        r_alarm <= r_alarm | alarm;
                end
            endcase
        end
    end

    // independent rising-edge detector for the counter rule
    reg alarm_d;
    always @(posedge clk or negedge por_n)
        if (!por_n) alarm_d <= 1'b0; else alarm_d <= alarm;

    reg past_ok = 1'b0;          // $past is meaningful (after the first cycle)
    always @(posedge clk) past_ok <= init_done;

`ifdef FORMAL
    // At power-on the user reset is also active (the board top holds rst_n
    // low while por_n is low). After that rst_n is free: the user may reset
    // at any time, which is exactly the case the properties must survive.
    always @(*) if (!init_done) assume (!rst_n);

`ifdef REACH_RELEASE
    always @(*) if (init_done) assert (!(ct_valid && ct_out != {WD{1'b0}}));
`elsif REACH_LOCKDOWN
    always @(*) if (init_done) assert (!(lockdown && key == 128'h0));
`else
    always @(*) begin
        if (init_done) begin
            // S1: the gate releases exactly when the specification says so:
            //     no alarm from accept to decision, not in lockdown.
            assert (ct_valid == r_release2);
            assert (gate_blocked == (r_block | r_lockblk));
            // S2: what is released is exactly what the AES delivered
            if (ct_valid) assert (ct_out == r_ct);
            // S3: nothing is visible on the output unless ct_valid
            if (!ct_valid) assert (ct_out == {WD{1'b0}});
            // S3b: the same property read the other way: a non-zero ct_out
            //      implies ct_valid
            if (ct_out != {WD{1'b0}}) assert (ct_valid);
            // S11: the two control copies never disagree in the fault-free design
            assert (!gate_fault);
            // S4: lockdown <=> counter reached N; zeroize request follows it
            assert (lockdown == (tamper_counter >= N));
            assert (zeroize_req == lockdown);
            // S5: below N, no zeroize and no lockdown (anti-DoS)
            if (tamper_counter < N) assert (!zeroize_req && !lockdown);
            // S6: the key is zero whenever the tripwire is set
            if (!async_zeroize_n) assert (key == 128'h0);
        end
    end

    always @(posedge clk) begin
        if (past_ok) begin
            // S7: lockdown never clears, whatever the user reset does
            if ($past(lockdown)) assert (lockdown);
            // S8: no release in the cycle after lockdown is set
            if ($past(lockdown)) assert (!ct_valid);
            // S9: the counter moves by +1 exactly on a rising alarm edge and
            //     never goes down (saturates at 15)
            if ($past(alarm & ~alarm_d) && $past(tamper_counter) != 4'hf)
                assert (tamper_counter == $past(tamper_counter) + 4'd1);
            else
                assert (tamper_counter == $past(tamper_counter));
            // S10: one cycle after the zeroize request the key is erased
            if ($past(zeroize_req)) assert (!async_zeroize_n && key == 128'h0);
        end
    end
`endif
`endif
endmodule
