// Self-checking testbench for clock_monitor (P2-1).
// ro_clk is the local time base (fixed). clk_mon is the watched clock; the
// test drives it at nominal, stopped, far too slow, and far too fast, and
// checks the alarm fires for every abnormal case and stays quiet at nominal.
`timescale 1ns/1ps
module tb_clock_monitor;
    localparam integer WINDOW = 64, LO = 25, HI = 205, CW = 12;
    reg ro_clk = 0; always #10 ro_clk = ~ro_clk;   // local oscillator, 50 MHz

    reg rst_n = 0, en = 1;
    reg clk_mon = 0;
    wire alarm, valid;
    integer errors = 0;

    clock_monitor #(.WINDOW(WINDOW), .LO(LO), .HI(HI), .CW(CW)) dut (
        .ro_clk(ro_clk), .rst_n(rst_n), .en(en), .clk_mon(clk_mon),
        .alarm(alarm), .valid(valid)
    );

    // clk_mon generator: half period in ns, 0 = stopped
    real mon_half;
    initial begin
        mon_half = 6.25;                 // ~80 MHz nominal (faster than ro_clk)
        forever begin
            if (mon_half <= 0.0) begin #1 clk_mon = clk_mon; end
            else begin #(mon_half) clk_mon = ~clk_mon; end
        end
    end

    // observe alarms over a number of windows
    integer win_seen, alm_seen;
    task observe; input integer nwin; begin
        win_seen = 0; alm_seen = 0;
        while (win_seen < nwin) begin
            @(posedge ro_clk);
            if (valid) win_seen = win_seen + 1;
            if (alarm) alm_seen = alm_seen + 1;
        end
    end endtask

    task chk; input cond; input [8*48-1:0] nm; begin
        if (!cond) begin $display("FAIL %0s (alarms=%0d/%0d windows)", nm, alm_seen, win_seen); errors=errors+1; end
        else $display("  ok %0s", nm); end
    endtask

    initial begin
        repeat (3) @(posedge ro_clk); rst_n = 1;
        // nominal: ~5-6 edges per 64-cycle window at 80/50 MHz -> in band
        observe(6);
        chk(alm_seen == 0, "nominal clock: no alarm");

        // stopped
        mon_half = 0.0;
        repeat (4) @(posedge ro_clk);
        observe(4);
        chk(alm_seen >= 3, "stopped clock: alarm");

        // too slow (1/16 of nominal)
        mon_half = 800.0;
        repeat (4) @(posedge ro_clk);
        observe(4);
        chk(alm_seen >= 3, "far-too-slow clock: alarm");

        // back to nominal: alarm clears
        mon_half = 6.25;
        repeat (4) @(posedge ro_clk);
        observe(6);
        chk(alm_seen == 0, "nominal again: no alarm");

        // too fast (edges >= HI per window)
        mon_half = 1.0;
        repeat (4) @(posedge ro_clk);
        observe(4);
        chk(alm_seen >= 3, "far-too-fast clock: alarm");

        // disabled monitor: no alarm, no window, even with the clock stopped
        en = 0; mon_half = 0.0;
        win_seen = 0; alm_seen = 0;
        repeat (4 * WINDOW) begin
            @(posedge ro_clk);
            if (valid) win_seen = win_seen + 1;
            if (alarm) alm_seen = alm_seen + 1;
        end
        chk(alm_seen == 0 && win_seen == 0, "disabled monitor: no window, no alarm");
        en = 1; mon_half = 6.25;

        if (errors == 0) $display("PASS tb_clock_monitor");
        else             $display("FAIL tb_clock_monitor (%0d errors)", errors);
        $finish;
    end
endmodule
