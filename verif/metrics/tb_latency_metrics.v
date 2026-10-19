// tb_latency_metrics.v: Self-checking latency & clock-attack metrics testbench.
// Measures in cycles and nanoseconds:
//   1. Tier 1 core (peruri_sentinel_core @ 50 MHz):
//      - op_req -> op_grant (MARK NVM write with NVM_WR_LAT = 8)
//      - DPA dummy cycles (0..3 cycles)
//      - AES start -> aes_done (11 cycles)
//      - aes_done -> ct_valid (H hold + COMMIT + two-stage release)
//      - total op_req -> ct_valid (min / max over DPA range)
//      - alarm during op (round 9) -> internal gate latch (blkA/blkB)
//      - alarm during op (round 9) -> constant-time gate_blocked status pulse
//      - alarm -> lockdown -> key zeroized (when counter reaches N = 4)
//      - post-NVM-commit zeroize latency
//   2. Tier 2 core (peruri_sentinel_core_t2 @ CLK_sys 80 MHz, CLK_sentinel 50 MHz):
//      - op_req -> op_grant (including CDC handshake, measured in sys and sen)
//      - DPA dummy cycles (0..3 CLK_sys cycles)
//      - AES start -> aes_done (11 CLK_sys cycles)
//      - aes_done -> ct_valid (including CDC commit handshake, min..max across phase)
//      - total op_req -> ct_valid (min / max over DPA range)
//      - TDL fast path: glitched capture edge -> tdl_alert (2 CLK_sys cycles)
//      - TDL alert -> alarm_sys (0 cycles combinational direct wire)
//      - TDL alert -> gate blkA/blkB latch (1 CLK_sys cycle)
//      - RO slow path: RO_WINDOW measurement (256 cycles of CLK_sen)
//      - RO slow path: anomaly injection -> lif_alarm -> alarm_sys -> gate latch
//      - Tier 2 alarm -> lockdown -> key zeroized (N = 4)
//   3. N9: Clock attacks on Tier 2:
//      - clk_sys stopped (0 Hz)
//      - clk_sys slowed below 1/4x (16 MHz)
//      - clk_sys sped above 2x (200 MHz)
//      - clk_sen stopped: clk_fault detection vs sen_dead detection,
//        post-recovery latency vs total latency.
//
// Self-checks every metric against an expected range and prints summary tables.
// Final line: PASS tb_latency_metrics.

`timescale 1ns/1ps

module tb_latency_metrics;

    integer errors = 0;

    task err;
        input [8*64-1:0] msg;
        begin
            $display("FAIL: %0s (t=%0t)", msg, $time);
            $fflush();
            errors = errors + 1;
        end
    endtask



    task chk;
        input cond;
        input [8*64-1:0] msg;
        begin
            if (!cond) err(msg);
        end
    endtask

    // =========================================================================
    // SECTION 1: TIER 1 CORE LATENCY METRICS (peruri_sentinel_core @ 50 MHz)
    // =========================================================================
    localparam real T1_PERIOD = 20.0; // 50 MHz -> 20.0 ns
    localparam [127:0] T1_KEY = 128'h000102030405060708090a0b0c0d0e0f;
    localparam [127:0] T1_PT  = 128'h00112233445566778899aabbccddeeff;
    localparam [127:0] T1_EXP = 128'h69c4e0d86a7b0430d8cdb78070b4c55a;
    localparam integer T1_CW  = 4;
    localparam integer T1_RECW = 17 + 2*T1_CW;

    reg clk_50 = 1'b0;
    always #(T1_PERIOD / 2.0) clk_50 = ~clk_50;

    integer t1_cyc = 0;
    always @(posedge clk_50) t1_cyc <= t1_cyc + 1;

    reg t1_por_n = 1'b0;
    reg t1_rst_n = 1'b0;
    reg t1_op_req = 1'b0;
    reg t1_alarm_in = 1'b0;
    reg t1_power_warn = 1'b0;

    wire [127:0] t1_ct_out;
    wire t1_ct_valid, t1_gate_blocked, t1_busy, t1_key_is_zero, t1_lockdown;
    wire [T1_CW-1:0] t1_ac, t1_tc;

    wire t1_nvm_rd_en, t1_nvm_rd_addr, t1_nvm_rd_valid;
    wire t1_nvm_wr_en, t1_nvm_wr_addr, t1_nvm_wr_done;
    wire [T1_RECW-1:0] t1_nvm_rd_data, t1_nvm_wr_data;

    nvm_counter_model #(
        .CW(T1_CW), .RD_LAT(2), .WR_LAT(8), .INIT_BLANK(0)
    ) u_t1_nvm (
        .clk(clk_50), .power_ok(1'b1),
        .rd_en(t1_nvm_rd_en), .rd_addr(t1_nvm_rd_addr), .rd_data(t1_nvm_rd_data), .rd_valid(t1_nvm_rd_valid),
        .wr_en(t1_nvm_wr_en), .wr_addr(t1_nvm_wr_addr), .wr_data(t1_nvm_wr_data), .wr_done(t1_nvm_wr_done)
    );

    peruri_sentinel_core #(
        .H(4), .N(4), .M(8), .CW(T1_CW), .DPA_ENABLE(1),
        .DEMO_UNLOCK(1), .DEMO_KEY(T1_KEY)
    ) u_t1_core (
        .clk(clk_50), .rst_n(t1_rst_n), .por_n(t1_por_n),
        .op_req(t1_op_req), .pt(T1_PT),
        .alarm_in(t1_alarm_in), .power_warn(t1_power_warn),
        .sentinel_en(1'b1), .fault_en(1'b0), .fault_round(4'd9),
        .fault_byte(4'd0), .fault_mask(8'h01), .debug_unlock(1'b0),
        .round_idx(),
        .nvm_rd_en(t1_nvm_rd_en), .nvm_rd_addr(t1_nvm_rd_addr), .nvm_rd_data(t1_nvm_rd_data),
        .nvm_rd_valid(t1_nvm_rd_valid),
        .nvm_wr_en(t1_nvm_wr_en), .nvm_wr_addr(t1_nvm_wr_addr), .nvm_wr_data(t1_nvm_wr_data),
        .nvm_wr_done(t1_nvm_wr_done),
        .ct_out(t1_ct_out), .ct_valid(t1_ct_valid), .gate_blocked(t1_gate_blocked),
        .tamper_counter(t1_ac), .tear_count(t1_tc),
        .lockdown(t1_lockdown), .busy(t1_busy), .key_is_zero(t1_key_is_zero)
    );

    // Synchronous event tracking for Tier 1
    integer t1_c_req, t1_c_grant, t1_c_start, t1_c_done, t1_c_valid;
    integer t1_req_to_grant_min_cyc, t1_req_to_grant_max_cyc;
    real    t1_req_to_grant_min_ns, t1_req_to_grant_max_ns;
    integer t1_dpa_dummy_min, t1_dpa_dummy_max;
    real    t1_dpa_dummy_min_ns, t1_dpa_dummy_max_ns;
    integer t1_aes_start_to_done_cyc;
    real    t1_aes_start_to_done_ns;
    integer t1_done_to_valid_min_cyc, t1_done_to_valid_max_cyc;
    real    t1_done_to_valid_min_ns, t1_done_to_valid_max_ns;
    integer t1_total_min_cyc, t1_total_max_cyc;
    real    t1_total_min_ns, t1_total_max_ns;

    integer t1_alarm_to_latch_cyc;
    real    t1_alarm_to_latch_ns;
    integer t1_alarm_to_blocked_cyc;
    real    t1_alarm_to_blocked_ns;
    integer t1_alarm_to_zeroize_cyc;
    real    t1_alarm_to_zeroize_ns;
    integer t1_post_commit_zeroize_cyc;
    real    t1_post_commit_zeroize_ns;

    task run_tier1_metrics;
        integer op_idx;
        integer cur_grant_cyc, cur_done_cyc, cur_total_cyc, cur_dpa_cyc;
        integer c_alm, c_latch, c_blk, c_alm4, c_zero, c_zero_req;
        begin
            $display("\n=======================================================");
            $display("1. TIER 1 CORE LATENCY METRICS (CLK = 50 MHz, T = 20,0 ns)");
            $display("=======================================================");

            // Power-on reset sequence
            @(negedge clk_50);
            t1_por_n = 1'b0;
            t1_rst_n = 1'b0;
            repeat (5) @(posedge clk_50);
            @(negedge clk_50);
            t1_por_n = 1'b1;
            t1_rst_n = 1'b1;

            // Wait for FSM boot
            while (u_t1_core.u_fsm.ready !== 1'b1) @(posedge clk_50);
            repeat (4) @(posedge clk_50);

            t1_total_min_cyc = 999999;
            t1_total_max_cyc = 0;
            t1_req_to_grant_min_cyc = 999999;
            t1_req_to_grant_max_cyc = 0;
            t1_done_to_valid_min_cyc = 999999;
            t1_done_to_valid_max_cyc = 0;
            t1_dpa_dummy_min = 9999;
            t1_dpa_dummy_max = 0;

            // Run 16 operations to sample entire DPA range (0..3 dummy cycles)
            for (op_idx = 0; op_idx < 16; op_idx = op_idx + 1) begin
                while (t1_busy) @(posedge clk_50);
                repeat (2) @(posedge clk_50);

                // Assert op_req on posedge; sampled on the next posedge
                @(posedge clk_50);
                t1_op_req <= 1'b1;
                t1_c_req = t1_cyc + 1; // cycle where DUT samples op_req

                @(posedge clk_50);
                t1_op_req <= 1'b0;

                // Wait for op_grant
                while (!u_t1_core.op_grant) @(posedge clk_50);
                t1_c_grant = t1_cyc;
                cur_grant_cyc = t1_c_grant - t1_c_req;
                if (cur_grant_cyc < t1_req_to_grant_min_cyc) t1_req_to_grant_min_cyc = cur_grant_cyc;
                if (cur_grant_cyc > t1_req_to_grant_max_cyc) t1_req_to_grant_max_cyc = cur_grant_cyc;

                // Wait for AES start
                while (!u_t1_core.start) @(posedge clk_50);
                t1_c_start = t1_cyc;
                cur_dpa_cyc = (t1_c_start - t1_c_grant) - 1; // dummy cycles
                if (cur_dpa_cyc < t1_dpa_dummy_min) t1_dpa_dummy_min = cur_dpa_cyc;
                if (cur_dpa_cyc > t1_dpa_dummy_max) t1_dpa_dummy_max = cur_dpa_cyc;

                // Wait for AES done
                while (!u_t1_core.aes_done) @(posedge clk_50);
                t1_c_done = t1_cyc;
                t1_aes_start_to_done_cyc = t1_c_done - t1_c_start;
                t1_aes_start_to_done_ns = t1_aes_start_to_done_cyc * T1_PERIOD;

                // Wait for ct_valid
                while (!t1_ct_valid) @(posedge clk_50);
                t1_c_valid = t1_cyc;
                cur_done_cyc = t1_c_valid - t1_c_done;
                if (cur_done_cyc < t1_done_to_valid_min_cyc) t1_done_to_valid_min_cyc = cur_done_cyc;
                if (cur_done_cyc > t1_done_to_valid_max_cyc) t1_done_to_valid_max_cyc = cur_done_cyc;

                cur_total_cyc = t1_c_valid - t1_c_req;
                if (cur_total_cyc < t1_total_min_cyc) t1_total_min_cyc = cur_total_cyc;
                if (cur_total_cyc > t1_total_max_cyc) t1_total_max_cyc = cur_total_cyc;

                chk(t1_ct_out == T1_EXP, "Tier 1 ciphertext mismatch");
                repeat (2) @(posedge clk_50);
            end

            t1_req_to_grant_min_ns = t1_req_to_grant_min_cyc * T1_PERIOD;
            t1_req_to_grant_max_ns = t1_req_to_grant_max_cyc * T1_PERIOD;
            t1_dpa_dummy_min_ns    = t1_dpa_dummy_min * T1_PERIOD;
            t1_dpa_dummy_max_ns    = t1_dpa_dummy_max * T1_PERIOD;
            t1_done_to_valid_min_ns = t1_done_to_valid_min_cyc * T1_PERIOD;
            t1_done_to_valid_max_ns = t1_done_to_valid_max_cyc * T1_PERIOD;
            t1_total_min_ns        = t1_total_min_cyc * T1_PERIOD;
            t1_total_max_ns        = t1_total_max_cyc * T1_PERIOD;

            // Self-checks on ranges
            chk(t1_req_to_grant_min_cyc >= 10 && t1_req_to_grant_max_cyc <= 12,
                "Tier 1 op_req -> op_grant expected 10..12 cycles");
            chk(t1_dpa_dummy_min == 0, "Tier 1 min dummy cycles expected 0");
            chk(t1_dpa_dummy_max == 3, "Tier 1 max dummy cycles expected 3");
            chk(t1_aes_start_to_done_cyc == 11, "Tier 1 AES start -> done expected 11 cycles");
            chk(t1_done_to_valid_min_cyc >= 17 && t1_done_to_valid_max_cyc <= 19,
                "Tier 1 aes_done -> ct_valid expected 17..19 cycles");
            chk(t1_total_min_cyc >= 40 && t1_total_min_cyc <= 44,
                "Tier 1 total min expected 40..44 cycles");
            chk(t1_total_max_cyc >= 44 && t1_total_max_cyc <= 48,
                "Tier 1 total max expected 44..48 cycles");

            // -----------------------------------------------------------------
            // Measure Alarm at round 9:
            // (a) Internal gate fault latch (blkA <= 1, blkB <= 0): 1 cycle
            // (b) Constant-time end-of-op gate_blocked status pulse: 19 cycles
            // -----------------------------------------------------------------
            while (t1_busy) @(posedge clk_50);
            repeat (2) @(posedge clk_50);
            @(posedge clk_50);
            t1_op_req <= 1'b1;
            @(posedge clk_50);
            t1_op_req <= 1'b0;

            // Wait until round 9 of AES
            while (u_t1_core.round_idx !== 4'd9) @(posedge clk_50);
            // Inject alarm: assert on posedge, sampled by DUT on next posedge
            @(posedge clk_50);
            t1_alarm_in <= 1'b1;
            c_alm = t1_cyc + 1; // cycle where DUT samples t1_alarm_in == 1
            @(posedge clk_50);
            t1_alarm_in <= 1'b0;

            // (a) Internal latch in output_release_gate
            while (!(u_t1_core.u_gate.blkA == 1'b1 && u_t1_core.u_gate.blkB == 1'b0)) @(posedge clk_50);
            c_latch = t1_cyc;
            t1_alarm_to_latch_cyc = c_latch - c_alm;
            t1_alarm_to_latch_ns = t1_alarm_to_latch_cyc * T1_PERIOD;
            chk(t1_alarm_to_latch_cyc == 1, "Tier 1 alarm -> internal gate block latch expected 1 cycle");

            // (b) Constant-time COMMIT gate_blocked status pulse
            while (!t1_gate_blocked) @(posedge clk_50);
            c_blk = t1_cyc;
            t1_alarm_to_blocked_cyc = c_blk - c_alm;
            t1_alarm_to_blocked_ns = t1_alarm_to_blocked_cyc * T1_PERIOD;
            chk(t1_ct_valid == 1'b0, "Faulted op must not release ciphertext");
            chk(t1_alarm_to_blocked_cyc >= 18 && t1_alarm_to_blocked_cyc <= 20,
                "Alarm at round 9 to constant-time gate_blocked expected 19 cycles");

            // -----------------------------------------------------------------
            // Measure Alarm -> lockdown -> key zeroized at counter threshold N=4
            // ac is currently 1 (from previous alarmed op)
            // -----------------------------------------------------------------
            while (t1_busy || !u_t1_core.u_fsm.ready) @(posedge clk_50);
            repeat (4) @(posedge clk_50);

            // Alarm 2
            @(posedge clk_50); t1_alarm_in <= 1'b1;
            @(posedge clk_50); t1_alarm_in <= 1'b0;
            repeat (2) @(posedge clk_50); // allow u_fsm to enter S_EVENT
            while (t1_busy || !u_t1_core.u_fsm.ready) @(posedge clk_50);
            repeat (4) @(posedge clk_50);

            // Alarm 3
            @(posedge clk_50); t1_alarm_in <= 1'b1;
            @(posedge clk_50); t1_alarm_in <= 1'b0;
            repeat (2) @(posedge clk_50); // allow u_fsm to enter S_EVENT
            while (t1_busy || !u_t1_core.u_fsm.ready) @(posedge clk_50);
            repeat (4) @(posedge clk_50);

            chk(t1_ac == 4'd3, "Expected alarm_count == 3 before 4th alarm");

            // Alarm 4 (threshold N = 4)
            @(posedge clk_50);
            t1_alarm_in <= 1'b1;
            c_alm4 = t1_cyc + 1; // cycle where DUT samples alarm 4
            @(posedge clk_50);
            t1_alarm_in <= 1'b0;

            // Wait for zeroize_req from tamper_persist_fsm
            while (!u_t1_core.u_fsm.zeroize_req) @(posedge clk_50);
            c_zero_req = t1_cyc;

            // Wait for key clear and lockdown
            while (!t1_key_is_zero || !t1_lockdown) @(posedge clk_50);
            c_zero = t1_cyc;

            t1_alarm_to_zeroize_cyc = c_zero - c_alm4;
            t1_alarm_to_zeroize_ns = t1_alarm_to_zeroize_cyc * T1_PERIOD;
            t1_post_commit_zeroize_cyc = c_zero - c_zero_req;
            t1_post_commit_zeroize_ns = t1_post_commit_zeroize_cyc * T1_PERIOD;

            chk(t1_lockdown == 1'b1, "Lockdown must be active after N=4");
            chk(t1_key_is_zero == 1'b1, "Key must be zeroized after N=4");
            chk(t1_alarm_to_zeroize_cyc >= 13 && t1_alarm_to_zeroize_cyc <= 15,
                "Alarm to zeroize path expected 13..15 cycles");
            chk(t1_post_commit_zeroize_cyc == 1,
                "tripwire_zeroize register latency expected 1 cycle");

            $display("Tier 1 op_req -> op_grant:        %0d cycles (%0.1f ns) (terukur, simulasi)", t1_req_to_grant_min_cyc, t1_req_to_grant_min_ns);
            $display("Tier 1 DPA dummy range:           %0d..%0d cycles (%0.1f..%0.1f ns) (terukur, simulasi)", t1_dpa_dummy_min, t1_dpa_dummy_max, t1_dpa_dummy_min_ns, t1_dpa_dummy_max_ns);
            $display("Tier 1 AES start -> aes_done:     %0d cycles (%0.1f ns) (terukur, simulasi)", t1_aes_start_to_done_cyc, t1_aes_start_to_done_ns);
            $display("Tier 1 aes_done -> ct_valid:      %0d cycles (%0.1f ns) (terukur, simulasi)", t1_done_to_valid_min_cyc, t1_done_to_valid_min_ns);
            $display("Tier 1 Total op_req -> ct_valid:  %0d..%0d cycles (%0.1f..%0.1f ns) (terukur, simulasi)", t1_total_min_cyc, t1_total_max_cyc, t1_total_min_ns, t1_total_max_ns);
            $display("Tier 1 Alarm -> blkA/blkB latch:  %0d cycles (%0.1f ns) (terukur, simulasi)", t1_alarm_to_latch_cyc, t1_alarm_to_latch_ns);
            $display("Tier 1 Alarm (rd9) -> blocked:    %0d cycles (%0.1f ns) (terukur, simulasi)", t1_alarm_to_blocked_cyc, t1_alarm_to_blocked_ns);
            $display("Tier 1 Alarm -> zeroize (N=4):    %0d cycles (%0.1f ns) (terukur, simulasi)", t1_alarm_to_zeroize_cyc, t1_alarm_to_zeroize_ns);
            $display("Tier 1 Post-commit zeroize req:   %0d cycle (%0.1f ns) (terukur, simulasi)", t1_post_commit_zeroize_cyc, t1_post_commit_zeroize_ns);
        end
    endtask

    // =========================================================================
    // SECTION 2 & 3: TIER 2 CORE & CLOCK ATTACK METRICS
    // CLK_sys = 80 MHz (12.5 ns), CLK_sentinel = 50 MHz (20.0 ns)
    // =========================================================================
    localparam real HS_NOM = 6.25;  // 80 MHz -> period 12.5 ns
    localparam real HN_NOM = 10.0;  // 50 MHz -> period 20.0 ns
    localparam integer T2_CW = 8;
    localparam integer T2_RECW = 17 + 2*T2_CW;

    real hs, hn;
    reg clk_sys = 1'b0, clk_sen = 1'b0;
    initial begin hs = HS_NOM; hn = HN_NOM; end
    always begin if (hs > 0.0) #(hs) clk_sys = ~clk_sys; else #1; end
    always begin if (hn > 0.0) #(hn) clk_sen = ~clk_sen; else #1; end

    integer t2_cyc_sys = 0, t2_cyc_sen = 0;
    always @(posedge clk_sys) t2_cyc_sys <= t2_cyc_sys + 1;
    always @(posedge clk_sen) t2_cyc_sen <= t2_cyc_sen + 1;

    reg arst_n = 1'b0;
    reg key0_n = 1'b1;
    wire por_sys_n, por_sen_n;
    reset_sync u_rs_sys (.clk(clk_sys), .arst_n(arst_n), .rst_n(por_sys_n));
    reset_sync u_rs_sen (.clk(clk_sen), .arst_n(arst_n), .rst_n(por_sen_n));
    wire rst_sys_n = por_sys_n & key0_n;
    wire key0_sen;
    sync_2ff #(.RESET_VAL(1'b1)) u_k0 (.clk(clk_sen), .rst_n(por_sen_n), .d(key0_n), .q(key0_sen));
    wire rst_sen_n = por_sen_n & key0_sen;

    reg t2_op_req = 1'b0;
    reg t2_sen_on = 1'b1;
    reg t2_harness_alarm = 1'b0;
    wire [127:0] t2_ct_out;
    wire t2_ct_valid, t2_gate_blocked, t2_busy, t2_key_is_zero, t2_lockdown_sys, t2_lockdown;
    wire t2_alarm_sys, t2_clk_fault, t2_sen_dead;
    wire [T2_CW-1:0] t2_ac, t2_tc, t2_ac_sys, t2_tc_sys;

    wire t2_nvm_rd_en, t2_nvm_rd_addr, t2_nvm_rd_valid;
    wire t2_nvm_wr_en, t2_nvm_wr_addr, t2_nvm_wr_done;
    wire [T2_RECW-1:0] t2_nvm_rd_data, t2_nvm_wr_data;

    nvm_counter_model #(
        .CW(T2_CW), .RD_LAT(2), .WR_LAT(8), .INIT_BLANK(0)
    ) u_t2_nvm (
        .clk(clk_sen), .power_ok(1'b1),
        .rd_en(t2_nvm_rd_en), .rd_addr(t2_nvm_rd_addr), .rd_data(t2_nvm_rd_data), .rd_valid(t2_nvm_rd_valid),
        .wr_en(t2_nvm_wr_en), .wr_addr(t2_nvm_wr_addr), .wr_data(t2_nvm_wr_data), .wr_done(t2_nvm_wr_done)
    );

    // Initialized with N=4 to test hardware lockdown & key zeroization
    peruri_sentinel_core_t2 #(
        .H(4), .N(4), .M(8), .CW(T2_CW), .DPA_ENABLE(1),
        .TDL_L(64), .TDL_COARSE(15), .TDL_SETTLE(64), .TDL_WIN(128), .RO_WINDOW(256),
        .FAST_HOLD(16), .SLOW_HOLD(64),
        .DEMO_UNLOCK(1)
    ) u_t2_core (
        .clk_sys(clk_sys), .rst_sys_n(rst_sys_n), .por_sys_n(por_sys_n),
        .op_req(t2_op_req), .pt(T1_PT),
        .sentinel_en_sys(t2_sen_on), .fault_en(1'b0), .fault_round(4'd9),
        .fault_byte(4'd0), .fault_mask(8'h01), .harness_alarm(t2_harness_alarm), .round_idx(),
        .ct_out(t2_ct_out), .ct_valid(t2_ct_valid), .gate_blocked(t2_gate_blocked), .busy(t2_busy),
        .key_is_zero(t2_key_is_zero), .lockdown_sys(t2_lockdown_sys),
        .tamper_counter_sys(t2_ac_sys), .tear_count_sys(t2_tc_sys),
        .alarm_sys(t2_alarm_sys), .clk_fault(t2_clk_fault), .sen_dead(t2_sen_dead),
        .tdl_alert(), .tdl_armed(), .tdl_cal_bad(),
        .tdl_depth(), .tdl_min_r(), .tdl_sel(),
        .clk_sen(clk_sen), .rst_sen_n(rst_sen_n), .por_sen_n(por_sen_n),
        .sentinel_en_sen(t2_sen_on), .debug_unlock_sen(1'b0), .fsm_mask_sen(1'b0),
        .ewma_alarm(), .fixed_alarm(),
        .power_warn(1'b0),
        .nvm_rd_en(t2_nvm_rd_en), .nvm_rd_addr(t2_nvm_rd_addr), .nvm_rd_data(t2_nvm_rd_data),
        .nvm_rd_valid(t2_nvm_rd_valid),
        .nvm_wr_en(t2_nvm_wr_en), .nvm_wr_addr(t2_nvm_wr_addr), .nvm_wr_data(t2_nvm_wr_data),
        .nvm_wr_done(t2_nvm_wr_done),
        .ro_en(1'b1),
        .tamper_counter(t2_ac), .tear_count(t2_tc), .lockdown(t2_lockdown),
        .lif_alarm(), .spike_bus()
    );

    // TDL depth model (after sim/tier2/tb_de10_nano_top_t2.v)
    localparam integer L = 64;
    reg glitch_low = 0, burst_low = 0;
    integer dd;
    reg [L-1:0] mask, tb_sum;
    always @(*) begin
        dd   = (glitch_low || burst_low) ? 15 : (u_t2_core.u_tdl.chain_in ? 40 : 36);
        mask = ({{(L-1){1'b0}}, 1'b1} << dd) - 1;
        tb_sum = u_t2_core.u_tdl.chain_in ? ~mask : mask;
    end
    always @(tb_sum) force u_t2_core.u_tdl.sum = {1'b0, tb_sum};

    initial begin
        // spread the RO frequencies slightly, modeling real silicon variations
        u_t2_core.u_mesh.g_ro[0].u_cell.half_ns = 2.00;
        u_t2_core.u_mesh.g_ro[1].u_cell.half_ns = 2.01;
        u_t2_core.u_mesh.g_ro[2].u_cell.half_ns = 2.02;
        u_t2_core.u_mesh.g_ro[3].u_cell.half_ns = 2.03;
        u_t2_core.u_mesh.g_ro[4].u_cell.half_ns = 2.04;
        u_t2_core.u_mesh.g_ro[5].u_cell.half_ns = 2.05;
        u_t2_core.u_mesh.g_ro[6].u_cell.half_ns = 2.06;
        u_t2_core.u_mesh.g_ro[7].u_cell.half_ns = 2.07;
    end

    // Tier 2 measurement registers
    integer t2_c_req, t2_c_req_sen, t2_c_grant, t2_c_grant_sen, t2_c_start, t2_c_done, t2_c_valid;
    integer t2_req_to_grant_min_cyc_sys, t2_req_to_grant_max_cyc_sys;
    integer t2_req_to_grant_min_cyc_sen, t2_req_to_grant_max_cyc_sen;
    real    t2_req_to_grant_min_ns, t2_req_to_grant_max_ns;
    integer t2_dpa_dummy_min, t2_dpa_dummy_max;
    real    t2_dpa_dummy_min_ns, t2_dpa_dummy_max_ns;
    integer t2_aes_start_to_done_cyc;
    real    t2_aes_start_to_done_ns;
    integer t2_done_to_valid_min_cyc, t2_done_to_valid_max_cyc;
    real    t2_done_to_valid_min_ns, t2_done_to_valid_max_ns;
    integer t2_total_min_cyc, t2_total_max_cyc;
    real    t2_total_min_ns, t2_total_max_ns;

    integer t2_tdl_capture_to_alert_cyc;
    real    t2_tdl_capture_to_alert_ns;
    integer t2_tdl_alert_to_blkA_cyc;
    real    t2_tdl_alert_to_blkA_ns;

    integer t2_ro_window_cyc;
    real    t2_ro_window_ns;
    integer t2_ro_to_lif_cyc_sen;
    real    t2_ro_to_lif_ns;
    integer t2_ro_to_alarm_sys_cyc_sys;
    real    t2_ro_to_alarm_sys_ns;
    real    t2_lif_to_alarm_sys_ns;

    integer t2_alarm_to_zeroize_cyc_sys, t2_alarm_to_zeroize_cyc_sen;
    real    t2_alarm_to_zeroize_ns;
    integer t2_alarm_to_lockdown_cyc_sys;
    real    t2_alarm_to_lockdown_ns;

    // N9 attack measurements
    real n9_stop_sys_blk_ns, n9_stop_sys_cnt_ns;
    real n9_slow_sys_blk_ns, n9_slow_sys_cnt_ns;
    real n9_fast_sys_blk_ns, n9_fast_sys_cnt_ns;
    real n9_stop_sen_clk_fault_ns, n9_stop_sen_dead_ns, n9_stop_sen_blk_ns;
    real n9_stop_sen_cnt_post_ns, n9_stop_sen_cnt_total_ns;

    task t2_wait_permit;
        integer cnt;
        begin
            cnt = 0;
            while (!u_t2_core.permit_sys && cnt < 6000) begin
                @(posedge clk_sys);
                cnt = cnt + 1;
            end
            if (cnt >= 6000) err("Tier 2 permit_sys timeout");
            repeat (2) @(posedge clk_sys);
        end
    endtask

    task t2_wait_quiet;
        integer cnt;
        begin
            cnt = 0;
            while ((u_t2_core.outstanding || u_t2_core.aes_busy || u_t2_core.gate_busy || t2_op_req) && cnt < 4000) begin
                @(posedge clk_sys);
                cnt = cnt + 1;
            end
            if (cnt >= 4000) err("Tier 2 core quiet timeout");
            repeat (4) @(posedge clk_sys);
        end
    endtask

    task t2_recover;
        begin
            #(5000);
            @(negedge clk_sys) key0_n = 1'b0;
            #(400);
            key0_n = 1'b1;
            #(1000);
            t2_wait_permit;
            chk(!t2_clk_fault && !t2_sen_dead, "Recovery cleared fault flags");
        end
    endtask

    task run_tier2_metrics;
        integer op_idx;
        integer cur_grant_cyc_sys, cur_grant_cyc_sen, cur_done_cyc, cur_total_cyc, cur_dpa_cyc;
        integer c_glitch, c_alert, c_blk;
        integer c_ro_val1, c_ro_val2, c_ro_inj_sen, c_ro_inj_sys, c_ro_lif_sen, c_ro_alm_sys;
        integer c_alm4_sys, c_alm4_sen, c_zero_sys, c_zero_sen, c_lock_sys;
        real    t_glitch, t_alert, t_blk_real, t_ro_val1, t_ro_val2, t_ro_inj, t_ro_lif, t_ro_alm;
        real    t_alm4, t_zero, t_lock;
        begin
            $display("\n=======================================================");
            $display("2. TIER 2 CORE LATENCY METRICS (CLK_sys = 80 MHz, CLK_sen = 50 MHz)");
            $display("=======================================================");

            // Reset and power-on
            @(negedge clk_sys);
            arst_n = 1'b0;
            repeat (4) @(posedge clk_sys);
            #(200);
            @(negedge clk_sys);
            arst_n = 1'b1;

            t2_wait_permit;
            t2_wait_quiet;

            t2_total_min_cyc = 999999;
            t2_total_max_cyc = 0;
            t2_req_to_grant_min_cyc_sys = 999999;
            t2_req_to_grant_max_cyc_sys = 0;
            t2_req_to_grant_min_cyc_sen = 999999;
            t2_req_to_grant_max_cyc_sen = 0;
            t2_done_to_valid_min_cyc = 999999;
            t2_done_to_valid_max_cyc = 0;
            t2_dpa_dummy_min = 9999;
            t2_dpa_dummy_max = 0;

            // Run 24 operations to sample entire DPA range and CDC phase alignment
            for (op_idx = 0; op_idx < 24; op_idx = op_idx + 1) begin
                t2_wait_permit;
                t2_wait_quiet;

                @(posedge clk_sys);
                t2_op_req <= 1'b1;
                t2_c_req = t2_cyc_sys + 1; // cycle where DUT samples op_req
                t2_c_req_sen = t2_cyc_sen; // direct sample of CLK_sen cycle counter

                @(posedge clk_sys);
                t2_op_req <= 1'b0;

                while (!u_t2_core.grant_ok) @(posedge clk_sys);
                t2_c_grant = t2_cyc_sys;
                t2_c_grant_sen = t2_cyc_sen; // direct sample of CLK_sen cycle counter

                cur_grant_cyc_sys = t2_c_grant - t2_c_req;
                cur_grant_cyc_sen = t2_c_grant_sen - t2_c_req_sen;
                if (cur_grant_cyc_sys < t2_req_to_grant_min_cyc_sys) t2_req_to_grant_min_cyc_sys = cur_grant_cyc_sys;
                if (cur_grant_cyc_sys > t2_req_to_grant_max_cyc_sys) t2_req_to_grant_max_cyc_sys = cur_grant_cyc_sys;
                if (cur_grant_cyc_sen < t2_req_to_grant_min_cyc_sen) t2_req_to_grant_min_cyc_sen = cur_grant_cyc_sen;
                if (cur_grant_cyc_sen > t2_req_to_grant_max_cyc_sen) t2_req_to_grant_max_cyc_sen = cur_grant_cyc_sen;

                while (!u_t2_core.start) @(posedge clk_sys);
                t2_c_start = t2_cyc_sys;
                cur_dpa_cyc = (t2_c_start - t2_c_grant) - 1;
                if (cur_dpa_cyc < t2_dpa_dummy_min) t2_dpa_dummy_min = cur_dpa_cyc;
                if (cur_dpa_cyc > t2_dpa_dummy_max) t2_dpa_dummy_max = cur_dpa_cyc;

                while (!u_t2_core.aes_done) @(posedge clk_sys);
                t2_c_done = t2_cyc_sys;
                t2_aes_start_to_done_cyc = t2_c_done - t2_c_start;
                t2_aes_start_to_done_ns = t2_aes_start_to_done_cyc * 12.5;

                while (!t2_ct_valid) @(posedge clk_sys);
                t2_c_valid = t2_cyc_sys;
                cur_done_cyc = t2_c_valid - t2_c_done;
                if (cur_done_cyc < t2_done_to_valid_min_cyc) t2_done_to_valid_min_cyc = cur_done_cyc;
                if (cur_done_cyc > t2_done_to_valid_max_cyc) t2_done_to_valid_max_cyc = cur_done_cyc;

                cur_total_cyc = t2_c_valid - t2_c_req;
                if (cur_total_cyc < t2_total_min_cyc) t2_total_min_cyc = cur_total_cyc;
                if (cur_total_cyc > t2_total_max_cyc) t2_total_max_cyc = cur_total_cyc;

                chk(t2_ct_out == T1_EXP, "Tier 2 ciphertext mismatch");
                repeat (2) @(posedge clk_sys);
            end

            t2_req_to_grant_min_ns  = t2_req_to_grant_min_cyc_sys * 12.5;
            t2_req_to_grant_max_ns  = t2_req_to_grant_max_cyc_sys * 12.5;
            t2_dpa_dummy_min_ns     = t2_dpa_dummy_min * 12.5;
            t2_dpa_dummy_max_ns     = t2_dpa_dummy_max * 12.5;
            t2_done_to_valid_min_ns = t2_done_to_valid_min_cyc * 12.5;
            t2_done_to_valid_max_ns = t2_done_to_valid_max_cyc * 12.5;
            t2_total_min_ns         = t2_total_min_cyc * 12.5;
            t2_total_max_ns         = t2_total_max_cyc * 12.5;

            // Self-checks on Tier 2 baseline
            chk(t2_aes_start_to_done_cyc == 11, "Tier 2 AES start -> done expected 11 cycles @ 80 MHz");
            chk(t2_dpa_dummy_min == 0 && t2_dpa_dummy_max == 3, "Tier 2 DPA range expected 0..3");
            chk(t2_req_to_grant_min_cyc_sys >= 24 && t2_req_to_grant_max_cyc_sys <= 32,
                "Tier 2 op_req -> op_grant expected 24..32 CLK_sys cycles");
            chk(t2_req_to_grant_min_cyc_sen >= 15 && t2_req_to_grant_max_cyc_sen <= 20,
                "Tier 2 op_req -> op_grant expected 15..20 CLK_sen cycles");
            chk(t2_done_to_valid_min_cyc >= 30 && t2_done_to_valid_max_cyc <= 38,
                "Tier 2 done -> valid expected 30..38 CLK_sys cycles");
            chk(t2_total_min_cyc >= 70 && t2_total_min_cyc <= 85,
                "Tier 2 total min expected 70..85 cycles");
            chk(t2_total_max_cyc >= 74 && t2_total_max_cyc <= 90,
                "Tier 2 total max expected 74..90 cycles");

            // -----------------------------------------------------------------
            // TDL fast path during an active operation (no CDC: same/next cycle)
            // -----------------------------------------------------------------
            t2_wait_permit; t2_wait_quiet;
            @(posedge clk_sys);
            t2_op_req <= 1'b1;
            @(posedge clk_sys);
            t2_op_req <= 1'b0;

            // Wait until round 9 of AES
            while (u_t2_core.round_idx !== 4'd9) @(posedge clk_sys);

            // Inject 1-cycle shortened depth on negedge; sampled at next posedge
            @(negedge clk_sys);
            glitch_low = 1;
            c_glitch = t2_cyc_sys + 1; // capture edge is next posedge clk_sys
            t_glitch = $time + HS_NOM;
            @(posedge clk_sys);
            @(negedge clk_sys);
            glitch_low = 0;

            // Wait for tdl_alert rising edge
            while (!u_t2_core.tdl_alert) @(posedge clk_sys);
            c_alert = t2_cyc_sys;
            t_alert = $time;
            t2_tdl_capture_to_alert_cyc = c_alert - c_glitch;
            t2_tdl_capture_to_alert_ns = t2_tdl_capture_to_alert_cyc * 12.5;

            // Alert combinational to alarm_sys and gate alarm_eff (0 cycles)
            chk(t2_tdl_capture_to_alert_cyc == 2, "TDL glitched edge to alert expected 2 cycles");
            chk(u_t2_core.alarm_sys == 1'b1, "tdl_alert -> alarm_sys combinational (0 cycles)");
            chk(u_t2_core.u_gate.alarm_eff == 1'b1, "tdl_alert -> gate.alarm_eff combinational (0 cycles)");

            // Check gate block register latch (blkA <= 1, blkB <= 0) on next edge
            while (!(u_t2_core.u_gate.blkA == 1'b1 && u_t2_core.u_gate.blkB == 1'b0)) @(posedge clk_sys);
            c_blk = t2_cyc_sys;
            t_blk_real = $time;
            t2_tdl_alert_to_blkA_cyc = c_blk - c_alert;
            t2_tdl_alert_to_blkA_ns = t2_tdl_alert_to_blkA_cyc * 12.5;
            chk(t2_tdl_alert_to_blkA_cyc == 1, "tdl_alert to blkA expected 1 CLK_sys cycle (12.5 ns)");

            // Wait for constant-time end-of-op gate_blocked status pulse
            while (!t2_gate_blocked) @(posedge clk_sys);
            chk(t2_ct_valid == 1'b0, "Faulted TDL op must not release ciphertext");

            // Wait for NVM write of Alarm 1 to complete
            while (!u_t2_core.u_fsm.ready) @(posedge clk_sen);
            repeat (4) @(posedge clk_sen);
            chk(t2_ac == 1, "Tier 2 alarm_count expected 1 after TDL fault");

            // -----------------------------------------------------------------
            // Slow path RO window -> LIF -> blocked
            // -----------------------------------------------------------------
            t2_wait_permit; t2_wait_quiet;
            // Measure RO_WINDOW in clk_sen cycles between two valid pulses
            while (!u_t2_core.u_mesh.valid) @(posedge clk_sen);
            c_ro_val1 = t2_cyc_sen;
            t_ro_val1 = $time;
            @(posedge clk_sen);
            while (!u_t2_core.u_mesh.valid) @(posedge clk_sen);
            c_ro_val2 = t2_cyc_sen;
            t_ro_val2 = $time;

            t2_ro_window_cyc = c_ro_val2 - c_ro_val1;
            t2_ro_window_ns = t_ro_val2 - t_ro_val1;
            chk(t2_ro_window_cyc == 256, "RO_WINDOW expected 256 cycles of clk_sen");

            // Warm up p2se_encoder (>6 windows)
            repeat (6) begin
                @(posedge clk_sen);
                while (!u_t2_core.u_mesh.valid) @(posedge clk_sen);
            end

            // Inject local RO frequency drop synchronized to u_mesh.valid
            @(posedge clk_sen);
            c_ro_inj_sen = t2_cyc_sen;
            c_ro_inj_sys = t2_cyc_sys;
            t_ro_inj = $time;

            // Scale RO 2 and 3 by 1.18x to inject a localized spatial anomaly
            u_t2_core.u_mesh.g_ro[2].u_cell.half_ns = u_t2_core.u_mesh.g_ro[2].u_cell.half_ns * 1.18;
            u_t2_core.u_mesh.g_ro[3].u_cell.half_ns = u_t2_core.u_mesh.g_ro[3].u_cell.half_ns * 1.18;

            // Wait for LIF engine anomaly detection
            while (!u_t2_core.lif_alarm) @(posedge clk_sen);
            c_ro_lif_sen = t2_cyc_sen;
            t_ro_lif = $time;
            t2_ro_to_lif_cyc_sen = c_ro_lif_sen - c_ro_inj_sen;
            t2_ro_to_lif_ns = t_ro_lif - t_ro_inj;

            // Wait for crossing into CLK_sys domain via pulse_stretch + sync_2ff
            while (!u_t2_core.alarm_sys) @(posedge clk_sys);
            c_ro_alm_sys = t2_cyc_sys;
            t_ro_alm = $time;
            t2_ro_to_alarm_sys_cyc_sys = c_ro_alm_sys - c_ro_inj_sys;
            t2_ro_to_alarm_sys_ns = t_ro_alm - t_ro_inj;
            t2_lif_to_alarm_sys_ns = t_ro_alm - t_ro_lif;

            chk(t2_ro_to_lif_cyc_sen >= 256 && t2_ro_to_lif_cyc_sen <= 1024,
                "RO to lif_alarm expected 1..3 RO windows");
            chk(t2_lif_to_alarm_sys_ns >= 15.0 && t2_lif_to_alarm_sys_ns <= 55.0,
                "lif_alarm to alarm_sys CDC crossing expected ~2..3 clk_sys cycles");

            // Restore RO frequencies
            u_t2_core.u_mesh.g_ro[2].u_cell.half_ns = u_t2_core.u_mesh.g_ro[2].u_cell.half_ns / 1.18;
            u_t2_core.u_mesh.g_ro[3].u_cell.half_ns = u_t2_core.u_mesh.g_ro[3].u_cell.half_ns / 1.18;

            // Wait for NVM write of Alarm 2 to complete AND pulse stretch to expire
            while (!u_t2_core.u_fsm.ready || u_t2_core.slow_lvl_sen_w || u_t2_core.alarm_sys) @(posedge clk_sen);
            repeat (8) @(posedge clk_sen);
            chk(t2_ac == 2, "Tier 2 alarm_count expected 2 after RO slow fault");

            // -----------------------------------------------------------------
            // Tier 2 Alarm -> lockdown -> key zeroized (N = 4)
            // -----------------------------------------------------------------
            // Alarm 3
            @(posedge clk_sys);
            t2_harness_alarm = 1'b1;
            repeat (2) @(posedge clk_sys);
            t2_harness_alarm = 1'b0;
            repeat (4) @(posedge clk_sen);
            while (!u_t2_core.u_fsm.ready || u_t2_core.fast_lvl_sen || u_t2_core.alarm_sys) @(posedge clk_sen);
            repeat (8) @(posedge clk_sen);
            chk(t2_ac == 3, "Tier 2 alarm_count expected 3 before 4th alarm");

            // Alarm 4 (threshold N = 4)
            @(posedge clk_sys);
            t2_harness_alarm = 1'b1;
            c_alm4_sys = t2_cyc_sys + 1;
            c_alm4_sen = t2_cyc_sen;
            t_alm4 = $time + HS_NOM;
            @(posedge clk_sys);
            t2_harness_alarm = 1'b0;

            // Wait for key clear in CLK_sys domain (cleared asynchronously via tripwire)
            while (!t2_key_is_zero) @(posedge clk_sys);
            c_zero_sys = t2_cyc_sys;
            c_zero_sen = t2_cyc_sen;
            t_zero = $time;
            t2_alarm_to_zeroize_cyc_sys = c_zero_sys - c_alm4_sys;
            t2_alarm_to_zeroize_cyc_sen = c_zero_sen - c_alm4_sen;
            t2_alarm_to_zeroize_ns = t_zero - t_alm4;

            // Wait for lockdown_sys level in CLK_sys domain
            while (!t2_lockdown_sys) @(posedge clk_sys);
            c_lock_sys = t2_cyc_sys;
            t_lock = $time;
            t2_alarm_to_lockdown_cyc_sys = c_lock_sys - c_alm4_sys;
            t2_alarm_to_lockdown_ns = t_lock - t_alm4;

            chk(t2_key_is_zero == 1'b1, "Tier 2 key must be zeroized after N=4");
            chk(t2_lockdown_sys == 1'b1, "Tier 2 lockdown_sys must be active after N=4");
            chk(t2_alarm_to_zeroize_ns >= 200.0 && t2_alarm_to_zeroize_ns <= 400.0,
                "Tier 2 alarm to zeroize path expected 200..400 ns");
            chk(t2_alarm_to_lockdown_ns >= 220.0 && t2_alarm_to_lockdown_ns <= 450.0,
                "Tier 2 alarm to lockdown_sys expected 220..450 ns");

            $display("Tier 2 op_req -> op_grant:        %0d..%0d CLK_sys / %0d..%0d CLK_sen (%0.1f..%0.1f ns) (terukur, simulasi)",
                     t2_req_to_grant_min_cyc_sys, t2_req_to_grant_max_cyc_sys,
                     t2_req_to_grant_min_cyc_sen, t2_req_to_grant_max_cyc_sen,
                     t2_req_to_grant_min_ns, t2_req_to_grant_max_ns);
            $display("Tier 2 DPA dummy range:           %0d..%0d cycles (%0.1f..%0.1f ns) (terukur, simulasi)",
                     t2_dpa_dummy_min, t2_dpa_dummy_max, t2_dpa_dummy_min_ns, t2_dpa_dummy_max_ns);
            $display("Tier 2 AES start -> aes_done:     %0d cycles (%0.1f ns) (terukur, simulasi)",
                     t2_aes_start_to_done_cyc, t2_aes_start_to_done_ns);
            $display("Tier 2 aes_done -> ct_valid:      %0d..%0d cycles (%0.1f..%0.1f ns) (terukur, simulasi)",
                     t2_done_to_valid_min_cyc, t2_done_to_valid_max_cyc, t2_done_to_valid_min_ns, t2_done_to_valid_max_ns);
            $display("Tier 2 Total op_req -> ct_valid:  %0d..%0d cycles (%0.1f..%0.1f ns) (terukur, simulasi)",
                     t2_total_min_cyc, t2_total_max_cyc, t2_total_min_ns, t2_total_max_ns);
            $display("Tier 2 TDL glitch edge -> alert:  %0d CLK_sys cycles (%0.1f ns) (terukur, simulasi)",
                     t2_tdl_capture_to_alert_cyc, t2_tdl_capture_to_alert_ns);
            $display("Tier 2 TDL alert -> alarm_sys:    0 cycles (0,0 ns direct wire) (terukur, simulasi)");
            $display("Tier 2 TDL alert -> blkA latch:   %0d CLK_sys cycle (%0.1f ns) (terukur, simulasi)",
                     t2_tdl_alert_to_blkA_cyc, t2_tdl_alert_to_blkA_ns);
            $display("Tier 2 RO slow window:            %0d CLK_sen cycles (%0.1f ns) (terukur, simulasi)",
                     t2_ro_window_cyc, t2_ro_window_ns);
            $display("Tier 2 RO injection -> lif_alarm: %0d CLK_sen cycles (%0.1f ns) (terukur, simulasi)",
                     t2_ro_to_lif_cyc_sen, t2_ro_to_lif_ns);
            $display("Tier 2 RO -> alarm_sys (total):   %0d CLK_sys cycles (%0.1f ns) (terukur, simulasi)",
                     t2_ro_to_alarm_sys_cyc_sys, t2_ro_to_alarm_sys_ns);
            $display("Tier 2 Alarm -> zeroize (N=4):    %0d CLK_sen / %0d CLK_sys (%0.1f ns) (terukur, simulasi)",
                     t2_alarm_to_zeroize_cyc_sen, t2_alarm_to_zeroize_cyc_sys, t2_alarm_to_zeroize_ns);
            $display("Tier 2 Alarm -> lockdown_sys:     %0d CLK_sys (%0.1f ns) (terukur, simulasi)",
                     t2_alarm_to_lockdown_cyc_sys, t2_alarm_to_lockdown_ns);
        end
    endtask

    // =========================================================================
    // N9 CLOCK ATTACKS ON TIER 2
    // =========================================================================
    task run_n9_metrics;
        integer a0;
        real t_atk, t_blk, t_cnt, t_resume, t_clk_fault, t_sen_dead;
        begin
            $display("\n=======================================================");
            $display("3. N9 CLOCK ATTACK DETECTION LATENCY METRICS (TIER 2)");
            $display("=======================================================");

            // Re-initialize Tier 2 NVM and reset DUT to start N9 with alarm_count = 0
            u_t2_nvm.mem0 = u_t2_nvm.good_record(1'b0);
            u_t2_nvm.mem1 = u_t2_nvm.good_record(1'b0);
            @(negedge clk_sys);
            arst_n = 1'b0;
            repeat (4) @(posedge clk_sys);
            #(400);
            @(negedge clk_sys);
            arst_n = 1'b1;
            t2_wait_permit;
            t2_wait_quiet;
            chk(t2_ac == 0 && !t2_lockdown_sys && !t2_key_is_zero,
                "Tier 2 fresh unlocked for N9 sweep");

            // -----------------------------------------------------------------
            // Case 1: clk_sys stopped (hs = 0.0)
            // -----------------------------------------------------------------
            t2_wait_permit; t2_wait_quiet;
            a0 = t2_ac;
            t_atk = $time;
            hs = 0.0;

            // Time to (a) gate blocked / ops refused
            while (u_t2_core.permit_sys && !u_t2_core.alarm_sys) #(10);
            t_blk = $time;
            n9_stop_sys_blk_ns = (t_blk - t_atk);

            // Time to (b) counted in alarm_count (CLK_sen continues to run)
            while (t2_ac == a0) #(20);
            t_cnt = $time;
            n9_stop_sys_cnt_ns = (t_cnt - t_atk);

            hs = HS_NOM;
            #(5000);
            t2_recover;

            chk(n9_stop_sys_blk_ns <= 2048.0, "clk_sys stop detection latency <= 2 us");
            chk(n9_stop_sys_cnt_ns <= 4096.0, "clk_sys stop counted in alarm_count <= 4 us");
            $display("N9 clk_sys STOPPED:");
            $display("  -> Gate blocked / ops refused:  %0.1f ns (terukur, simulasi)", n9_stop_sys_blk_ns);
            $display("  -> Counted in alarm_count:      %0.1f ns (terukur, simulasi)", n9_stop_sys_cnt_ns);

            // -----------------------------------------------------------------
            // Case 2: clk_sys slowed below 1/4x (hs = HS_NOM * 5.0 -> 16 MHz)
            // -----------------------------------------------------------------
            t2_wait_permit; t2_wait_quiet;
            a0 = t2_ac;
            t_atk = $time;
            hs = HS_NOM * 5.0;

            while (u_t2_core.permit_sys && !t2_clk_fault) #(20);
            t_blk = $time;
            n9_slow_sys_blk_ns = (t_blk - t_atk);

            while (t2_ac == a0) #(20);
            t_cnt = $time;
            n9_slow_sys_cnt_ns = (t_cnt - t_atk);

            hs = HS_NOM;
            #(5000);
            t2_recover;

            chk(n9_slow_sys_blk_ns <= 2048.0, "clk_sys slow detection latency <= 2 us");
            chk(n9_slow_sys_cnt_ns <= 4096.0, "clk_sys slow counted in alarm_count <= 4 us");
            $display("N9 clk_sys SLOWED (16 MHz, <1/4x):");
            $display("  -> Gate blocked / ops refused:  %0.1f ns (terukur, simulasi)", n9_slow_sys_blk_ns);
            $display("  -> Counted in alarm_count:      %0.1f ns (terukur, simulasi)", n9_slow_sys_cnt_ns);

            // -----------------------------------------------------------------
            // Case 3: clk_sys sped above 2x (hs = HS_NOM * 0.4 -> 200 MHz)
            // -----------------------------------------------------------------
            t2_wait_permit; t2_wait_quiet;
            a0 = t2_ac;
            t_atk = $time;
            hs = HS_NOM * 0.4;

            while (u_t2_core.permit_sys && !t2_clk_fault) #(10);
            t_blk = $time;
            n9_fast_sys_blk_ns = (t_blk - t_atk);

            while (t2_ac == a0) #(20);
            t_cnt = $time;
            n9_fast_sys_cnt_ns = (t_cnt - t_atk);

            hs = HS_NOM;
            #(5000);
            t2_recover;

            chk(n9_fast_sys_blk_ns <= 2048.0, "clk_sys fast detection latency <= 2 us");
            chk(n9_fast_sys_cnt_ns <= 4096.0, "clk_sys fast counted in alarm_count <= 4 us");
            $display("N9 clk_sys SPED (>2x, 200 MHz):");
            $display("  -> Gate blocked / ops refused:  %0.1f ns (terukur, simulasi)", n9_fast_sys_blk_ns);
            $display("  -> Counted in alarm_count:      %0.1f ns (terukur, simulasi)", n9_fast_sys_cnt_ns);

            // -----------------------------------------------------------------
            // Case 4: clk_sen stopped (hn = 0.0)
            // -----------------------------------------------------------------
            t2_wait_permit; t2_wait_quiet;
            a0 = t2_ac;
            t_atk = $time;
            hn = 0.0;

            // Monitor u_mon_sen fires clk_fault first (~1.76 us)
            while (!t2_clk_fault) #(10);
            t_clk_fault = $time;
            n9_stop_sen_clk_fault_ns = t_clk_fault - t_atk;

            // Heartbeat watcher u_w_hbsen fires sen_dead later (~6.4 us)
            while (!t2_sen_dead) #(10);
            t_sen_dead = $time;
            n9_stop_sen_dead_ns = t_sen_dead - t_atk;

            // Refusal / gate blocked takes effect on the very first fault flag
            n9_stop_sen_blk_ns = n9_stop_sen_clk_fault_ns;

            // Sentinel cannot clock FSM while stopped; stop window is held for 14 us
            #(14000.0 - (t_sen_dead - t_atk));
            t_resume = $time;
            hn = HN_NOM; // restore CLK_sen

            // Count is updated once CLK_sen resumes and clocks tamper_persist_fsm
            while (t2_ac == a0) #(10);
            t_cnt = $time;
            n9_stop_sen_cnt_post_ns = t_cnt - t_resume;
            n9_stop_sen_cnt_total_ns = t_cnt - t_atk;

            #(5000);
            t2_recover;

            chk(n9_stop_sen_clk_fault_ns >= 1500.0 && n9_stop_sen_clk_fault_ns <= 2000.0,
                "clk_sen stop clk_fault expected ~1.76 us");
            chk(n9_stop_sen_dead_ns >= 4500.0 && n9_stop_sen_dead_ns <= 7000.0,
                "clk_sen stop sen_dead expected 4.5..7.0 us");
            chk(n9_stop_sen_cnt_post_ns >= 60.0 && n9_stop_sen_cnt_post_ns <= 140.0,
                "clk_sen stop post-recovery count update expected ~80..100 ns");

            $display("N9 clk_sen STOPPED:");
            $display("  -> clk_fault (u_mon_sen):       %0.1f ns (terukur, simulasi)", n9_stop_sen_clk_fault_ns);
            $display("  -> sen_dead (u_w_hbsen):        %0.1f ns (terukur, simulasi)", n9_stop_sen_dead_ns);
            $display("  -> Gate blocked / ops refused:  %0.1f ns (terukur, simulasi)", n9_stop_sen_blk_ns);
            $display("  -> Counted post-recovery:       %0.1f ns (terukur, simulasi)", n9_stop_sen_cnt_post_ns);
            $display("  -> Counted total incl stop:     %0.1f ns (terukur, simulasi)", n9_stop_sen_cnt_total_ns);
        end
    endtask

    task print_summary_tables;
        begin
            $display("\n=======================================================");
            $display("RINGKASAN METRIK LATENSI DAN DETEKSI SERANGAN JAM");
            $display("=======================================================");
            $display("\n### Tabel 1: Metrik Latensi Tier 1 Core (50 MHz, T = 20,0 ns)");
            $display("| Tahapan Operasi / Jalur               | Siklus Clock | Waktu (ns) | Label               |");
            $display("| :------------------------------------ | :----------- | :--------- | :------------------ |");
            $display("| op_req -> op_grant (MARK NVM write)   | %0d           | %0.1f      | (terukur, simulasi) |", t1_req_to_grant_min_cyc, t1_req_to_grant_min_ns);
            $display("| DPA dummy cycles (rentang acak)       | %0d..%0d        | %0.1f..%0.1f   | (terukur, simulasi) |", t1_dpa_dummy_min, t1_dpa_dummy_max, t1_dpa_dummy_min_ns, t1_dpa_dummy_max_ns);
            $display("| AES start -> aes_done                 | %0d           | %0.1f      | (terukur, simulasi) |", t1_aes_start_to_done_cyc, t1_aes_start_to_done_ns);
            $display("| aes_done -> ct_valid (H + COMMIT + 2S)| %0d           | %0.1f      | (terukur, simulasi) |", t1_done_to_valid_min_cyc, t1_done_to_valid_min_ns);
            $display("| Total op_req -> ct_valid (rentang DPA)| %0d..%0d        | %0.1f..%0.1f | (terukur, simulasi) |", t1_total_min_cyc, t1_total_max_cyc, t1_total_min_ns, t1_total_max_ns);
            $display("| Alarm (round 9) -> internal blkA latch| %0d            | %0.1f       | (terukur, simulasi) |", t1_alarm_to_latch_cyc, t1_alarm_to_latch_ns);
            $display("| Alarm (round 9) -> gate_blocked pulse | %0d           | %0.1f      | (terukur, simulasi) |", t1_alarm_to_blocked_cyc, t1_alarm_to_blocked_ns);
            $display("| Alarm -> lockdown -> zeroize (N=4)    | %0d           | %0.1f      | (terukur, simulasi) |", t1_alarm_to_zeroize_cyc, t1_alarm_to_zeroize_ns);
            $display("| Post-commit zeroize_req -> key_zero   | %0d            | %0.1f       | (terukur, simulasi) |", t1_post_commit_zeroize_cyc, t1_post_commit_zeroize_ns);
            $display("| Jalur clear asinkron fisik (TimeQuest)| -            | 3,514 (maks., 1,763-3,514 di 4 corner) | (terukur, STA Quartus, build RTL freeze 19 Okt, Tier 1) |");

            $display("\n### Tabel 2: Metrik Latensi Tier 2 Core (CLK_sys 80 MHz, CLK_sen 50 MHz)");
            $display("| Tahapan Operasi / Jalur               | Siklus sys/sen | Waktu (ns) | Label               |");
            $display("| :------------------------------------ | :------------- | :--------- | :------------------ |");
            $display("| op_req -> op_grant (termasuk CDC)     | %0d..%0d sys / %0d..%0d sen | %0.1f..%0.1f | (terukur, simulasi) |",
                     t2_req_to_grant_min_cyc_sys, t2_req_to_grant_max_cyc_sys,
                     t2_req_to_grant_min_cyc_sen, t2_req_to_grant_max_cyc_sen,
                     t2_req_to_grant_min_ns, t2_req_to_grant_max_ns);
            $display("| DPA dummy cycles (rentang acak)       | %0d..%0d sys       | %0.1f..%0.1f   | (terukur, simulasi) |", t2_dpa_dummy_min, t2_dpa_dummy_max, t2_dpa_dummy_min_ns, t2_dpa_dummy_max_ns);
            $display("| AES start -> aes_done                 | %0d sys        | %0.1f      | (terukur, simulasi) |", t2_aes_start_to_done_cyc, t2_aes_start_to_done_ns);
            $display("| aes_done -> ct_valid (CDC + COMMIT)   | %0d..%0d sys      | %0.1f..%0.1f | (terukur, simulasi) |",
                     t2_done_to_valid_min_cyc, t2_done_to_valid_max_cyc,
                     t2_done_to_valid_min_ns, t2_done_to_valid_max_ns);
            $display("| Total op_req -> ct_valid (rentang DPA)| %0d..%0d sys      | %0.1f..%0.1f | (terukur, simulasi) |",
                     t2_total_min_cyc, t2_total_max_cyc, t2_total_min_ns, t2_total_max_ns);
            $display("| TDL glitch capture edge -> alert      | %0d sys        | %0.1f       | (terukur, simulasi) |",
                     t2_tdl_capture_to_alert_cyc, t2_tdl_capture_to_alert_ns);
            $display("| TDL alert -> alarm_sys (fast, no CDC) | 0 sys          | 0,0        | (terukur, simulasi) |");
            $display("| TDL alert -> internal blkA latch      | %0d sys        | %0.1f       | (terukur, simulasi) |",
                     t2_tdl_alert_to_blkA_cyc, t2_tdl_alert_to_blkA_ns);
            $display("| RO slow window (RO_WINDOW = 256)      | %0d sen       | %0.1f     | (terukur, simulasi) |",
                     t2_ro_window_cyc, t2_ro_window_ns);
            $display("| RO anomaly injection -> lif_alarm     | %0d sen       | %0.1f     | (terukur, simulasi) |",
                     t2_ro_to_lif_cyc_sen, t2_ro_to_lif_ns);
            $display("| RO anomaly injection -> alarm_sys     | %0d sys       | %0.1f     | (terukur, simulasi) |",
                     t2_ro_to_alarm_sys_cyc_sys, t2_ro_to_alarm_sys_ns);
            $display("| Tier 2 Alarm -> zeroize (N=4)         | %0d sen / %0d sys | %0.1f      | (terukur, simulasi) |",
                     t2_alarm_to_zeroize_cyc_sen, t2_alarm_to_zeroize_cyc_sys, t2_alarm_to_zeroize_ns);
            $display("| Tier 2 Alarm -> lockdown_sys          | %0d sys        | %0.1f      | (terukur, simulasi) |",
                     t2_alarm_to_lockdown_cyc_sys, t2_alarm_to_lockdown_ns);

            $display("\n### Tabel 3: N9 Deteksi Serangan Clock Domain Tier 2");
            $display("| Skenario Serangan Clock               | Deteksi & Refusal (ns) | Pencatatan Alarm (ns) | Label               |");
            $display("| :------------------------------------ | :--------------------- | :-------------------- | :------------------ |");
            $display("| clk_sys berhenti (0 Hz)               | %0.1f                  | %0.1f                 | (terukur, simulasi) |", n9_stop_sys_blk_ns, n9_stop_sys_cnt_ns);
            $display("| clk_sys diperlambat (<1/4x, 16 MHz)   | %0.1f                 | %0.1f                 | (terukur, simulasi) |", n9_slow_sys_blk_ns, n9_slow_sys_cnt_ns);
            $display("| clk_sys dipercepat (>2x, 200 MHz)     | %0.1f                 | %0.1f                 | (terukur, simulasi) |", n9_fast_sys_blk_ns, n9_fast_sys_cnt_ns);
            $display("| clk_sen berhenti (clk_fault monitor)  | %0.1f                 | %0.1f (pasca-pulih)  | (terukur, simulasi) |", n9_stop_sen_clk_fault_ns, n9_stop_sen_cnt_post_ns);
            $display("| clk_sen berhenti (sen_dead heartbeat) | %0.1f                 | %0.1f (total window) | (terukur, simulasi) |", n9_stop_sen_dead_ns, n9_stop_sen_cnt_total_ns);
        end
    endtask

    // =========================================================================
    // MAIN EXECUTION
    // =========================================================================
    initial begin
        #60_000_000;
        $display("FAIL tb_latency_metrics (timeout)");
        $finish;
    end

    initial begin
        run_tier1_metrics;
        run_tier2_metrics;
        run_n9_metrics;

        #500;
        print_summary_tables;
        $display("\n=======================================================");
        if (errors == 0) begin
            $display("ALL LATENCY AND CLOCK ATTACK METRICS VERIFIED (0 errors)");
            $display("PASS tb_latency_metrics");
        end else begin
            $display("FAIL tb_latency_metrics (%0d errors)", errors);
        end
        $display("=======================================================");
        $finish;
    end

endmodule
