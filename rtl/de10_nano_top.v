// de10_nano_top: Tier 1 demo top for Terasic DE10-Nano (Cyclone V 5CSEBA6U23I7).
// Pure FPGA fabric, 50 MHz board clock, no HPS, no PLL.
//
// Controls
//   KEY0 (active low)  user reset. Hold SW3 high while pressing KEY0 for the
//                      demo-only debug unlock (clears LOCKDOWN for rehearsal).
//   KEY1 (active low)  with SW3 = 0: run the next encryption WITH a fault at
//                      round 9. With SW3 = 1, KEY1 selects a power scenario
//                      by SW2/SW1 (no fault is injected):
//                        SW3 SW2 SW1 = 1 0 0  card removed from the reader:
//                                             power-on reset of the core only;
//                                             the NVM model keeps its record
//                        1 0 1  power cut in the middle of the next encryption
//                        1 1 0  power_warn (droop) during the next encryption
//                        1 1 1  toggle LED[2:0] between alarm_count and
//                               tear_count
//   SW0                Sentinel enable (0 = OFF, faulty ciphertext leaks).
//   SW1                attack mode (SW3 = 0): 0 = clock-glitch emulation,
//                      1 = droop emulation (both are emulated byte faults).
//   SW3                debug unlock qualifier (see KEY0) / power scenarios.
// LEDs
//   LED[2:0] alarm_count (or tear_count, see KEY1 with SW3 SW2 SW1 = 111)
//   LED[3]   heartbeat (~1.5 Hz)
//   LED[4]   last released ciphertext matched FIPS-197 C.1 (off for 0.5 s
//            when a faulty ciphertext is released, off in LOCKDOWN)
//   LED[5]   release blocked by gate (0.5 s)
//   LED[6]   alarm seen (0.5 s)
//   LED[7]   LOCKDOWN, key zeroized
//
// Tier 1 alarm source: the demo harness raises the alarm in the round where
// it injects the fault. This tests gate and tamper-controller logic only;
// real TDL/RO sensors replace it in Tier 2.
//
// The tamper counters live in nvm_counter_model (registers that the core's
// power-on reset does not touch), standing in for the parent chip's NVM. A
// real board power-off or reprogramming still clears them; "card removed"
// above is the scenario the NVM is for.
module de10_nano_top #(
    parameter integer DEB_CYCLES     = 500000,     // 10 ms
    parameter integer STRETCH_CYCLES = 25000000,   // 0.5 s
    parameter integer OP_PERIOD      = 5000000,    // one clean op every 0.1 s
    parameter integer HB_BIT         = 24,         // 50 MHz / 2^25 ~ 1.5 Hz
    parameter integer N              = 4,
    parameter integer M              = 8,
    parameter integer H              = 4,
    parameter integer DEMO_UNLOCK    = 1,
    parameter integer CUT_CYCLES     = 16,         // length of an emulated power loss
    parameter integer NVM_WR_LAT     = 8
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

    wire clk = FPGA_CLK1_50;

    // ---------------- board power-on reset ----------------
    reg [3:0] por_cnt = 4'd0;       // power-up value 0 (FPGA configuration)
    always @(posedge clk)
        if (!por_cnt[3]) por_cnt <= por_cnt + 4'd1;
    wire por_n = por_cnt[3];

    // ---------------- board inputs ----------------
    wire key0_s, key1_s;
    wire [3:0] sw_s;
    sync_2ff #(.RESET_VAL(1'b1)) u_sk0 (.clk(clk), .rst_n(por_n), .d(KEY[0]), .q(key0_s));
    sync_2ff #(.RESET_VAL(1'b1)) u_sk1 (.clk(clk), .rst_n(por_n), .d(KEY[1]), .q(key1_s));
    sync_2ff u_ss0 (.clk(clk), .rst_n(por_n), .d(SW[0]), .q(sw_s[0]));
    sync_2ff u_ss1 (.clk(clk), .rst_n(por_n), .d(SW[1]), .q(sw_s[1]));
    sync_2ff u_ss2 (.clk(clk), .rst_n(por_n), .d(SW[2]), .q(sw_s[2]));
    sync_2ff u_ss3 (.clk(clk), .rst_n(por_n), .d(SW[3]), .q(sw_s[3]));

    wire key0_n, key1_n;   // debounced, active low
    debounce #(.CYCLES(DEB_CYCLES), .INIT(1'b1)) u_db0 (.clk(clk), .rst_n(por_n), .d(key0_s), .q(key0_n));
    debounce #(.CYCLES(DEB_CYCLES), .INIT(1'b1)) u_db1 (.clk(clk), .rst_n(por_n), .d(key1_s), .q(key1_n));

    wire sentinel_en  = sw_s[0];
    wire attack_mode  = sw_s[1];
    wire debug_unlock = sw_s[3] & ~key0_n;

    reg key1_d;
    always @(posedge clk or negedge por_n)
        if (!por_n) key1_d <= 1'b1;
        else        key1_d <= key1_n;
    wire key1_press   = key1_d & ~key1_n;       // falling edge = press
    wire attack_press = key1_press & ~sw_s[3];
    wire p_card       = key1_press &  sw_s[3] & ~sw_s[2] & ~sw_s[1];
    wire p_cut        = key1_press &  sw_s[3] & ~sw_s[2] &  sw_s[1];
    wire p_warn       = key1_press &  sw_s[3] &  sw_s[2] & ~sw_s[1];
    wire p_view       = key1_press &  sw_s[3] &  sw_s[2] &  sw_s[1];

    // ---------------- emulated power loss of the core ----------------
    wire [3:0] round_idx;
    reg        cut_pending, warn_pending, warn_active, tear_view;
    reg [$clog2(CUT_CYCLES+1)-1:0] cut_cnt;
    wire cutting = (cut_cnt != 0);
    always @(posedge clk or negedge por_n) begin
        if (!por_n) begin
            cut_cnt      <= 0;
            cut_pending  <= 1'b0;
            warn_pending <= 1'b0;
            warn_active  <= 1'b0;
            tear_view    <= 1'b0;
        end else begin
            if (p_view) tear_view <= ~tear_view;
            if (p_cut)  cut_pending  <= 1'b1;
            if (p_warn) warn_pending <= 1'b1;
            // card removed now; or power cut once the AES is at round 5
            if (p_card || (cut_pending && round_idx == 4'd5)) begin
                cut_cnt     <= CUT_CYCLES;
                cut_pending <= 1'b0;
            end else if (cutting)
                cut_cnt <= cut_cnt - 1'b1;
            // droop flagged by power_warn while the AES is in rounds 3..6
            warn_active <= warn_pending && (round_idx >= 4'd3) && (round_idx <= 4'd6);
            if (warn_active) warn_pending <= 1'b0;
        end
    end

    wire core_por_n = por_n & ~cutting;          // core power-on reset
    wire rst_n      = core_por_n & key0_n;        // user reset (also during a cut)

    // ---------------- demo harness: operation scheduler ----------------
    wire         core_busy;
    wire [127:0] ct_out;
    wire         ct_valid, gate_blocked, lockdown, key_is_zero;
    wire [CW-1:0] alarm_count, tear_count;

    localparam integer TW = $clog2(OP_PERIOD + 1);
    reg [TW-1:0] op_timer;
    reg          attack_pending;
    reg          cur_fault;
    reg          op_req;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            op_timer       <= {TW{1'b0}};
            attack_pending <= 1'b0;
            cur_fault      <= 1'b0;
            op_req         <= 1'b0;
        end else begin
            op_req <= 1'b0;
            if (attack_press) attack_pending <= 1'b1;
            if (op_timer >= OP_PERIOD - 1) begin
                if (!core_busy && !lockdown) begin
                    op_req    <= 1'b1;
                    cur_fault <= attack_pending | attack_press;
                    attack_pending <= 1'b0;
                    op_timer  <= {TW{1'b0}};
                end
            end else begin
                op_timer <= op_timer + 1'b1;
            end
        end
    end

    wire [3:0] f_round = 4'd9;
    wire [3:0] f_byte  = attack_mode ? 4'd5  : 4'd0;
    wire [7:0] f_mask  = attack_mode ? 8'hff : 8'h01;

    // Harness alarm: one cycle, in the round where the fault is injected.
    wire harness_alarm = cur_fault & core_busy & (round_idx == f_round);

    // ---------------- NVM model (parent chip NVM stand-in) ----------------
    wire            nvm_rd_en, nvm_rd_addr, nvm_rd_valid, nvm_wr_en, nvm_wr_addr, nvm_wr_done;
    wire [RECW-1:0] nvm_rd_data, nvm_wr_data;
    nvm_counter_model #(.CW(CW), .RD_LAT(2), .WR_LAT(NVM_WR_LAT), .INIT_BLANK(0)) u_nvm (
        .clk(clk), .power_ok(~cutting),
        .rd_en(nvm_rd_en), .rd_addr(nvm_rd_addr), .rd_data(nvm_rd_data), .rd_valid(nvm_rd_valid),
        .wr_en(nvm_wr_en), .wr_addr(nvm_wr_addr), .wr_data(nvm_wr_data), .wr_done(nvm_wr_done)
    );

    // ---------------- Sentinel core ----------------
    peruri_sentinel_core #(
        .H(H), .N(N), .M(M), .CW(CW), .DEMO_UNLOCK(DEMO_UNLOCK), .DPA_ENABLE(1),
        .DEMO_KEY(DEMO_KEY)
    ) u_core (
        .clk(clk), .rst_n(rst_n), .por_n(core_por_n), .op_req(op_req), .pt(DEMO_PT),
        .alarm_in(harness_alarm), .power_warn(warn_active),
        .sentinel_en(sentinel_en),
        .fault_en(cur_fault), .fault_round(f_round), .fault_byte(f_byte), .fault_mask(f_mask),
        .debug_unlock(debug_unlock), .round_idx(round_idx),
        .nvm_rd_en(nvm_rd_en), .nvm_rd_addr(nvm_rd_addr), .nvm_rd_data(nvm_rd_data),
        .nvm_rd_valid(nvm_rd_valid), .nvm_wr_en(nvm_wr_en), .nvm_wr_addr(nvm_wr_addr),
        .nvm_wr_data(nvm_wr_data), .nvm_wr_done(nvm_wr_done),
        .ct_out(ct_out), .ct_valid(ct_valid), .gate_blocked(gate_blocked),
        .tamper_counter(alarm_count), .tear_count(tear_count),
        .lockdown(lockdown), .busy(core_busy), .key_is_zero(key_is_zero)
    );

    // ---------------- LED status ----------------
    wire released_ok  = ct_valid & (ct_out == EXP_CT);
    wire released_bad = ct_valid & (ct_out != EXP_CT);

    reg ok_latched;
    always @(posedge clk or negedge rst_n)
        if (!rst_n)            ok_latched <= 1'b0;
        else if (released_ok)  ok_latched <= 1'b1;
        else if (released_bad) ok_latched <= 1'b0;

    wire bad_led, blk_led, alm_led;
    pulse_stretch #(.CYCLES(STRETCH_CYCLES)) u_ps_bad (.clk(clk), .rst_n(por_n), .p(released_bad),  .q(bad_led));
    pulse_stretch #(.CYCLES(STRETCH_CYCLES)) u_ps_blk (.clk(clk), .rst_n(por_n), .p(gate_blocked), .q(blk_led));
    pulse_stretch #(.CYCLES(STRETCH_CYCLES)) u_ps_alm (.clk(clk), .rst_n(por_n), .p(harness_alarm & sentinel_en), .q(alm_led));

    reg [HB_BIT:0] hb;
    always @(posedge clk or negedge por_n)
        if (!por_n) hb <= 0;
        else        hb <= hb + 1'b1;

    wire [CW-1:0] cnt_show = tear_view ? tear_count : alarm_count;
    assign LED[2:0] = (cnt_show > 4'd7) ? 3'd7 : cnt_show[2:0];
    assign LED[3]   = hb[HB_BIT];
    assign LED[4]   = ok_latched & ~bad_led & ~lockdown;
    assign LED[5]   = blk_led;
    assign LED[6]   = alm_led;
    assign LED[7]   = lockdown & key_is_zero;
endmodule
