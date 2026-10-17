// Self-checking testbench for glitch_injector.
// clk_a: 80 MHz (T = 12,5 ns). clk_b: same clock delayed by PHI = 8,0 ns.
// Expected: without arm, clk_out == clk_a. One arm rising edge produces
// exactly one shortened period (PHI) followed by one long period (2T - PHI).
`timescale 1ns/1ps
module tb_glitch_injector;

    // Waveform: sim_build/tb_glitch_injector.vcd (buka dengan GTKWave atau Surfer).
    // Tambahkan -DNO_DUMP saat compile untuk melewatinya.
`ifndef NO_DUMP
    initial begin
        $dumpfile("sim_build/tb_glitch_injector.vcd");
        $dumpvars(0, tb_glitch_injector);
    end
`endif
    localparam real T   = 12.5;
    localparam real PHI = 8.0;

    reg clk_a = 0, clk_b = 0, rst_n = 0, arm = 0;
    initial forever #(T / 2.0) clk_a = ~clk_a;
    initial begin #(PHI); forever #(T / 2.0) clk_b = ~clk_b; end

    wire clk_out, en;
    glitch_injector #(.ENABLE(1)) dut (
        .clk_a(clk_a), .clk_b(clk_b), .rst_n(rst_n), .arm(arm), .clk_out(clk_out), .en(en)
    );
    wire clk_off, en_off;
    glitch_injector #(.ENABLE(0)) dut_off (
        .clk_a(clk_a), .clk_b(clk_b), .rst_n(rst_n), .arm(arm), .clk_out(clk_off), .en(en_off)
    );

    integer errors = 0;
    realtime t_last = 0, per;
    integer n_short = 0, n_long = 0, n_norm = 0, n_other = 0, n_edges = 0;
    always @(posedge clk_out) begin
        if (n_edges > 0) begin
            per = $realtime - t_last;
            if (per > PHI - 0.01 && per < PHI + 0.01)                n_short = n_short + 1;
            else if (per > 2*T - PHI - 0.01 && per < 2*T - PHI + 0.01) n_long = n_long + 1;
            else if (per > T - 0.01 && per < T + 0.01)               n_norm = n_norm + 1;
            else                                                      n_other = n_other + 1;
        end
        t_last  = $realtime;
        n_edges = n_edges + 1;
    end

    // shortest high/low pulse on clk_out (a runt pulse would show up here)
    realtime t_chg = 0, minpw = 1000.0;
    always @(clk_out) begin
        if ($realtime - t_chg < minpw && $realtime > 30.0) minpw = $realtime - t_chg;
        t_chg = $realtime;
    end

    integer n_off_edges = 0;
    always @(posedge clk_off) n_off_edges = n_off_edges + 1;
    integer n_a_edges = 0;
    always @(posedge clk_a) n_a_edges = n_a_edges + 1;
    integer mismatch = 0;
    always @(clk_out or clk_a) #0.001 if (!en && (clk_out !== clk_a) && rst_n) mismatch = mismatch + 1;

    task chk;
        input            cond;
        input [8*56-1:0] name;
        begin
            if (!cond) begin
                $display("FAIL %0s (short=%0d long=%0d norm=%0d other=%0d minpw=%0.3f)",
                         name, n_short, n_long, n_norm, n_other, minpw);
                errors = errors + 1;
            end else
                $display("  ok %0s", name);
        end
    endtask

    initial begin
        #20 rst_n = 1;
        #60;
        // start counting after reset (en is X before reset in simulation)
        n_short = 0; n_long = 0; n_norm = 0; n_other = 0;
        n_off_edges = 0; n_a_edges = 0; minpw = 1000.0; mismatch = 0;
        #500;
        chk(n_short == 0 && n_long == 0 && n_other == 0, "no glitch without arm");

        // arm from the clk_out domain, held for 4 cycles
        @(posedge clk_out); arm = 1;
        repeat (4) @(posedge clk_out); arm = 0;
        #300;
        chk(n_short == 1, "exactly one shortened period (PHI)");
        chk(n_long == 1 && n_other == 0, "one long period after it, nothing else");
        chk(minpw > PHI - T/2.0 - 0.01, "no pulse narrower than the designed glitch");
        chk(mismatch == 0, "clk_out equals clk_a whenever en = 0");

        // second arm gives a second, single glitch
        @(posedge clk_out); arm = 1;
        repeat (4) @(posedge clk_out); arm = 0;
        #300;
        chk(n_short == 2, "re-arm gives one more glitch");

        chk(n_off_edges == n_a_edges, "ENABLE = 0 build passes clk_a unchanged");

        if (errors == 0) $display("PASS tb_glitch_injector");
        else             $display("FAIL tb_glitch_injector (%0d errors)", errors);
        $finish;
    end
endmodule
