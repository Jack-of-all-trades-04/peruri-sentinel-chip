# PERURI-SENTINEL Tier 1 timing constraints
create_clock -name clk50 -period 20.000 [get_ports {FPGA_CLK1_50}]
derive_clock_uncertainty

# Buttons and switches are asynchronous and go through sync_2ff.
set_false_path -from [get_ports {KEY[*] SW[*]}]
# LEDs are human-visible only.
set_false_path -to [get_ports {LED[*]}]
