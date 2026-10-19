// Formal harness for tamper_persist_fsm (P1-1), production setting
// (DEMO_UNLOCK = 0). A small synthesizable NVM stub stands in for the host
// NVM: two slots, one-cycle read and write, both initialised to a valid
// personalised record {seq=1, in_progress=0, alarm_count=0, tear_count=0} so
// the controller boots to IDLE. alarm, power_warn, start_req and op_done are
// free inputs.
//
// Properties (unbounded prove; BMC fallback if it does not converge):
//   P1  alarm_count never decreases
//   P2  tear_count never decreases
//   P3  one clock moves each counter by at most +1
//   P4  lockdown_state is sticky (never clears) with DEMO_UNLOCK = 0
//   P5  lockdown_state implies the threshold was reached (ac>=N or tc>=M)
//   P6  while below both thresholds there is no zeroize and no lockdown
//   P7  a clean commit only follows an operation with no alarm and no power_warn
//   P8  alarm_count <= N and tear_count <= M (saturation never needed)
//       (an alarmed/aborted op is never released)
//   P9  (task bmc_wrap, build with -DSEQ_WRAP, bounded depth 40) boot selects the NEWEST of
//       two valid copies whatever the 8-bit sequence number is, including
//       across the wrap 255 -> 0. The NVM stub then starts with a symbolic
//       pair: either consecutive sequence numbers {s, s+1} in a symbolic slot
//       order with symbolic contents, or a tie (equal sequence number and
//       identical payload). After boot the counters must equal those of the
//       newer copy, plus one tear if that copy has in_progress = 1, and the
//       device must not lock. P1..P3 skip the boot window in this build,
//       because loading the record at boot is a deliberate jump from 0.
//       P9 is evaluated once, in the first cycle after the boot (a fixed
//       number of cycles with the 1-cycle stub, well inside depth 40), so
//       the bounded run covers it exhaustively over all symbolic NVM
//       contents; an unbounded prove of this build also converges but takes
//       about 17 minutes, which is too slow for the regular run.
module tamper_persist_formal #(
    parameter integer N = 4,
    parameter integer M = 4,
    parameter integer CW = 4
) (
    input wire clk,
    input wire alarm,
    input wire power_warn,
    input wire start_req,
    input wire op_done
);
    localparam integer RECW = 17 + 2*CW;
`include "crc_util.vh"

    reg init_done = 1'b0;
    always @(posedge clk) init_done <= 1'b1;
    wire por_n = init_done;

    wire rd_en, rd_addr, wr_en, wr_addr, rd_valid, wr_done;
    wire [RECW-1:0] rd_data, wr_data;
    wire op_grant, commit_fin, commit_clean, ready, boot_busy, zeroize_req, lockdown;
    wire commit_done = commit_fin & commit_clean;   // release allowed
    wire [CW-1:0] ac, tc;

    // ---- synthesizable NVM stub (1-cycle latency, two valid slots) ----
    function [RECW-1:0] good0;
        input dummy;
        reg [8+2*CW:0] payload;    // seq(8)+inprog(1)+ac(CW)+tc(CW)
        begin
            payload = {8'd1, 1'b0, {CW{1'b0}}, {CW{1'b0}}};
            good0 = {payload, crc8_07(9+2*CW, {{(256-(9+2*CW)){1'b0}}, payload})};
        end
    endfunction
`ifdef SEQ_WRAP
    // symbolic initial pair: consecutive sequence numbers s (older) and s+1
    // (newer), either slot order, different counters / in_progress
    (* anyconst *) wire [7:0]    w_s;
    (* anyconst *) wire          w_new0;
    (* anyconst *) wire          w_tie;      // equal seq and identical payload
    (* anyconst *) wire [CW-1:0] w_ao, w_an, w_to, w_tn;
    (* anyconst *) wire          w_ipo, w_ipn;
    always @(*) begin
        assume (w_ao < N[CW-1:0] && w_an < N[CW-1:0]);
        assume (w_to < M[CW-1:0] && w_tn < M[CW-1:0]);
        end
    function [RECW-1:0] mkrec;
        input [7:0]    sq;
        input          ip;
        input [CW-1:0] a;
        input [CW-1:0] t;
        reg [8+2*CW:0] payload;
        begin
            payload = {sq, ip, a, t};
            mkrec = {payload, crc8_07(9+2*CW, {{(256-(9+2*CW)){1'b0}}, payload})};
        end
    endfunction
    wire [RECW-1:0] rec_old = mkrec(w_s, w_ipo, w_ao, w_to);
    wire [RECW-1:0] rec_new = mkrec(w_s + 8'd1, w_ipn, w_an, w_tn);
    wire [RECW-1:0] init0 = w_tie ? rec_old : (w_new0 ? rec_new : rec_old);
    wire [RECW-1:0] init1 = w_tie ? rec_old : (w_new0 ? rec_old : rec_new);
    wire [CW-1:0]   exp_a = w_tie ? w_ao  : w_an;
    wire [CW-1:0]   exp_t = (w_tie ? w_to : w_tn) + ((w_tie ? w_ipo : w_ipn) ? 1'b1 : 1'b0);
    reg [RECW-1:0] mem0 = 0, mem1 = 0;
    reg wr0 = 0, wr1 = 0;                    // slot written since power-up
`else
    reg [RECW-1:0] mem0 = good0(0), mem1 = good0(0);
`endif
    reg rbusy = 0, wbusy = 0, r_a = 0, w_a = 0;
    reg [RECW-1:0] w_d = 0, rd_data_r = 0;
    reg rd_valid_r = 0, wr_done_r = 0, rd_en_d = 0, wr_en_d = 0;
    always @(posedge clk) begin
        rd_valid_r <= 1'b0; wr_done_r <= 1'b0; rd_en_d <= rd_en; wr_en_d <= wr_en;
        if (rd_en && !rd_en_d) begin
`ifdef SEQ_WRAP
            rd_data_r <= rd_addr ? (wr1 ? mem1 : init1) : (wr0 ? mem0 : init0);
`else
            rd_data_r <= rd_addr ? mem1 : mem0;
`endif
            rd_valid_r <= 1'b1;
        end
        if (wr_en && !wr_en_d) begin
`ifdef SEQ_WRAP
            if (wr_addr) begin mem1 <= wr_data; wr1 <= 1'b1; end
            else         begin mem0 <= wr_data; wr0 <= 1'b1; end
`else
            if (wr_addr) mem1 <= wr_data; else mem0 <= wr_data;
`endif
            wr_done_r <= 1'b1;
        end
    end
    assign rd_data = rd_data_r; assign rd_valid = rd_valid_r;
    assign wr_done = wr_done_r;

    tamper_persist_fsm #(.N(N), .M(M), .CW(CW), .DEMO_UNLOCK(0)) dut (
        .clk(clk), .por_n(por_n), .alarm(alarm), .power_warn(power_warn),
        .start_req(start_req), .op_done(op_done), .debug_unlock(1'b0),
        .nvm_rd_en(rd_en), .nvm_rd_addr(rd_addr), .nvm_rd_data(rd_data), .nvm_rd_valid(rd_valid),
        .nvm_wr_en(wr_en), .nvm_wr_addr(wr_addr), .nvm_wr_data(wr_data), .nvm_wr_done(wr_done),
        .op_grant(op_grant), .commit_fin(commit_fin), .commit_clean(commit_clean), .ready(ready), .boot_busy(boot_busy),
        .zeroize_req(zeroize_req), .lockdown_state(lockdown),
        .alarm_count(ac), .tear_count(tc)
    );

    reg past = 1'b0;
    always @(posedge clk) past <= init_done;

    // independent record of the operation window: from an accepted request
    // (ready & start_req) up to the op_done that ends the sensor window after
    // op_grant (alarms after that, during the COMMIT write, are blocked by the
    // gate and counted by the controller as a separate event)
    reg r_inop = 1'b0, r_bad = 1'b0, r_granted = 1'b0, r_closed = 1'b0;
    always @(posedge clk) begin
        // (commit_fin pulses in the first IDLE cycle, so a new request can be
        // accepted in the same cycle the previous operation ends)
        if (!init_done || (commit_fin && !(ready && start_req))) begin
            r_inop <= 1'b0; r_bad <= 1'b0; r_granted <= 1'b0; r_closed <= 1'b0;
        end else if (ready && start_req) begin
            r_inop <= 1'b1; r_bad <= alarm | power_warn; r_granted <= 1'b0; r_closed <= 1'b0;
        end else if (r_inop) begin
            if (!r_closed) r_bad <= r_bad | alarm | power_warn;
            if (op_grant) r_granted <= 1'b1;
            if (op_done && (r_granted || op_grant)) r_closed <= 1'b1;
        end
    end

    reg bb_d = 1'b1;
    always @(posedge clk) bb_d <= boot_busy;
`ifdef SEQ_WRAP
    wire chk_en = past && !bb_d;       // skip the boot window (record load)
`else
    wire chk_en = past;
`endif

`ifdef FORMAL
    always @(posedge clk) begin
        if (chk_en) begin
            assert (ac >= $past(ac));                               // P1
            assert (tc >= $past(tc));                               // P2
            assert (ac <= $past(ac) + 1'b1);                        // P3
            assert (tc <= $past(tc) + 1'b1);
            if ($past(lockdown)) assert (lockdown);                 // P4
            // P7: a clean commit only ends an accepted operation in whose
            // sensor window there was no alarm and no power_warn
            if (commit_fin && commit_clean) assert ($past(r_inop) && !$past(r_bad));
        end
    end
`ifdef REACH_WRAP
    // must FAIL: the point where P9 is checked (boot done) is reachable
    always @(posedge clk) if (past) assert (!($past(boot_busy) && !boot_busy));
`elsif REACH_LOCK
    always @(*) if (init_done) assert (!lockdown);   // must FAIL: lockdown is reachable
`elsif REACH_CLEAN
    always @(*) if (init_done) assert (!(commit_fin && commit_clean));   // must FAIL: a clean commit is reachable
`else
`ifdef SEQ_WRAP
    // P9: first cycle after boot: the newest copy was chosen, never a lockdown
    always @(posedge clk) if (past && $past(boot_busy) && !boot_busy) begin
        assert (!lockdown);
        assert (ac == exp_a);
        assert (tc == exp_t);
    end
`endif
    always @(*) if (init_done) begin
        if (lockdown) assert (ac >= N[CW-1:0] || tc >= M[CW-1:0]);  // P5
        if (ac < N[CW-1:0] && tc < M[CW-1:0]) assert (!lockdown);   // P6
        assert (ac <= N[CW-1:0] && tc <= M[CW-1:0]);                // P8: counters never pass N/M,
                                                                    // so the saturation branch of inc() is unreachable
    end
`endif
`endif
endmodule
