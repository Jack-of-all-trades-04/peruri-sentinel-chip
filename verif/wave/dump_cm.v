module dump_cm;
  initial begin
    $dumpfile("sim_build/tb_clockmon_sel.vcd");
    $dumpvars(0, tb_core_t2_clockmon.u_main.clk_sys, tb_core_t2_clockmon.u_main.clk_sen,
      tb_core_t2_clockmon.u_main.op_req, tb_core_t2_clockmon.u_main.ct_valid, tb_core_t2_clockmon.u_main.gate_blocked,
      tb_core_t2_clockmon.u_main.busy, tb_core_t2_clockmon.u_main.alarm_sys, tb_core_t2_clockmon.u_main.clk_fault,
      tb_core_t2_clockmon.u_main.sen_dead, tb_core_t2_clockmon.u_main.ac, tb_core_t2_clockmon.u_main.tc,
      tb_core_t2_clockmon.u_main.dut.permit_sys, tb_core_t2_clockmon.u_main.dut.u_aes.busy,
      tb_core_t2_clockmon.u_main.dut.u_gate.blkA, tb_core_t2_clockmon.u_main.dut.u_mon_sys.alarm,
      tb_core_t2_clockmon.u_main.dut.u_mon_sen.alarm, tb_core_t2_clockmon.u_main.dut.u_w_hbsen.dead,
      tb_core_t2_clockmon.u_main.dut.u_w_hbsys.dead);
  end
endmodule
