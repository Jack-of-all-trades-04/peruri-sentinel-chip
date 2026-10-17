# Generating sys_pll (Tier 2)

The Tier 2 top instantiates a module named `sys_pll`. It is a Quartus IP and must be generated once in the IP Catalog. The simulation model with the same ports is `sim/tier2/models/sys_pll.v`.

## Steps (Quartus Prime Lite)

1. Open `quartus/tier2/de10_nano_top_t2.qpf`.
2. Tools > IP Catalog. Search for **PLL Intel FPGA IP** (Cyclone V, `altera_pll`). Double-click.
3. File name: `ip/sys_pll.v` (inside `quartus/tier2/`). Language: Verilog.
4. General tab:
   - Reference clock frequency: **50.0 MHz**
   - Operation mode: **normal**
   - Number of clocks: **3**
   - Enable locked output port: **on**
5. Output clocks (keep "Specify output frequency"):

| Output | Frequency | Phase shift | Duty | Role |
|---|---|---|---|---|
| outclk0 | **80 MHz** | 0 ps | 50% | CLK_sys A |
| outclk1 | **50 MHz** | 0 ps | 50% | CLK_sentinel |
| outclk2 | **80 MHz** | **8000 ps** | 50% | CLK_sys B (glitch source) |

6. Finish. When asked, add the generated `.qip` to the project. The `.qsf` already lists `ip/sys_pll.qip`.
7. Check that the generated module ports are `refclk`, `rst`, `outclk_0`, `outclk_1`, `outclk_2`, `locked`. These are the names the top uses.

## Choosing the numbers

- **CLK_sys 80 MHz (target).** The Tier 1 compile reports Fmax 93,49 MHz at Slow 1100mV 100C (estimasi, STA), limited by one full AES round per cycle. 80 MHz leaves margin. If timing fails after adding the sensors, try 70 or 75 MHz and change outclk2 to the same frequency.
- **outclk2 phase PHI.** One injected glitch shortens one CLK_sys cycle from T to PHI. It must satisfy T/2 < PHI < T (6,25-12,5 ns at 80 MHz). A smaller PHI is a harder glitch:
  - 8,0 ns (default) is shorter than the AES round path (about 10 ns), so the cipher is expected to fault.
  - Increase PHI towards 11-12 ns for a weaker glitch that may not fault the AES, to see whether the TDL still catches it.
- If you change the frequencies, update the parameters in `rtl/tier2/de10_nano_top_t2.v` (`DEB_CYCLES`, `STRETCH_CYCLES`, `OP_PERIOD`, `HB_BIT` assume 80 MHz) and the sim model defaults.
