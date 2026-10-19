// Sequence-number wrap test for tamper_persist_fsm (NVM record selection).
//
// The record carries an 8-bit sequence number that wraps 255 -> 0. Boot must
// pick the NEWEST valid copy across the wrap (serial-number arithmetic). With
// a plain "seq0 >= seq1" compare, boot at the wrap picks the OLDER copy, which
// rolls a counter back or turns an old MARK record (in_progress = 1) into a
// false tear.
//
// Part A: reference-model run. For each operation type and for each start
//   offset 252..257 (so MARK/COMMIT writes land on every value of the wrap
//   region 253..2), idle power cycles first walk the sequence number to the
//   offset (each boot writes once), then one operation runs and the core is
//   power-cycled (POR with the NVM kept). After every boot the counters must
//   equal a reference model that never loses an increment and charges a tear
//   only when the newest record has in_progress = 1.
// Part B: hand-made record pairs preloaded into the NVM model: 254/255,
//   255/0, 0/1, 127-apart, one copy corrupt at the wrap, both corrupt, and
//   ties (identical payload: accepted; different payload: lock).
`timescale 1ns/1ps
module tb_seq_wrap;
    localparam integer CW = 8, N = 255, M = 255, RECW = 17 + 2*CW, PW = 9 + 2*CW;
    reg clk = 0; always #5 clk = ~clk;

    reg  por_n = 0, power_ok = 1;
    reg  alarm = 0, power_warn = 0, start_req = 0, op_done = 0;
    wire rd_en, rd_addr, wr_en, wr_addr, rd_valid, wr_done;
    wire [RECW-1:0] rd_data, wr_data;
    wire op_grant, commit_fin, commit_clean, ready, boot_busy, zreq, lock;
    wire [CW-1:0] ac, tc;
    integer errors = 0;

`include "crc_util.vh"

    function [RECW-1:0] pack;
        input [7:0]    s;
        input          ip;
        input [CW-1:0] a;
        input [CW-1:0] t;
        reg [PW-1:0]   payload;
        begin
            payload = {s, ip, a, t};
            pack = {payload, crc8_07(PW, {{(256-PW){1'b0}}, payload})};
        end
    endfunction

    tamper_persist_fsm #(.N(N), .M(M), .CW(CW), .DEMO_UNLOCK(0)) u_fsm (
        .clk(clk), .por_n(por_n), .alarm(alarm), .power_warn(power_warn),
        .start_req(start_req), .op_done(op_done), .debug_unlock(1'b0),
        .nvm_rd_en(rd_en), .nvm_rd_addr(rd_addr), .nvm_rd_data(rd_data), .nvm_rd_valid(rd_valid),
        .nvm_wr_en(wr_en), .nvm_wr_addr(wr_addr), .nvm_wr_data(wr_data), .nvm_wr_done(wr_done),
        .op_grant(op_grant), .commit_fin(commit_fin), .commit_clean(commit_clean), .ready(ready), .boot_busy(boot_busy),
        .zeroize_req(zreq), .lockdown_state(lock), .alarm_count(ac), .tear_count(tc)
    );
    nvm_counter_model #(.CW(CW), .INIT_BLANK(0), .RD_LAT(2), .WR_LAT(6)) u_nvm (
        .clk(clk), .power_ok(power_ok),
        .rd_en(rd_en), .rd_addr(rd_addr), .rd_data(rd_data), .rd_valid(rd_valid),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data), .wr_done(wr_done)
    );

    // coverage: sequence number selected at each boot, and NVM write count
    reg [255:0] cov = 256'd0;
    integer nwrites = 0, nboots = 0;
    always @(posedge clk) begin
        if (u_fsm.st == 4'd3 && !u_fsm.nvm_wr_en) begin   // first S_TEAR cycle
            cov[u_fsm.seq] <= 1'b1;
            nboots = nboots + 1;
        end
        if (wr_done) nwrites = nwrites + 1;
    end

    // reference model
    integer ac_ref = 0, tc_ref = 0;

    task chk; input cond; input [8*72-1:0] nm; begin
        if (!cond) begin
            $display("FAIL %0s (ac=%0d/%0d tc=%0d/%0d lock=%b seq=%0d)", nm, ac, ac_ref, tc, tc_ref, lock, u_fsm.seq);
            errors = errors + 1;
        end
    end endtask

    task wait_boot; integer t; begin
        t = 0; while (boot_busy && t < 600) begin @(negedge clk); t = t + 1; end
        repeat (2) @(negedge clk);
    end endtask

    task boot; begin
        por_n = 0; repeat (3) @(negedge clk); por_n = 1;
        wait_boot;
    end endtask

    task check_ref; input [8*72-1:0] what; begin
        chk(ac == ac_ref && tc == tc_ref && !lock && ready, what);
    end endtask

    // run one operation; kind 0 clean, 1 alarmed, 2 power_warn abort
    task do_op; input integer kind; integer t; begin
        @(negedge clk) start_req = 1; @(negedge clk) start_req = 0;
        t = 0; while (!op_grant && !lock && t < 400) begin @(negedge clk); t = t + 1; end
        chk(op_grant, "op_grant");
        repeat (3) @(negedge clk);
        if (kind == 1) begin alarm = 1; repeat (2) @(negedge clk); alarm = 0; ac_ref = ac_ref + 1; end
        if (kind == 2) begin power_warn = 1; @(negedge clk); power_warn = 0; tc_ref = tc_ref + 1; end
        if (kind != 2) begin @(negedge clk) op_done = 1; @(negedge clk) op_done = 0; end
        t = 0; while (!commit_fin && !lock && t < 400) begin @(negedge clk); t = t + 1; end
        chk(commit_fin, "commit_fin");
        repeat (3) @(negedge clk);
        check_ref("live counters after op");
    end endtask

    // POR in the middle of the operation (after the MARK write)
    task op_por_mid; integer t; begin
        @(negedge clk) start_req = 1; @(negedge clk) start_req = 0;
        t = 0; while (!op_grant && !lock && t < 400) begin @(negedge clk); t = t + 1; end
        chk(op_grant, "op_grant (por mid)");
        repeat (3) @(negedge clk);
        tc_ref = tc_ref + 1;        // reboot finds in_progress = 1: one tear
    end endtask

    // tear the COMMIT write of a clean op (power lost during the write)
    task op_tear_commit; integer t; begin
        @(negedge clk) start_req = 1; @(negedge clk) start_req = 0;
        t = 0; while (!op_grant && !lock && t < 400) begin @(negedge clk); t = t + 1; end
        chk(op_grant, "op_grant (torn commit)");
        repeat (3) @(negedge clk);
        @(negedge clk) op_done = 1; @(negedge clk) op_done = 0;
        t = 0; while (!u_nvm.wbusy && t < 50) begin @(negedge clk); t = t + 1; end
        repeat (2) @(negedge clk);
        power_ok = 0;
        while (u_nvm.wbusy) @(negedge clk);
        power_ok = 1;
        tc_ref = tc_ref + 1;        // newest valid record is the MARK (in_progress = 1)
    end endtask

    // idle power cycles until the last written sequence number is `target`
    task pad_to; input [7:0] target; integer g; begin
        g = 0;
        while (u_fsm.seq != target && g < 300) begin
            boot; check_ref("idle boot: counters unchanged, no spurious tear");
            g = g + 1;
        end
        chk(u_fsm.seq == target, "pad_to reached the target sequence number");
    end endtask

    // ---------------- part B helper ----------------
    // preload both NVM slots (c0/c1: 1 = corrupt that copy), power cycle, boot
    task load_boot;
        input [7:0] s0; input ip0; input [CW-1:0] a0; input [CW-1:0] t0; input c0;
        input [7:0] s1; input ip1; input [CW-1:0] a1; input [CW-1:0] t1; input c1;
        begin
            por_n = 0; repeat (3) @(negedge clk);
            u_nvm.mem0 = pack(s0, ip0, a0, t0) ^ (c0 ? {{(RECW-11){1'b0}}, 11'h400} : {RECW{1'b0}});
            u_nvm.mem1 = pack(s1, ip1, a1, t1) ^ (c1 ? {{(RECW-11){1'b0}}, 11'h400} : {RECW{1'b0}});
            por_n = 1;
            wait_boot;
        end
    endtask

    task expect_sel; input integer ea; input integer et; input integer elock; input [8*60-1:0] nm; begin
        if (ac !== ea[CW-1:0] || tc !== et[CW-1:0] || lock !== elock[0]) begin
            $display("FAIL %0s: got ac=%0d tc=%0d lock=%b, expected ac=%0d tc=%0d lock=%0d", nm, ac, tc, lock, ea, et, elock);
            errors = errors + 1;
        end
    end endtask

    integer ty, off, i;
    initial begin
        // ================= part A =================
        boot;
        check_ref("first boot");
        for (ty = 0; ty < 5; ty = ty + 1) begin
            for (off = 0; off < 6; off = off + 1) begin
                pad_to((252 + off) & 255);
                case (ty)
                    0: do_op(0);
                    1: do_op(1);
                    2: do_op(2);
                    3: op_por_mid;
                    default: op_tear_commit;
                endcase
                boot; check_ref("boot after the operation (wrap region)");
                boot; check_ref("second boot: no extra tear");
            end
        end
        chk(cov[253] && cov[254] && cov[255] && cov[0] && cov[1] && cov[2],
            "every sequence number 253..2 was the newest record at a boot");
        chk(nwrites > 260, "more than 260 NVM writes");
        chk(ac_ref > 0 && tc_ref > 0, "reference model exercised both counters");

        // ================= part B =================
        // args: copy0 {seq, in_progress, ac, tc, corrupt}, copy1 {...}
        load_boot(8'd254,0,4,1,0,  8'd255,0,5,1,0);
        expect_sel(5,1,0, "254/255: 255 is newer");
        load_boot(8'd255,0,5,1,0,  8'd254,0,4,1,0);
        expect_sel(5,1,0, "255/254 (swapped slots): 255 is newer");
        load_boot(8'd255,0,5,1,0,  8'd0,0,6,1,0);
        expect_sel(6,1,0, "255/0: 0 is newer (wrap)");
        load_boot(8'd0,0,6,1,0,    8'd255,0,5,1,0);
        expect_sel(6,1,0, "0/255 (swapped slots): 0 is newer (wrap)");
        load_boot(8'd0,0,7,2,0,    8'd1,0,8,2,0);
        expect_sel(8,2,0, "0/1: 1 is newer");
        load_boot(8'd1,0,8,2,0,    8'd0,0,7,2,0);
        expect_sel(8,2,0, "1/0 (swapped slots): 1 is newer");
        // in_progress handling at the wrap
        load_boot(8'd255,0,5,1,0,  8'd0,1,5,1,0);
        expect_sel(5,2,0, "255 clean / 0 MARK: newest has in_progress, one tear");
        load_boot(8'd255,1,5,1,0,  8'd0,0,5,1,0);
        expect_sel(5,1,0, "255 MARK / 0 clean: old MARK is not a tear");
        load_boot(8'd0,0,5,1,0,    8'd255,1,5,1,0);
        expect_sel(5,1,0, "0 clean / 255 MARK (swapped): old MARK is not a tear");
        // the half-window edge: 127 apart is still ordered
        load_boot(8'd130,0,9,3,0,  8'd3,0,8,3,0);
        expect_sel(9,3,0, "130 vs 3 (127 apart): 130 is newer");
        load_boot(8'd0,0,2,0,0,    8'd127,0,3,0,0);
        expect_sel(3,0,0, "0 vs 127 (127 apart): 127 is newer");
        // one copy corrupt at the wrap: the valid one is used
        load_boot(8'd255,0,9,1,0,  8'd0,0,10,1,1);
        expect_sel(9,1,0, "255 valid / 0 corrupt: 255 used");
        load_boot(8'd255,0,9,1,1,  8'd0,0,10,1,0);
        expect_sel(10,1,0, "255 corrupt / 0 valid: 0 used");
        // both corrupt: lock
        load_boot(8'd255,0,9,1,1,  8'd0,0,10,1,1);
        expect_sel(0,0,1, "both corrupt: lockdown");
        // ties: identical payload is accepted, different payload locks
        load_boot(8'd7,0,3,1,0,    8'd7,0,3,1,0);
        expect_sel(3,1,0, "tie, identical payload: accepted");
        load_boot(8'd7,0,3,1,0,    8'd7,0,4,1,0);
        expect_sel(0,0,1, "tie, different counters: fail-secure lockdown");
        load_boot(8'd7,0,3,1,0,    8'd7,1,3,1,0);
        expect_sel(0,0,1, "tie, different in_progress: fail-secure lockdown");
        load_boot(8'd7,0,3,1,0,    8'd7,0,4,1,1);
        expect_sel(3,1,0, "tie but one copy corrupt: the valid copy is used");

        if (errors == 0) $display("PASS tb_seq_wrap");
        else             $display("FAIL tb_seq_wrap (%0d errors)", errors);
        $finish;
    end

    initial begin
        #40_000_000;
        $display("FAIL tb_seq_wrap (watchdog)");
        $finish;
    end
endmodule
