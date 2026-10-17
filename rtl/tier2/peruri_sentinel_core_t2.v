// peruri_sentinel_core_t2: Tier 2 integration with two clock domains.
//
// CLK_sys (attacked domain)
//   dpa_hiding_lfsr -> aes128_core -> output_release_gate -> ct_out
//   tdl_glitch_line observes CLK_sys; its alert goes into the gate
//   DIRECTLY (no synchronizer). This is the "no faulty ciphertext leaves"
//   guarantee: the alert reaches the gate within the H-cycle hold window.
//   master_key_vault (async clear from the sentinel domain)
//
// CLK_sentinel (isolated domain)
//   ro_sensor_mesh -> p2se_encoder -> snn_lif_engine (+ ablation_detectors)
//   graduated_tamper_fsm -> tripwire_zeroize -> async clear of the key vault
//
// Crossings (all through sync_2ff, single-bit levels)
//   fast events (TDL alert, harness alarm) -> stretched to FAST_HOLD
//     CLK_sys cycles -> sentinel domain: counted once per burst by the FSM
//   slow alarm (selected detector) -> stretched to SLOW_HOLD sentinel
//     cycles -> CLK_sys: blocks releases while it is high (sticky window)
//   lockdown -> CLK_sys; tamper_counter bits -> CLK_sys (LED display only)
//
// DETECTOR_SEL selects which slow detector drives the alarm:
//   0 = LIF (default), 1 = EWMA only, 2 = fixed threshold, 3 = none.
// fsm_mask (debug/calibration mode) stops alarms from being counted, so a
// board with an uncalibrated sensor cannot lock itself; the gate still
// blocks. It is honoured only when DEMO_UNLOCK = 1.
module peruri_sentinel_core_t2 #(
    parameter integer H            = 4,
    parameter integer N            = 4,
    parameter integer DEMO_UNLOCK  = 1,
    parameter integer DPA_ENABLE   = 1,
    parameter [127:0] DEMO_KEY     = 128'h000102030405060708090a0b0c0d0e0f,
    // TDL
    parameter integer TDL_L        = 64,
    parameter integer TDL_COARSE   = 24,
    parameter integer TDL_K        = 4,
    parameter integer TDL_SETTLE   = 1024,
    parameter integer TDL_WIN      = 4096,
    // RO / slow path
    parameter integer RO_NUM       = 8,
    parameter integer RO_STAGES    = 13,
    parameter integer RO_DIV_BITS  = 3,
    parameter integer RO_WINDOW    = 256,
    parameter integer P2SE_DTH     = 8,
    parameter integer ABL_FTH      = 12,
    parameter integer ABL_ETH      = 8,
    parameter integer DETECTOR_SEL = 0,
    // crossings
    parameter integer FAST_HOLD    = 16,     // CLK_sys cycles
    parameter integer SLOW_HOLD    = 1024    // CLK_sentinel cycles
) (
    // CLK_sys domain
    input  wire         clk_sys,
    input  wire         rst_sys_n,       // user reset (KEY0) + POR
    input  wire         sentinel_en_sys,
    input  wire         op_req,
    input  wire [127:0] pt,
    input  wire         fault_en,        // demo harness only
    input  wire [3:0]   fault_round,
    input  wire [3:0]   fault_byte,
    input  wire [7:0]   fault_mask,
    input  wire         harness_alarm,   // demo harness only (Tier 1 mode)
    output wire [127:0] ct_out,
    output wire         ct_valid,
    output wire         gate_blocked,
    output wire         busy,
    output wire [3:0]   round_idx,
    output wire         key_is_zero,
    output wire         lockdown_sys,
    output wire [3:0]   tamper_counter_sys,
    output wire         alarm_sys,       // what the gate sees
    output wire         tdl_alert,
    output wire         tdl_armed,
    output wire         tdl_cal_bad,
    output wire [$clog2(TDL_L+1)-1:0] tdl_depth,
    output wire [$clog2(TDL_L+1)-1:0] tdl_min_r,
    // CLK_sentinel domain
    input  wire         clk_sen,
    input  wire         rst_sen_n,       // user reset + POR (sensor pipeline)
    input  wire         por_sen_n,       // POR only (persistent tamper state)
    input  wire         sentinel_en_sen,
    input  wire         debug_unlock_sen,
    input  wire         fsm_mask_sen,
    input  wire         ro_en,
    output wire [3:0]   tamper_counter,
    output wire         lockdown,
    output wire         lif_alarm,
    output wire         ewma_alarm,
    output wire         fixed_alarm,
    output wire [11:0]  spike_bus
);
    // =========================== CLK_sys ===========================
    wire [127:0] key;
    wire         go, aes_done, aes_busy;
    wire [127:0] ct_raw;
    wire [1:0]   dummy_cnt;
    wire         async_zeroize_n;
    wire         slow_lvl_sys;
    wire         slow_lvl_sen_w;   // driven in the sentinel domain below

    tdl_glitch_line #(
        .L(TDL_L), .COARSE(TDL_COARSE), .K_TDL(TDL_K),
        .CAL_SETTLE(TDL_SETTLE), .CAL_WIN(TDL_WIN)
    ) u_tdl (
        .clk(clk_sys), .rst_n(rst_sys_n), .enable(sentinel_en_sys),
        .alert(tdl_alert), .armed(tdl_armed), .cal_bad(tdl_cal_bad),
        .depth_q(tdl_depth), .min_r(tdl_min_r), .min_f()
    );

    sync_2ff u_s_slow (.clk(clk_sys), .rst_n(rst_sys_n), .d(slow_lvl_sen_w), .q(slow_lvl_sys));
    sync_2ff u_s_lock (.clk(clk_sys), .rst_n(rst_sys_n), .d(lockdown), .q(lockdown_sys));
    genvar gi;
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : g_cnt
            sync_2ff u_s_cnt (.clk(clk_sys), .rst_n(rst_sys_n), .d(tamper_counter[gi]),
                              .q(tamper_counter_sys[gi]));
        end
    endgenerate

    // gate alarm: TDL directly, slow path through its synchronizer
    assign alarm_sys = sentinel_en_sys & (tdl_alert | harness_alarm | slow_lvl_sys);

    reg req_pending;
    always @(posedge clk_sys or negedge rst_sys_n) begin
        if (!rst_sys_n)                    req_pending <= 1'b0;
        else if (go)                       req_pending <= 1'b0;
        else if (op_req && !lockdown_sys)  req_pending <= 1'b1;
    end

    dpa_hiding_lfsr #(.ENABLE(DPA_ENABLE)) u_dpa (
        .clk(clk_sys), .rst_n(rst_sys_n),
        .req(op_req & ~lockdown_sys & ~aes_busy & ~req_pending),
        .go(go), .dummy_cnt(dummy_cnt)
    );

    master_key_vault #(.DEMO_KEY(DEMO_KEY)) u_vault (
        .clk(clk_sys), .rst_n(rst_sys_n), .async_zeroize_n(async_zeroize_n),
        .key_to_cipher(key)
    );

    aes128_core u_aes (
        .clk(clk_sys), .rst_n(rst_sys_n), .start(go & ~lockdown_sys),
        .key(key), .pt(pt),
        .fault_en(fault_en), .fault_round(fault_round),
        .fault_byte(fault_byte), .fault_mask(fault_mask),
        .ct_raw(ct_raw), .done(aes_done), .busy(aes_busy), .round_idx(round_idx)
    );

    output_release_gate #(.H(H)) u_gate (
        .clk(clk_sys), .rst_n(rst_sys_n), .enable(sentinel_en_sys), .lockdown(lockdown_sys),
        .op_start(go & ~lockdown_sys), .aes_done(aes_done), .ct_raw(ct_raw),
        .alarm(alarm_sys), .ct_out(ct_out), .ct_valid(ct_valid),
        .gate_blocked(gate_blocked)
    );

    // fast events to the sentinel domain: stretch so a burst is one level
    wire fast_lvl_sys;
    pulse_stretch #(.CYCLES(FAST_HOLD)) u_ps_fast (
        .clk(clk_sys), .rst_n(rst_sys_n),
        .p(sentinel_en_sys & (tdl_alert | harness_alarm)), .q(fast_lvl_sys)
    );

    assign busy        = aes_busy | req_pending;
    assign key_is_zero = (key == 128'h0);

    // ========================= CLK_sentinel =========================
    wire fast_lvl_sen;
    sync_2ff u_s_fast (.clk(clk_sen), .rst_n(rst_sen_n), .d(fast_lvl_sys), .q(fast_lvl_sen));

    wire [RO_NUM*16-1:0] ro_counts;
    wire                 ro_valid;
    ro_sensor_mesh #(
        .NUM(RO_NUM), .STAGES(RO_STAGES), .DIV_BITS(RO_DIV_BITS),
        .CNT_W(16), .WINDOW(RO_WINDOW)
    ) u_mesh (
        .clk(clk_sen), .rst_n(rst_sen_n), .en(ro_en),
        .ro_counts(ro_counts), .valid(ro_valid)
    );

    wire tick;
    p2se_encoder #(.NUM(RO_NUM), .CNT_W(16), .DTH(P2SE_DTH)) u_p2se (
        .clk(clk_sen), .rst_n(rst_sen_n), .ro_counts(ro_counts), .ro_valid(ro_valid),
        .tdl_event(fast_lvl_sen), .spike_bus(spike_bus), .tick(tick)
    );

    wire [7:0] fire;
    snn_lif_engine u_lif (
        .clk(clk_sen), .rst_n(rst_sen_n), .tick(tick), .spike_bus(spike_bus),
        .fire(fire), .anomaly_alarm(lif_alarm)
    );

    ablation_detectors #(.NUM(RO_NUM), .CNT_W(16), .FTH(ABL_FTH), .ETH(ABL_ETH)) u_abl (
        .clk(clk_sen), .rst_n(rst_sen_n), .ro_counts(ro_counts), .ro_valid(ro_valid),
        .fixed_alarm(fixed_alarm), .ewma_alarm(ewma_alarm)
    );

    wire slow_pulse = (DETECTOR_SEL == 0) ? lif_alarm   :
                      (DETECTOR_SEL == 1) ? ewma_alarm  :
                      (DETECTOR_SEL == 2) ? fixed_alarm : 1'b0;

    pulse_stretch #(.CYCLES(SLOW_HOLD)) u_ps_slow (
        .clk(clk_sen), .rst_n(rst_sen_n), .p(sentinel_en_sen & slow_pulse), .q(slow_lvl_sen_w)
    );

    wire mask = (DEMO_UNLOCK != 0) & fsm_mask_sen;
    wire fsm_alarm = sentinel_en_sen & ~mask & (fast_lvl_sen | slow_lvl_sen_w);

    wire zeroize_req;
    graduated_tamper_fsm #(.N(N), .DEMO_UNLOCK(DEMO_UNLOCK)) u_fsm (
        .clk(clk_sen), .por_n(por_sen_n), .alarm(fsm_alarm), .debug_unlock(debug_unlock_sen),
        .tamper_counter(tamper_counter), .zeroize_req(zeroize_req), .lockdown_state(lockdown)
    );

    tripwire_zeroize u_trip (
        .clk(clk_sen), .por_n(por_sen_n), .zeroize_req(zeroize_req),
        .async_zeroize_n(async_zeroize_n)
    );
endmodule
