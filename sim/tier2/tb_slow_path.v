// Self-checking testbench for the slow path:
//   ro_sensor_mesh -> p2se_encoder -> snn_lif_engine, plus ablation_detectors.
// Ring oscillators are behavioral models whose half period the testbench
// changes. CLK_sentinel = 50 MHz, window = 256 cycles (5,12 us).
// Scenarios:
//   A stable                 -> no detector fires
//   B slow uniform drift     -> LIF and EWMA quiet, fixed threshold fires
//                               (the false alarm the ablation should show)
//   C fast local drop, 1 RO  -> LIF fires within a few windows
//   D fast uniform step      -> LIF quiet (common mode), EWMA-only fires
`timescale 1ns/1ps
module tb_slow_path;
    reg clk = 0;
    always #10 clk = ~clk;
    reg rst_n = 1;          // dropped at t = 1 ns so async resets see a real edge
    integer errors = 0;

    wire [8*16-1:0] counts;
    wire            valid, tick, lif, fixed_a, ewma_a;
    wire [11:0]     spikes;
    wire [7:0]      fire;

    ro_sensor_mesh #(.NUM(8), .DIV_BITS(3), .CNT_W(16), .WINDOW(256)) u_mesh (
        .clk(clk), .rst_n(rst_n), .en(1'b1), .ro_counts(counts), .valid(valid)
    );
    p2se_encoder #(.NUM(8), .CNT_W(16), .DTH(8)) u_p2se (
        .clk(clk), .rst_n(rst_n), .ro_counts(counts), .ro_valid(valid),
        .tdl_event(1'b0), .spike_bus(spikes), .tick(tick)
    );
    snn_lif_engine u_lif (
        .clk(clk), .rst_n(rst_n), .tick(tick), .spike_bus(spikes),
        .fire(fire), .anomaly_alarm(lif)
    );
    ablation_detectors #(.NUM(8), .CNT_W(16), .FTH(12), .ETH(8)) u_abl (
        .clk(clk), .rst_n(rst_n), .ro_counts(counts), .ro_valid(valid),
        .fixed_alarm(fixed_a), .ewma_alarm(ewma_a)
    );

    // nominal half periods: 2,00 .. 2,07 ns (process spread between ROs)
    real hp [0:7];
    integer k;
    task apply;
        begin
            u_mesh.g_ro[0].u_cell.half_ns = hp[0];
            u_mesh.g_ro[1].u_cell.half_ns = hp[1];
            u_mesh.g_ro[2].u_cell.half_ns = hp[2];
            u_mesh.g_ro[3].u_cell.half_ns = hp[3];
            u_mesh.g_ro[4].u_cell.half_ns = hp[4];
            u_mesh.g_ro[5].u_cell.half_ns = hp[5];
            u_mesh.g_ro[6].u_cell.half_ns = hp[6];
            u_mesh.g_ro[7].u_cell.half_ns = hp[7];
        end
    endtask

    integer n_lif, n_fix, n_ewma, n_win;
    always @(posedge clk) begin
        if (lif)     n_lif  = n_lif + 1;
        if (fixed_a) n_fix  = n_fix + 1;
        if (ewma_a)  n_ewma = n_ewma + 1;
        if (valid)   n_win  = n_win + 1;
    end
    task clear; begin n_lif = 0; n_fix = 0; n_ewma = 0; n_win = 0; end endtask
    task windows;
        input integer n;
        integer w;
        begin
            for (w = 0; w < n; w = w + 1) @(posedge valid);
        end
    endtask

    task chk;
        input            cond;
        input [8*60-1:0] name;
        begin
            if (!cond) begin
                $display("FAIL %0s (lif=%0d fixed=%0d ewma=%0d)", name, n_lif, n_fix, n_ewma);
                errors = errors + 1;
            end else
                $display("  ok %0s (lif=%0d fixed=%0d ewma=%0d)", name, n_lif, n_fix, n_ewma);
        end
    endtask

    integer w, lat;
    initial begin
        clear;
        for (k = 0; k < 8; k = k + 1) hp[k] = 2.0 + 0.01 * k;
        #1 apply; rst_n = 0;
        #100 rst_n = 1;

        // A: stable (includes warm-up)
        windows(12); clear; windows(10);
        chk(n_lif == 0 && n_fix == 0 && n_ewma == 0, "A stable: no detector fires");

        // B: slow uniform drift, +0,4% half period per window for 30 windows
        clear;
        for (w = 0; w < 30; w = w + 1) begin
            for (k = 0; k < 8; k = k + 1) hp[k] = hp[k] * 1.004;
            apply;
            windows(1);
        end
        windows(2);
        chk(n_lif == 0,  "B slow uniform drift: LIF quiet");
        chk(n_ewma == 0, "B slow uniform drift: EWMA quiet");
        chk(n_fix > 0,   "B slow uniform drift: fixed threshold false alarm");

        // let baselines settle at the new operating point
        windows(30);

        // C: fast local drop on RO 3 (frequency -15%)
        clear;
        hp[3] = hp[3] * 1.18; apply;
        lat = -1;
        for (w = 0; w < 8; w = w + 1) begin
            windows(1);
            @(posedge clk); @(posedge clk); @(posedge clk); @(posedge clk);
            if (n_lif > 0 && lat < 0) lat = w + 1;
        end
        chk(lat > 0 && lat <= 4, "C local drop on one RO: LIF fires within 4 windows");
        $display("     C latency %0d windows", lat);

        // recover and settle
        hp[3] = hp[3] / 1.18; apply;
        windows(40);

        // D: fast uniform step on all ROs (frequency -15%)
        clear;
        for (k = 0; k < 8; k = k + 1) hp[k] = hp[k] * 1.18;
        apply;
        windows(8);
        chk(n_lif == 0,  "D fast uniform step: LIF quiet (common mode removed)");
        chk(n_ewma > 0,  "D fast uniform step: EWMA-only fires");

        if (errors == 0) $display("PASS tb_slow_path");
        else             $display("FAIL tb_slow_path (%0d errors)", errors);
        $finish;
    end
endmodule
