// BUILD: both
// Tier 2 core with the NVM-backed tamper controller (tamper_persist_fsm in
// CLK_sentinel) behind the toggle handshakes. Runs the same scenarios at
// several CLK_sys / CLK_sentinel ratios (each bench has its own clocks).
//
// Per bench, units (each is a full peruri_sentinel_core_t2 + nvm_counter_model,
// with its own reset generator):
//   uA  wide counters (CW = 8, N = 100, M = 250): functional scenarios and the
//       reset / power_warn sweeps
//   uL  default counters (N = 4, M = 8): alarm lockdown, requests hammered
//       through the lockdown transition
//   uB  blank NVM: lockdown at boot
//   uT  (first bench only) N = 100, M = 3: tear lockdown
//
// The TDL alert is forced by the testbench (RTL has no gate delay); the RO
// mesh is disabled (ro_en = 0). The alert still goes through the real
// crossings: directly into the gate, stretched into the sentinel domain.
//
// Checked at every CLK_sys cycle (all units):
//   - ct_valid only with the FIPS-197 C.1 ciphertext
//   - ct_valid only after the sys side has seen a CLEAN commit answer, after
//     the controller finished the NVM commit, and with in_progress = 0 in the
//     newest NVM record
//   - ct_out is zero whenever ct_valid is 0
`timescale 1ns/1ps

// sweep range and step (CLK_sys cycles); override with -DSWMAX=.. -DSWSTEP=.. for quick runs
`ifndef SWMAX
`define SWMAX 130
`endif
`ifndef SWSTEP
`define SWSTEP 3
`endif

module t2_unit #(
    parameter integer ID     = 0,
    parameter integer CW     = 4,
    parameter integer N      = 4,
    parameter integer M      = 8,
    parameter integer BLANK  = 0,
    parameter integer WR_LAT = 8,
    parameter integer SW_MAX = 130,     // sweep range (CLK_sys cycles after the request)
    parameter integer SW_STEP = 1,
    parameter real    T_SYS  = 12.5,
    parameter real    T_SEN  = 20.0
) (
    input wire clk_sys,
    input wire clk_sen
);
    localparam integer RECW = 17 + 2*CW;
    localparam [127:0] KEY = 128'h000102030405060708090a0b0c0d0e0f;
    localparam [127:0] PT  = 128'h00112233445566778899aabbccddeeff;
    localparam [127:0] EXP = 128'h69c4e0d86a7b0430d8cdb78070b4c55a;
    localparam real    T_SLOW  = (T_SYS > T_SEN) ? T_SYS : T_SEN;

    integer errors = 0;

    // ---------------- resets (as in the board top) ----------------
    reg arst_n = 1'b0;
    reg key0_n = 1'b1;
    wire por_sys_n, por_sen_n;
    reset_sync u_rs_sys (.clk(clk_sys), .arst_n(arst_n), .rst_n(por_sys_n));
    reset_sync u_rs_sen (.clk(clk_sen), .arst_n(arst_n), .rst_n(por_sen_n));
    wire rst_sys_n = por_sys_n & key0_n;
    wire key0_sen;
    sync_2ff #(.RESET_VAL(1'b1)) u_k0 (.clk(clk_sen), .rst_n(por_sen_n), .d(key0_n), .q(key0_sen));
    wire rst_sen_n = por_sen_n & key0_sen;

    // ---------------- stimulus and DUT ----------------
    reg          op_req     = 1'b0;
    reg          power_warn = 1'b0;
    reg          f_tdl      = 1'b0;
    reg          key_wr_en  = 1'b0;
    wire [127:0] ct_out;
    wire         ct_valid, gate_blocked, busy, key_is_zero, lockdown_sys, lockdown;
    wire [CW-1:0] ac, tc, ac_sys, tc_sys;

    wire            nvm_rd_en, nvm_rd_addr, nvm_rd_valid, nvm_wr_en, nvm_wr_addr, nvm_wr_done;
    wire [RECW-1:0] nvm_rd_data, nvm_wr_data;
    nvm_counter_model #(.CW(CW), .RD_LAT(2), .WR_LAT(WR_LAT), .INIT_BLANK(BLANK)) nvm (
        .clk(clk_sen), .power_ok(1'b1),
        .rd_en(nvm_rd_en), .rd_addr(nvm_rd_addr), .rd_data(nvm_rd_data), .rd_valid(nvm_rd_valid),
        .wr_en(nvm_wr_en), .wr_addr(nvm_wr_addr), .wr_data(nvm_wr_data), .wr_done(nvm_wr_done)
    );

    peruri_sentinel_core_t2 #(
        .H(4), .N(N), .M(M), .CW(CW), .DPA_ENABLE(1),
        .TDL_L(8), .TDL_COARSE(3), .TDL_SETTLE(16), .TDL_WIN(64), .RO_WINDOW(256), .FAST_HOLD(16), .SLOW_HOLD(64)
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
        .tamper_counter_sys(ac_sys), .tear_count_sys(tc_sys),
        .alarm_sys(), .tdl_alert(), .tdl_armed(), .tdl_cal_bad(),
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
    initial force dut.tdl_alert = f_tdl;

    // ---------------- NVM view ----------------
    // newest copy: the sequence number is 8 bits and wraps, so compare modulo 256
    wire [7:0]      nv_d   = nvm.mem0[RECW-1:RECW-8] - nvm.mem1[RECW-1:RECW-8];
    wire [RECW-1:0] nv_rec = (nv_d < 8'd128) ? nvm.mem0 : nvm.mem1;
    wire [CW-1:0]   nv_ac  = nv_rec[8+CW +: CW];
    wire [CW-1:0]   nv_tc  = nv_rec[8 +: CW];
    wire            nv_ip  = nv_rec[8+2*CW];

    // ---------------- observers ----------------
    integer n_rel = 0, n_blk = 0, n_clean_sys = 0, n_clean_fsm = 0;
    always @(posedge clk_sen)
        if (dut.fsm_commit_fin && dut.fsm_commit_clean) n_clean_fsm = n_clean_fsm + 1;
    reg chk_en = 1'b0;               // set once the first power-on reset is done
    always @(posedge clk_sys) if (chk_en) begin
        if (dut.commit_fin_sys && dut.commit_clean_sys) n_clean_sys = n_clean_sys + 1;
        if (gate_blocked) n_blk = n_blk + 1;
        if (dut.start && dut.stale) err("AES started for a request cut short by the user reset");
        if (ct_valid) begin
            if (ct_out !== EXP)            err("released ciphertext is not FIPS-197 C.1");
            if (n_clean_sys <= n_rel)      err("ct_valid before the sys side saw a clean commit");
            if (n_clean_fsm <= n_rel)      err("ct_valid before the NVM commit finished");
            if (nv_ip === 1'b1)            err("ct_valid with in_progress set in the NVM");
            n_rel = n_rel + 1;
        end else if (ct_out !== 128'h0)
            err("ct_out not zero while ct_valid = 0");
    end

    // ---------------- helpers ----------------
    task err;
        input [8*60-1:0] msg;
        begin
            errors = errors + 1;
            $display("FAIL[u%0d] %0s  (ac=%0d tc=%0d nv=%0d/%0d lock=%b rel=%0d blk=%0d t=%0t)",
                     ID, msg, ac, tc, nv_ac, nv_tc, lockdown, n_rel, n_blk, $time);
        end
    endtask
    task chk;
        input            cond;
        input [8*60-1:0] msg;
        begin
            if (!cond) err(msg);
        end
    endtask
    task cs; input integer n; begin repeat (n) @(posedge clk_sys); end endtask
    task cn; input integer n; begin repeat (n) @(posedge clk_sen); end endtask

    task req;                       // one-cycle request
        begin
            @(negedge clk_sys) op_req = 1'b1;
            @(negedge clk_sys) op_req = 1'b0;
        end
    endtask

    task alert1;                    // one-cycle TDL alert
        begin
            @(negedge clk_sys) f_tdl = 1'b1;
            @(negedge clk_sys) f_tdl = 1'b0;
        end
    endtask

    task warn_pulse;                // power_warn for 3 CLK_sentinel cycles
        begin
            @(negedge clk_sen) power_warn = 1'b1;
            cn(3);
            @(negedge clk_sen) power_warn = 1'b0;
        end
    endtask

    task wait_idle;                 // until the whole core is quiet (not for lockdown)
        integer t;
        begin
            t = 0;
            while ((busy || op_req) && t < 4000) begin cs(1); t = t + 1; end
            if (t >= 4000) err("core stuck busy");
            cs(4);
        end
    endtask

    task wait_for;                  // wait until `sel` is true (1 aes_busy, 2 op_live, 3 gate op_done)
        input integer sel;
        integer t;
        reg c;
        begin
            t = 0; c = 1'b0;
            while (!c && t < 2000) begin
                @(posedge clk_sys);
                case (sel)
                    1: c = dut.aes_busy;
                    2: c = dut.op_live;
                    default: c = dut.gate_op_done;
                endcase
                t = t + 1;
            end
            if (!c) err("timeout waiting for an operation phase");
        end
    endtask

    task do_por;
        integer t;
        begin
            @(negedge clk_sys) arst_n = 1'b0;
            cs(4); cn(4);
            @(negedge clk_sys) arst_n = 1'b1;
            t = 0;
            while (!(dut.ready_sys || lockdown_sys) && t < 6000) begin cs(1); t = t + 1; end
            if (t >= 6000) err("boot timeout");
            chk_en = 1'b1;
`ifndef DEMO_BUILD
            @(negedge clk_sys) key_wr_en = 1'b1;
            @(negedge clk_sys) key_wr_en = 1'b0;
`endif
            cs(6);
        end
    endtask

    integer dbg_off = -1;
    task nvm_sync_chk;              // newest NVM record equals the controller counters
        begin
            if (!(nv_ac == ac && nv_tc == tc && nv_ip === 1'b0))
                $display("  dbg[u%0d] st=%0d out=%b stale=%b busy=%b ip=%b off=%0d t=%0t", ID, dut.u_fsm.st, dut.outstanding, dut.stale, busy, nv_ip, dbg_off, $time);
            chk(nv_ac == ac && nv_tc == tc && nv_ip === 1'b0, "NVM record matches the counters");
        end
    endtask

    task clean_op;
        integer r0, a0, t0;
        begin
            wait_idle;
            r0 = n_rel; a0 = ac; t0 = tc;
            req; wait_idle;
            chk(n_rel == r0 + 1, "clean op releases exactly one ciphertext");
            chk(ac == a0 && tc == t0, "clean op leaves the counters unchanged");
            nvm_sync_chk;
        end
    endtask

    // v: 0 alert while the AES runs, 1 alert right after the grant (before or at
    //    the AES start), 2 alert after the gate decision point (commit wait)
    task alarm_op;
        input integer v;
        integer r0, a0, t0, b0;
        begin
            wait_idle;
            r0 = n_rel; a0 = ac; t0 = tc; b0 = n_blk;
            req;
            case (v)
                0: begin wait_for(1); cs(2); alert1; end
                1: begin wait_for(2); alert1; end
                default: begin wait_for(3); alert1; end
            endcase
            wait_idle;
            chk(n_rel == r0,                "alarmed op: nothing released");
            chk(n_blk == b0 + 1,            "alarmed op: gate blocked once");
            chk(ac == a0 + 1 && tc == t0,   "alarmed op: alarm_count +1 only");
            nvm_sync_chk;
        end
    endtask

    task warn_op;
        integer r0, a0, t0, b0;
        begin
            wait_idle;
            r0 = n_rel; a0 = ac; t0 = tc; b0 = n_blk;
            req; wait_for(1); cs(2); warn_pulse;
            wait_idle;
            chk(n_rel == r0,                "power_warn op: nothing released");
            chk(n_blk == b0 + 1,            "power_warn op: gate blocked once");
            chk(tc == t0 + 1 && ac == a0,   "power_warn op: tear_count +1 only");
            nvm_sync_chk;
        end
    endtask

    // power lost (POR of both domains) in the middle of an operation
    task por_midop;
        integer r0, a0, t0;
        begin
            wait_idle;
            r0 = n_rel; a0 = ac; t0 = tc;
            req; wait_for(1); cs(2);
            do_por;
            chk(n_rel == r0,              "POR mid-op: nothing released");
            chk(tc == t0 + 1 && ac == a0, "POR mid-op: boot charges one tear");
            nvm_sync_chk;
        end
    endtask

    task por_persist;
        integer a0, t0;
        begin
            wait_idle;
            a0 = ac; t0 = tc;
            do_por;
            chk(ac == a0 && tc == t0, "counters survive a POR of both domains");
            chk(!lockdown_sys && !key_is_zero, "no lockdown after POR with a valid record");
            nvm_sync_chk;
        end
    endtask

    // user reset (KEY0 style, with the usual skew into CLK_sentinel) at every
    // offset after the request
    task reset_sweep;
        input integer hold_cyc;     // reset width in cycles of the slower clock
        integer off, r0, a0, t0, w;
        begin
            for (off = 0; off <= SW_MAX; off = off + SW_STEP) begin
                wait_idle;
                r0 = n_rel; a0 = ac; t0 = tc;
                dbg_off = off;
                req; cs(off);
                w = dut.aes_busy;
                key0_n = 1'b0; #(hold_cyc * T_SLOW); key0_n = 1'b1;
                wait_idle;
                chk(ac == a0, "reset sweep: alarm_count unchanged");
                chk(tc == t0 || tc == t0 + 1, "reset sweep: at most one tear");
                if (n_rel != r0) chk(tc == t0, "reset sweep: released op has no tear");
                if (w) begin
                    chk(tc == t0 + 1 && n_rel == r0, "reset sweep: reset during the AES is a tear");
                end
                nvm_sync_chk;
                chk(dut.outstanding === 1'b0 && dut.stale === 1'b0, "reset sweep: handshake closed");
                clean_op;
            end
        end
    endtask

    task warn_sweep;
        integer off, r0, a0, t0, w;
        begin
            for (off = 0; off <= SW_MAX; off = off + SW_STEP) begin
                wait_idle;
                r0 = n_rel; a0 = ac; t0 = tc;
                dbg_off = 1000 + off;
                req; cs(off);
                w = dut.aes_busy;
                warn_pulse;
                wait_idle;
                chk(ac == a0, "warn sweep: alarm_count unchanged");
                chk(tc == t0 || tc == t0 + 1, "warn sweep: at most one tear");
                if (n_rel != r0) chk(tc == t0, "warn sweep: released op has no tear");
                if (w) begin
                    chk(tc == t0 + 1 && n_rel == r0, "warn sweep: droop during the AES is a tear");
                end
                nvm_sync_chk;
                chk(dut.outstanding === 1'b0, "warn sweep: handshake closed");
                clean_op;
            end
        end
    endtask

    wire sys_quiet = !(dut.outstanding | dut.aes_busy | dut.gate_busy);

    // keep requesting; every operation gets one alert at its AES start
    // (alarm = 1) or one power_warn (alarm = 0), until the lockdown.
    // In Tier 2 CLK_sys can be faster than CLK_sentinel; power_warn is held
    // while aes_busy is high so that CLK_sentinel reliably samples the droop.
    task hammer;
        input integer alarm;
        integer t;
        reg busy_d;
        begin
            busy_d = 1'b0;
            for (t = 0; t < 8000 && !lockdown_sys; t = t + 1) begin
                @(negedge clk_sys);
                op_req = 1'b1;
                if (alarm) f_tdl = dut.aes_busy & ~busy_d;
                else       power_warn = dut.aes_busy;
                busy_d = dut.aes_busy;
            end
            @(negedge clk_sys);
            op_req = 1'b0; f_tdl = 1'b0; power_warn = 1'b0;
            if (!lockdown_sys) err("hammer: no lockdown reached");
        end
    endtask

    // ---------------- scenarios ----------------
    task run_functional;
        integer i;
        begin
            do_por;
            chk(!lockdown_sys && !key_is_zero && ac == 0 && tc == 0, "boot from a valid NVM record");
            for (i = 0; i < 3; i = i + 1) clean_op;            // (a)
            alarm_op(0);                                        // (c)
            alarm_op(1);
            alarm_op(2);
            clean_op;
            warn_op;                                            // (d)
            clean_op;
            por_persist;                                        // (e)
            clean_op;
            por_midop;
            clean_op;
            por_persist;
            reset_sweep(6);                                     // (h)
            reset_sweep(3);                                     // short reset: a late grant must be dropped
            warn_sweep;
            clean_op;
        end
    endtask

    task run_lockdown;                                          // (f)
        integer r0, i;
        begin
            do_por;
            r0 = n_rel;
            for (i = 0; i < 3; i = i + 1) alarm_op(0);
            chk(!lockdown_sys && !key_is_zero, "below N: no lockdown yet");
            hammer(1);
            cs(300);
            chk(lockdown_sys && lockdown, "lockdown after N alarmed operations");
            chk(ac == N && tc == 0, "lockdown: alarm_count = N");
            chk(key_is_zero, "lockdown: key zeroized");
            chk(n_rel == r0, "no ciphertext released by alarmed operations");
            chk(sys_quiet, "lockdown: core not stuck busy");
            req; cs(60); req; cs(60);
            chk(n_rel == r0 && sys_quiet && !dut.outstanding, "requests after lockdown ignored");
            nvm_sync_chk;
            do_por;                                             // lockdown persists
            chk(lockdown_sys && key_is_zero && ac == N, "lockdown survives a POR");
            req; cs(60);
            chk(n_rel == r0 && sys_quiet, "still no output after POR");
        end
    endtask

    task run_tear_lockdown;
        integer r0;
        begin
            do_por;
            r0 = n_rel;
            hammer(0);
            cs(300);
            chk(lockdown_sys && key_is_zero, "tear_count = M locks the device");
            chk(tc == M && ac == 0, "tear lockdown: tear_count = M");
            chk(n_rel == r0 && sys_quiet, "tear lockdown: nothing released, not busy");
        end
    endtask

    // an alert outside an operation starts an NVM write (controller not ready)
    // while a request still sees ready = 1 through the synchronizer; the alert
    // is the Nth event, so the controller locks. The request must be answered,
    // not left hanging.
    task run_race;
        input integer k;
        begin
            do_por;
            alarm_op(0);
            alert1; cs(k); req;
            cs(400);
            chk(lockdown_sys && ac == N, "race: alert + request near lockdown ends in lockdown");
            chk(sys_quiet && !dut.outstanding, "race: request answered, core not stuck busy");
            chk(key_is_zero, "race: key zeroized");
        end
    endtask

    task run_blank;                                             // (g)
        begin
            do_por;
            chk(lockdown_sys && lockdown && key_is_zero, "blank NVM: lockdown at boot");
            req; cs(80);
            chk(n_rel == 0 && sys_quiet && !dut.outstanding, "blank NVM: requests ignored, not busy");
        end
    endtask
endmodule

// One CLK_sys / CLK_sentinel pair with the units attached.
module t2_bench #(
    parameter integer ID      = 0,
    parameter real    T_SYS   = 12.5,
    parameter real    T_SEN   = 20.0,
    parameter real    PH_SEN  = 0.0,
    parameter integer WITH_T  = 0,
    parameter integer SW_MAX  = 130,
    parameter integer SW_STEP = 1,
    parameter integer RACE    = 8       // number of lockdown-race units (offsets 0..RACE-1)
) (
    output reg         done,
    output reg [31:0]  errors
);
    reg clk_sys = 1'b0, clk_sen = 1'b0;
    always #(T_SYS / 2.0) clk_sys = ~clk_sys;
    initial begin
        #(PH_SEN);
        forever #(T_SEN / 2.0) clk_sen = ~clk_sen;
    end

    t2_unit #(.ID(ID*10+0), .CW(8), .N(100), .M(250), .SW_MAX(SW_MAX), .SW_STEP(SW_STEP), .T_SYS(T_SYS), .T_SEN(T_SEN)) uA (.clk_sys(clk_sys), .clk_sen(clk_sen));
    t2_unit #(.ID(ID*10+1), .CW(4), .N(4),   .M(8),   .T_SYS(T_SYS), .T_SEN(T_SEN)) uL (.clk_sys(clk_sys), .clk_sen(clk_sen));
    t2_unit #(.ID(ID*10+2), .CW(4), .N(4),   .M(8),   .BLANK(1), .T_SYS(T_SYS), .T_SEN(T_SEN)) uB (.clk_sys(clk_sys), .clk_sen(clk_sen));
    integer    rk;
    reg [11:0] r_done = (RACE == 0) ? 12'hfff : 12'h000;
    integer    r_errs = 0;
    genvar gk;
    generate
        for (gk = 0; gk < RACE; gk = gk + 1) begin : g_race
            t2_unit #(.ID(ID*10+4), .CW(4), .N(2), .M(8), .T_SYS(T_SYS), .T_SEN(T_SEN)) uR (.clk_sys(clk_sys), .clk_sen(clk_sen));
            initial begin
                uR.run_race(gk);
                r_errs = r_errs + uR.errors;
                r_done[gk] = 1'b1;
            end
        end
    endgenerate

    reg        t_done = (WITH_T == 0);
    reg [31:0] t_err  = 0;
    generate
        if (WITH_T != 0) begin : g_t
            t2_unit #(.ID(ID*10+3), .CW(4), .N(15), .M(3), .T_SYS(T_SYS), .T_SEN(T_SEN)) uT (.clk_sys(clk_sys), .clk_sen(clk_sen));
            initial begin
                uT.run_tear_lockdown;
                t_err  = uT.errors;
                t_done = 1'b1;
            end
        end
    endgenerate

    initial begin
        done = 1'b0; errors = 0;
        fork
            uA.run_functional;
            uL.run_lockdown;
            uB.run_blank;
        join
        wait (t_done);
        for (rk = 0; rk < RACE; rk = rk + 1) wait (r_done[rk]);
        errors = uA.errors + uL.errors + uB.errors + t_err + r_errs;
        $display("  bench %0d (T_SYS=%0.2f T_SEN=%0.2f): uA rel=%0d blk=%0d ac=%0d tc=%0d | uL rel=%0d blk=%0d ac=%0d lock=%b | uB lock=%b | errors=%0d",
                 ID, T_SYS, T_SEN, uA.n_rel, uA.n_blk, uA.ac, uA.tc, uL.n_rel, uL.n_blk, uL.ac, uL.lockdown_sys, uB.lockdown_sys, errors);
        done = 1'b1;
    end
endmodule

module tb_core_t2_persist;
    wire [3:0]  d;
    wire [31:0] e0, e1, e2, e3;

    // sys faster than sen (80 / 50 MHz), sys slower than sen (30 / 50 MHz),
    // sys much faster (120 / 50 MHz) and equal frequency with an offset phase
    t2_bench #(.ID(0), .T_SYS(12.5),   .T_SEN(20.0), .PH_SEN(0.0), .WITH_T(1), .SW_MAX(`SWMAX), .SW_STEP(`SWSTEP)) b0 (.done(d[0]), .errors(e0));
    t2_bench #(.ID(1), .T_SYS(33.333), .T_SEN(20.0), .PH_SEN(3.7), .SW_MAX(`SWMAX), .SW_STEP(`SWSTEP)) b1 (.done(d[1]), .errors(e1));
    t2_bench #(.ID(2), .T_SYS(8.333),  .T_SEN(20.0), .PH_SEN(1.1), .SW_MAX(`SWMAX), .SW_STEP(`SWSTEP), .RACE(0)) b2 (.done(d[2]), .errors(e2));
    t2_bench #(.ID(3), .T_SYS(20.0),   .T_SEN(20.0), .PH_SEN(7.3), .SW_MAX(`SWMAX), .SW_STEP(`SWSTEP), .RACE(0)) b3 (.done(d[3]), .errors(e3));

    initial begin
        #400_000_000;
        $display("FAIL tb_core_t2_persist (timeout, done=%b)", d);
        $finish;
    end

    initial begin
        wait (&d);
        #100;
        if (e0 + e1 + e2 + e3 == 0) $display("PASS tb_core_t2_persist");
        else $display("FAIL tb_core_t2_persist (%0d errors)", e0 + e1 + e2 + e3);
        $finish;
    end
endmodule
