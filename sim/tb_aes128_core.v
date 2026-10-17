// Self-checking testbench for aes128_core.
// Vectors: FIPS-197 Appendix C.1, FIPS-197 Appendix B, NIST SP 800-38A F.1.1 block 1.
`timescale 1ns/1ps
module tb_aes128_core;

    // Waveform: sim_build/tb_aes128_core.vcd (open with GTKWave or Surfer).
    // Compile with -DNO_DUMP to skip it.
`ifndef NO_DUMP
    initial begin
        $dumpfile("sim_build/tb_aes128_core.vcd");
        $dumpvars(0, tb_aes128_core);
    end
`endif
    reg clk = 0;
    always #5 clk = ~clk;

    reg          rst_n = 0;
    reg          start = 0;
    reg  [127:0] key, pt;
    reg          fault_en = 0;
    reg  [3:0]   fault_round = 0, fault_byte = 0;
    reg  [7:0]   fault_mask = 0;
    wire [127:0] ct;
    wire         done, busy;
    wire [3:0]   round_idx;
    integer      errors = 0;
    integer      cycles;
    reg  [127:0] clean_ct;

    aes128_core dut (
        .clk(clk), .rst_n(rst_n), .start(start), .key(key), .pt(pt),
        .fault_en(fault_en), .fault_round(fault_round), .fault_byte(fault_byte),
        .fault_mask(fault_mask), .ct_raw(ct), .done(done), .busy(busy),
        .round_idx(round_idx)
    );

    task run;
        input [127:0] k;
        input [127:0] p;
        begin
            key = k; pt = p;
            @(negedge clk) start = 1;
            @(negedge clk) start = 0;
            cycles = 1;
            while (!done) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
        end
    endtask

    task check;
        input [127:0] k;
        input [127:0] p;
        input [127:0] exp;
        input [8*24-1:0] name;
        begin
            run(k, p);
            if (ct !== exp) begin
                $display("FAIL %0s: got %h expected %h", name, ct, exp);
                errors = errors + 1;
            end else
                $display("  ok %0s (latency %0d cycles)", name, cycles);
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;

        check(128'h000102030405060708090a0b0c0d0e0f,
              128'h00112233445566778899aabbccddeeff,
              128'h69c4e0d86a7b0430d8cdb78070b4c55a, "FIPS-197 C.1");
        check(128'h2b7e151628aed2a6abf7158809cf4f3c,
              128'h3243f6a8885a308d313198a2e0370734,
              128'h3925841d02dc09fbdc118597196a0b32, "FIPS-197 App. B");
        check(128'h2b7e151628aed2a6abf7158809cf4f3c,
              128'h6bc1bee22e409f96e93d7e117393172a,
              128'h3ad77bb40d7a3660a89ecaf32466ef97, "SP800-38A F.1.1");

        // fault at round 9 must change the ciphertext
        run(128'h000102030405060708090a0b0c0d0e0f, 128'h00112233445566778899aabbccddeeff);
        clean_ct = ct;
        fault_en = 1; fault_round = 9; fault_byte = 0; fault_mask = 8'h01;
        run(128'h000102030405060708090a0b0c0d0e0f, 128'h00112233445566778899aabbccddeeff);
        if (ct === clean_ct) begin
            $display("FAIL round-9 fault did not change ciphertext");
            errors = errors + 1;
        end else
            $display("  ok round-9 fault changes ciphertext (%h)", ct);
        // a round-9 single-byte fault must corrupt exactly 4 ciphertext bytes (one column through MixColumns)
        begin : count_bytes
            integer i, n;
            n = 0;
            for (i = 0; i < 16; i = i + 1)
                if (ct[127-8*i -: 8] !== clean_ct[127-8*i -: 8]) n = n + 1;
            if (n != 4) begin
                $display("FAIL round-9 fault corrupted %0d bytes, expected 4", n);
                errors = errors + 1;
            end else
                $display("  ok round-9 fault corrupts 4 bytes (DFA pattern)");
        end
        fault_en = 0;

        if (errors == 0) $display("PASS tb_aes128_core");
        else             $display("FAIL tb_aes128_core (%0d errors)", errors);
        $finish;
    end
endmodule
