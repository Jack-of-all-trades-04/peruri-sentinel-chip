// Self-checking testbench for tdl_glitch_line.
// RTL simulation has no gate delay, so the testbench forces the carry-chain
// output `sum` to the pattern a real chain would show for a chosen depth.
// Depth = number of taps the launched edge passed before the capture edge.
`timescale 1ns/1ps
module tb_tdl_glitch_line;

    // Waveform: sim_build/tb_tdl_glitch_line.vcd (buka dengan GTKWave atau Surfer).
    // Tambahkan -DNO_DUMP saat compile untuk melewatinya.
`ifndef NO_DUMP
    initial begin
        $dumpfile("sim_build/tb_tdl_glitch_line.vcd");
        $dumpvars(0, tb_tdl_glitch_line);
    end
`endif
    localparam integer L = 64;
    reg clk = 0;
    always #6.25 clk = ~clk;   // 80 MHz

    reg rst_n = 0, enable = 1;
    wire alert, armed, cal_bad;
    wire [6:0] depth, min_r, min_f;
    wire [5:0] sel;
    integer errors = 0;

    tdl_glitch_line #(.L(L), .COARSE(63), .K_TDL(4), .CAL_SETTLE(16), .CAL_WIN(64)) dut (
        .clk(clk), .rst_n(rst_n), .enable(enable), .alert(alert), .armed(armed),
        .cal_bad(cal_bad), .depth_q(depth), .min_r(min_r), .min_f(min_f), .sel(sel)
    );

    // depth model: d_r for rising edges at the chain input, d_f for falling.
    // A longer coarse tap leaves less of the period for the chain:
    // depth = d - slope * sel (clamped at 0).
    integer d_r = 40, d_f = 36, jitter = 1, slope = 0;
    integer bubble = -1;          // >= 0: this tap reads "not passed" although the edge passed it
    reg [L-1:0] mask;
    reg [L-1:0] tb_sum;
    integer dd;
    always @(*) begin
        dd = (dut.chain_in ? d_r : d_f) - slope * dut.sel;
        if (dd < 0) dd = 0;
        mask = (dd >= L) ? {L{1'b1}} : (({{(L-1){1'b0}}, 1'b1} << dd) - 1);
        if (bubble >= 0 && bubble < dd) mask[bubble] = 1'b0;
        tb_sum = dut.chain_in ? ~mask : mask;
    end
    // iverilog evaluates a force RHS once, so re-apply it on every change
    always @(tb_sum) force dut.sum = {1'b0, tb_sum};

    // small random jitter on the nominal depth, applied away from clock edges
    integer base_r = 40, base_f = 36;
    always @(negedge clk) begin
        if (jitter) begin
            d_r = base_r + ($random % 2);
            d_f = base_f + ($random % 2);
        end
    end

    task chk;
        input            cond;
        input [8*56-1:0] name;
        begin
            if (!cond) begin
                $display("FAIL %0s (armed=%b bad=%b min_r=%0d min_f=%0d depth=%0d)",
                         name, armed, cal_bad, min_r, min_f, depth);
                errors = errors + 1;
            end else
                $display("  ok %0s", name);
        end
    endtask

    integer n_alert;
    always @(posedge clk) if (alert) n_alert = n_alert + 1;

    // shorten exactly one captured sample (both polarities to be safe)
    task glitch_one;
        input integer d;
        begin
            @(negedge clk);
            jitter = 0; d_r = d; d_f = d;
            @(negedge clk);             // one capture edge has passed
            jitter = 1; d_r = base_r; d_f = base_f;
        end
    endtask

    // reset, then wait until the calibration sweep ends (armed or cal_bad)
    task recal;
        integer t;
        begin
            rst_n = 0; repeat (2) @(posedge clk); rst_n = 1;
            t = 0;
            @(posedge clk);
            while (!armed && !cal_bad && t < 20000) begin
                @(posedge clk); t = t + 1;
            end
            repeat (4) @(posedge clk);
        end
    endtask

    integer i, first, latency;
    initial begin
        n_alert = 0;
        repeat (3) @(posedge clk);
        recal;

        chk(armed && !cal_bad, "calibrates and arms with nominal depth");
        chk(sel == 0 && dut.pass == 0, "depth already in range: keeps tap 0, strict pass");
        chk(min_r >= 39 && min_r <= 41 && min_f >= 35 && min_f <= 37,
            "calibrated minimum per edge polarity");

        n_alert = 0;
        repeat (500) @(posedge clk);
        chk(n_alert == 0, "no alert over 500 nominal cycles with jitter");

        // one shortened cycle: depth 20 instead of about 40
        n_alert = 0;
        first = -1;
        fork
            glitch_one(20);
            begin
                for (i = 0; i < 6; i = i + 1) begin
                    @(posedge clk);
                    if (alert && first < 0) first = i;
                end
            end
        join
        repeat (5) @(posedge clk);
        chk(first >= 0 && first <= 3, "alert within 3 edges after the glitched capture");
        chk(n_alert >= 1 && n_alert <= 2, "alert is short (1-2 cycles)");

        // a bubble exactly at the threshold tap (edge passed, one tap reads
        // wrong) must not alert: the depth is still far above the threshold
        n_alert = 0;
        bubble = dut.thr_r;
        repeat (200) @(posedge clk);
        bubble = dut.thr_f;
        repeat (200) @(posedge clk);
        bubble = -1;
        chk(n_alert == 0, "bubble at the threshold tap does not alert");

        // a small dip inside the margin does not alert
        n_alert = 0;
        glitch_one(37);
        repeat (5) @(posedge clk);
        chk(n_alert == 0, "dip above threshold ignored");

        // Sentinel OFF
        enable = 0; n_alert = 0;
        glitch_one(10);
        repeat (5) @(posedge clk);
        chk(n_alert == 0, "no alert when Sentinel is off");
        enable = 1;

        // tap sweep: depth 70/66 at tap 0, 2 taps less per coarse step.
        // First tap with every depth in [16, 60] (jitter +-1) is tap 6.
        base_r = 70; base_f = 66; d_r = 70; d_f = 66; slope = 2;
        recal;
        chk(armed && !cal_bad && sel == 6 && dut.pass == 0, "sweep stops at first tap in range (tap 6)");
        chk(min_r >= 57 && min_r <= 59 && min_f >= 53 && min_f <= 55, "minimum measured on the chosen tap");
        n_alert = 0;
        repeat (300) @(posedge clk);
        chk(n_alert == 0, "no alert on the chosen tap with jitter");
        n_alert = 0;
        glitch_one(30 + 2 * 6);         // depth 30 on tap 6
        repeat (5) @(posedge clk);
        chk(n_alert >= 1 && n_alert <= 2, "glitch caught on the chosen tap");
        slope = 0;

        // shallow depth everywhere: strict pass fails, loose pass arms
        base_r = 10; base_f = 10; jitter = 0; d_r = 10; d_f = 10;
        recal;
        chk(armed && !cal_bad && dut.pass == 1 && sel == 0, "loose pass arms when strict limits never fit");

        // saturated chain on every tap: calibration must refuse
        base_r = 64; base_f = 64; jitter = 0; d_r = 64; d_f = 64;
        recal;
        chk(cal_bad && !armed, "saturated chain reports cal_bad, not armed");
        n_alert = 0;
        glitch_one(10);
        repeat (5) @(posedge clk);
        chk(n_alert == 0, "unarmed line never alerts");

        // edge never reaches the chain (coarse delay too long)
        base_r = 2; base_f = 2; d_r = 2; d_f = 2;
        recal;
        chk(cal_bad && !armed, "edge not reaching chain reports cal_bad");

        if (errors == 0) $display("PASS tb_tdl_glitch_line");
        else             $display("FAIL tb_tdl_glitch_line (%0d errors)", errors);
        $finish;
    end
endmodule
