# Quartus project (Tier 1)

Target: Terasic DE10-Nano, Cyclone V SE `5CSEBA6U23I7`, Quartus Prime Lite 25.1.

## Compile and program

1. Open `quartus/de10_nano_top.qpf` in Quartus Prime Lite.
2. Processing > Start Compilation.
3. Check Timing Analyzer: setup and hold slack must be positive for `clk50` (50 MHz).
4. Tools > Programmer > Hardware Setup: select DE-SoC (USB-Blaster II). Auto Detect, choose `5CSEBA6U23I7`, then attach `output_files/de10_nano_top.sof` to the FPGA device (not the HPS) and press Start.

Before the first programming, verify the pin table in `de10_nano_top.qsf` against the DE10-Nano User Manual.

## Board controls

| Control | Function |
|---|---|
| SW0 | Sentinel enable (0 = OFF) |
| SW1 | attack mode: 0 clock-glitch emulation, 1 droop emulation |
| KEY1 | run the next encryption with a round-9 fault |
| KEY0 | reset; with SW3 = 1, demo-only debug unlock of LOCKDOWN |

| LED | Meaning |
|---|---|
| LED0-2 | tamper counter |
| LED3 | heartbeat |
| LED4 | last released ciphertext correct (FIPS-197 C.1) |
| LED5 | release blocked by gate |
| LED6 | alarm seen |
| LED7 | LOCKDOWN, key zeroized |

## Demo sequence

1. SW0 = 1. LED4 on, LED3 blinking.
2. SW0 = 0, press KEY1: LED4 goes off briefly (a faulty ciphertext was released).
3. SW0 = 1, press KEY1 three times: LED5 and LED6 flash, counter shows 1, 2, 3, LED4 stays on.
4. Press KEY1 a fourth time: LED7 on, LED4 off. The key is zero and no ciphertext leaves.
5. Rehearsal reset: SW3 = 1, press KEY0, SW3 = 0.

## Estimated resources

Yosys `synth_intel_alm` gives about 2.160 ALUTs and 754 flip-flops for the whole Tier 1 top (estimasi). This is under 5% of the device. Use the Quartus Fitter report for the real number.
