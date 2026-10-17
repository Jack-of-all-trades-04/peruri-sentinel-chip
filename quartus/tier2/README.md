# Quartus project (Tier 2)

Tier 2 adds real sensors on top of the Tier 1 demo: a tapped delay line (TDL) on CLK_sys that goes straight into the output release gate, eight ring oscillators with an LIF filter on a separate CLK_sentinel, and a clock-glitch injector for the live attack. The Tier 1 project in `quartus/` is unchanged and remains the fallback.

## First compile

1. Generate the PLL: [PLL_SETUP.md](PLL_SETUP.md).
2. Open `quartus/tier2/de10_nano_top_t2.qpf`, Processing > Start Compilation.
3. Expected warnings (not errors): combinational loops in `ro_cell` (ring oscillators), gated clock at `glitch_injector`, unconstrained RO clocks.
4. Timing Analyzer:
   - Report Clocks: each `get_clocks` pattern in the `.sdc` matches one PLL clock.
   - Setup and hold slack positive for the CLK_sys A and CLK_sentinel clocks.
5. Check the sensors were not optimised away:
   - Technology Map Viewer (Post-Fitting), search `u_tdl`: a carry chain of 64 cells and 24 coarse LUTs.
   - Search `u_mesh`: each `g_ro[i].u_cell` keeps 13 LUTs.

## Board controls

| Control | Function |
|---|---|
| SW0 | Sentinel enable |
| SW1 | KEY1 attack type: 0 emulated byte fault (Tier 1 path), 1 real clock glitch |
| SW2 | calibration view (alarms are not counted while on) |
| KEY0 | reset; also restarts TDL calibration and RO baselines. With SW3 = 1: debug unlock |
| KEY1 | attack |

| LED, SW2 = 0 | Meaning | LED, SW2 = 1 | Meaning |
|---|---|---|---|
| LED0-2 | tamper counter | LED0-5 | TDL calibrated minimum depth (0-63) |
| LED3 | heartbeat | | |
| LED4 | last ciphertext correct | | |
| LED5 | release blocked | | |
| LED6 | alarm seen | LED6 | TDL calibration failed |
| LED7 | LOCKDOWN | LED7 | TDL armed |

## TDL calibration on the board

The TDL only works if the launched edge reaches the middle of the 64-tap carry chain at the capture edge. That depends on the real LUT and routing delays, so `TDL_COARSE` (number of inverter LUTs before the chain, default 24) must be tuned once per board and clock frequency.

1. Program, set SW2 = 1, press KEY0 (recalibrates, takes under 1 ms).
2. Read the LEDs:

| LED7 | LED6 | LED0-5 | Meaning | Action |
|---|---|---|---|---|
| 1 | 0 | about 10-50 | armed, good | done; best near 32 |
| 0 | 1 | 63 | edge passes the whole chain | increase `TDL_COARSE` |
| 0 | 1 | 0-4 | edge does not reach the chain | decrease `TDL_COARSE` |

3. Change `TDL_COARSE` in `rtl/tier2/de10_nano_top_t2.v`, recompile, repeat. Odd and even values both work; the RTL compensates for the inversion.
4. False-alarm check: SW0 = 1, SW2 = 0, leave the board idle for 5 minutes. LED6 must stay off and the counter at 0. If not, increase `TDL_K` (margin, default 4 taps).

## Demo sequence

1. SW0 = 1, SW1 = 1. LED4 on, LED3 blinking, counter 0.
2. SW0 = 0, press KEY1: a real clock glitch hits the last AES rounds. If the AES faults, LED4 goes off briefly (faulty ciphertext released).
3. SW0 = 1, press KEY1: LED5 and LED6 flash, counter +1, LED4 stays on. The TDL caught the glitch; no ciphertext was released for that operation.
4. Repeat until the 4th event: LED7 on, key zeroized.
5. Rehearsal reset: SW3 = 1, press KEY0, SW3 = 0.

SW1 = 0 keeps the Tier 1 behaviour (emulated fault and harness alarm) as a fallback.

## What is and is not measured yet

- Simulation (Icarus Verilog) checks the logic with modelled sensor delays. TDL depth, RO frequencies and the effect of the glitch on the AES are only known after the board run.
- The slow path (RO + LIF) is designed for local anomalies (local heating, probing). A uniform change on all ROs is treated as environment and ignored by the LIF by design.
