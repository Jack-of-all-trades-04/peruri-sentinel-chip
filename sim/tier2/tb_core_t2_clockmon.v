// BUILD: both
// Tier 2 core with the clock monitors and the cross-domain heartbeat.
//
// Main unit (cm_main): the core with its real time-base oscillator model
// (ro_cell, half period 2 ns = 250 MHz), CLK_sys 80 MHz and CLK_sentinel
// 50 MHz, generated here with run-time adjustable (and stoppable) periods.
// Scenarios:
//   a  nominal clocks for >= 20 monitor windows with clean operations:
//      no alarm, every operation released with the FIPS-197 C.1 ciphertext
//   b  CLK_sentinel stopped, idle and in the middle of an operation:
//      nothing released, new requests refused, sen_dead and clk_fault set,
//      counted once
//   c  CLK_sys slowed below 1/4x and sped above 2x, idle and in an operation:
//      alarm, gate blocked, counted once per event
//   d  CLK_sys stopped at every offset of an operation (and for a long time):
//      counted once, nothing released after the clock returns
//   e  Sentinel OFF (demo build): none of the new alarms fire
//   f  warm-up: no operation is granted before MON_WARM clean windows and
//      before the first heartbeat edge
//   g  heartbeat alone (monitor output forced quiet): stopped CLK_sentinel
//      and stopped CLK_sys are still blocked and counted
//   h  time base stopped: the oscillator watchdog raises clk_fault
// Race unit (cm_race): CLK_sys slow, CLK_sentinel fast, NVM write latency 1,
// power_warn right after the grant. The abort answer lands in the same cycle
// as the DPA `go` for some operations; the AES must not start, the core must
// return to idle and nothing is released.
//
// Checked on every CLK_sys cycle: ct_valid only with the FIPS-197 C.1
// ciphertext, ct_out zero while ct_valid = 0, no request accepted while the
// guard does not permit operations.
`timescale 1ns/1ps

module cm_main #(
    parameter integer CW = 8
) ();
    localparam [127:0] KEY = 128'h000102030405060708090a0b0c0d0e0f;
    localparam [127:0] PT  = 128'h00112233445566778899aabbccddeeff;
    localparam [127:0] EXP = 128'h69c4e0d86a7b0430d8cdb78070b4c55a;
    localparam integer RECW = 17 + 2*CW;
    localparam real HS_NOM = 6.25;      // 80 MHz
    localparam real HN_NOM = 10.0;      // 50 MHz

    integer errors = 0;
    reg finished = 1'b0;

    // ---------------- clocks (adjustable, stoppable) ----------------
    real hs, hn;
    reg clk_sys = 1'b0, clk_sen = 1'b0;
    initial begin hs = HS_NOM; hn = HN_NOM; end
    always begin if (hs > 0.0) begin #(hs) clk_sys = ~clk_sys; end else #1; end
    always begin if (hn > 0.0) begin #(hn) clk_sen = ~clk_sen; end else #1; end

    // ---------------- resets ----------------
    reg arst_n = 1'b0;
    reg key0_n = 1'b1;
    wire por_sys_n, por_sen_n;
    reset_sync u_rs_sys (.clk(clk_sys), .arst_n(arst_n), .rst_n(por_sys_n));
    reset_sync u_rs_sen (.clk(clk_sen), .arst_n(arst_n), .rst_n(por_sen_n));
    wire rst_sys_n = por_sys_n & key0_n;
    wire key0_sen;
    sync_2ff #(.RESET_VAL(1'b1)) u_k0 (.clk(clk_sen), .rst_n(por_sen_n), .d(key0_n), .q(key0_sen));
    wire rst_sen_n = por_sen_n & key0_sen;

    // ---------------- DUT ----------------
    reg          op_req    = 1'b0;
    reg          key_wr_en = 1'b0;
    reg          sen_on    = 1'b1;       // Sentinel enable (demo build only)
    wire [127:0] ct_out;
    wire         ct_valid, gate_blocked, busy, key_is_zero, lockdown_sys, lockdown, alarm_sys;
    wire         clk_fault, sen_dead;
    wire [CW-1:0] ac, tc, ac_sys, tc_sys;

    wire            nvm_rd_en, nvm_rd_addr, nvm_rd_valid, nvm_wr_en, nvm_wr_addr, nvm_wr_done;
    wire [RECW-1:0] nvm_rd_data, nvm_wr_data;
    nvm_counter_model #(.CW(CW), .RD_LAT(2), .WR_LAT(8), .INIT_BLANK(0)) nvm (
        .clk(clk_sen), .power_ok(1'b1),
        .rd_en(nvm_rd_en), .rd_addr(nvm_rd_addr), .rd_data(nvm_rd_data), .rd_valid(nvm_rd_valid),
        .wr_en(nvm_wr_en), .wr_addr(nvm_wr_addr), .wr_data(nvm_wr_data), .wr_done(nvm_wr_done)
    );

    peruri_sentinel_core_t2 #(
        .H(4), .N(100), .M(250), .CW(CW), .DPA_ENABLE(1),
        .TDL_L(8), .TDL_COARSE(3), .TDL_SETTLE(16), .TDL_WIN(64), .RO_WINDOW(256),
        .FAST_HOLD(16), .SLOW_HOLD(64)
`ifdef DEMO_BUILD
        , .DEMO_UNLOCK(0)
`endif
    ) dut (
        .clk_sys(clk_sys), .rst_sys_n(rst_sys_n), .por_sys_n(por_sys_n),
        .op_req(op_req), .pt(PT),
`ifdef DEMO_BUILD
        .sentinel_en_sys(sen_on), .fault_en(1'b0), .fault_round(4'd9), .fault_byte(4'd0),
        .fault_mask(8'h01), .harness_alarm(1'b0), .round_idx(),
`else
        .key_wr_en(key_wr_en), .key_wr_data(KEY),
`endif
        .ct_out(ct_out), .ct_valid(ct_valid), .gate_blocked(gate_blocked), .busy(busy),
        .key_is_zero(key_is_zero), .lockdown_sys(lockdown_sys),
        .tamper_counter_sys(ac_sys), .tear_count_sys(tc_sys),
        .alarm_sys(alarm_sys), .clk_fault(clk_fault), .sen_dead(sen_dead),
        .tdl_alert(), .tdl_armed(), .tdl_cal_bad(),
        .tdl_depth(), .tdl_min_r(), .tdl_sel(),
        .clk_sen(clk_sen), .rst_sen_n(rst_sen_n), .por_sen_n(por_sen_n),
`ifdef DEMO_BUILD
        .sentinel_en_sen(sen_on), .debug_unlock_sen(1'b0), .fsm_mask_sen(1'b0),
        .ewma_alarm(), .fixed_alarm(),
`endif
        .power_warn(1'b0),
        .nvm_rd_en(nvm_rd_en), .nvm_rd_addr(nvm_rd_addr), .nvm_rd_data(nvm_rd_data),
        .nvm_rd_valid(nvm_rd_valid), .nvm_wr_en(nvm_wr_en), .nvm_wr_addr(nvm_wr_addr),
        .nvm_wr_data(nvm_wr_data), .nvm_wr_done(nvm_wr_done),
        .ro_en(1'b0),
        .tamper_counter(ac), .tear_count(tc), .lockdown(lockdown),
        .lif_alarm(), .spike_bus()
    );
    initial force dut.tdl_alert = 1'b0;     // RTL has no gate delay: keep the TDL quiet

    // ---------------- observers ----------------
    integer n_rel = 0, n_blk = 0, n_acc = 0, n_alm = 0;
    integer t_alm_first = -1, t_rel_last = -1;
    reg     chk_en = 1'b0;
    always @(posedge clk_sys) if (chk_en) begin
        if (dut.req_accept && !dut.permit_sys) err("request accepted while the guard does not permit");
        if (dut.req_accept) n_acc = n_acc + 1;
        if (gate_blocked)   n_blk = n_blk + 1;
        if (alarm_sys)      n_alm = n_alm + 1;
        if (alarm_sys && t_alm_first < 0) t_alm_first = $time;
        if (ct_valid) t_rel_last = $time;
        if (ct_valid) begin
            if (ct_out !== EXP) err("released ciphertext is not FIPS-197 C.1");
            n_rel = n_rel + 1;
        end else if (ct_out !== 128'h0)
            err("ct_out not zero while ct_valid = 0");
    end
    // monitor windows seen (time-base domain)
    integer n_win = 0;
    always @(posedge dut.mon_clk) if (dut.mon_val_s) n_win = n_win + 1;

    task err; input [8*64-1:0] msg; begin
        errors = errors + 1;
        $display("FAIL[main] %0s  (t=%0t ac=%0d tc=%0d rel=%0d blk=%0d clkf=%b dead=%b)",
                 msg, $time, ac, tc, n_rel, n_blk, clk_fault, sen_dead);
    end endtask
    task chk; input c; input [8*64-1:0] msg; begin if (!c) err(msg); end endtask

    // ---------------- helpers ----------------
    task cs; input integer n; begin repeat (n) @(posedge clk_sys); end endtask
    task us; input integer n; begin #(n * 1000.0); end endtask

    task req;
        begin
            @(negedge clk_sys) op_req = 1'b1;
            @(negedge clk_sys) op_req = 1'b0;
        end
    endtask

    wire sys_quiet = !(dut.outstanding | dut.aes_busy | dut.gate_busy);
    task wait_quiet;                // CLK_sys running; until no operation is open
        integer t;
        begin
            t = 0;
            while ((!sys_quiet || op_req) && t < 4000) begin cs(1); t = t + 1; end
            if (t >= 4000) err("core stuck in an operation");
            cs(8);
        end
    endtask
    task wait_permit;
        integer t;
        begin
            t = 0;
            while (!dut.permit_sys && t < 6000) begin cs(1); t = t + 1; end
            if (t >= 6000) err("guard never permits operations");
            cs(2);
        end
    endtask
    task wait_for_aes;
        integer t;
        begin
            t = 0;
            while (!dut.aes_busy && t < 2000) begin cs(1); t = t + 1; end
            if (t >= 2000) err("timeout waiting for the AES");
        end
    endtask

    task do_por;
        begin
            @(negedge clk_sys) arst_n = 1'b0;
            cs(4); #200;
            @(negedge clk_sys) arst_n = 1'b1;
            chk_en = 1'b1;
`ifndef DEMO_BUILD
            cs(4);
            @(negedge clk_sys) key_wr_en = 1'b1;
            @(negedge clk_sys) key_wr_en = 1'b0;
`endif
        end
    endtask

    task user_reset;
        begin
            @(negedge clk_sys) key0_n = 1'b0;
            #400;
            key0_n = 1'b1;
            us(1);
        end
    endtask
    // all clocks nominal for a while, then the user reset clears the sticky bits
    task recover;
        begin
            us(5);
            user_reset;
            wait_permit;
            chk(!clk_fault && !sen_dead, "user reset clears the sticky fault bits");
        end
    endtask

    task clean_op;
        integer r0, a0, b0;
        begin
            wait_permit; wait_quiet;
            r0 = n_rel; a0 = ac; b0 = n_blk;
            req; wait_quiet;
            chk(n_rel == r0 + 1, "clean op releases exactly one ciphertext");
            chk(ac == a0 && n_blk == b0, "clean op: counter and gate unchanged");
        end
    endtask

    task refused;                   // a request now must not be accepted
        integer a0;
        begin
            a0 = n_acc;
            req; cs(30);
            chk(n_acc == a0 && sys_quiet, "request refused while the guard blocks");
        end
    endtask

    // ---------------- scenarios ----------------
    integer i, r0, a0, b0, t0, w0, off, rs, k;

    task scen_a;                    // nominal, >= 20 windows
        begin
            w0 = n_win; a0 = ac; n_alm = 0;
            for (i = 0; i < 12; i = i + 1) begin clean_op; us(2); end
            while (n_win < w0 + 24) us(1);
            chk(n_win - w0 >= 20, "a: at least 20 monitor windows observed");
            chk(n_alm == 0 && !clk_fault && !sen_dead && ac == a0 && tc == 0,
                "a: nominal clocks raise no alarm and count nothing");
        end
    endtask

    task scen_b_idle;               // CLK_sentinel stopped while idle
        begin
            wait_permit; wait_quiet;
            r0 = n_rel; a0 = ac; b0 = n_acc;
            hn = 0.0;
            us(14);
            chk(sen_dead && clk_fault, "b: sen_dead and clk_fault set while CLK_sentinel is stopped");
            chk(!dut.permit_sys && alarm_sys, "b: guard blocks and alarm_sys is high");
            refused;
            hn = HN_NOM;
            us(8);
            chk(ac == a0 + 1 && tc == 0, "b: the stop was counted once after the clock returned");
            chk(sen_dead && clk_fault, "b: bits stay sticky after the clock returned");
            refused;
            chk(n_rel == r0, "b: nothing released");
            recover;
            clean_op;
            chk(ac == a0 + 1, "b: counter unchanged by the recovery");
        end
    endtask

    task scen_b_mid;                // CLK_sentinel stopped in the middle of an operation
        input integer wait_cyc;     // sys cycles after the AES starts
        begin
            wait_permit; wait_quiet;
            r0 = n_rel; a0 = ac; t0 = tc;
            req; wait_for_aes; cs(wait_cyc);
            hn = 0.0;
            us(14);
            chk(sen_dead && clk_fault, "b: flags set when CLK_sentinel stops mid-operation");
            hn = HN_NOM;
            us(8);
            wait_quiet;
            chk(n_rel == r0, "b: nothing released for the operation hit by the stop");
            chk(ac == a0 + 1 && tc == t0, "b: counted once (mid-operation)");
            chk(sys_quiet, "b: core returns to idle");
            recover;
            clean_op;
        end
    endtask

    // CLK_sys off-nominal; scale = half-period factor.
    // strict = 1: the clock change happens early enough in the operation that
    // the gate must block it. strict = 0: the operation may finish before the
    // monitor window closes (detection takes 1 to 2 windows); then the release
    // is allowed only if it happened before alarm_sys rose.
    task scen_c;
        input real scale;
        input integer in_op;
        input integer strict;
        begin
            wait_permit; wait_quiet;
            r0 = n_rel; a0 = ac; b0 = n_blk; t0 = tc;
            t_alm_first = -1;
            if (in_op) begin req; wait_for_aes; end
            hs = HS_NOM * scale;
            us(7);
            chk(clk_fault && alarm_sys && !dut.permit_sys, "c: clk_fault, alarm_sys and refusal while CLK_sys is off-nominal");
            hs = HS_NOM;
            us(6);
            wait_quiet;
            if (in_op && strict) begin
                chk(n_rel == r0, "c: nothing released");
                chk(n_blk == b0 + 1, "c: gate blocked the operation");
            end else if (n_rel != r0) begin
                chk(t_alm_first >= 0 && t_rel_last < t_alm_first,
                    "c: a release is allowed only before the alarm rose");
            end
            chk(ac == a0 + 1 && tc == t0, "c: counted once per event");
            recover;
            clean_op;
        end
    endtask

    task scen_d_sweep;              // CLK_sys stopped at an offset of an operation
        input integer from;
        input integer to;
        input integer step;
        input integer stop_us;
        begin
            for (off = from; off <= to; off = off + step) begin
                wait_permit; wait_quiet;
                r0 = n_rel; a0 = ac; t0 = tc;
                req; cs(off);
                hs = 0.0;
                #(3 * HS_NOM);              // let the last clock edge pass
                rs = n_rel;                 // releases before the clock really stopped
                us(stop_us);
                hs = HS_NOM;
                us(6);
                wait_quiet;
`ifdef CM_VERBOSE
                $display("  d off=%0d: rel before stop=%0d after=%0d gate_st=%0d ac=%0d", off, rs - r0, n_rel - r0, dut.u_gate.stA, ac - a0);
`endif
                chk(n_rel == rs, "d: nothing released after the stopped clock returned");
                chk(ac == a0 + 1 && tc == t0, "d: stop counted once");
                chk(sys_quiet, "d: core returns to idle");
                recover;
            end
            clean_op;
        end
    endtask

    task scen_e;                    // Sentinel OFF (demo)
        begin
            wait_permit; wait_quiet;
            r0 = n_rel; a0 = ac; n_alm = 0;
            sen_on = 1'b0;
            us(1);
            hn = 0.0; us(14); hn = HN_NOM; us(6);
            hs = HS_NOM * 5.0; us(7); hs = HS_NOM; us(5);
            hs = HS_NOM / 2.5; us(7); hs = HS_NOM; us(5);
            hs = 0.0; us(6); hs = HS_NOM; us(5);
            chk(n_alm == 0 && !clk_fault && !sen_dead, "e: Sentinel OFF: no new alarm fires");
            chk(ac == a0 && tc == 0, "e: Sentinel OFF: nothing is counted");
            chk(dut.permit_sys, "e: Sentinel OFF: operations are still permitted");
            clean_op;
            chk(n_rel == r0 + 1 && n_alm == 0, "e: Sentinel OFF: DFA demo path keeps working");
            sen_on = 1'b1;
            us(4);
            chk(!clk_fault && !sen_dead && dut.permit_sys, "e: nothing latched when Sentinel comes back on");
            clean_op;
        end
    endtask

    task scen_f;                    // warm-up after power-on
        integer t_rel, t_first, c;
        reg     got;
        begin
            // (1) monitor warm-up: requests are hammered from the first cycle
            @(negedge clk_sys) arst_n = 1'b0;
            cs(4); #200;
            n_acc = 0;
            t_rel = $time;
            @(negedge clk_sys) arst_n = 1'b1;
            t_rel = $time;
            got = 1'b0; t_first = 0;
            c = 0;
            while (!got && c < 6000) begin
                @(negedge clk_sys);
                op_req = 1'b1;
`ifndef DEMO_BUILD
                key_wr_en = (c == 4);       // production: write the key once, early
`endif
                @(posedge clk_sys);
                if (n_acc > 0) begin got = 1'b1; t_first = $time; end
                c = c + 1;
            end
            op_req = 1'b0;
            key_wr_en = 1'b0;
            chk(got, "f: an operation is granted after warm-up");
            // MON_WARM = 4 windows of 256 oscillator cycles of 4 ns = 4096 ns
            chk((t_first - t_rel) >= 4000, "f: no grant before MON_WARM clean monitor windows");
            $display("  f: first grant %0d ns after power-on release (warm-up)", t_first - t_rel);
            wait_quiet;
            // (2) heartbeat: monitor forced warm; the first heartbeat edge still gates the grant
            @(negedge clk_sys) arst_n = 1'b0;
            cs(4); #200;
            force dut.warm_sys = 1'b1;
            n_acc = 0;
            @(negedge clk_sys) arst_n = 1'b1;
            t_rel = $time;
            got = 1'b0; c = 0;
            while (!got && c < 3000) begin
                @(negedge clk_sys);
                op_req = 1'b1;
`ifndef DEMO_BUILD
                key_wr_en = (c == 4);
`endif
                @(posedge clk_sys);
                if (n_acc > 0) begin got = 1'b1; t_first = $time; end
                c = c + 1;
            end
            op_req = 1'b0;
            key_wr_en = 1'b0;
            release dut.warm_sys;
            chk(got, "f: an operation is granted after the first heartbeat edge");
            // HB_K = 64 CLK_sentinel cycles of 20 ns = 1280 ns to the first edge
            chk((t_first - t_rel) >= 1200, "f: no grant before the first heartbeat edge");
            $display("  f: first grant %0d ns after power-on release (heartbeat only)", t_first - t_rel);
            wait_quiet;
        end
    endtask

    task scen_g;                    // heartbeat alone: the monitor output is forced quiet
        begin
            wait_permit; wait_quiet;
            force dut.bad_any = 1'b0;
            // CLK_sentinel stopped, idle
            r0 = n_rel; a0 = ac;
            hn = 0.0; us(14);
            chk(sen_dead && !clk_fault, "g: heartbeat alone sets sen_dead (monitor quiet)");
            refused;
            hn = HN_NOM; us(8);
            chk(ac == a0 + 1, "g: heartbeat-only stop is counted once");
            chk(n_rel == r0, "g: nothing released");
            recover;
            clean_op;
            // CLK_sys stopped mid-operation, longer than the sentinel timeout
            a0 = ac; r0 = n_rel; t0 = tc;
            req; wait_for_aes; cs(2);
            hs = 0.0; us(16); hs = HS_NOM; us(6);
            wait_quiet;
            chk(n_rel == r0, "g: no release after the CLK_sys stop (heartbeat only)");
            chk(ac == a0 + 1 && tc == t0, "g: CLK_sys stop mid-operation counted once (heartbeat only)");
            chk(!clk_fault, "g: monitor stayed quiet (forced)");
            release dut.bad_any;
            recover;
            clean_op;
        end
    endtask

    task scen_h;                    // time base stopped: the watchdog
        begin
            wait_permit; wait_quiet;
            a0 = ac; r0 = n_rel;
            dut.u_mon_ro.half_ns = 3000.0;      // ~170x slower than nominal
            us(60);
            chk(clk_fault && !dut.permit_sys, "h: stopped time base sets clk_fault and refuses operations");
            dut.u_mon_ro.half_ns = 2.0;
            us(14);
            chk(ac >= a0 + 1 && ac <= a0 + 1, "h: stopped time base counted once");
            chk(n_rel == r0, "h: nothing released");
            recover;
            clean_op;
        end
    endtask

    // ---------------- main ----------------
    initial begin
        do_por;
        wait_permit;
        scen_a;
        scen_b_idle;
        scen_b_mid(3);
        scen_b_mid(14);
        scen_c(5.0, 0, 0);       // 16 MHz = 0.2x
        scen_c(5.0, 1, 0);
        scen_c(40.0, 1, 1);      // 2 MHz: the operation cannot finish before the alarm
        scen_c(0.4, 0, 0);       // 200 MHz = 2.5x
        scen_c(0.4, 1, 0);
        scen_d_sweep(0, 34, 2, 5);
        scen_d_sweep(35, 90, 1, 5);   // fine steps around the commit answer
        scen_d_sweep(1, 3, 1, 14);   // long stop (also trips the heartbeat in CLK_sentinel)
        scen_g;
        scen_h;
`ifdef DEMO_BUILD
        scen_e;
`endif
        scen_f;
        wait_permit;
        scen_a;                  // still clean after everything
        finished = 1'b1;
    end
endmodule

// ---------------------------------------------------------------------------
// Race unit: start / abort-commit in the same CLK_sys cycle (item 7).
// ---------------------------------------------------------------------------
module cm_race ();
    localparam integer CW = 8;
    localparam integer RECW = 17 + 2*CW;
    localparam [127:0] KEY = 128'h000102030405060708090a0b0c0d0e0f;
    localparam [127:0] PT  = 128'h00112233445566778899aabbccddeeff;
    localparam [127:0] EXP = 128'h69c4e0d86a7b0430d8cdb78070b4c55a;

    integer errors = 0;
    reg finished = 1'b0;

    real hs, hn;
    reg clk_sys = 1'b0, clk_sen = 1'b0;
    initial begin hs = 15.0; hn = 5.0; end
    always begin #(hs) clk_sys = ~clk_sys; end
    always begin #(hn) clk_sen = ~clk_sen; end

    reg arst_n = 1'b0;
    wire por_sys_n, por_sen_n;
    reset_sync u_rs_sys (.clk(clk_sys), .arst_n(arst_n), .rst_n(por_sys_n));
    reset_sync u_rs_sen (.clk(clk_sen), .arst_n(arst_n), .rst_n(por_sen_n));
    wire rst_sys_n = por_sys_n;
    wire rst_sen_n = por_sen_n;

    reg          op_req = 1'b0, power_warn = 1'b0, key_wr_en = 1'b0;
    wire [127:0] ct_out;
    wire         ct_valid, gate_blocked, busy, key_is_zero, lockdown_sys, lockdown;
    wire [CW-1:0] ac, tc;
    wire            nvm_rd_en, nvm_rd_addr, nvm_rd_valid, nvm_wr_en, nvm_wr_addr, nvm_wr_done;
    wire [RECW-1:0] nvm_rd_data, nvm_wr_data;
    nvm_counter_model #(.CW(CW), .RD_LAT(1), .WR_LAT(1), .INIT_BLANK(0)) nvm (
        .clk(clk_sen), .power_ok(1'b1),
        .rd_en(nvm_rd_en), .rd_addr(nvm_rd_addr), .rd_data(nvm_rd_data), .rd_valid(nvm_rd_valid),
        .wr_en(nvm_wr_en), .wr_addr(nvm_wr_addr), .wr_data(nvm_wr_data), .wr_done(nvm_wr_done)
    );

    // monitor bounds opened wide: this unit tests the handshake, not the monitors
    peruri_sentinel_core_t2 #(
        .H(4), .N(250), .M(250), .CW(CW), .DPA_ENABLE(1),
        .TDL_L(8), .TDL_COARSE(3), .TDL_SETTLE(16), .TDL_WIN(64), .RO_WINDOW(256),
        .FAST_HOLD(16), .SLOW_HOLD(64),
        .MON_LO_SYS(0), .MON_HI_SYS(4000), .MON_LO_SEN(0), .MON_HI_SEN(4000)
`ifdef DEMO_BUILD
        , .DEMO_UNLOCK(0)
`endif
    ) dut (
        .clk_sys(clk_sys), .rst_sys_n(rst_sys_n), .por_sys_n(por_sys_n),
        .op_req(op_req), .pt(PT),
`ifdef DEMO_BUILD
        .sentinel_en_sys(1'b1), .fault_en(1'b0), .fault_round(4'd9), .fault_byte(4'd0),
        .fault_mask(8'h01), .harness_alarm(1'b0), .round_idx(),
`else
        .key_wr_en(key_wr_en), .key_wr_data(KEY),
`endif
        .ct_out(ct_out), .ct_valid(ct_valid), .gate_blocked(gate_blocked), .busy(busy),
        .key_is_zero(key_is_zero), .lockdown_sys(lockdown_sys),
        .tamper_counter_sys(), .tear_count_sys(), .alarm_sys(), .clk_fault(), .sen_dead(),
        .tdl_alert(), .tdl_armed(), .tdl_cal_bad(),
        .tdl_depth(), .tdl_min_r(), .tdl_sel(),
        .clk_sen(clk_sen), .rst_sen_n(rst_sen_n), .por_sen_n(por_sen_n),
`ifdef DEMO_BUILD
        .sentinel_en_sen(1'b1), .debug_unlock_sen(1'b0), .fsm_mask_sen(1'b0),
        .ewma_alarm(), .fixed_alarm(),
`endif
        .power_warn(power_warn),
        .nvm_rd_en(nvm_rd_en), .nvm_rd_addr(nvm_rd_addr), .nvm_rd_data(nvm_rd_data),
        .nvm_rd_valid(nvm_rd_valid), .nvm_wr_en(nvm_wr_en), .nvm_wr_addr(nvm_wr_addr),
        .nvm_wr_data(nvm_wr_data), .nvm_wr_done(nvm_wr_done),
        .ro_en(1'b0),
        .tamper_counter(ac), .tear_count(tc), .lockdown(lockdown),
        .lif_alarm(), .spike_bus()
    );
    initial force dut.tdl_alert = 1'b0;

    integer n_rel = 0, coll = 0, n_start_bad = 0;
    reg     coll_pend = 1'b0, chk_en = 1'b0;
    always @(posedge clk_sys) if (chk_en) begin
        if (ct_valid) n_rel = n_rel + 1;
        if (dut.req_accept) coll_pend = 1'b0;
        if (dut.go && dut.op_live && dut.commit_fin_sys) begin
            coll = coll + 1;
            coll_pend = 1'b1;
        end
        if (dut.start && dut.commit_fin_sys) begin
            n_start_bad = n_start_bad + 1;
            err("AES start in the same cycle as the abort answer");
        end
        if (coll_pend && dut.aes_busy) begin
            err("AES running for an operation closed by the abort answer");
            coll_pend = 1'b0;
        end
    end

    task err; input [8*64-1:0] msg; begin
        errors = errors + 1;
        $display("FAIL[race] %0s  (t=%0t rel=%0d coll=%0d)", msg, $time, n_rel, coll);
    end endtask

    task cs; input integer n; begin repeat (n) @(posedge clk_sys); end endtask
    task wait_idle;
        integer t;
        begin
            t = 0;
            while ((dut.outstanding | dut.aes_busy | dut.gate_busy | !dut.permit_sys | !dut.ready_sys) && t < 3000) begin
                cs(1); t = t + 1;
            end
            if (t >= 3000) err("core hangs busy");
            cs(6);
        end
    endtask

    integer ti, d, rep, r0, a0, t0, nops;
    real periods [0:3];
    initial begin
        periods[0] = 15.0; periods[1] = 22.5; periods[2] = 30.0; periods[3] = 12.0;
        @(negedge clk_sys) arst_n = 1'b0;
        cs(4); #100;
        @(negedge clk_sys) arst_n = 1'b1;
        chk_en = 1'b1;
`ifndef DEMO_BUILD
        cs(4);
        @(negedge clk_sys) key_wr_en = 1'b1;
        @(negedge clk_sys) key_wr_en = 1'b0;
`endif
        wait_idle;
        nops = 0;
        for (ti = 0; ti < 4; ti = ti + 1) begin
            hs = periods[ti];
            for (d = 0; d < 9; d = d + 1) begin
                for (rep = 0; rep < 6; rep = rep + 1) begin
                    wait_idle;
                    r0 = n_rel;
                    @(negedge clk_sys) op_req = 1'b1;
                    @(negedge clk_sys) op_req = 1'b0;
                    // power_warn d CLK_sentinel cycles after the grant, 3 cycles long
                    begin : wait_grant
                        integer t;
                        t = 0;
                        while (!dut.fsm_op_grant && t < 400) begin @(posedge clk_sen); t = t + 1; end
                        if (t >= 400) err("no grant seen");
                    end
                    repeat (d) @(posedge clk_sen);
                    @(negedge clk_sen) power_warn = 1'b1;
                    repeat (3) @(posedge clk_sen);
                    @(negedge clk_sen) power_warn = 1'b0;
                    wait_idle;
                    if (n_rel != r0) err("a power_warn operation released a ciphertext");
                    nops = nops + 1;
                end
            end
        end
        $display("  race: %0d operations, %0d start/abort collisions", nops, coll);
        if (coll == 0) err("the start/abort collision was never exercised");
        finished = 1'b1;
    end
endmodule

module tb_core_t2_clockmon;
    cm_main u_main ();
    cm_race u_race ();

    initial begin
        #60_000_000;
        $display("FAIL tb_core_t2_clockmon (timeout: main=%b race=%b)", u_main.finished, u_race.finished);
        $finish;
    end
    initial begin
        wait (u_main.finished && u_race.finished);
        #200;
        if (u_main.errors + u_race.errors == 0) $display("PASS tb_core_t2_clockmon");
        else $display("FAIL tb_core_t2_clockmon (%0d errors)", u_main.errors + u_race.errors);
        $finish;
    end
endmodule
