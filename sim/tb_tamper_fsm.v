// Self-checking testbench for graduated_tamper_fsm + tripwire_zeroize +
// master_key_vault.
`timescale 1ns/1ps
module tb_tamper_fsm;

    // Waveform: sim_build/tb_tamper_fsm.vcd (buka dengan GTKWave atau Surfer).
    // Tambahkan -DNO_DUMP saat compile untuk melewatinya.
`ifndef NO_DUMP
    initial begin
        $dumpfile("sim_build/tb_tamper_fsm.vcd");
        $dumpvars(0, tb_tamper_fsm);
    end
`endif
    reg clk = 0;
    always #5 clk = ~clk;

    reg          por_n = 0, rst_n = 0, alarm = 0, debug_unlock = 0;
    wire [3:0]   cnt;
    wire         zreq, lock, zn;
    wire [127:0] key;
    integer      errors = 0;
    realtime     t_req, t_clr;

    graduated_tamper_fsm #(.N(4), .DEMO_UNLOCK(1)) u_fsm (
        .clk(clk), .por_n(por_n), .alarm(alarm), .debug_unlock(debug_unlock),
        .tamper_counter(cnt), .zeroize_req(zreq), .lockdown_state(lock)
    );
    tripwire_zeroize u_trip (.clk(clk), .por_n(por_n), .zeroize_req(zreq), .async_zeroize_n(zn));
    master_key_vault u_vault (.clk(clk), .rst_n(rst_n), .por_n(por_n), .async_zeroize_n(zn), .key_to_cipher(key), .key_loaded());

    task pulse;
        input integer len;
        begin
            @(negedge clk) alarm = 1;
            repeat (len - 1) @(negedge clk);
            @(negedge clk) alarm = 0;
            repeat (3) @(negedge clk);
        end
    endtask

    task chk;
        input       cond;
        input [8*48-1:0] name;
        begin
            if (!cond) begin
                $display("FAIL %0s (cnt=%0d lock=%b key=%h)", name, cnt, lock, key);
                errors = errors + 1;
            end else
                $display("  ok %0s", name);
        end
    endtask

    // key must become zero as soon as the clear asserts, not on a clock edge
    always @(negedge zn) begin
        t_clr = $realtime;
        #0.1;
        if (key !== 128'h0) begin
            $display("FAIL key not cleared asynchronously");
            errors = errors + 1;
        end
    end

    initial begin
        repeat (2) @(negedge clk);
        por_n = 1;
        repeat (2) @(negedge clk);          // rst_n low: key loads
        rst_n = 1;
        chk(key == 128'h000102030405060708090a0b0c0d0e0f, "key loaded after reset");

        pulse(1); pulse(1);
        pulse(40);                          // long sticky alarm counts once
        chk(cnt == 3 && !lock, "3 alarms (one sticky) -> cnt 3, no lockdown");
        chk(key != 128'h0, "key intact before N");

        pulse(1);
        repeat (3) @(negedge clk);
        chk(cnt == 4 && lock, "4th alarm -> lockdown");
        chk(key == 128'h0, "key zeroized");

        // user reset must not undo lockdown or reload the key
        rst_n = 0; repeat (3) @(negedge clk); rst_n = 1; repeat (2) @(negedge clk);
        chk(lock && key == 128'h0 && cnt == 4, "lockdown survives user reset");

        // debug unlock (demo rehearsal) with reset held: key reloads
        rst_n = 0; debug_unlock = 1; repeat (3) @(negedge clk);
        debug_unlock = 0; repeat (2) @(negedge clk); rst_n = 1; repeat (2) @(negedge clk);
        chk(!lock && cnt == 0 && key == 128'h000102030405060708090a0b0c0d0e0f, "debug unlock restores demo state");

        if (errors == 0) $display("PASS tb_tamper_fsm");
        else             $display("FAIL tb_tamper_fsm (%0d errors)", errors);
        $finish;
    end
endmodule
