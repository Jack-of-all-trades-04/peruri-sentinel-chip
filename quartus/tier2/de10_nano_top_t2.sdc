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

# CLK_sys and CLK_sentinel are unrelated; every crossing goes through
# sync_2ff, reset_sync or the Gray-coded RO counters.
set_clock_groups -asynchronous -group [list $clk_sys_a] -group [list $clk_sen] -group [list clk50]

# TDL: the carry-chain capture registers sample a moving edge on purpose.
set_false_path -to [get_registers {*u_tdl|cap1[*]}]

# RO mesh: ring oscillators clock the dividers and Gray counters; their
# values reach CLK_sentinel only through the 2-FF Gray synchronizers.
# The RO "clocks" stay unconstrained (expected in Unconstrained Paths).
set_false_path -to [get_registers {*u_mesh*gs1[*]}]

# Board I/O: asynchronous inputs through sync_2ff, LEDs are human-visible.
set_false_path -from [get_ports {KEY[*] SW[*]}]
set_false_path -to   [get_ports {LED[*]}]
