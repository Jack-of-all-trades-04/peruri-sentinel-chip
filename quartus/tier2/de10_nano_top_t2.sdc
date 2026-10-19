# PERURI-SENTINEL Tier 2 timing constraints.
# Clock names below use wildcards on the generated PLL counters. After the
# first compile, open Timing Analyzer > Report Clocks and check that each
# get_clocks pattern matches exactly one clock. Adjust the patterns if not.

create_clock -name clk50 -period 20.000 [get_ports {FPGA_CLK1_50}]
derive_pll_clocks
derive_clock_uncertainty

set clk_sys_a [get_clocks {*u_pll*general[0]*}]
set clk_sen   [get_clocks {*u_pll*general[1]*}]
set clk_sys_b [get_clocks {*u_pll*general[2]*}]

# CLK_sys = glitch_injector output = clk_a | (en & clk_b). Both PLL clocks
# propagate through the OR gate. Normal operation is timed against clk_a;
# clk_b only matters for the injected glitch, which is meant to violate
# timing. Remove clk_b from analysis.
set_false_path -from $clk_sys_b
set_false_path -to   $clk_sys_b

# RO mesh: the ripple-divider bits are clocks (divided ring-oscillator
# outputs). Their frequency is set by silicon delay, not by a PLL, so they
# are declared with a conservative period: 10 ns assumes each divider bit
# toggles at no more than 100 MHz, above the expected RO frequency of a
# 13-LUT ring (estimasi). This times the Gray counters inside each RO
# domain instead of leaving them unconstrained.
# Each RO gets its own clock tree: div[0] is a base clock, div[1] and
# div[2] are generated clocks (divide by 2 each, ripple divider).
set ro_clks {}
for {set i 0} {$i < 8} {incr i} {
    set d0 [get_registers "*u_mesh|g_ro?${i}?.div?0?"]
    set d1 [get_registers "*u_mesh|g_ro?${i}?.div?1?"]
    set d2 [get_registers "*u_mesh|g_ro?${i}?.div?2?"]
    create_clock -name ro${i}_d0 -period 10.000 $d0
    create_generated_clock -name ro${i}_d1 -source $d0 -divide_by 2 $d1
    create_generated_clock -name ro${i}_d2 -source $d1 -divide_by 2 $d2
    lappend ro_clks ro${i}_d0 ro${i}_d1 ro${i}_d2
}

# Clock-monitor time base (u_mon_ro in peruri_sentinel_core_t2): one more ring
# oscillator, divided by 4 with a ripple divider like the RO mesh. mon_d0 is
# osc/2 and gets the same conservative 10 ns as the mesh dividers (osc at most
# 200 MHz, estimasi); mon_d1 = osc/4 is the clock of both clock_monitor
# instances and of the window logic (its longest path is about 7 ns, so it is
# timed against 20 ns). The measured ring frequency decides the monitor
# thresholds, see the header of peruri_sentinel_core_t2.v.
set mon_d0 [get_registers {*|mon_d0}]
set mon_d1 [get_registers {*|mon_d1}]
create_clock -name mon_d0 -period 10.000 $mon_d0
create_generated_clock -name mon_d1 -source $mon_d0 -divide_by 2 $mon_d1

# CLK_sys B (glitch injector input) is also a launch/latch clock of the
# CLK_sys logic; keep the monitor time base unrelated to it as well.
set_false_path -from [get_clocks {mon_d0 mon_d1}] -to $clk_sys_b
set_false_path -from $clk_sys_b -to [get_clocks {mon_d0 mon_d1}]

# CLK_sys, CLK_sentinel and the RO clocks are unrelated; every crossing
# goes through sync_2ff, reset_sync or the Gray-coded RO counters.
set_clock_groups -asynchronous -group [list $clk_sys_a] -group [list $clk_sen] -group [list clk50] -group [get_clocks $ro_clks] -group [get_clocks {mon_d0 mon_d1}]

# TDL: the carry-chain capture registers sample a moving edge on purpose.
set_false_path -to [get_registers {*u_tdl|cap1[*]}]

# RO mesh: ring oscillators clock the dividers and Gray counters; their
# values reach CLK_sentinel only through the 2-FF Gray synchronizers.
set_false_path -to [get_registers {*u_mesh*gs1[*]}]
# Clock monitors: the monitored clock's Gray counter reaches the window logic
# only through the 2-FF gs1/gs2 synchronizer; the window flags (bad_r, warm_r,
# win_r) and the async set of clk_flag_a cross only into sync_2ff stages or
# into the sticky fault flag, which is deliberately asynchronous.
set_false_path -to [get_registers {*u_mon_s*|gs1[*]}]
set_false_path -to [get_registers {*|clk_flag_a}]
# Clock monitors, resets. The monitor time base is reset by the two power-on
# resets (asynchronous to the ring) and its own reset_sync releases the window
# logic. The same reset also clears the Gray counters of the monitored clocks
# (CLK_sys, CLK_sentinel); they only matter as differences, so an arbitrary
# release phase costs at most one count in the first window, which is ignored
# during warm-up.
set_false_path -from [get_registers {*u_rs_sys|s[*] *u_rs_sen|s[*]}] -to [get_registers {*u_rs_mon|s[*] *|mon_d0 *|mon_d1}]
set_false_path -from [get_registers {*u_rs_mon|s[*]}] -to [get_registers {*u_mon_s*|bin_m[*] *u_mon_s*|gray_m[*]}]

# Board I/O: asynchronous inputs through sync_2ff, LEDs are human-visible.
set_false_path -from [get_ports {KEY[*] SW[*]}]
set_false_path -to   [get_ports {LED[*]}]
