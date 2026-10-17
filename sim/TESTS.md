# Simulation tests (Tier 1)

Run all tests: `./sim/run_sim.sh` (Icarus Verilog from PATH, or the LibreLane docker image).
Each testbench is self-checking and prints one `PASS <name>` or `FAIL <name>` line.

| Testbench | What it checks |
|---|---|
| `tb_aes128_core` | FIPS-197 Appendix C.1, FIPS-197 Appendix B and NIST SP 800-38A F.1.1 vectors; latency 11 cycles from start; a round-9 single-byte fault changes exactly 4 ciphertext bytes (the DFA pattern) |
| `tb_output_release_gate` | alarm mid-operation, at `aes_done`, and at `aes_done`+1..+4 blocks the release; alarm at +5 and no alarm release it; `ct_out` is zero whenever `ct_valid` is 0; Sentinel OFF ignores alarms; lockdown suppresses every release |
| `tb_tamper_fsm` | counter increments once per rising edge (a 40-cycle sticky alarm counts once); no zeroize below N = 4; zeroize and lockdown at N; key cleared asynchronously; lockdown survives user reset; demo debug unlock restores the demo state |
| `tb_de10_nano_top` | full board-level demo with buttons and switches: clean operations release the FIPS-197 C.1 ciphertext; SW0 = 0 + KEY1 releases a faulty ciphertext; SW0 = 1 + KEY1 blocks every faulty ciphertext and moves the counter; the 4th attack zeroizes the key and locks the chip; KEY0 does not undo lockdown; SW3 + KEY0 unlocks for rehearsal |

Limits of Tier 1 simulation: the alarm comes from the demo harness, not from a physical sensor. The TDL carry chain and ring oscillators are added in Tier 2 and must be confirmed on the board, because RTL simulation does not model their delays.

## Waveforms

Each testbench writes `sim_build/<testbench>.vcd` when it runs. Open it with GTKWave (`gtkwave sim_build/tb_de10_nano_top.vcd`) or Surfer.
`sim_build/` is git-ignored, so the waves are always regenerated from the current RTL. Add `-DNO_DUMP` to the iverilog command to skip them.
For the pitch, the most useful file is `tb_de10_nano_top.vcd`: it shows the clean run, the blocked faulty ciphertext, the counter climbing and the final lockdown.
