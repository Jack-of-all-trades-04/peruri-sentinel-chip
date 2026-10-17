// Integration testbench for de10_nano_top with shrunken timing parameters.
// Drives the board buttons and switches exactly as in the live demo.
`timescale 1ns/1ps
module tb_de10_nano_top;

    // Waveform: sim_build/tb_de10_nano_top.vcd (open with GTKWave or Surfer).
    // Compile with -DNO_DUMP to skip it.
`ifndef NO_DUMP
    initial begin
        $dumpfile("sim_build/tb_de10_nano_top.vcd");
        $dumpvars(0, tb_de10_nano_top);
    end
`endif
    reg clk = 0;
    always #10 clk = ~clk;   // 50 MHz

    reg  [1:0] KEY = 2'b11;
    reg  [3:0] SW  = 4'b0001;  // Sentinel ON
    wire [7:0] LED;
    integer errors = 0;

    de10_nano_top #(
        .DEB_CYCLES(4), .STRETCH_CYCLES(50), .OP_PERIOD(60), .HB_BIT(4)
    ) dut (.FPGA_CLK1_50(clk), .KEY(KEY), .SW(SW), .LED(LED));

    localparam [127:0] EXP_CT = 128'h69c4e0d86a7b0430d8cdb78070b4c55a;

    integer n_ok = 0, n_bad = 0, n_blk = 0;
    always @(posedge clk) begin
        if (dut.u_core.ct_valid) begin
            if (dut.u_core.ct_out == EXP_CT) n_ok = n_ok + 1;
            else                             n_bad = n_bad + 1;
        end
        if (dut.u_core.gate_blocked) n_blk = n_blk + 1;
    end

    task press;
        input integer k;
        begin
            KEY[k] = 1'b0;
            repeat (20) @(posedge clk);
            KEY[k] = 1'b1;
            repeat (20) @(posedge clk);
        end
    endtask

    task wait_ops;
        input integer n;
        begin
            repeat (n * 80) @(posedge clk);
        end
    endtask

    task chk;
        input            cond;
        input [8*56-1:0] name;
        begin
            if (!cond) begin
                $display("FAIL %0s (ok=%0d bad=%0d blk=%0d cnt=%0d LED=%b)",
                         name, n_ok, n_bad, n_blk, dut.u_core.tamper_counter, LED);
                errors = errors + 1;
            end else
                $display("  ok %0s", name);
        end
    endtask

    integer ok0, bad0, blk0, i;
    initial begin
        wait_ops(5);
        chk(n_ok >= 3 && n_bad == 0 && n_blk == 0, "clean ops release the FIPS-197 ciphertext");
        chk(LED[4] == 1'b1 && LED[7] == 1'b0, "LED4 on, LED7 off in normal operation");

        // ---- Sentinel OFF: faulty ciphertext leaks ----
        SW[0] = 1'b0; repeat (10) @(posedge clk);
        bad0 = n_bad; blk0 = n_blk;
        press(1); wait_ops(3);
        chk(n_bad == bad0 + 1 && n_blk == blk0, "SW0=0 + KEY1: faulty ciphertext released (DFA possible)");
        chk(dut.u_core.tamper_counter == 0, "SW0=0: tamper counter does not move");

        // ---- Sentinel ON: every faulty ciphertext blocked ----
        SW[0] = 1'b1; repeat (10) @(posedge clk);
        bad0 = n_bad; blk0 = n_blk;
        for (i = 1; i <= 3; i = i + 1) begin
            press(1); wait_ops(3);
        end
        chk(n_bad == bad0 && n_blk == blk0 + 3, "SW0=1 + KEY1 x3: all 3 faulty ciphertexts blocked");
        chk(dut.u_core.tamper_counter == 3 && LED[2:0] == 3'd3 && !LED[7], "counter 3 on LED[2:0], no lockdown yet");
        ok0 = n_ok; wait_ops(3);
        chk(n_ok > ok0, "clean ops still released below N");

        SW[1] = 1'b1;           // droop-emulation mode for the 4th attack
        press(1); wait_ops(3);
        chk(n_bad == bad0 && dut.u_core.tamper_counter == 4, "4th attack blocked, counter 4");
        chk(dut.u_core.lockdown && dut.u_core.key_is_zero && LED[7], "LOCKDOWN, key zeroized, LED7 on");
        ok0 = n_ok; wait_ops(4);
        chk(n_ok == ok0 && LED[4] == 1'b0, "no ciphertext released in LOCKDOWN");

        // ---- user reset does not undo lockdown ----
        press(0); wait_ops(3);
        chk(dut.u_core.lockdown && LED[7] && n_ok == ok0, "LOCKDOWN survives KEY0 reset");

        // ---- demo-only debug unlock: SW3 + KEY0 ----
        SW[3] = 1'b1; press(0); SW[3] = 1'b0;
        ok0 = n_ok; wait_ops(5);
        chk(!dut.u_core.lockdown && !dut.u_core.key_is_zero && n_ok > ok0 && LED[2:0] == 0,
            "SW3+KEY0 debug unlock restores demo state");

        if (errors == 0) $display("PASS tb_de10_nano_top");
        else             $display("FAIL tb_de10_nano_top (%0d errors)", errors);
        $finish;
    end
endmodule
