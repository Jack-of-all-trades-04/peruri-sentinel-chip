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
//   tamper_persist_fsm (NVM-backed counters) -> tripwire_zeroize
//     -> async clear of the key vault
//
// Crossings
//   fast events (TDL alert, harness alarm) -> stretched to FAST_HOLD
//     CLK_sys cycles -> sentinel domain (sync_2ff): counted once per burst
//   slow alarm (selected detector) -> stretched to SLOW_HOLD sentinel
//     cycles -> CLK_sys (sync_2ff): blocks releases while it is high
//   ready, lockdown, counters -> CLK_sys through sync_2ff (levels; counters
//     are for the LED display only)
//   operation handshake with the NVM-backed controller, same sequence as
//   Tier 1 but over toggle crossings (cdc_toggle_tx / cdc_toggle_rx):
//     sys -> sen  start   toggle on an accepted request; in sen a pending flag
//                         drives start_req while the controller is ready
//     sen -> sys  grant   toggle after the MARK write; starts the DPA/AES
//     sys -> sen  op_done toggle from the gate's decision point
//     sen -> sys  commit  clean bit registered and held, then the toggle; sys
//                         samples the held bit when it sees the edge and drives
//                         the gate's commit_fin / commit_clean for one cycle
//   The controller answers every start exactly once (commit toggle). If it
//   cannot take a start (abort or lockdown while the start is pending), it
//   answers with commit_clean = 0 instead, so the sys side never hangs.
//   The toggles and the sys-side "open request" flag are on the power-on
//   resets only, so a user reset in one domain cannot fake or hide an edge.
//   A user reset in CLK_sys (rst_sys_n) is also sent to the sentinel domain as
//   a level and, like rst_sen_n and power_warn, aborts an operation in
//   progress: the controller counts one tear and closes the handshake.
//   The TDL alert still goes to the gate directly, without any crossing.
//   Assumption: a user reset lasts at least 3 cycles of the slower clock
//   (KEY0 is debounced, so this holds on the board).
//
// Clock and liveness guard (fail-secure)
//   Threats: CLK_sentinel stopped or slowed (the RO/LIF windows stop, the slow
//   path goes silent and nothing is counted) and CLK_sys stopped, slowed or
//   sped up grossly. Two independent mechanisms:
//   1. Clock monitors. A dedicated local ring oscillator (ro_cell, always
//      enabled) is the time base for two clock_monitor instances, one on
//      CLK_sys and one on CLK_sentinel. Each counts clock edges per
//      MON_WINDOW cycles of the divided oscillator (osc/4); zero, <= LO or
//      >= HI raises an alarm.
//      The oscillator domain keeps `bad_any` = "the last window was bad" and
//      crosses it as a level into both domains (sync_2ff).
//   2. Heartbeat. Each domain flips a toggle every HB_K of its own cycles; the
//      other domain synchronizes it and flags `dead` when no edge arrives for
//      HB_TO local cycles. It does not depend on the oscillator.
//      A third pair of watchers checks the oscillator itself (window toggle,
//      RO_TO local cycles), so a stopped time base cannot silence mechanism 1.
//   Effects in CLK_sys: clk_fault (monitor or dead time base) and sen_dead
//   (heartbeat) are sticky until the user reset (KEY0 or POR). The sticky
//   bit can be cleared by the user reset because every event is also counted
//   in the NVM record (below), so an attacker gains at most N events; a bad
//   clock that is still bad sets the bit again at once. While a fault level
//   or a sticky bit is set, alarm_sys blocks the gate and req_accept is
//   refused. Effects in CLK_sentinel: the level goes into fsm_alarm, so the
//   controller counts one alarm per event (rising edge), as for any alarm;
//   a missing CLK_sys heartbeat counts only while an operation is open; the
//   sticky sen_dead bit is also passed to the sentinel domain, so the event
//   is counted even if the oscillator is broken.
//   Stopped CLK_sys: the sys domain cannot register a fault while its own
//   clock is stopped, and a 2-flop synchronizer would deliver the fault only
//   two cycles after the clock returns, too late for an answer already in
//   flight. So the monitor level `bad_any` (a flop in the oscillator domain)
//   also sets a flag in CLK_sys ASYNCHRONOUSLY (clk_flag_a, async set, cleared
//   by the user reset): it is already high when the first cycle after the
//   restart begins, blocks the gate from that cycle on, and ct_valid / ct_out
//   are masked while any guard fault is set, so a release that was decided
//   before the stop but is still in the output pipeline is not delivered.
//   Detection needs the stop to last 1 to 2 monitor windows; a shorter stop is
//   below the gross-tamper threshold of this block (the TDL covers short
//   cycles).
//   Warm-up: no operation is accepted until (a) MON_WARM consecutive clean
//   monitor windows have been seen after power-on and (b) the first heartbeat
//   edge of CLK_sentinel has arrived. Nothing is judged before that, so there
//   is no alarm during warm-up either. Warm-up is MON_WARM windows
//   = 4 x 1,02 us = 4,1 us for an oscillator near 250 MHz (estimasi), plus
//   the synchronizer; the first heartbeat edge of CLK_sentinel needs at most
//   HB_K cycles (1,28 us at 50 MHz); the two run in parallel.
//   Demo builds: with sentinel_en_sys / sentinel_en_sen = 0 ("Sentinel OFF")
//   none of these alarms fire or count, so the DFA leakage demo still works.
//   The warm-up readiness is independent of Sentinel OFF.
//   Sizing (estimasi, CLK_sys 80 MHz, CLK_sentinel 50 MHz, oscillator model
//   250 MHz, window 64 x osc/4 = 256 oscillator cycles = 1,02 us): nominal edges per
//   window sys 82, sen 51. LO_SYS 24 (0,29x), HI_SYS 160 (1,95x), LO_SEN 14
//   (0,27x), HI_SEN 100 (1,95x): stop, slower than 1/4x and faster than 2x
//   alarm; nominal stays inside as long as the oscillator runs between about
//   130 and 850 MHz (sys: 256 x 80 / f must stay in (24, 160)).
//   The real FPGA oscillator frequency is unknown until the board test: the
//   bounds are parameters and must be recomputed from the measured frequency.
//   Heartbeat: HB_K 64, HB_TO 512: alarm for a stopped peer and for a peer
//   about 8x slower than the local clock. RO_TO 2048 local cycles: alarm if
//   the time base stops or runs about 40x slower than nominal.
//
// DETECTOR_SEL selects which slow detector drives the alarm:
//   0 = LIF (default), 1 = EWMA only, 2 = fixed threshold, 3 = none.
// fsm_mask (debug/calibration mode) stops alarms from being counted, so a
// board with an uncalibrated sensor cannot lock itself; the gate still
// blocks. It is honoured only when DEMO_UNLOCK = 1.
//
// Builds: with DEMO_BUILD defined the core has the demo ports (Sentinel
// enable, fault hook, harness alarm, debug unlock, fsm_mask, round_idx), the
// DEMO_KEY constant and the ablation detectors (DETECTOR_SEL). Without it
// (production) none of these exist: Sentinel always on, the LIF detector
// drives the slow path, and the key is written once per power-on through
// key_wr_en / key_wr_data.
module peruri_sentinel_core_t2 #(
    parameter integer H            = 4,
    parameter integer N            = 4,
    parameter integer M            = 8,      // tear lockdown threshold
    parameter integer CW           = 4,      // counter width
    parameter integer DPA_ENABLE   = 1,
`ifdef DEMO_BUILD
    parameter integer DEMO_UNLOCK  = 1,
    parameter [127:0] DEMO_KEY     = 128'h000102030405060708090a0b0c0d0e0f,
    parameter integer DETECTOR_SEL = 0,
`endif
    // TDL
    parameter integer TDL_L        = 64,
    parameter integer TDL_COARSE   = 63,     // max coarse LUTs, tap chosen at run time
    parameter integer TDL_K        = 4,
    parameter integer TDL_SETTLE   = 1024,
    parameter integer TDL_WIN      = 4096,
    // RO / slow path
    parameter integer RO_NUM       = 8,
    parameter integer RO_STAGES    = 13,
    parameter integer RO_DIV_BITS  = 3,
    parameter integer RO_WINDOW    = 256,
    parameter integer RO_CNT_W     = 12,     // per-window RO count width: up to 4095 divided-RO cycles
                                             // per window, far above the expected count (estimasi)
    parameter integer P2SE_DTH     = 8,
    parameter integer ABL_FTH      = 12,
    parameter integer ABL_ETH      = 8,
    // crossings
    parameter integer FAST_HOLD    = 16,     // CLK_sys cycles
    parameter integer SLOW_HOLD    = 1024,   // CLK_sentinel cycles
    // clock monitors and heartbeat (see the header)
    parameter integer MON_STAGES   = 13,     // time-base oscillator ring length (odd)
    parameter integer MON_WINDOW   = 64,     // window length in cycles of osc/4 (= 256 oscillator cycles)
    parameter integer MON_LO_SYS   = 24,
    parameter integer MON_HI_SYS   = 160,
    parameter integer MON_LO_SEN   = 14,
    parameter integer MON_HI_SEN   = 100,
    parameter integer MON_WARM     = 4,      // clean windows before the first grant
    parameter integer HB_K         = 64,     // heartbeat toggle period, source cycles
    parameter integer HB_TO        = 512,    // heartbeat timeout, local cycles
    parameter integer RO_TO        = 2048,   // time-base window timeout, local cycles
    parameter integer RECW         = 17 + 2*CW   // NVM record width (derived)
) (
    // CLK_sys domain
    input  wire         clk_sys,
    input  wire         rst_sys_n,       // user reset (KEY0) + POR
    input  wire         por_sys_n,       // POR only, CLK_sys domain (key vault seal)
    input  wire         op_req,
    input  wire [127:0] pt,
`ifdef DEMO_BUILD
    input  wire         sentinel_en_sys,
    input  wire         fault_en,        // demo harness only
    input  wire [3:0]   fault_round,
    input  wire [3:0]   fault_byte,
    input  wire [7:0]   fault_mask,
    input  wire         harness_alarm,   // demo harness only (Tier 1 mode)
    output wire [3:0]   round_idx,
`else
    input  wire         key_wr_en,       // write-only key port (once per power-on)
    input  wire [127:0] key_wr_data,
`endif
    output wire [127:0] ct_out,
    output wire         ct_valid,
    output wire         gate_blocked,
    output wire         busy,
    output wire         key_is_zero,
    output wire         lockdown_sys,
    output wire [CW-1:0] tamper_counter_sys,
    output wire [CW-1:0] tear_count_sys,
    output wire         alarm_sys,       // what the gate sees
    output wire         clk_fault,       // sticky: clock monitor / time base fault (user reset clears)
    output wire         sen_dead,        // sticky: CLK_sentinel heartbeat lost (user reset clears)
    output wire         tdl_alert,
    output wire         tdl_armed,
    output wire         tdl_cal_bad,
    output wire [$clog2(TDL_L+1)-1:0] tdl_depth,
    output wire [$clog2(TDL_L+1)-1:0] tdl_min_r,
    output wire [$clog2(TDL_COARSE+1)-1:0] tdl_sel,
    // CLK_sentinel domain
    input  wire         clk_sen,
    input  wire         rst_sen_n,       // user reset + POR (sensor pipeline)
    input  wire         por_sen_n,       // POR only (persistent tamper state)
`ifdef DEMO_BUILD
    input  wire         sentinel_en_sen,
    input  wire         debug_unlock_sen,
    input  wire         fsm_mask_sen,
    output wire         ewma_alarm,
    output wire         fixed_alarm,
`endif
    input  wire         power_warn,      // supply/RF droop flag, CLK_sentinel domain (synchronous)
    // host NVM holding the tamper record (CLK_sentinel domain)
    output wire         nvm_rd_en,
    output wire         nvm_rd_addr,
    input  wire [RECW-1:0] nvm_rd_data,
    input  wire         nvm_rd_valid,
    output wire         nvm_wr_en,
    output wire         nvm_wr_addr,
    output wire [RECW-1:0] nvm_wr_data,
    input  wire         nvm_wr_done,
    input  wire         ro_en,
    output wire [CW-1:0] tamper_counter, // = alarm_count
    output wire [CW-1:0] tear_count,
    output wire         lockdown,
    output wire         lif_alarm,
    output wire [11:0]  spike_bus
);
`ifndef DEMO_BUILD
    // production: Sentinel always on, no harness, no unlock, no mask
    wire sentinel_en_sys = 1'b1;
    wire sentinel_en_sen = 1'b1;
    wire harness_alarm   = 1'b0;
`endif
    // =========================== CLK_sys ===========================
    wire [127:0] key;
    wire         go, aes_done, aes_busy, key_loaded;
    wire         gate_op_done, gate_busy;
    wire [127:0] ct_raw;
    wire [127:0] ct_out_g;
    wire         ct_valid_g;
    wire [1:0]   dummy_cnt;
    wire         async_zeroize_n;
    wire         slow_lvl_sys;
    wire         slow_lvl_sen_w;   // driven in the sentinel domain below
    // tamper controller side (CLK_sentinel), declared here for the crossings
    wire         fsm_ready, fsm_op_grant, fsm_commit_fin, fsm_commit_clean;
    wire         t_start, t_grant, t_done, t_commit;   // toggle levels
    reg          clean_hold;                            // CLK_sentinel, held until the next commit

    tdl_glitch_line #(
        .L(TDL_L), .COARSE(TDL_COARSE), .K_TDL(TDL_K),
        .CAL_SETTLE(TDL_SETTLE), .CAL_WIN(TDL_WIN)
    ) u_tdl (
        .clk(clk_sys), .rst_n(rst_sys_n), .enable(sentinel_en_sys),
        .alert(tdl_alert), .armed(tdl_armed), .cal_bad(tdl_cal_bad),
        .depth_q(tdl_depth), .min_r(tdl_min_r), .min_f(), .sel(tdl_sel)
    );

    sync_2ff u_s_slow (.clk(clk_sys), .rst_n(rst_sys_n), .d(slow_lvl_sen_w), .q(slow_lvl_sys));
    sync_2ff u_s_lock (.clk(clk_sys), .rst_n(rst_sys_n), .d(lockdown), .q(lockdown_sys));
    wire ready_sys;
    sync_2ff u_s_rdy  (.clk(clk_sys), .rst_n(rst_sys_n), .d(fsm_ready), .q(ready_sys));
    genvar gi;
    generate
        for (gi = 0; gi < CW; gi = gi + 1) begin : g_cnt
            sync_2ff u_s_cnt (.clk(clk_sys), .rst_n(rst_sys_n), .d(tamper_counter[gi]),
                              .q(tamper_counter_sys[gi]));
            sync_2ff u_s_tear (.clk(clk_sys), .rst_n(rst_sys_n), .d(tear_count[gi]),
                               .q(tear_count_sys[gi]));
        end
    endgenerate

    // ---- clock monitors, heartbeat: CLK_sys side ----
    wire bad_any, warm_ro, win_tgl;          // oscillator domain, declared below
    wire hb_sen, hb_sys;                     // heartbeat toggles
    wire mon_bad_sys, warm_sys;
    sync_2ff u_s_bad_sys  (.clk(clk_sys), .rst_n(por_sys_n), .d(bad_any), .q(mon_bad_sys));
    sync_2ff u_s_warm_sys (.clk(clk_sys), .rst_n(por_sys_n), .d(warm_ro), .q(warm_sys));
    wire hb_seen_sys, hbsen_dead, ro_seen_sys, ro_dead_sys;
    heartbeat_watch #(.TO(HB_TO)) u_w_hbsen (
        .clk(clk_sys), .por_n(por_sys_n), .tgl(hb_sen), .seen(hb_seen_sys), .dead(hbsen_dead));
    heartbeat_watch #(.TO(RO_TO)) u_w_ro_sys (
        .clk(clk_sys), .por_n(por_sys_n), .tgl(win_tgl), .seen(ro_seen_sys), .dead(ro_dead_sys));
    heartbeat_gen #(.K(HB_K)) u_hb_sys (.clk(clk_sys), .por_n(por_sys_n), .tgl(hb_sys));

    // asynchronous path from the oscillator domain (see the header)
    reg  clk_flag_a;
    wire clk_set_a = sentinel_en_sys & bad_any;
    always @(posedge clk_sys or posedge clk_set_a) begin
        if (clk_set_a)       clk_flag_a <= 1'b1;
        else if (!rst_sys_n) clk_flag_a <= 1'b0;
    end
    wire clkf_lvl = mon_bad_sys | ro_dead_sys;
    wire dead_lvl = hbsen_dead;
    reg  clk_fault_q, sen_dead_q;
    always @(posedge clk_sys or negedge rst_sys_n) begin
        if (!rst_sys_n) begin
            clk_fault_q <= 1'b0;
            sen_dead_q  <= 1'b0;
        end else begin
            if (sentinel_en_sys & clkf_lvl) clk_fault_q <= 1'b1;
            if (sentinel_en_sys & dead_lvl) sen_dead_q  <= 1'b1;
        end
    end
    assign clk_fault = clk_fault_q | clk_flag_a;
    assign sen_dead  = sen_dead_q;
    wire fault_sys  = sentinel_en_sys & (clk_fault_q | sen_dead_q | clkf_lvl | dead_lvl) | clk_flag_a;
    // operations are accepted only after warm-up and while there is no fault
    wire permit_sys = hb_seen_sys & warm_sys & ~fault_sys;

    // gate alarm: TDL directly, slow path and clock faults through synchronizers
    assign alarm_sys = sentinel_en_sys & (tdl_alert | harness_alarm | slow_lvl_sys | fault_sys);

    // ---- operation handshake, CLK_sys side ----
    // commit answer from the controller: edge of t_commit, then the held
    // clean bit is sampled (it has been stable since before the toggle flipped)
    wire commit_edge, grant_edge;
    cdc_toggle_rx u_rx_commit (.clk(clk_sys), .rst_n(por_sys_n), .tgl(t_commit), .pulse(commit_edge));
    cdc_toggle_rx u_rx_grant  (.clk(clk_sys), .rst_n(por_sys_n), .tgl(t_grant),  .pulse(grant_edge));
    reg commit_fin_sys, commit_clean_sys;
    always @(posedge clk_sys or negedge por_sys_n) begin
        if (!por_sys_n) begin
            commit_fin_sys   <= 1'b0;
            commit_clean_sys <= 1'b0;
        end else begin
            commit_fin_sys <= commit_edge;
            if (commit_edge) commit_clean_sys <= clean_hold;
        end
    end

    // `outstanding`: a start was sent and its commit answer has not arrived.
    // The controller answers every start exactly once, so a new request is
    // accepted only after that answer. It is not cleared by the user reset: an
    // answer to a request cut short by KEY0 must still be consumed, otherwise
    // it would be mistaken for the answer to the next request.
    // `stale`: the user reset hit while a request was open. Its grant (if it
    // arrives later) is dropped; only its commit answer closes the handshake.
    // An ignored request (not ready, locked, busy) never sets either flag.
    reg outstanding, stale;
    wire req_accept = op_req & ready_sys & permit_sys & ~lockdown_sys & key_loaded & ~aes_busy
                    & ~outstanding & ~gate_busy;
    always @(posedge clk_sys or negedge por_sys_n) begin
        if (!por_sys_n) begin
            outstanding <= 1'b0;
            stale       <= 1'b0;
        end else if (commit_fin_sys) begin
            outstanding <= 1'b0;
            stale       <= 1'b0;
        end else begin
            if (req_accept)  outstanding <= 1'b1;
            if (!rst_sys_n)  stale       <= outstanding;
        end
    end

    cdc_toggle_tx u_tx_start (.clk(clk_sys), .rst_n(por_sys_n), .pulse(req_accept),    .tgl(t_start));
    cdc_toggle_tx u_tx_done  (.clk(clk_sys), .rst_n(por_sys_n), .pulse(gate_op_done),  .tgl(t_done));

    wire grant_ok = grant_edge & ~stale;
    dpa_hiding_lfsr #(.ENABLE(DPA_ENABLE)) u_dpa (
        .clk(clk_sys), .rst_n(rst_sys_n),
        .req(grant_ok),
        .go(go), .dummy_cnt(dummy_cnt)
    );

`ifdef DEMO_BUILD
    master_key_vault #(.DEMO_KEY(DEMO_KEY)) u_vault (
        .clk(clk_sys), .rst_n(rst_sys_n), .por_n(por_sys_n), .async_zeroize_n(async_zeroize_n),
        .key_to_cipher(key), .key_loaded(key_loaded)
    );
`else
    master_key_vault u_vault (
        .clk(clk_sys), .rst_n(rst_sys_n), .por_n(por_sys_n), .async_zeroize_n(async_zeroize_n),
        .key_wr_en(key_wr_en), .key_wr_data(key_wr_data),
        .key_to_cipher(key), .key_loaded(key_loaded)
    );
`endif

    // The AES only starts for an operation the controller has marked and not
    // yet closed: a `go` that arrives after an abort (commit answer before the
    // DPA dummy cycles end) is dropped.
    reg op_live;
    always @(posedge clk_sys or negedge rst_sys_n) begin
        if (!rst_sys_n)           op_live <= 1'b0;
        else if (commit_fin_sys)  op_live <= 1'b0;
        else if (grant_ok)        op_live <= 1'b1;
        else if (go)              op_live <= 1'b0;
    end
    // `~commit_fin_sys`: a `go` in the same cycle as the controller's answer
    // (abort) must not start the AES; the answer closes the operation.
    wire start = go & op_live & ~commit_fin_sys & ~lockdown_sys;

    aes128_core u_aes (
        .clk(clk_sys), .rst_n(rst_sys_n), .start(start),
        .key(key), .pt(pt),
`ifdef DEMO_BUILD
        .fault_en(fault_en), .fault_round(fault_round),
        .fault_byte(fault_byte), .fault_mask(fault_mask),
        .round_idx(round_idx),
`endif
        .ct_raw(ct_raw), .done(aes_done), .busy(aes_busy)
    );

    output_release_gate #(.H(H)) u_gate (
        .clk(clk_sys), .rst_n(rst_sys_n),
`ifdef DEMO_BUILD
        .enable(sentinel_en_sys),
`endif
        .lockdown(lockdown_sys),
        .op_start(start), .aes_done(aes_done), .ct_raw(ct_raw),
        .alarm(alarm_sys),
        .commit_fin(commit_fin_sys), .commit_clean(commit_clean_sys),
        .ct_out(ct_out_g), .ct_valid(ct_valid_g),
        .gate_blocked(gate_blocked), .op_done(gate_op_done), .busy(gate_busy)
    );

    // While a clock / heartbeat fault is set nothing leaves the core, even a
    // release the gate decided just before CLK_sys stopped.
    assign ct_valid = ct_valid_g & ~fault_sys;
    assign ct_out   = ct_out_g & {128{~fault_sys}};

    // fast events to the sentinel domain: stretch so a burst is one level
    wire fast_lvl_sys;
    pulse_stretch #(.CYCLES(FAST_HOLD)) u_ps_fast (
        .clk(clk_sys), .rst_n(rst_sys_n),
        .p(sentinel_en_sys & (tdl_alert | harness_alarm)), .q(fast_lvl_sys)
    );

    assign busy        = aes_busy | outstanding | gate_busy | ~ready_sys | ~permit_sys;
    assign key_is_zero = (key == 128'h0);

    // ========================= CLK_sentinel =========================
    wire fast_lvl_sen;
    sync_2ff u_s_fast (.clk(clk_sen), .rst_n(rst_sen_n), .d(fast_lvl_sys), .q(fast_lvl_sen));

    wire [RO_NUM*RO_CNT_W-1:0] ro_counts;
    wire                 ro_valid;
    ro_sensor_mesh #(
        .NUM(RO_NUM), .STAGES(RO_STAGES), .DIV_BITS(RO_DIV_BITS),
        .CNT_W(RO_CNT_W), .WINDOW(RO_WINDOW)
    ) u_mesh (
        .clk(clk_sen), .rst_n(rst_sen_n), .en(ro_en),
        .ro_counts(ro_counts), .valid(ro_valid)
    );

    wire tick;
    p2se_encoder #(.NUM(RO_NUM), .CNT_W(RO_CNT_W), .DTH(P2SE_DTH)) u_p2se (
        .clk(clk_sen), .rst_n(rst_sen_n), .ro_counts(ro_counts), .ro_valid(ro_valid),
        .tdl_event(fast_lvl_sen), .spike_bus(spike_bus), .tick(tick)
    );

    wire [7:0] fire;
    snn_lif_engine u_lif (
        .clk(clk_sen), .rst_n(rst_sen_n), .tick(tick), .spike_bus(spike_bus),
        .fire(fire), .anomaly_alarm(lif_alarm)
    );

`ifdef DEMO_BUILD
    // ablation reference detectors: demo/test build only
    ablation_detectors #(.NUM(RO_NUM), .CNT_W(RO_CNT_W), .FTH(ABL_FTH), .ETH(ABL_ETH)) u_abl (
        .clk(clk_sen), .rst_n(rst_sen_n), .ro_counts(ro_counts), .ro_valid(ro_valid),
        .fixed_alarm(fixed_alarm), .ewma_alarm(ewma_alarm)
    );

    wire slow_pulse = (DETECTOR_SEL == 0) ? lif_alarm   :
                      (DETECTOR_SEL == 1) ? ewma_alarm  :
                      (DETECTOR_SEL == 2) ? fixed_alarm : 1'b0;
`else
    wire slow_pulse = lif_alarm;
`endif

    pulse_stretch #(.CYCLES(SLOW_HOLD)) u_ps_slow (
        .clk(clk_sen), .rst_n(rst_sen_n), .p(sentinel_en_sen & slow_pulse), .q(slow_lvl_sen_w)
    );

`ifdef DEMO_BUILD
    wire mask = (DEMO_UNLOCK != 0) & fsm_mask_sen;
`else
    wire mask = 1'b0;
`endif

    // ---- clock monitors and heartbeat: CLK_sentinel side ----
    wire mon_bad_sen, sysflag_sen;
    sync_2ff u_s_bad_sen  (.clk(clk_sen), .rst_n(por_sen_n), .d(bad_any), .q(mon_bad_sen));
    sync_2ff u_s_sdead    (.clk(clk_sen), .rst_n(por_sen_n), .d(sen_dead_q), .q(sysflag_sen));
    heartbeat_gen #(.K(HB_K)) u_hb_sen (.clk(clk_sen), .por_n(por_sen_n), .tgl(hb_sen));
    wire hb_seen_sen, hbsys_dead, ro_seen_sen, ro_dead_sen;
    heartbeat_watch #(.TO(HB_TO)) u_w_hbsys (
        .clk(clk_sen), .por_n(por_sen_n), .tgl(hb_sys), .seen(hb_seen_sen), .dead(hbsys_dead));
    heartbeat_watch #(.TO(RO_TO)) u_w_ro_sen (
        .clk(clk_sen), .por_n(por_sen_n), .tgl(win_tgl), .seen(ro_seen_sen), .dead(ro_dead_sen));
    // an operation is open from the start toggle until the controller answers
    reg op_open_sen;
    wire start_edge, done_edge;
    wire clkf_lvl_sen = mon_bad_sen | ro_dead_sen | sysflag_sen | (hbsys_dead & op_open_sen);

    wire fsm_alarm = sentinel_en_sen & ~mask & (fast_lvl_sen | slow_lvl_sen_w | clkf_lvl_sen);

    // ---- operation handshake, CLK_sentinel side ----
    // Abort sources: power_warn, the user reset of this domain, and the user
    // reset of CLK_sys (as a level). Any of them during MARK/RUN makes the
    // controller count one tear and answer with commit_clean = 0.
    wire sysrst_n_sen;
    sync_2ff #(.RESET_VAL(1'b1)) u_s_srst (.clk(clk_sen), .rst_n(por_sen_n), .d(rst_sys_n), .q(sysrst_n_sen));
    wire abort_in = power_warn | ~rst_sen_n | ~sysrst_n_sen;

    cdc_toggle_rx u_rx_start (.clk(clk_sen), .rst_n(por_sen_n), .tgl(t_start), .pulse(start_edge));
    cdc_toggle_rx u_rx_done  (.clk(clk_sen), .rst_n(por_sen_n), .tgl(t_done),  .pulse(done_edge));

    // A start waits in `pend` until the controller is ready. If an abort or a
    // lockdown shows up while it waits, the start is dropped and answered with
    // commit_clean = 0, so the sys side never waits for a grant that cannot come.
    reg  pend;
    wire take      = pend & fsm_ready;
    wire drop_fire = pend & ~fsm_ready & (abort_in | lockdown) & ~start_edge;
    always @(posedge clk_sen or negedge por_sen_n) begin
        if (!por_sen_n)                   pend <= 1'b0;
        else if (start_edge)              pend <= 1'b1;
        else if (take || drop_fire)       pend <= 1'b0;
    end

    always @(posedge clk_sen or negedge por_sen_n) begin
        if (!por_sen_n)                          op_open_sen <= 1'b0;
        else if (start_edge)                     op_open_sen <= 1'b1;
        else if (fsm_commit_fin || drop_fire)    op_open_sen <= 1'b0;
    end

    // commit answer: clean bit first, toggle one cycle later
    reg fin_ev_d;
    always @(posedge clk_sen or negedge por_sen_n) begin
        if (!por_sen_n) begin
            fin_ev_d   <= 1'b0;
            clean_hold <= 1'b0;
        end else begin
            fin_ev_d <= fsm_commit_fin | drop_fire;
            if (fsm_commit_fin)    clean_hold <= fsm_commit_clean;
            else if (drop_fire)    clean_hold <= 1'b0;
        end
    end
    cdc_toggle_tx u_tx_commit (.clk(clk_sen), .rst_n(por_sen_n), .pulse(fin_ev_d),       .tgl(t_commit));
    cdc_toggle_tx u_tx_grant  (.clk(clk_sen), .rst_n(por_sen_n), .pulse(fsm_op_grant),   .tgl(t_grant));

    wire zeroize_req, boot_busy;
`ifdef DEMO_BUILD
    wire unlock_in = debug_unlock_sen;
`else
    wire unlock_in = 1'b0;
`endif
    tamper_persist_fsm #(
        .N(N), .M(M), .CW(CW),
`ifdef DEMO_BUILD
        .DEMO_UNLOCK(DEMO_UNLOCK)
`else
        .DEMO_UNLOCK(0)
`endif
    ) u_fsm (
        .clk(clk_sen), .por_n(por_sen_n), .alarm(fsm_alarm), .power_warn(abort_in),
        .start_req(take), .op_done(done_edge), .debug_unlock(unlock_in),
        .nvm_rd_en(nvm_rd_en), .nvm_rd_addr(nvm_rd_addr), .nvm_rd_data(nvm_rd_data),
        .nvm_rd_valid(nvm_rd_valid), .nvm_wr_en(nvm_wr_en), .nvm_wr_addr(nvm_wr_addr),
        .nvm_wr_data(nvm_wr_data), .nvm_wr_done(nvm_wr_done),
        .ready(fsm_ready), .op_grant(fsm_op_grant), .commit_fin(fsm_commit_fin),
        .commit_clean(fsm_commit_clean), .boot_busy(boot_busy),
        .zeroize_req(zeroize_req), .lockdown_state(lockdown),
        .alarm_count(tamper_counter), .tear_count(tear_count)
    );

    // ======================= oscillator domain =======================
    // Local time base for the two clock monitors. Always enabled, reset only
    // by the power-on resets. The ring is divided by 4 (ripple divider, as in
    // ro_sensor_mesh) so that the window logic, which has a path of several
    // nanoseconds, runs far below the ring frequency whatever the silicon
    // delay is. The divided clock mon_clk is the monitor clock; its reset is
    // released synchronously in that domain.
    wire mon_osc, mon_rst_n, mon_clk;
    wire mon_arst_n = por_sys_n & por_sen_n;
    ro_cell #(.STAGES(MON_STAGES)) u_mon_ro (.en(1'b1), .osc(mon_osc));
    reg mon_d0, mon_d1;
    always @(posedge mon_osc or negedge mon_arst_n)
        if (!mon_arst_n) mon_d0 <= 1'b0;
        else             mon_d0 <= ~mon_d0;
    always @(negedge mon_d0 or negedge mon_arst_n)
        if (!mon_arst_n) mon_d1 <= 1'b0;
        else             mon_d1 <= ~mon_d1;
    assign mon_clk = mon_d1;
    reset_sync u_rs_mon (.clk(mon_clk), .arst_n(mon_arst_n), .rst_n(mon_rst_n));

    wire mon_alm_s, mon_val_s, mon_alm_n, mon_val_n;
    clock_monitor #(.WINDOW(MON_WINDOW), .LO(MON_LO_SYS), .HI(MON_HI_SYS), .CW(12)) u_mon_sys (
        .ro_clk(mon_clk), .rst_n(mon_rst_n), .en(1'b1), .clk_mon(clk_sys),
        .alarm(mon_alm_s), .valid(mon_val_s)
    );
    clock_monitor #(.WINDOW(MON_WINDOW), .LO(MON_LO_SEN), .HI(MON_HI_SEN), .CW(12)) u_mon_sen (
        .ro_clk(mon_clk), .rst_n(mon_rst_n), .en(1'b1), .clk_mon(clk_sen),
        .alarm(mon_alm_n), .valid(mon_val_n)
    );

    // Both monitors share the oscillator, the reset and the window length, so
    // their `valid` pulses coincide. Until MON_WARM consecutive clean windows
    // have passed nothing is flagged (warm-up); afterwards `bad_any` follows
    // the latest window. `win_tgl` flips once per window (time-base watchdog).
    localparam integer WARM_W = $clog2(MON_WARM + 1);
    reg [WARM_W-1:0] warm_cnt;
    reg              warm_r, bad_r, win_r;
    always @(posedge mon_clk or negedge mon_rst_n) begin
        if (!mon_rst_n) begin
            warm_cnt <= {WARM_W{1'b0}};
            warm_r   <= 1'b0;
            bad_r    <= 1'b0;
            win_r    <= 1'b0;
        end else if (mon_val_s) begin
            win_r <= ~win_r;
            if (!warm_r) begin
                if (mon_alm_s | mon_alm_n)        warm_cnt <= {WARM_W{1'b0}};
                else if (warm_cnt == MON_WARM - 1) warm_r   <= 1'b1;
                else                              warm_cnt <= warm_cnt + 1'b1;
            end else begin
                bad_r <= mon_alm_s | mon_alm_n;
            end
        end
    end
    assign bad_any = bad_r;
    assign warm_ro = warm_r;
    assign win_tgl = win_r;

    tripwire_zeroize u_trip (
        .clk(clk_sen), .por_n(por_sen_n), .zeroize_req(zeroize_req),
        .async_zeroize_n(async_zeroize_n)
    );

    wire unused_ok = &{1'b0, dummy_cnt, boot_busy, mon_val_n, hb_seen_sen, ro_seen_sys, ro_seen_sen};
endmodule
