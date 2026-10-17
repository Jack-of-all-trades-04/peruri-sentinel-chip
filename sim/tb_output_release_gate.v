// Self-checking testbench for output_release_gate.
// Alarm timing sweep around aes_done (cycle T): mid-op, at T, T+1..T+4 must
// block; T+5 and no alarm must release. Also checks that ct_out is zero
// whenever ct_valid is 0, Sentinel OFF passes everything, and lockdown
// suppresses everything.
`timescale 1ns/1ps
module tb_output_release_gate;

    // Waveform: sim_build/tb_output_release_gate.vcd (buka dengan GTKWave atau Surfer).
    // Tambahkan -DNO_DUMP saat compile untuk melewatinya.
`ifndef NO_DUMP
    initial begin
        $dumpfile("sim_build/tb_output_release_gate.vcd");
        $dumpvars(0, tb_output_release_gate);
    end
`endif
    reg clk = 0;
    always #5 clk = ~clk;

    reg          rst_n = 0, enable = 1, lockdown = 0;
    reg          op_start = 0, aes_done = 0, alarm = 0;
    reg  [127:0] ct_raw = 0;
    wire [127:0] ct_out;
    wire         ct_valid, gate_blocked;
    integer      errors = 0;

    output_release_gate #(.H(4)) dut (
        .clk(clk), .rst_n(rst_n), .enable(enable), .lockdown(lockdown),
        .op_start(op_start), .aes_done(aes_done), .ct_raw(ct_raw),
        .alarm(alarm), .ct_out(ct_out), .ct_valid(ct_valid),
        .gate_blocked(gate_blocked)
    );

    // ct_out must never leak while ct_valid is low
    always @(posedge clk)
        if (rst_n && !ct_valid && ct_out !== 128'h0) begin
            $display("FAIL ct_out non-zero while ct_valid = 0");
            errors = errors + 1;
        end

    // run one op of 11 cycles; alarm_at = cycle offset relative to done
    // (-5 = mid-op, 0 = at done, 1..5 = after done, 99 = none)
    // expect_release: 1 if the result must be released
    task op;
        input integer   alarm_at;
        input           expect_release;
        input [8*28-1:0] name;
        integer t, released, blocked;
        begin
            released = 0; blocked = 0;
            ct_raw = {$random, $random, $random, $random};
            @(negedge clk) op_start = 1;
            @(negedge clk) op_start = 0;
            for (t = -9; t <= 8; t = t + 1) begin
                aes_done = (t == 0);
                alarm    = (t == alarm_at);
                @(posedge clk); #1;
                if (ct_valid) begin
                    released = released + 1;
                    if (ct_out !== ct_raw) begin
                        $display("FAIL %0s: released wrong data", name);
                        errors = errors + 1;
                    end
                end
                if (gate_blocked) blocked = blocked + 1;
                @(negedge clk);
            end
            aes_done = 0; alarm = 0;
            if (expect_release && (released != 1 || blocked != 0)) begin
                $display("FAIL %0s: expected release (rel=%0d blk=%0d)", name, released, blocked);
                errors = errors + 1;
            end else if (!expect_release && (released != 0 || blocked != 1)) begin
                $display("FAIL %0s: expected block (rel=%0d blk=%0d)", name, released, blocked);
                errors = errors + 1;
            end else
                $display("  ok %0s", name);
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;
        op(99, 1, "no alarm -> release");
        op(-5, 0, "alarm mid-op -> block");
        op(0,  0, "alarm at done -> block");
        op(1,  0, "alarm at done+1 -> block");
        op(2,  0, "alarm at done+2 -> block");
        op(3,  0, "alarm at done+3 -> block");
        op(4,  0, "alarm at done+4 -> block");
        op(5,  1, "alarm at done+5 -> release");
        enable = 0;
        op(-5, 1, "Sentinel OFF ignores alarm");
        enable = 1; lockdown = 1;
        op(99, 0, "lockdown suppresses release");
        lockdown = 0;
        if (errors == 0) $display("PASS tb_output_release_gate");
        else             $display("FAIL tb_output_release_gate (%0d errors)", errors);
        $finish;
    end
endmodule
