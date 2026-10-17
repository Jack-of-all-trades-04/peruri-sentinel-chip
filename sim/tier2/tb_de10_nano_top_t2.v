// Integration testbench for de10_nano_top_t2 (two clock domains, PLL model,
// RO models) with shrunken timing parameters.
//
// TDL: RTL has no gate delay, so the testbench forces the carry-chain
// output to a nominal depth (about 40 taps) and lowers it to 15 taps for the
// capture at the glitched clock edge, which is what a real chain shows when
// the period is cut short. Everything else (glitch timing, gate, CDC, FSM,
// zeroize) is the real RTL.
`timescale 1ns/1ps
module tb_de10_nano_top_t2;

    // Waveform: sim_build/tb_de10_nano_top_t2.vcd (buka dengan GTKWave atau Surfer).
    // Tambahkan -DNO_DUMP saat compile untuk melewatinya.
`ifndef NO_DUMP
    initial begin
        $dumpfile("sim_build/tb_de10_nano_top_t2.vcd");
        $dumpvars(0, tb_de10_nano_top_t2);
    end
`endif
    reg clk50 = 0;
    always #10 clk50 = ~clk50;

    reg  [1:0] KEY = 2'b11;
    reg  [3:0] SW  = 4'b0001;    // Sentinel ON
    wire [7:0] LED;
    integer errors = 0;

    de10_nano_top_t2 #(
        .DEB_CYCLES(4), .STRETCH_CYCLES(50), .OP_PERIOD(100), .HB_BIT(4),
        .TDL_SETTLE(16), .TDL_WIN(64), .RO_WINDOW(256),
        .FAST_HOLD(16), .SLOW_HOLD(64)
    ) dut (.FPGA_CLK1_50(clk50), .KEY(KEY), .SW(SW), .LED(LED));

    localparam [127:0] EXP_CT = 128'h69c4e0d86a7b0430d8cdb78070b4c55a;
    localparam integer L = 64;

    // ---------------- TDL depth model ----------------
    reg glitch_low = 0, burst_low = 0;
    integer dd;
    reg [L-1:0] mask, tb_sum;
    always @(*) begin
        dd   = (glitch_low || burst_low) ? 15 : (dut.u_core.u_tdl.cd[24] ? 40 : 36);
        mask = ({{(L-1){1'b0}}, 1'b1} << dd) - 1;
        tb_sum = dut.u_core.u_tdl.cd[24] ? ~mask : mask;
    end
    always @(tb_sum) force dut.u_core.u_tdl.sum = {1'b0, tb_sum};

    // the edge after `en` rises is the shortened one: lower the depth for it
    integer n_glitch = 0, glitch_round = -1;
    always @(posedge dut.u_glitch.en) begin
        glitch_low = 1;
        @(posedge dut.clk_sys);
        n_glitch     = n_glitch + 1;
        glitch_round = dut.round_idx;
        #1 glitch_low = 0;
    end

    // ---------------- observers (CLK_sys) ----------------
    integer n_ok = 0, n_bad = 0, n_blk = 0;
    always @(posedge dut.clk_sys) begin
        if (dut.ct_valid) begin
            if (dut.ct_out == EXP_CT) n_ok = n_ok + 1;
            else                      n_bad = n_bad + 1;
        end
        if (dut.gate_blocked) n_blk = n_blk + 1;
    end

    task cyc; input integer n; begin repeat (n) @(posedge dut.clk_sys); end endtask
    task press;
        input integer k;
        begin
            KEY[k] = 1'b0; cyc(20);
            KEY[k] = 1'b1; cyc(20);
        end
    endtask
    task wait_ops; input integer n; begin cyc(n * 130); end endtask

    task chk;
        input            cond;
        input [8*60-1:0] name;
        begin
            if (!cond) begin
                $display("FAIL %0s (ok=%0d bad=%0d blk=%0d cnt=%0d glitches=%0d LED=%b)",
                         name, n_ok, n_bad, n_blk, dut.u_core.tamper_counter, n_glitch, LED);
                errors = errors + 1;
            end else
                $display("  ok %0s", name);
        end
    endtask

    // RO helpers (slow path)
    task ro_scale;
        input integer idx;
        input real f;
        begin
            case (idx)
                0: dut.u_core.u_mesh.g_ro[0].u_cell.half_ns = dut.u_core.u_mesh.g_ro[0].u_cell.half_ns * f;
                1: dut.u_core.u_mesh.g_ro[1].u_cell.half_ns = dut.u_core.u_mesh.g_ro[1].u_cell.half_ns * f;
                2: dut.u_core.u_mesh.g_ro[2].u_cell.half_ns = dut.u_core.u_mesh.g_ro[2].u_cell.half_ns * f;
                3: dut.u_core.u_mesh.g_ro[3].u_cell.half_ns = dut.u_core.u_mesh.g_ro[3].u_cell.half_ns * f;
            endcase
        end
    endtask

    integer ok0, bad0, blk0, cnt0, g0, i;
    initial begin
        // spread the RO frequencies a little, like real silicon
        dut.u_core.u_mesh.g_ro[1].u_cell.half_ns = 2.01;
        dut.u_core.u_mesh.g_ro[2].u_cell.half_ns = 2.02;
        dut.u_core.u_mesh.g_ro[3].u_cell.half_ns = 2.03;
        dut.u_core.u_mesh.g_ro[4].u_cell.half_ns = 2.04;
        dut.u_core.u_mesh.g_ro[5].u_cell.half_ns = 2.05;
        dut.u_core.u_mesh.g_ro[6].u_cell.half_ns = 2.06;
        dut.u_core.u_mesh.g_ro[7].u_cell.half_ns = 2.07;

        wait (dut.pll_locked);
        wait_ops(4);

        // ---- calibration view (SW2) ----
        SW[2] = 1; cyc(8);
        chk(LED[7] && !LED[6] && LED[5:0] >= 39 && LED[5:0] <= 41,
            "SW2 view: TDL armed, calibration ok, min depth ~40");
        SW[2] = 0; cyc(8);

        // ---- clean operations ----
        ok0 = n_ok; wait_ops(5);
        chk(n_ok > ok0 && n_bad == 0 && n_blk == 0, "clean ops at 80 MHz release FIPS-197 ciphertext");
        chk(LED[4] && !LED[7] && LED[2:0] == 0, "LED4 on, no lockdown, counter 0");

        // ---- Tier 1 path still works: SW1 = 0 ----
        bad0 = n_bad; blk0 = n_blk;
        press(1); wait_ops(3);
        chk(n_blk == blk0 + 1 && n_bad == bad0 && dut.u_core.tamper_counter == 1,
            "SW1=0 + KEY1: emulated fault blocked, counter 1");

        // ---- physical glitch, Sentinel ON ----
        SW[1] = 1; cyc(8);
        ok0 = n_ok; blk0 = n_blk; g0 = n_glitch;
        press(1); wait_ops(3);
        chk(n_glitch == g0 + 1, "SW1=1 + KEY1: exactly one clock glitch injected");
        $display("     glitch landed in round %0d", glitch_round);
        chk(glitch_round >= 8 && glitch_round <= 10, "glitch lands in the last AES rounds");
        chk(n_blk == blk0 + 1 && dut.u_core.tamper_counter == 2,
            "TDL catches the glitch: release blocked, counter 2");

        // ---- physical glitch, Sentinel OFF ----
        SW[0] = 0; cyc(8);
        ok0 = n_ok; blk0 = n_blk; g0 = n_glitch;
        press(1); wait_ops(3);
        chk(n_glitch == g0 + 1 && n_blk == blk0 && dut.u_core.tamper_counter == 2,
            "Sentinel OFF: glitch not blocked, not counted");
        SW[0] = 1; cyc(8);

        // ---- a burst of TDL alerts outside an operation counts once ----
        cnt0 = dut.u_core.tamper_counter;
        @(negedge dut.clk_sys); burst_low = 1;
        cyc(5);
        @(negedge dut.clk_sys); burst_low = 0;
        wait_ops(2);
        chk(dut.u_core.tamper_counter == cnt0 + 1, "5-cycle TDL burst counted once (counter 3)");

        // ---- calibration view masks counting ----
        SW[2] = 1; cyc(8);
        cnt0 = dut.u_core.tamper_counter;
        @(negedge dut.clk_sys); burst_low = 1;
        cyc(3);
        @(negedge dut.clk_sys); burst_low = 0;
        wait_ops(2);
        chk(dut.u_core.tamper_counter == cnt0, "SW2 calibration view: alarms not counted");
        SW[2] = 0; cyc(8);

        // ---- slow path: local RO drop -> LIF -> 4th event -> LOCKDOWN ----
        ok0 = n_ok;
        ro_scale(3, 1.18);
        // up to 8 windows of 5,12 us
        for (i = 0; i < 8 && !dut.u_core.lockdown; i = i + 1) #5120;
        wait_ops(2);
        chk(dut.u_core.tamper_counter == 4, "local RO drop seen by LIF, counter 4");
        chk(dut.u_core.lockdown && dut.key_is_zero && LED[7], "4th event: key zeroized, LOCKDOWN, LED7");
        ok0 = n_ok; wait_ops(3);
        chk(n_ok == ok0, "no ciphertext after lockdown");
        ro_scale(3, 1.0 / 1.18);

        // ---- persistence and rehearsal unlock ----
        press(0); wait_ops(2);
        chk(dut.u_core.lockdown && LED[7], "KEY0 does not undo LOCKDOWN");
        SW[3] = 1; KEY[0] = 0; cyc(40); KEY[0] = 1; cyc(40); SW[3] = 0;
        wait_ops(6);
        ok0 = n_ok; wait_ops(4);
        chk(!dut.u_core.lockdown && !dut.key_is_zero && n_ok > ok0 && LED[2:0] == 0,
            "SW3+KEY0 unlock restores demo state");

        if (errors == 0) $display("PASS tb_de10_nano_top_t2");
        else             $display("FAIL tb_de10_nano_top_t2 (%0d errors)", errors);
        $finish;
    end
endmodule
