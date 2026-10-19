// de10_nano_top_t2: Tier 2 demo top for Terasic DE10-Nano (5CSEBA6U23I7).
// Two clock domains from a PLL, real TDL and RO sensors, no HPS.
//
// Clocks (sys_pll is generated in the Quartus IP Catalog, see
// quartus/tier2/PLL_SETUP.md):
//   outclk_0  CLK_sys A       e.g. 80 MHz (target; Tier 1 Fmax is 93,49 MHz)
//   outclk_1  CLK_sentinel    e.g. 50 MHz
//   outclk_2  CLK_sys B       same frequency as outclk_0, phase PHI, T/2 < PHI < T
// The tamper counters and the lockdown live in nvm_counter_model, a stand-in
// for the parent chip's NVM (the tamper_persist_fsm of the core runs in the
// CLK_sentinel domain, so the model uses that clock).
// glitch_injector builds CLK_sys from A and B. All CLK_sys logic (AES, TDL,
// gate) runs on that output, so an injected short cycle hits the cipher and
// the TDL at the same time.
//
// Controls
//   SW0  Sentinel enable (0 = OFF)
//   SW1  attack mode for KEY1:
//          0 = emulated byte fault at round 9 + harness alarm (Tier 1 path)
//          1 = physical clock glitch near round GLITCH_ROUND, no harness
//              alarm: only the TDL can catch it
//   SW2  calibration/debug view: LEDs show TDL status, and alarms are not
//        counted by the tamper FSM (gate still blocks). Demo builds only.
//   SW3  with KEY0: demo-only debug unlock of LOCKDOWN. With SW3 = 1 and
//        SW2 = 0, KEY1 does not attack but selects (by SW1):
//          SW1 = 0  power_warn (droop flag) during the next encryption
//          SW1 = 1  toggle LED[2:0] between alarm_count and tear_count
//   KEY0 user reset (also restarts TDL calibration and RO baselines). During
//        an encryption it aborts it like a power loss: one tear is counted.
//   KEY1 attack (SW3 = 0)
// LEDs, SW2 = 0 (same meaning as Tier 1)
//   LED[2:0] alarm_count (or tear_count, see SW3 above)  LED3 heartbeat  LED4 last ciphertext correct
//   LED5 release blocked     LED6 alarm seen  LED7 LOCKDOWN, key zero
// LEDs, SW2 = 1, SW3 = 0 (calibration view)
//   LED7 TDL armed  LED6 TDL calibration failed
//   LED[5:0] with SW1 = 0: calibrated TDL minimum depth (rising edge),
//            saturates at 63
//            with SW1 = 1: coarse tap chosen by the calibration sweep
// LEDs, SW2 = 1, SW3 = 1 (alarm-source view, for false-alarm hunting)
//   LED7 TDL alert seen (0.5 s, needs SW0 = 1)
//   LED6 slow-path LIF alarm seen (raw, independent of SW0)
//   LED[5:0] lowest TDL depth (either edge) in the last 2^HB_BIT cycles,
//            about 0.4 s; compare with the calibrated minimum: the gap is
//            how much margin TDL_K needs
//   (KEY0 in this view also does the debug unlock, since SW3 = 1)
// Clock and heartbeat faults (core outputs clk_fault, sen_dead): all eight LEDs
// are in use in every view, so there is no dedicated LED. Both faults are part
// of alarm_sys, so they light LED6 (alarm seen) and LED5 (release blocked) in
// the normal view; they are counted in alarm_count (LED[2:0]) like any alarm.
// Until warm-up has finished (about 5 us after power-on) the core reports busy
// and no operation is requested.
module de10_nano_top_t2 #(
    parameter integer DEB_CYCLES     = 800000,     // 10 ms at 80 MHz
    parameter integer STRETCH_CYCLES = 40000000,   // 0.5 s at 80 MHz
    parameter integer OP_PERIOD      = 8000000,    // one clean op every 0.1 s
    parameter integer HB_BIT         = 25,         // ~1,2 Hz at 80 MHz
    parameter integer N              = 4,
    parameter integer M              = 8,
    parameter integer H              = 4,
    parameter integer NVM_WR_LAT     = 8,      // CLK_sentinel cycles per NVM write
    parameter integer DEMO_UNLOCK    = 1,
    parameter integer GLITCH_ROUND   = 6,      // arm here; glitch lands ~3 rounds later
    parameter integer GLITCH_ENABLE  = 1,
    parameter integer TDL_L          = 64,
    parameter integer TDL_COARSE     = 63,     // max coarse LUTs; tap picked by calibration
    parameter integer TDL_K          = 12,     // margin in taps; the demo glitch removes far more
    parameter integer TDL_SETTLE     = 1024,
    parameter integer TDL_WIN        = 4096,
    parameter integer RO_WINDOW      = 256,
    parameter integer P2SE_DTH       = 8,
    parameter integer DETECTOR_SEL   = 0,
    parameter integer FAST_HOLD      = 16,
    parameter integer SLOW_HOLD      = 1024,
    // clock monitors and heartbeat (see peruri_sentinel_core_t2)
    parameter integer MON_STAGES     = 13,
    parameter integer MON_WINDOW     = 64,
    parameter integer MON_LO_SYS     = 24,
    parameter integer MON_HI_SYS     = 160,
    parameter integer MON_LO_SEN     = 14,
    parameter integer MON_HI_SEN     = 100,
    parameter integer MON_WARM       = 4,
    parameter integer HB_K           = 64,
    parameter integer HB_TO          = 512,
    parameter integer RO_TO          = 2048
) (
    input  wire       FPGA_CLK1_50,
    input  wire [1:0] KEY,
    input  wire [3:0] SW,
    output wire [7:0] LED
);
`ifndef DEMO_BUILD
    // This board top uses the demo-only ports of the core. Compile it with
    // DEMO_BUILD defined (Quartus: VERILOG_MACRO "DEMO_BUILD=1"; iverilog:
    // -DDEMO_BUILD). Without it, elaboration fails here on purpose.
    DEMO_BUILD_must_be_defined_for_the_board_top u_build_check ();
`endif
    localparam [127:0] DEMO_KEY = 128'h000102030405060708090a0b0c0d0e0f;
    localparam [127:0] DEMO_PT  = 128'h00112233445566778899aabbccddeeff;
    localparam [127:0] EXP_CT   = 128'h69c4e0d86a7b0430d8cdb78070b4c55a;
    localparam integer CW   = 4;
    localparam integer RECW = 17 + 2*CW;

    // ---------------- clocks and resets ----------------
    reg [3:0] por_cnt = 4'd0;      // power-up value 0 (FPGA configuration)
    always @(posedge FPGA_CLK1_50)
        if (!por_cnt[3]) por_cnt <= por_cnt + 4'd1;

    wire clk_a, clk_b, clk_sen, pll_locked;
    sys_pll u_pll (
        .refclk(FPGA_CLK1_50), .rst(~por_cnt[3]),
        .outclk_0(clk_a), .outclk_1(clk_sen), .outclk_2(clk_b),
        .locked(pll_locked)
    );

    wire arst_n = por_cnt[3] & pll_locked;
    wire glitch_arm;
    wire glitch_en;
    wire clk_sys;
    glitch_injector #(.ENABLE(GLITCH_ENABLE)) u_glitch (
        .clk_a(clk_a), .clk_b(clk_b), .rst_n(arst_n), .arm(glitch_arm),
        .clk_out(clk_sys), .en(glitch_en)
    );

    wire por_sys_n, por_sen_n;
    reset_sync u_rs_sys (.clk(clk_sys), .arst_n(arst_n), .rst_n(por_sys_n));
    reset_sync u_rs_sen (.clk(clk_sen), .arst_n(arst_n), .rst_n(por_sen_n));

    // ---------------- board inputs (CLK_sys) ----------------
    wire key0_s, key1_s;
    wire [3:0] sw_s;
    sync_2ff #(.RESET_VAL(1'b1)) u_sk0 (.clk(clk_sys), .rst_n(por_sys_n), .d(KEY[0]), .q(key0_s));
    sync_2ff #(.RESET_VAL(1'b1)) u_sk1 (.clk(clk_sys), .rst_n(por_sys_n), .d(KEY[1]), .q(key1_s));
    sync_2ff u_ss0 (.clk(clk_sys), .rst_n(por_sys_n), .d(SW[0]), .q(sw_s[0]));
    sync_2ff u_ss1 (.clk(clk_sys), .rst_n(por_sys_n), .d(SW[1]), .q(sw_s[1]));
    sync_2ff u_ss2 (.clk(clk_sys), .rst_n(por_sys_n), .d(SW[2]), .q(sw_s[2]));
    sync_2ff u_ss3 (.clk(clk_sys), .rst_n(por_sys_n), .d(SW[3]), .q(sw_s[3]));

    wire key0_n, key1_n;
    debounce #(.CYCLES(DEB_CYCLES), .INIT(1'b1)) u_db0 (.clk(clk_sys), .rst_n(por_sys_n), .d(key0_s), .q(key0_n));
    debounce #(.CYCLES(DEB_CYCLES), .INIT(1'b1)) u_db1 (.clk(clk_sys), .rst_n(por_sys_n), .d(key1_s), .q(key1_n));

    wire rst_sys_n    = por_sys_n & key0_n;
    wire sentinel_en  = sw_s[0];
    wire attack_mode  = sw_s[1];
    wire debug_view   = sw_s[2];
    wire debug_unlock = sw_s[3] & ~key0_n;

    // ---------------- control signals into CLK_sentinel ----------------
    wire en_sen, unlock_sen, mask_sen, key0_sen;
    sync_2ff u_c0 (.clk(clk_sen), .rst_n(por_sen_n), .d(sentinel_en),  .q(en_sen));
    sync_2ff u_c1 (.clk(clk_sen), .rst_n(por_sen_n), .d(debug_unlock), .q(unlock_sen));
    sync_2ff u_c2 (.clk(clk_sen), .rst_n(por_sen_n), .d(debug_view),   .q(mask_sen));
    sync_2ff #(.RESET_VAL(1'b1)) u_c3 (.clk(clk_sen), .rst_n(por_sen_n), .d(key0_n), .q(key0_sen));
    wire rst_sen_n = por_sen_n & key0_sen;

    // ---------------- demo harness: operation scheduler ----------------
    reg key1_d;
    always @(posedge clk_sys or negedge por_sys_n)
        if (!por_sys_n) key1_d <= 1'b1;
        else            key1_d <= key1_n;
    wire key1_press   = key1_d & ~key1_n;
    wire attack_press = key1_press & ~sw_s[3];
    wire p_warn       = key1_press &  sw_s[3] & ~sw_s[2] & ~sw_s[1];
    wire p_view       = key1_press &  sw_s[3] & ~sw_s[2] &  sw_s[1];

    wire         core_busy, lockdown_sys;
    wire [3:0]   round_idx;
    wire [127:0] ct_out;
    wire         ct_valid, gate_blocked, key_is_zero, alarm_sys;

    localparam integer TW = $clog2(OP_PERIOD + 1);
    reg [TW-1:0] op_timer;
    reg          attack_pending, pending_mode;
    reg          cur_fault, cur_glitch;
    reg          op_req;

    always @(posedge clk_sys or negedge rst_sys_n) begin
        if (!rst_sys_n) begin
            op_timer       <= {TW{1'b0}};
            attack_pending <= 1'b0;
            pending_mode   <= 1'b0;
            cur_fault      <= 1'b0;
            cur_glitch     <= 1'b0;
            op_req         <= 1'b0;
        end else begin
            op_req <= 1'b0;
            if (attack_press) begin
                attack_pending <= 1'b1;
                pending_mode   <= attack_mode;
            end
            if (op_timer >= OP_PERIOD - 1) begin
                if (!core_busy && !lockdown_sys) begin
                    op_req         <= 1'b1;
                    cur_fault      <= attack_pending & ~pending_mode;
                    cur_glitch     <= attack_pending &  pending_mode;
                    attack_pending <= 1'b0;
                    op_timer       <= {TW{1'b0}};
                end
            end else begin
                op_timer <= op_timer + 1'b1;
            end
        end
    end

    // Tier 1 path: emulated byte fault + harness alarm in the same round
    wire [3:0] f_round = 4'd9;
    wire [3:0] f_byte  = 4'd0;
    wire [7:0] f_mask  = 8'h01;
    wire harness_alarm = cur_fault & core_busy & (round_idx == f_round);

    // physical glitch path: hold `arm` for 4 cycles from round GLITCH_ROUND
    reg [2:0] arm_cnt;
    always @(posedge clk_sys or negedge rst_sys_n) begin
        if (!rst_sys_n) arm_cnt <= 3'd0;
        else if (cur_glitch && core_busy && round_idx == GLITCH_ROUND && arm_cnt == 3'd0)
            arm_cnt <= 3'd4;
        else if (arm_cnt != 3'd0)
            arm_cnt <= arm_cnt - 3'd1;
    end
    assign glitch_arm = (arm_cnt != 3'd0);

    // power_warn emulation: flagged while the AES is in rounds 3..6 of the
    // next encryption, then synchronized into CLK_sentinel
    reg warn_pending, warn_active, tear_view;
    always @(posedge clk_sys or negedge por_sys_n) begin
        if (!por_sys_n) begin
            warn_pending <= 1'b0;
            warn_active  <= 1'b0;
            tear_view    <= 1'b0;
        end else begin
            if (p_view) tear_view <= ~tear_view;
            if (p_warn) warn_pending <= 1'b1;
            warn_active <= warn_pending && (round_idx >= 4'd3) && (round_idx <= 4'd6);
            if (warn_active) warn_pending <= 1'b0;
        end
    end
    wire warn_lvl, power_warn_sen;
    pulse_stretch #(.CYCLES(8)) u_ps_warn (.clk(clk_sys), .rst_n(por_sys_n), .p(warn_active), .q(warn_lvl));
    sync_2ff u_c4 (.clk(clk_sen), .rst_n(por_sen_n), .d(warn_lvl), .q(power_warn_sen));

    // ---------------- NVM model (parent chip NVM stand-in) ----------------
    wire            nvm_rd_en, nvm_rd_addr, nvm_rd_valid, nvm_wr_en, nvm_wr_addr, nvm_wr_done;
    wire [RECW-1:0] nvm_rd_data, nvm_wr_data;
    nvm_counter_model #(.CW(CW), .RD_LAT(2), .WR_LAT(NVM_WR_LAT), .INIT_BLANK(0)) u_nvm (
        .clk(clk_sen), .power_ok(1'b1),
        .rd_en(nvm_rd_en), .rd_addr(nvm_rd_addr), .rd_data(nvm_rd_data), .rd_valid(nvm_rd_valid),
        .wr_en(nvm_wr_en), .wr_addr(nvm_wr_addr), .wr_data(nvm_wr_data), .wr_done(nvm_wr_done)
    );

    // ---------------- Sentinel core ----------------
    wire [CW-1:0] cnt_sys, tear_sys;
    wire       clk_fault, sen_dead;   // sticky clock/heartbeat faults (no free LED, see header)
    wire       tdl_alert, tdl_armed, tdl_cal_bad;
    wire [6:0] tdl_depth, tdl_min_r;
    wire [$clog2(TDL_COARSE+1)-1:0] tdl_sel;
    wire [CW-1:0] cnt_sen, tear_sen;
    wire       lock_sen, lif_alarm, ewma_alarm, fixed_alarm;
    wire [11:0] spike_bus;

    peruri_sentinel_core_t2 #(
        .H(H), .N(N), .M(M), .CW(CW), .DEMO_UNLOCK(DEMO_UNLOCK), .DPA_ENABLE(1), .DEMO_KEY(DEMO_KEY),
        .TDL_L(TDL_L), .TDL_COARSE(TDL_COARSE), .TDL_K(TDL_K),
        .TDL_SETTLE(TDL_SETTLE), .TDL_WIN(TDL_WIN),
        .RO_WINDOW(RO_WINDOW), .P2SE_DTH(P2SE_DTH), .DETECTOR_SEL(DETECTOR_SEL),
        .FAST_HOLD(FAST_HOLD), .SLOW_HOLD(SLOW_HOLD),
        .MON_STAGES(MON_STAGES), .MON_WINDOW(MON_WINDOW),
        .MON_LO_SYS(MON_LO_SYS), .MON_HI_SYS(MON_HI_SYS),
        .MON_LO_SEN(MON_LO_SEN), .MON_HI_SEN(MON_HI_SEN), .MON_WARM(MON_WARM),
        .HB_K(HB_K), .HB_TO(HB_TO), .RO_TO(RO_TO)
    ) u_core (
        .clk_sys(clk_sys), .rst_sys_n(rst_sys_n), .por_sys_n(por_sys_n), .sentinel_en_sys(sentinel_en),
        .op_req(op_req), .pt(DEMO_PT),
        .fault_en(cur_fault), .fault_round(f_round), .fault_byte(f_byte), .fault_mask(f_mask),
        .harness_alarm(harness_alarm),
        .ct_out(ct_out), .ct_valid(ct_valid), .gate_blocked(gate_blocked),
        .busy(core_busy), .round_idx(round_idx), .key_is_zero(key_is_zero),
        .lockdown_sys(lockdown_sys), .tamper_counter_sys(cnt_sys), .tear_count_sys(tear_sys), .alarm_sys(alarm_sys),
        .clk_fault(clk_fault), .sen_dead(sen_dead),
        .tdl_alert(tdl_alert), .tdl_armed(tdl_armed), .tdl_cal_bad(tdl_cal_bad),
        .tdl_depth(tdl_depth), .tdl_min_r(tdl_min_r), .tdl_sel(tdl_sel),
        .clk_sen(clk_sen), .rst_sen_n(rst_sen_n), .por_sen_n(por_sen_n),
        .sentinel_en_sen(en_sen), .debug_unlock_sen(unlock_sen), .fsm_mask_sen(mask_sen),
        .power_warn(power_warn_sen),
        .nvm_rd_en(nvm_rd_en), .nvm_rd_addr(nvm_rd_addr), .nvm_rd_data(nvm_rd_data),
        .nvm_rd_valid(nvm_rd_valid), .nvm_wr_en(nvm_wr_en), .nvm_wr_addr(nvm_wr_addr),
        .nvm_wr_data(nvm_wr_data), .nvm_wr_done(nvm_wr_done),
        .ro_en(1'b1),
        .tamper_counter(cnt_sen), .tear_count(tear_sen), .lockdown(lock_sen),
        .lif_alarm(lif_alarm), .ewma_alarm(ewma_alarm), .fixed_alarm(fixed_alarm),
        .spike_bus(spike_bus)
    );

    // ---------------- LEDs ----------------
    wire released_ok  = ct_valid & (ct_out == EXP_CT);
    wire released_bad = ct_valid & (ct_out != EXP_CT);

    reg ok_latched;
    always @(posedge clk_sys or negedge rst_sys_n)
        if (!rst_sys_n)        ok_latched <= 1'b0;
        else if (released_ok)  ok_latched <= 1'b1;
        else if (released_bad) ok_latched <= 1'b0;

    wire bad_led, blk_led, alm_led;
    pulse_stretch #(.CYCLES(STRETCH_CYCLES)) u_ps_bad (.clk(clk_sys), .rst_n(por_sys_n), .p(released_bad), .q(bad_led));
    pulse_stretch #(.CYCLES(STRETCH_CYCLES)) u_ps_blk (.clk(clk_sys), .rst_n(por_sys_n), .p(gate_blocked), .q(blk_led));
    pulse_stretch #(.CYCLES(STRETCH_CYCLES)) u_ps_alm (.clk(clk_sys), .rst_n(por_sys_n), .p(alarm_sys),    .q(alm_led));

    reg [HB_BIT:0] hb;
    always @(posedge clk_sys or negedge por_sys_n)
        if (!por_sys_n) hb <= 0;
        else            hb <= hb + 1'b1;

    wire [CW-1:0] cnt_show = tear_view ? tear_sys : cnt_sys;
    wire [7:0] led_normal = {
        lockdown_sys & key_is_zero,
        alm_led,
        blk_led,
        ok_latched & ~bad_led & ~lockdown_sys,
        hb[HB_BIT],
        (cnt_show > 4'd7) ? 3'd7 : cnt_show[2:0]
    };
    wire [5:0] depth_led = (tdl_min_r > 7'd63) ? 6'd63 : tdl_min_r[5:0];
    wire [5:0] sel_led   = (tdl_sel > 63) ? 6'd63 : tdl_sel[5:0];
    wire [7:0] led_debug = {tdl_armed, tdl_cal_bad, attack_mode ? sel_led : depth_led};

    // alarm-source view: which detector fires, and how low the TDL depth goes
    wire tdl_seen, lif_seen;
    pulse_stretch #(.CYCLES(STRETCH_CYCLES)) u_ps_tdl (.clk(clk_sys), .rst_n(por_sys_n), .p(tdl_alert), .q(tdl_seen));
    pulse_stretch #(.CYCLES(STRETCH_CYCLES)) u_ps_lif (.clk(clk_sen), .rst_n(por_sen_n), .p(lif_alarm), .q(lif_seen));

    reg [6:0] dmin_win, dmin_show;
    wire      win_end = (hb[HB_BIT-1:0] == {HB_BIT{1'b0}});
    always @(posedge clk_sys or negedge rst_sys_n) begin
        if (!rst_sys_n) begin
            dmin_win  <= 7'h7f;
            dmin_show <= 7'h7f;
        end else if (win_end) begin
            dmin_show <= dmin_win;
            dmin_win  <= 7'h7f;
        end else if (tdl_armed && tdl_depth < dmin_win) begin
            dmin_win  <= tdl_depth;
        end
    end
    wire [5:0] dmin_led = (dmin_show > 7'd63) ? 6'd63 : dmin_show[5:0];
    wire [7:0] led_diag = {tdl_seen, lif_seen, dmin_led};

    assign LED = !debug_view ? led_normal : (sw_s[3] ? led_diag : led_debug);
endmodule
