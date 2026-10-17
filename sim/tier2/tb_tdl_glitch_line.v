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
    integer errors = 0;

    tdl_glitch_line #(.L(L), .COARSE(24), .K_TDL(4), .CAL_SETTLE(16), .CAL_WIN(64)) dut (
        .clk(clk), .rst_n(rst_n), .enable(enable), .alert(alert), .armed(armed),
        .cal_bad(cal_bad), .depth_q(depth), .min_r(min_r), .min_f(min_f)
    );

    // depth model: d_r for rising edges at the chain input, d_f for falling
    integer d_r = 40, d_f = 36, jitter = 1;
    reg [L-1:0] mask;
    reg [L-1:0] tb_sum;
    integer dd;
    always @(*) begin
        dd = dut.cd[24] ? d_r : d_f;
        mask = (dd >= L) ? {L{1'b1}} : (({{(L-1){1'b0}}, 1'b1} << dd) - 1);
        tb_sum = dut.cd[24] ? ~mask : mask;
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

    integer i, first, latency;
    initial begin
        n_alert = 0;
        repeat (3) @(posedge clk);
        rst_n = 1;
        repeat (120) @(posedge clk);

        chk(armed && !cal_bad, "calibrates and arms with nominal depth");
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
        chk(first >= 0 && first <= 2, "alert within 2 edges after the glitched capture");
        chk(n_alert >= 1 && n_alert <= 2, "alert is short (1-2 cycles)");

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

        // saturated chain (coarse delay too short): calibration must refuse
        base_r = 64; base_f = 64; jitter = 0; d_r = 64; d_f = 64;
        rst_n = 0; repeat (2) @(posedge clk); rst_n = 1;
        repeat (120) @(posedge clk);
        chk(cal_bad && !armed, "saturated chain reports cal_bad, not armed");
        n_alert = 0;
        glitch_one(10);
        repeat (5) @(posedge clk);
        chk(n_alert == 0, "unarmed line never alerts");

        // edge never reaches the chain (coarse delay too long)
        base_r = 2; base_f = 2; d_r = 2; d_f = 2;
        rst_n = 0; repeat (2) @(posedge clk); rst_n = 1;
        repeat (120) @(posedge clk);
        chk(cal_bad && !armed, "edge not reaching chain reports cal_bad");

        if (errors == 0) $display("PASS tb_tdl_glitch_line");
        else             $display("FAIL tb_tdl_glitch_line (%0d errors)", errors);
        $finish;
    end
endmodule
