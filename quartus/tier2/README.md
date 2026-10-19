# Quartus project (Tier 2)

Tier 2 adds real sensors on top of the Tier 1 demo: a tapped delay line (TDL) on CLK_sys that goes straight into the output release gate, eight ring oscillators with an LIF filter on a separate CLK_sentinel, and a clock-glitch injector for the live attack. The Tier 1 project in `quartus/` is unchanged and remains the fallback.

## First compile

1. Generate the PLL: [PLL_SETUP.md](PLL_SETUP.md).
2. Open `quartus/tier2/de10_nano_top_t2.qpf`, Processing > Start Compilation.
3. Expected warnings (not errors): combinational loops in `ro_cell` (ring oscillators) only. The RO divider bits are declared as clocks in the `.sdc` (one base clock and two generated clocks per RO, asynchronous to the PLL clocks), so Timing Analyzer reports the design as fully constrained for setup and hold.
4. Timing Analyzer:
   - Report Clocks: each `get_clocks` pattern in the `.sdc` matches one PLL clock.
   - Setup and hold slack positive for the CLK_sys A and CLK_sentinel clocks.
5. Check the sensors were not optimised away:
   - Technology Map Viewer (Post-Fitting), search `u_tdl`: a carry chain (`Add0`, cells linked by cout/cin), 63 coarse LUTs `cd[1..63]` and the tap mux feeding `chain_in`.
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
| LED0-2 | tamper counter | LED0-5 | SW1 = 0: TDL calibrated minimum depth (0-63); SW1 = 1: chosen coarse tap |
| LED3 | heartbeat | | |
| LED4 | last ciphertext correct | | |
| LED5 | release blocked | | |
| LED6 | alarm seen | LED6 | TDL calibration failed |
| LED7 | LOCKDOWN | LED7 | TDL armed |

Alarm-source view (SW2 = 1 and SW3 = 1), for hunting false alarms. Alarms are not counted while SW2 = 1. KEY0 in this view also performs the debug unlock.

| LED | Meaning |
|---|---|
| LED7 | TDL alert seen in the last 0.5 s (needs SW0 = 1) |
| LED6 | slow-path LIF alarm seen (raw, independent of SW0) |
| LED0-5 | lowest TDL depth (either edge) in the last ~0.4 s, saturates at 63. The gap to the calibrated minimum (SW3 = 0, SW1 = 0) is the margin `TDL_K` must cover |

## TDL calibration on the board

The TDL only works if the launched edge reaches the middle of the 64-tap carry chain at the capture edge. That depends on the real LUT and routing delays, so the coarse delay is chosen on the board, not at compile time: `tdl_glitch_line` has 63 kept inverter LUTs and a mux that feeds tap `cd[sel]` into the carry chain. After every reset the calibration sweeps `sel` from 0 upwards and keeps the first tap where both edge polarities give a depth between 16 and 60. If no tap fits, it sweeps again with the loose limits 5 to 63. The sweep takes about 7 ms at 80 MHz (estimasi).

1. Program, set SW2 = 1, press KEY0 and wait one second.
2. Read the LEDs:

| LED7 | LED6 | Meaning |
|---|---|---|
| 1 | 0 | armed, good |
| 0 | 1 | no tap worked in either pass |
| 0 | 0 | still calibrating (should end within 1 s) |

3. LED0-5 with SW1 = 0: calibrated minimum depth (rising edge), between 16 and 60 after a strict pass. With SW1 = 1: the coarse tap the sweep chose. Write both down; they are board measurements.
4. If LED6 = 1: the full coarse delay (63 LUTs) is still shorter than one period, or even tap 0 is longer than one period. Increase or decrease `TDL_COARSE` in `rtl/tier2/de10_nano_top_t2.v` and rebuild.
5. False-alarm check: SW0 = 1, SW2 = 0, leave the board idle for 5 minutes. LED6 must stay off and the counter at 0. If not, use the alarm-source view to see whether TDL or LIF fires, and how far the live depth drops below the calibrated minimum; set `TDL_K` (margin, default 12 taps in `de10_nano_top_t2.v`) above that gap. The demo glitch (8.0 ns instead of 12.5 ns) removes far more depth than the whole carry chain spans, so a larger margin does not hide it.

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
