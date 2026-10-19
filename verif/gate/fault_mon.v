// Security monitor for the gate-level fault campaign. Runs next to
// tb_de10_nano_top (second top-level module) and, at the end of the run,
// prints what the fault did to the protection:
//   leak     = ciphertexts released with the Sentinel ON (SW0 = 1) that are
//              not the correct FIPS-197 value (a faulty result got out)
//   zeroized = the key was erased at least once (expected after N attacks)
//   locked   = LOCKDOWN was reached at least once (expected after N attacks)
module fault_mon;
    localparam [127:0] EXP_CT = 128'h69c4e0d86a7b0430d8cdb78070b4c55a;
    integer leak = 0;
    reg zeroized = 1'b0, locked = 1'b0;
    always @(posedge tb_de10_nano_top.clk) begin
        if (tb_de10_nano_top.dut.u_core.ct_valid && tb_de10_nano_top.SW[0] &&
            tb_de10_nano_top.dut.u_core.ct_out !== EXP_CT)
            leak = leak + 1;
        if (tb_de10_nano_top.dut.u_core.key_is_zero === 1'b1) zeroized = 1'b1;
        if (tb_de10_nano_top.dut.u_core.lockdown === 1'b1)    locked   = 1'b1;
    end
    final $display("FSTAT leak=%0d zeroized=%0d locked=%0d", leak, zeroized, locked);
endmodule
