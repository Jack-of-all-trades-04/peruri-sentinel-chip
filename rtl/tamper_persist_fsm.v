// tamper_persist_fsm: persistent tamper state backed by the host NVM (P1-1).
//
// Two counters that never decrease:
//   alarm_count  +1 per operation during which a sensor alarm was seen, and
//                +1 per alarm event outside an operation
//   tear_count   +1 per operation aborted by power_warn, and +1 per boot that
//                finds an operation was in progress (power lost mid-op)
// Lockdown + zeroize when alarm_count >= N or tear_count >= M, so the number
// of attempts an attacker gets is bounded by N + M, whatever the mix.
//
// The counters live in an NVM record, kept in two alternating copies, each
// with a sequence number and a CRC-8 (poly 0x07). Boot picks the newest valid
// copy (wrap-safe serial-number comparison of the 8-bit sequence number, see
// S_SEL); if neither copy is valid the device locks (fail-secure), which also
// covers a blank (un-personalised) NVM.
//
// Per operation (handshake with the core):
//   start_req (taken only when ready = 1) -> MARK: write in_progress = 1
//   -> op_grant: the AES may start -> RUN -> op_done (gate decision) or
//   power_warn -> COMMIT: write the counts with in_progress = 0
//   -> commit_fin (always) together with commit_clean (no alarm, no abort).
// The gate releases only on commit_fin with commit_clean = 1. A clean op and
// an alarmed op both do two writes, so the response timing does not tell
// whether an alarm happened. power_warn during MARK aborts before op_grant.
//
// Alarm edges seen outside MARK/RUN are kept pending and committed by an
// EVENT write from IDLE; if a request arrives first, the pending alarm is
// charged to that operation instead (which is then not released).
//
// por_n resets only the controller sequencing, never the NVM. A user reset is
// not an input, so it cannot touch the counters or the lockdown.
module tamper_persist_fsm #(
    parameter integer N           = 4,     // alarm lockdown threshold
    parameter integer M           = 8,     // tear lockdown threshold
    parameter integer CW          = 4,     // counter width
    parameter integer DEMO_UNLOCK = 0,
    parameter integer RECW        = 17 + 2*CW   // record width (derived; do not override)
) (
    input  wire            clk,
    input  wire            por_n,
    input  wire            alarm,
    input  wire            power_warn,
    input  wire            start_req,
    input  wire            op_done,
    input  wire            debug_unlock,  // demo rehearsal only (DEMO_UNLOCK != 0)
    // NVM record interface
    output reg             nvm_rd_en,
    output reg             nvm_rd_addr,
    input  wire [RECW-1:0] nvm_rd_data,
    input  wire            nvm_rd_valid,
    output reg             nvm_wr_en,
    output reg             nvm_wr_addr,
    output reg  [RECW-1:0] nvm_wr_data,
    input  wire            nvm_wr_done,
    // outputs
    output wire            ready,
    output reg             op_grant,
    output reg             commit_fin,
    output reg             commit_clean,
    output wire            boot_busy,
    output reg             zeroize_req,
    output reg             lockdown_state,
    output reg  [CW-1:0]   alarm_count,
    output reg  [CW-1:0]   tear_count
);
    localparam integer PW = 9 + 2*CW;      // payload: seq(8) + in_progress(1) + 2 counters

    // N and M must fit the counter (1 .. 2^CW - 1); otherwise elaboration fails
    generate
        if (N < 1 || N > (1 << CW) - 1 || M < 1 || M > (1 << CW) - 1) begin : g_bad_param
            tamper_persist_fsm_N_and_M_must_be_1_to_2powCW_minus_1 u_param_check ();
        end
    endgenerate

`include "crc_util.vh"

    function [RECW-1:0] pack;
        input [7:0]    seq;
        input          inprog;
        input [CW-1:0] ac;
        input [CW-1:0] tc;
        reg [PW-1:0]   payload;
        begin
            payload = {seq, inprog, ac, tc};
            pack = {payload, crc8_07(PW, {{(256-PW){1'b0}}, payload})};
        end
    endfunction

    function rec_valid;
        input [RECW-1:0] rec;
        reg [PW-1:0] payload;
        begin
            payload   = rec[RECW-1:8];
            rec_valid = (crc8_07(PW, {{(256-PW){1'b0}}, payload}) == rec[7:0]);
        end
    endfunction

    function [CW-1:0] inc;                 // saturating +1
        input [CW-1:0] v;
        begin
            inc = (v == {CW{1'b1}}) ? v : v + 1'b1;
        end
    endfunction

    // ---------------- state ----------------
    localparam [3:0] S_RD0 = 4'd0, S_RD1 = 4'd1, S_SEL = 4'd2, S_TEAR = 4'd3,
                     S_IDLE = 4'd4, S_MARK = 4'd5, S_RUN = 4'd6, S_COMMIT = 4'd7,
                     S_LOCK = 4'd8, S_EVENT = 4'd9;
    (* fsm_encoding = "none" *) reg [3:0] st;
    reg [7:0]      seq;           // sequence number of the last good record
    reg            wr_slot;       // NVM slot the next write goes to
    reg [RECW-1:0] rec0, rec1;
    reg            v0, v1;
    reg            alarm_d, alarm_seen, abort_op, alarm_pend;

    wire alarm_rise = alarm & ~alarm_d;
    // boot selection helpers (see S_SEL)
    wire [7:0] seq_diff     = rec0[RECW-1:RECW-8] - rec1[RECW-1:RECW-8];
    wire       seq_tie      = (seq_diff == 8'd0);
    wire       same_payload = (rec0[RECW-1:8] == rec1[RECW-1:8]);
    wire over   = (alarm_count >= N[CW-1:0]) || (tear_count >= M[CW-1:0]);
    wire unlock = (DEMO_UNLOCK != 0) && debug_unlock;

    assign boot_busy = (st == S_RD0) || (st == S_RD1) || (st == S_SEL) || (st == S_TEAR);
    assign ready     = (st == S_IDLE) && !over && !unlock;

    always @(posedge clk or negedge por_n) begin
        if (!por_n) begin
            st             <= S_RD0;
            nvm_rd_en      <= 1'b0;
            nvm_rd_addr    <= 1'b0;
            nvm_wr_en      <= 1'b0;
            nvm_wr_addr    <= 1'b0;
            nvm_wr_data    <= {RECW{1'b0}};
            op_grant       <= 1'b0;
            commit_fin     <= 1'b0;
            commit_clean   <= 1'b0;
            zeroize_req    <= 1'b0;
            lockdown_state <= 1'b0;
            alarm_count    <= {CW{1'b0}};
            tear_count     <= {CW{1'b0}};
            seq            <= 8'd0;
            wr_slot        <= 1'b0;
            rec0           <= {RECW{1'b0}};
            rec1           <= {RECW{1'b0}};
            v0             <= 1'b0;
            v1             <= 1'b0;
            alarm_d        <= 1'b0;
            alarm_seen     <= 1'b0;
            abort_op       <= 1'b0;
            alarm_pend     <= 1'b0;
        end else begin
            op_grant     <= 1'b0;
            commit_fin   <= 1'b0;
            commit_clean <= 1'b0;
            alarm_d      <= alarm;

            // alarm edges outside an operation window stay pending
            if (alarm_rise && st != S_MARK && st != S_RUN && st != S_IDLE && st != S_EVENT)
                alarm_pend <= 1'b1;

            case (st)
                // -------- boot: read both copies --------
                S_RD0: begin
                    nvm_rd_en   <= 1'b1;
                    nvm_rd_addr <= 1'b0;
                    if (nvm_rd_valid) begin
                        rec0      <= nvm_rd_data;
                        v0        <= rec_valid(nvm_rd_data);
                        nvm_rd_en <= 1'b0;
                        st        <= S_RD1;
                    end
                end
                S_RD1: begin
                    nvm_rd_en   <= 1'b1;
                    nvm_rd_addr <= 1'b1;
                    if (nvm_rd_valid) begin
                        rec1      <= nvm_rd_data;
                        v1        <= rec_valid(nvm_rd_data);
                        nvm_rd_en <= 1'b0;
                        st        <= S_SEL;
                    end
                end
                // -------- choose the newest valid copy --------
                // seq is an 8-bit serial number that wraps 255 -> 0, so "newer"
                // is decided with serial-number arithmetic, not with >=:
                // copy 0 is newer when (seq0 - seq1) mod 256 is in [1, 127],
                // copy 1 is newer when it is in [128, 255]. This is correct
                // as long as the two valid copies are less than 128 writes
                // apart, which alternating writes guarantee (they differ by 1;
                // a corrupt copy is not compared at all).
                // Tie (equal seq, both valid) never happens with alternating
                // writes. Fail-secure policy: if the two payloads are identical
                // (the personalised factory pair) either copy gives the same
                // state, so copy 0 is used; if they differ, the NVM was
                // tampered with or is inconsistent, and the device locks
                // rather than guess which counters are the newer ones.
                S_SEL: begin
                    if ((!v0 && !v1) || (v0 && v1 && seq_tie && !same_payload)) begin
                        lockdown_state <= 1'b1;        // no usable record: fail-secure
                        zeroize_req    <= 1'b1;
                        st             <= S_LOCK;
                    end else begin
                        if (v0 && (!v1 || (seq_tie ? 1'b1 : !seq_diff[7]))) begin
                            seq         <= rec0[RECW-1:RECW-8];
                            alarm_count <= rec0[8+CW +: CW];
                            tear_count  <= rec0[8 +: CW];
                            wr_slot     <= 1'b1;
                            abort_op    <= rec0[8+2*CW];
                        end else begin
                            seq         <= rec1[RECW-1:RECW-8];
                            alarm_count <= rec1[8+CW +: CW];
                            tear_count  <= rec1[8 +: CW];
                            wr_slot     <= 1'b0;
                            abort_op    <= rec1[8+2*CW];
                        end
                        st <= S_TEAR;
                    end
                end
                // -------- charge one tear if an op was in progress --------
                S_TEAR: begin
                    if (!nvm_wr_en) begin
                        tear_count  <= abort_op ? inc(tear_count) : tear_count;
                        nvm_wr_en   <= 1'b1;
                        nvm_wr_addr <= wr_slot;
                        nvm_wr_data <= pack(seq + 8'd1, 1'b0, alarm_count,
                                            abort_op ? inc(tear_count) : tear_count);
                        abort_op    <= 1'b0;
                    end else if (nvm_wr_done) begin
                        nvm_wr_en <= 1'b0;
                        seq       <= seq + 8'd1;
                        wr_slot   <= ~wr_slot;
                        st        <= S_IDLE;
                    end
                end
                // -------- idle --------
                S_IDLE: begin
                    if (over) begin
                        lockdown_state <= 1'b1;
                        zeroize_req    <= 1'b1;
                        st             <= S_LOCK;
                    end else if (unlock) begin
                        alarm_count <= {CW{1'b0}};
                        tear_count  <= {CW{1'b0}};
                        alarm_pend  <= 1'b0;
                    end else if (start_req) begin
                        alarm_seen <= alarm_pend | alarm;
                        abort_op   <= power_warn;
                        alarm_pend <= 1'b0;
                        st         <= S_MARK;
                    end else if (alarm_pend || alarm_rise) begin
                        st <= S_EVENT;
                    end
                end
                // -------- alarm event outside an operation --------
                S_EVENT: begin
                    if (!nvm_wr_en) begin
                        alarm_count <= inc(alarm_count);
                        alarm_pend  <= alarm_rise;       // a new edge this cycle stays pending
                        nvm_wr_en   <= 1'b1;
                        nvm_wr_addr <= wr_slot;
                        nvm_wr_data <= pack(seq + 8'd1, 1'b0, inc(alarm_count), tear_count);
                    end else begin
                        if (alarm_rise) alarm_pend <= 1'b1;
                        if (nvm_wr_done) begin
                            nvm_wr_en <= 1'b0;
                            seq       <= seq + 8'd1;
                            wr_slot   <= ~wr_slot;
                            st        <= S_IDLE;
                        end
                    end
                end
                // -------- mark in_progress before the AES starts --------
                S_MARK: begin
                    if (alarm)      alarm_seen <= 1'b1;
                    if (power_warn) abort_op   <= 1'b1;
                    if (!nvm_wr_en) begin
                        nvm_wr_en   <= 1'b1;
                        nvm_wr_addr <= wr_slot;
                        nvm_wr_data <= pack(seq + 8'd1, 1'b1, alarm_count, tear_count);
                    end else if (nvm_wr_done) begin
                        nvm_wr_en <= 1'b0;
                        seq       <= seq + 8'd1;
                        wr_slot   <= ~wr_slot;
                        if (abort_op || power_warn) begin
                            abort_op <= 1'b1;
                            st       <= S_COMMIT;       // aborted before the AES started
                        end else begin
                            op_grant <= 1'b1;
                            st       <= S_RUN;
                        end
                    end
                end
                // -------- run: watch for alarm / power loss --------
                S_RUN: begin
                    if (alarm)      alarm_seen <= 1'b1;
                    if (power_warn) abort_op   <= 1'b1;
                    if (power_warn || op_done) st <= S_COMMIT;
                end
                // -------- commit the result of this operation --------
                S_COMMIT: begin
                    if (!nvm_wr_en) begin
                        alarm_count <= (!abort_op && alarm_seen) ? inc(alarm_count) : alarm_count;
                        tear_count  <= abort_op ? inc(tear_count) : tear_count;
                        nvm_wr_en   <= 1'b1;
                        nvm_wr_addr <= wr_slot;
                        nvm_wr_data <= pack(seq + 8'd1, 1'b0,
                            (!abort_op && alarm_seen) ? inc(alarm_count) : alarm_count,
                            abort_op ? inc(tear_count) : tear_count);
                    end else if (nvm_wr_done) begin
                        nvm_wr_en    <= 1'b0;
                        seq          <= seq + 8'd1;
                        wr_slot      <= ~wr_slot;
                        commit_fin   <= 1'b1;
                        commit_clean <= ~(alarm_seen | abort_op);
                        alarm_seen   <= 1'b0;
                        abort_op     <= 1'b0;
                        st           <= S_IDLE;     // IDLE locks next cycle if over
                    end
                end
                // -------- lockdown: held, key zeroized --------
                default: begin   // S_LOCK
                    zeroize_req    <= 1'b1;
                    lockdown_state <= 1'b1;
                    if (unlock) begin
                        alarm_count    <= {CW{1'b0}};
                        tear_count     <= {CW{1'b0}};
                        alarm_pend     <= 1'b0;
                        zeroize_req    <= 1'b0;
                        lockdown_state <= 1'b0;
                        st             <= S_IDLE;
                    end
                end
            endcase
        end
    end
endmodule
