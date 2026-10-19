// BUILD: both
// Exhaustive test of aes_sbox: all 256 inputs against an independent
// reference computed in the testbench from the S-box definition in
// FIPS-197 section 5.1.1 (multiplicative inverse in GF(2^8), then the
// affine transform). The reference does not use any table, so a typo in
// the RTL table cannot be copied into the check.
`timescale 1ns/1ps
module tb_aes_sbox;
    reg  [7:0] a;
    wire [7:0] y;
    aes_sbox dut (.a(a), .y(y));

    // GF(2^8) multiply modulo x^8 + x^4 + x^3 + x + 1
    function [7:0] gmul;
        input [7:0] p, q;
        reg   [7:0] r, x;
        integer k;
        begin
            r = 8'h00; x = p;
            for (k = 0; k < 8; k = k + 1) begin
                if (q[k]) r = r ^ x;
                x = {x[6:0], 1'b0} ^ (x[7] ? 8'h1b : 8'h00);
            end
            gmul = r;
        end
    endfunction

    function [7:0] ref_sbox;
        input [7:0] v;
        reg   [7:0] inv, b;
        integer c, i;
        begin
            inv = 8'h00;                         // inverse of 0 is defined as 0
            for (c = 1; c < 256; c = c + 1)
                if (gmul(v, c[7:0]) == 8'h01) inv = c[7:0];
            for (i = 0; i < 8; i = i + 1)        // b_i = inv_i ^ inv_{i+4} ^ inv_{i+5} ^ inv_{i+6} ^ inv_{i+7} ^ c_i
                b[i] = inv[i] ^ inv[(i + 4) % 8] ^ inv[(i + 5) % 8] ^
                       inv[(i + 6) % 8] ^ inv[(i + 7) % 8] ^ ((8'h63 >> i) & 1'b1);
            ref_sbox = b;
        end
    endfunction

    integer n, errors = 0;
    initial begin
        for (n = 0; n < 256; n = n + 1) begin
            a = n[7:0];
            #1;
            if (y !== ref_sbox(a)) begin
                $display("FAIL tb_aes_sbox: S(%02h) = %02h, expected %02h", a, y, ref_sbox(a));
                errors = errors + 1;
            end
        end
        if (errors == 0) $display("PASS tb_aes_sbox");
        else             $display("FAIL tb_aes_sbox (%0d errors)", errors);
        $finish;
    end
endmodule
