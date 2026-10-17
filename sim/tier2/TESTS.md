# Simulation tests (Tier 2)

Run all Tier 2 tests: `./sim/tier2/run_sim_t2.sh`. Tier 1 tests stay in `./sim/run_sim.sh`.
Each testbench is self-checking and prints one `PASS <name>` or `FAIL <name>` line.

Parts that exist only on the FPGA are replaced by models in `sim/tier2/models/`: `sys_pll` (ideal clocks with a configurable phase) and `ro_cell` (an oscillator whose half period the testbench changes). RTL simulation has no gate delays, so the TDL carry-chain output is forced by the testbench to the pattern a real chain would show for a chosen depth.

| Testbench | What it checks |
|---|---|
| `tb_tdl_glitch_line` | calibration arms with a nominal depth and records the minimum per edge polarity; no alert over 500 cycles with depth jitter; one shortened capture alerts within 2 edges and for at most 2 cycles; a dip inside the margin is ignored; no alert with Sentinel off; a saturated chain or an edge that never reaches the chain reports `cal_bad` and never alerts |
| `tb_glitch_injector` | without `arm` the output equals clk_a; one `arm` gives exactly one shortened period (PHI) and one long period (2T - PHI); no pulse narrower than the designed glitch; re-arm gives one more glitch; ENABLE = 0 passes clk_a unchanged |
| `tb_slow_path` | RO mesh, P2SE, LIF and the two ablation detectors on modelled ROs: stable, no detector fires; slow uniform drift, LIF and EWMA stay quiet while the fixed threshold raises a false alarm; fast drop on one RO, LIF fires within 4 windows; fast uniform step on all ROs, LIF stays quiet (common mode) while EWMA-only fires |
| `tb_de10_nano_top_t2` | full board top with PLL model, buttons and switches: SW2 view shows TDL armed and its depth; clean operations at 80 MHz release the FIPS-197 ciphertext; SW1 = 0 attack (Tier 1 path) blocked and counted; SW1 = 1 attack injects exactly one clock glitch in the last AES rounds, the TDL catches it, release blocked, counted once; Sentinel off, the same glitch is neither blocked nor counted; a 5-cycle TDL burst counts once; SW2 view stops counting; a local RO drop reaches the counter through LIF; the 4th event zeroizes the key and locks; KEY0 does not undo lockdown; SW3 + KEY0 unlocks |

Limits: TDL depth, RO frequencies and whether the injected glitch actually faults the AES depend on real silicon delays. They are checked on the board, not here.
