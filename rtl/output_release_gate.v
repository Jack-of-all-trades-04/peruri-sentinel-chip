// output_release_gate (CLK_sys domain)
//
// Holds the AES result internally and releases it only when
//   - no alarm was seen from op_start until the release decision, and
//   - the tamper controller has committed the operation to NVM (commit_fin)
//     and reported it clean (commit_clean), and
//   - the device is not in lockdown.
//
//   cycle T          : aes_done = 1 (alarm here still blocks)
//   T+1 .. T+H       : HOLD, alarm here still blocks; at T+H op_done pulses
//                      to the tamper controller (end of the sensor window)
//   T+H+1 ..         : WAIT for commit_fin (the NVM write); alarm still blocks
//   decision cycle D : both copies decide (commit known); RELEASE stages the
//                      result, SUPPRESS pulses gate_blocked at D+1
//   D+1              : stage confirm (second copy); lockdown still blocks here
//   D+2              : ct_valid = 1 for one cycle, ct_out = result (RELEASE)
//
// A commit_fin that arrives before the decision (the controller aborted the
// operation, e.g. power_warn) is remembered and ends the operation as soon as
// the hold window is over. Without commit_fin the result is never released.
//
// Single-fault tolerance (no single bit flip in any gate register can release
// a result that the fault-free gate would not release):
//   - Two complete copies of the control state. gate_A uses a sparse state
//     code (minimum Hamming distance 4 between legal codes, so one flipped
//     bit is always an illegal code). gate_B is written independently in the
//     complement domain: every register of B stores the bitwise inverse of
//     the same register of A, and B has its own HOLD counter.
//   - Two-stage registered release:
//       ct_hold --(A decides RELEASE at D)--> ct_stage
//               --(B confirms at D+1)-------> ct_out (register) --> port
//     ct_stage is cleared on every cycle unless copy A authorises it, ct_out
//     is cleared on every cycle unless copy B authorises it. A release needs
//     a_go (A) and b_go (B) together.
//   - ct_valid is a dual-rail pair (vp true, vn inverted). The port valid is
//     vp & ~vn, so one flipped rail can only suppress it, and ct_out is
//     masked with the same valid. ct_out is a register output; there is no
//     combinational path from ct_hold to the port.
//   - A parity bit taken from ct_raw at aes_done is checked against the
//     parity of ct_stage at the confirm: a flip in ct_hold, ct_stage or the
//     parity bit blocks the release. (A flip in the ct_out register in the
//     very cycle it is valid cannot be stopped, as the consumer already
//     samples it; the gate compares ct_out with the parity bit while valid
//     and raises gate_fault one cycle later.)
//   - Every cycle all A registers are compared with the inverse of the B
//     registers, both state codes are checked for legality, and the two
//     decisions are compared. Any disagreement or illegal code raises
//     gate_fault (registered, one cycle) and the gate drops the operation:
//     nothing is released, ct_hold/ct_stage/ct_out are cleared, both copies
//     return to idle, gate_blocked and op_done pulse once (op_done so that
//     the tamper controller can leave its RUN state), and busy stays high
//     only until that edge. The cores may route gate_fault to the alarm
//     counter.
//
// ct_out reads as zero whenever ct_valid is 0, so a held or blocked result
// is never visible on the output port.
//
// Release latency is one cycle longer than the single-copy gate (ct_valid at
// D+2 instead of D+1).
//
// enable = 0 (DEMO_BUILD only) models "Sentinel OFF" for the demo: alarms are
// ignored. The commit handshake still applies. lockdown = 1 suppresses every
// release.
module output_release_gate #(
    parameter integer H = 4,
    parameter integer W = 128    // data width: 128 in every build, only the formal harness lowers it
) (
    input  wire         clk,
    input  wire         rst_n,
`ifdef DEMO_BUILD
    input  wire         enable,      // demo "Sentinel OFF"; production: always on
`endif
    input  wire         lockdown,
    input  wire         op_start,
    input  wire         aes_done,
    input  wire [W-1:0] ct_raw,
    input  wire         alarm,
    input  wire         commit_fin,     // tamper controller finished the NVM commit
    input  wire         commit_clean,   // ... and the operation may be released
    output wire [W-1:0] ct_out,
    output wire         ct_valid,
    output reg          gate_blocked,
    output reg          op_done,        // to the tamper controller: decision point
    output reg          gate_fault,     // copies disagree or illegal state code (1 cycle)
    output wire         busy
);
    // ---------------- state codes ----------------
    // A: 6-bit codes, pairwise Hamming distance 4. B stores the inverse.
    localparam [5:0] A_IDLE = 6'b000000, A_OP = 6'b001111,
                     A_HOLD = 6'b110011, A_WAIT = 6'b111100;
    localparam [5:0] B_IDLE = ~A_IDLE, B_OP = ~A_OP,
                     B_HOLD = ~A_HOLD, B_WAIT = ~A_WAIT;
    localparam [7:0] HEND  = H - 1;

    // ---------------- registers ----------------
    // copy A (true polarity)
    (* keep, preserve, fsm_encoding = "none", syn_encoding = "user, safe" *) reg [5:0] stA;
    (* keep, preserve *) reg [7:0] hcA;
    (* keep, preserve *) reg       blkA, finA, fokA;
    (* keep, preserve *) reg       a_go;       // A authorised the staged release
    (* keep, preserve *) reg       pa;         // parity of ct_raw taken at aes_done
    // copy B (every register holds the inverse of the A register)
    (* keep, preserve, fsm_encoding = "none", syn_encoding = "user, safe" *) reg [5:0] stB;
    (* keep, preserve *) reg [7:0] hcB;
    (* keep, preserve *) reg       blkB, finB, fokB;
    (* keep, preserve *) reg       b_go_n;     // inverse: 0 = B confirms the staged release
    // release path
    (* keep, preserve *) reg [W-1:0] ct_hold;
    (* keep, preserve *) reg [W-1:0] ct_stage;
    (* keep, preserve *) reg [W-1:0] ct_out_r;
    (* keep, preserve *) reg         vp;       // valid, true rail
    (* keep, preserve *) reg         vn;       // valid, inverted rail

`ifdef DEMO_BUILD
    wire alarm_eff = enable & alarm;
`else
    wire alarm_eff = alarm;
`endif

    // port: valid needs both rails, data is masked with the same valid
    wire valid_p = vp & ~vn;
    assign ct_valid = valid_p;
    assign ct_out   = ct_out_r & {W{valid_p}};

    // ---------------- copy A decisions ----------------
    wire a_idle  = (stA == A_IDLE);
    wire a_op    = (stA == A_OP);
    wire a_hold  = (stA == A_HOLD);
    wire a_wait  = (stA == A_WAIT);
    wire a_legal = a_idle | a_op | a_hold | a_wait;
    wire a_hend  = a_hold & (hcA == HEND);
    wire a_fin_now = finA | commit_fin;
    wire a_ok_now  = finA ? fokA : commit_clean;
    wire a_dec   = a_wait & a_fin_now;
    wire a_rel   = a_dec & ~(blkA | alarm_eff | lockdown | ~a_ok_now);

    // ---------------- copy B decisions (complement domain) ----------------
    wire b_idle  = (stB == B_IDLE);
    wire b_op    = (stB == B_OP);
    wire b_hold  = (stB == B_HOLD);
    wire b_wait  = (stB == B_WAIT);
    wire b_legal = b_idle | b_op | b_hold | b_wait;
    wire b_hend  = b_hold & (hcB == ~HEND);
    wire b_fin_now = ~finB | commit_fin;
    wire b_ok_now  = ~finB ? ~fokB : commit_clean;
    wire b_dec   = b_wait & b_fin_now;
    wire b_rel   = b_dec & ~(~blkB | alarm_eff | lockdown | ~b_ok_now);

    // ---------------- cross checks ----------------
    wire st_bad  = ~&(stA ^ stB);                 // B must be the inverse of A
    wire hc_bad  = ~&(hcA ^ hcB);
    wire fl_bad  = ~&{blkA ^ blkB, finA ^ finB, fokA ^ fokB};
    wire go_bad  = ~(a_go ^ b_go_n);
    wire v_bad   = ~(vp ^ vn);
    wire dec_bad = (a_dec ^ b_dec) | (a_rel ^ b_rel) | (a_hend ^ b_hend);
    wire pending = a_go & ~b_go_n;                // both copies staged a release
    wire par_bad = pending & ((^ct_stage) ^ pa);
    wire out_bad = valid_p & ((^ct_out_r) ^ pa);  // port register corrupted while valid
    wire mism = st_bad | hc_bad | fl_bad | go_bad | v_bad | dec_bad | par_bad | out_bad
              | ~a_legal | ~b_legal;

    // the staged release is confirmed only without a fault and outside lockdown
    wire conf = pending & ~lockdown & ~mism;

    wire any_state = ~a_idle | ~b_idle;           // an operation is (or may be) running
    wire any_stage = a_go | ~b_go_n;

    assign busy = any_state | any_stage;

    // ---------------- sequential ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stA <= A_IDLE;  hcA <= 8'd0;  blkA <= 1'b0;  finA <= 1'b0;  fokA <= 1'b0;
            a_go <= 1'b0;   pa <= 1'b0;
            stB <= B_IDLE;  hcB <= 8'hFF; blkB <= 1'b1;  finB <= 1'b1;  fokB <= 1'b1;
            b_go_n <= 1'b1;
            ct_hold <= {W{1'b0}}; ct_stage <= {W{1'b0}}; ct_out_r <= {W{1'b0}};
            vp <= 1'b0;     vn <= 1'b1;
            gate_blocked <= 1'b0; op_done <= 1'b0; gate_fault <= 1'b0;
        end else begin
            // defaults: stage registers and pulses clear every cycle
            op_done      <= 1'b0;
            gate_blocked <= 1'b0;
            gate_fault   <= mism;
            a_go         <= 1'b0;
            b_go_n       <= 1'b1;
            ct_stage     <= {W{1'b0}};
            ct_out_r     <= {W{1'b0}};
            vp           <= 1'b0;
            vn           <= 1'b1;

            if (mism) begin
                // drop the operation: nothing is released, both copies idle
                stA <= A_IDLE;  hcA <= 8'd0;  blkA <= 1'b0;  finA <= 1'b0;  fokA <= 1'b0;
                pa  <= 1'b0;
                stB <= B_IDLE;  hcB <= 8'hFF; blkB <= 1'b1;  finB <= 1'b1;  fokB <= 1'b1;
                ct_hold <= {W{1'b0}};
                // (an op_start in the fault cycle counts as a running operation)
                if (any_state | op_start) op_done <= 1'b1;
                if (any_state | any_stage | op_start) gate_blocked <= 1'b1;
            end else begin
                // ---- stage 2: B confirms the staged release ----
                if (conf) begin
                    ct_out_r <= ct_stage;
                    vp       <= 1'b1;
                    vn       <= 1'b0;
                end else if (pending) begin
                    gate_blocked <= 1'b1;              // lockdown arrived at the confirm
                end

                // ---- copy A ----
                if (a_idle) begin
                    if (op_start) begin
                        stA  <= A_OP;
                        blkA <= alarm_eff;
                        finA <= 1'b0;
                        fokA <= 1'b0;
                    end
                end
                if (a_op) begin
                    if (alarm_eff) blkA <= 1'b1;
                    if (commit_fin) begin finA <= 1'b1; fokA <= commit_clean; end
                    if (aes_done) begin
                        ct_hold <= ct_raw;
                        pa      <= ^ct_raw;
                        hcA     <= 8'd0;
                        stA     <= A_HOLD;
                    end
                end
                if (a_hold) begin
                    if (alarm_eff) blkA <= 1'b1;
                    if (commit_fin) begin finA <= 1'b1; fokA <= commit_clean; end
                    if (a_hend) begin
                        op_done <= 1'b1;
                        if (lockdown) blkA <= 1'b1;
                        stA     <= A_WAIT;
                    end else
                        hcA <= hcA + 8'd1;
                end
                if (a_wait) begin
                    if (a_fin_now) begin
                        stA     <= A_IDLE;
                        blkA    <= 1'b0;
                        finA    <= 1'b0;
                        ct_hold <= {W{1'b0}};             // staged copy or dropped
                        if (a_rel) begin
                            ct_stage <= ct_hold;       // stage 1: A authorises
                            a_go     <= 1'b1;
                        end else
                            gate_blocked <= 1'b1;
                    end else if (alarm_eff)
                        blkA <= 1'b1;
                end

                // ---- copy B (inverse polarity, own counter) ----
                if (b_idle) begin
                    if (op_start) begin
                        stB  <= B_OP;
                        blkB <= ~alarm_eff;
                        finB <= 1'b1;
                        fokB <= 1'b1;
                    end
                end
                if (b_op) begin
                    if (alarm_eff) blkB <= 1'b0;
                    if (commit_fin) begin finB <= 1'b0; fokB <= ~commit_clean; end
                    if (aes_done) begin
                        hcB <= 8'hFF;
                        stB <= B_HOLD;
                    end
                end
                if (b_hold) begin
                    if (alarm_eff) blkB <= 1'b0;
                    if (commit_fin) begin finB <= 1'b0; fokB <= ~commit_clean; end
                    if (b_hend) begin
                        if (lockdown) blkB <= 1'b0;
                        stB <= B_WAIT;
                    end else
                        hcB <= hcB - 8'd1;
                end
                if (b_wait) begin
                    if (b_fin_now) begin
                        stB  <= B_IDLE;
                        blkB <= 1'b1;
                        finB <= 1'b1;
                        if (b_rel) b_go_n <= 1'b0;     // B agrees to the release
                    end else if (alarm_eff)
                        blkB <= 1'b0;
                end
            end
        end
    end

`ifdef FORMAL
    // Inductive invariants of the redundant structure. They are asserted so
    // that the unbounded proof of the parent harness (verif/formal) has the
    // lemmas it needs; they are not part of synthesis.
    always @(*) begin
        assert (a_legal);
        assert (stB == ~stA);
        assert (hcB == ~hcA);
        assert (blkB == ~blkA && finB == ~finA && fokB == ~fokA);
        assert (b_go_n == ~a_go);
        assert (vn == ~vp);
        if (a_go) assert (a_idle);
        if (a_hold | a_wait) assert ((^ct_hold) == pa);
        if (a_go) assert ((^ct_stage) == pa);
        if (!a_go) assert (ct_stage == {W{1'b0}});
        if (vp) assert ((^ct_out_r) == pa);
        if (!vp) assert (ct_out_r == {W{1'b0}});
        assert (!mism);
    end
`endif
endmodule
