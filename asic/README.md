# PERURI-SENTINEL ASIC Hardening Flow (SkyWater 130nm)

This directory contains the automated ASIC implementation flow for **PERURI-SENTINEL** on the open-source SkyWater 130nm PDK (`sky130A`) using the High-Density standard-cell library (`sky130_fd_sc_hd`) via LibreLane and OpenROAD.

## 1. Purpose and Architecture Scope

The ASIC flow targets the production-grade **Tier 1** core (`peruri_sentinel_core`):
* **Production Build (`DEMO_BUILD` undefined):** In production mode, testbench backdoors and demo registers are excluded. Master key injection uses a dedicated write-once interface (`key_wr_data`, `key_wr_valid`, `key_wr_ready`) that permanently locks after the initial key load.
* **Off-Core NVM Protection:** Persistent state storage (`nvm_counter_model.v`) represents secure non-volatile memory (EEPROM, Flash, or ReRAM) located off-core. The core manages atomic state transitions via hardware handshake signals (`mark_req`/`mark_ack` and `commit_req`/`commit_ack`) while holding rollback-resistant alarm and tear counts.
* **Digital Standard-Cell Hardening:** Physical anti-tamper sensors (such as Tapped Delay Line glitch-canaries and Ring Oscillator mesh nodes) require full-custom layout or dedicated analog macros. In this flow, only the digital cryptographic and control fabric is synthesized and hardened:
  - AES-128 encryption datapath (10 rounds, constant-time single-cycle-per-round)
  - Persistent tamper FSM and security controller
  - Output release gate (holding ciphertext until clean commit)
  - Master key vault with asynchronous zeroization tripwire
  - Always-on DPA hiding LFSR logic (0 to 3 random dummy cycles)
* **Tier 1 Single Clock Domain:** The Tier 1 design runs synchronously on a single clock domain (`clk`), targeted at 50 MHz (20.0 ns period) to match the FPGA evaluation platform.

## 2. RTL Freeze Date

The RTL for this sign-off run was frozen on **2026-10-19** following the completion of single-fault hardening, start/abort handshake race mitigation, and persistent NVM sequence wrap verification.

## 3. How to Run the Flow

### Prerequisites
* Docker engine (runs the hardened toolchain container: `ghcr.io/librelane/librelane:3.0.14`)
* Python 3 environment with the `librelane` package installed
* SkyWater 130nm PDK (`sky130A`) installed locally

### Execution
From this directory, execute `run_flow.sh` specifying the PDK root directory:

```bash
# Run with default 20.0 ns period (50 MHz)
PDK_ROOT=<path_to_pdk_root> CLOCK_PERIOD=20 ./run_flow.sh

# Run with custom run tag
PDK_ROOT=<path_to_pdk_root> CLOCK_PERIOD=20 RUN_TAG=clk20ns_pnr_corners2 ./run_flow.sh
```

To summarize and compare metrics across all completed runs in `runs/`:

```bash
python3 summarize_metrics.py
```

## 4. Key Configuration Choices

The flow is configured in `config.yaml` with the following architectural choices:
* **Cell Library Selection:** `sky130_fd_sc_hd` is chosen for optimal logic density and silicon area efficiency.
* **FSM Encoding Preservation:** The FSM state registers in the RTL carry `(* fsm_encoding = "none" *)`. This prevents Yosys optimization passes from modifying fault-tolerant state encodings (Hamming distance protection and one-hot states).
* **Synthesis Strategy (`SYNTH_STRATEGY: "AREA 0"`):**
  An area-focused synthesis strategy is used. Exploration showed that `DELAY 1` dramatically bloated instance count (+45%) and wire congestion, which degraded post-route timing. `AREA 0` provides clean logic depth with minimal routing parasitics.
* **Multi-Corner Place-and-Route (`PNR_CORNERS`):**
  Configured with `nom_tt_025C_1v80`, `nom_ss_100C_1v60`, and `nom_ff_n40C_1v95`. This forces OpenROAD's resizer to evaluate setup and hold constraints across multiple corners during CTS and placement, rather than only nominal typical-typical.
* **Hold Slack Margin Tuning (`PL_RESIZER_HOLD_SLACK_MARGIN: 0.02`):**
  The default hold slack margin of 0.10 ns caused the resizer to insert hundreds of delay buffers (`clkdlybuf`), which inadvertently bloated setup delays on output gate registers by ~130 ps. Lowering the margin to 0.02 ns eliminated unnecessary delay buffer insertion while maintaining clean positive hold slack (+0.011 ns worst corner).
* **Setup Slack Margin (`PL_RESIZER_SETUP_SLACK_MARGIN: 0.2`):**
  Guides post-CTS resizer optimization to target positive setup slack margin before detailed routing.
* **Fanout Constraint (`MAX_FANOUT_CONSTRAINT: 16`):**
  Controls buffer insertion tree depth without over-constraining the buffer count.
* **Floorplan Sizing and Density:**
  - `FP_SIZING: relative`
  - `FP_CORE_UTIL: 40`
  - `PL_TARGET_DENSITY_PCT: 50`
  The core routes 460 signal pins (462 total pins including `VPWR` and `VGND`, per `floorplan__design__io` and `design__io`; including 128-bit `pt_in`, 128-bit `ct_out`, and 128-bit `key_wr_data`). Sizing relative to cell area ensures adequate perimeter for pad pitch while maintaining 48.44% core utilization, resulting in zero DRC and zero LVS violations.

## 5. Sign-Off Timing Corners Analysed

Sign-off static timing analysis (STA) is performed across all 9 process-voltage-temperature (PVT) corners:
1. `nom_tt_025C_1v80`: Typical process, 25 C, 1.80 V, nominal parasitics
2. `nom_ss_100C_1v60`: Slow-slow process, 100 C, 1.60 V, nominal parasitics
3. `nom_ff_n40C_1v95`: Fast-fast process, -40 C, 1.95 V, nominal parasitics
4. `min_tt_025C_1v80`: Typical process, 25 C, 1.80 V, minimum parasitics
5. `min_ss_100C_1v60`: Slow-slow process, 100 C, 1.60 V, minimum parasitics
6. `min_ff_n40C_1v95`: Fast-fast process, -40 C, 1.95 V, minimum parasitics
7. `max_tt_025C_1v80`: Typical process, 25 C, 1.80 V, maximum parasitics
8. `max_ss_100C_1v60`: Slow-slow process, 100 C, 1.60 V, maximum parasitics (worst setup corner)
9. `max_ff_n40C_1v95`: Fast-fast process, -40 C, 1.95 V, maximum parasitics (worst hold corner)

### Timing Closure Qualification and Electrical DRVs

Timing closure on `clk20ns_pnr_corners2` (20.0 ns, 50 MHz) and `clk21ns` (21.0 ns, 47.62 MHz) denotes **setup and hold timing closure** (`timing__setup_vio__count = 0` and `timing__hold_vio__count = 0` across all 9 PVT corners). Electrical Design Rule Violations (DRVs) remain nonzero across all LibreLane runs in this standard-cell library: `design__max_slew_violation__count` ranges from 5,133 (`clk10ns`) to 11,908 (`clk20ns_delay1`), and `design__max_cap_violation__count` ranges from 5 (`clk22ns`) to 106 (`clk20ns_pnr_corners2`).

### Sign-Off Slack and Electrical DRV Breakdown for Closed Run (`clk20ns_pnr_corners2`)

| Corner | Setup WNS (ns) | Hold WNS (ns) | Setup Vio | Hold Vio | Slew Vio | Cap Vio | Fanout Vio | Status |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `max_ss_100C_1v60` (worst setup) | +1.913 | +0.659 | 0 | 0 | 6595 | 106 | 0 | MET |
| `max_ff_n40C_1v95` (worst hold) | +12.056 | +0.011 | 0 | 0 | 1147 | 1 | 0 | MET |
| `max_tt_025C_1v80` | +9.846 | +0.179 | 0 | 0 | 3631 | 1 | 0 | MET |
| `min_ss_100C_1v60` | +3.065 | +0.652 | 0 | 0 | 5268 | 31 | 0 | MET |
| `min_ff_n40C_1v95` | +12.279 | +0.016 | 0 | 0 | 187 | 1 | 0 | MET |
| `min_tt_025C_1v80` | +10.174 | +0.185 | 0 | 0 | 3151 | 1 | 0 | MET |
| `nom_ss_100C_1v60` | +2.489 | +0.657 | 0 | 0 | 5954 | 73 | 0 | MET |
| `nom_ff_n40C_1v95` | +12.175 | +0.016 | 0 | 0 | 574 | 1 | 0 | MET |
| `nom_tt_025C_1v80` | +10.015 | +0.185 | 0 | 0 | 3428 | 1 | 0 | MET |

### Hold Margin Caveat and Robust Operating Point

While `clk20ns_pnr_corners2` achieves setup and hold closure at 20.0 ns (50 MHz), its worst-case hold slack at `max_ff_n40C_1v95` is +0.011 ns (11.15 ps), and its max capacitance violations rise to 106 (driven primarily at `max_ss_100C_1v60`). In comparison, the `clk21ns` run (21.0 ns period, 47.62 MHz) provides a substantially more robust operating point with +0.076 ns hold slack, +0.869 ns setup slack, and only 7 max capacitance violations (with 615 hold buffers inserted). Therefore, for physical robustness (max slew/cap violations still remain in both runs), `clk21ns` represents the conservative sign-off point, while `clk20ns_pnr_corners2` demonstrates peak 50 MHz capability under tuned hold margin settings (`PL_RESIZER_HOLD_SLACK_MARGIN: 0.02`).

## 6. Post-Layout Implementation Results

> [!NOTE]
> All metrics below are post-layout sign-off results from `final/metrics.json` labelled `(estimasi, pasca-layout)`. Setup/hold violations reflect timing closure, while electrical DRVs (slew, cap, fanout) are reported separately.

| Run | Clock (ns) | Setup WNS (ns) | Hold WNS (ns) | Setup Vio | Hold Vio | Slew Vio | Cap Vio | Fanout Vio | Die Area (um2) | Core Util | Std Cells | Total Inst | FFs | Total Power | DRC (M/K) | LVS |
|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| clk10ns | 10 | -3.290 | +0.104 | 1598 | 0 | 5133 | 7 | 29 | 302218 | 52.85% | 17774 | 57299 | 780 | 24.38 mW | 0/0 | 0 |
| clk13ns | 13 | -3.438 | +0.107 | 1141 | 0 | 9107 | 6 | 30 | 302218 | 52.46% | 17743 | 57460 | 780 | 18.41 mW | 0/0 | 0 |
| clk15ns | 15 | -2.463 | +0.107 | 703 | 0 | 9369 | 9 | 28 | 302218 | 52.45% | 17743 | 57445 | 780 | 15.94 mW | 0/0 | 0 |
| clk17ns | 17 | -0.485 | +0.107 | 16 | 0 | 9471 | 9 | 28 | 302218 | 52.46% | 17753 | 57446 | 780 | 14.06 mW | 0/0 | 0 |
| clk18ns_rtl1301 | 18 | -2.131 | +0.076 | 186 | 0 | 8776 | 7 | 19 | 345562 | 51.66% | 19648 | 65826 | 1061 | 21.38 mW | 0/0 | 0 |
| clk20ns | 20 | -0.131 | +0.076 | 10 | 0 | 8776 | 7 | 19 | 345562 | 51.66% | 19648 | 65826 | 1061 | 19.24 mW | 0/0 | 0 |
| clk20ns_delay1 | 20 | -2.004 | +0.102 | 98 | 0 | 11908 | 79 | 9 | 492368 | 52.68% | 29681 | 95422 | 1061 | 22.74 mW | 0/0 | 0 |
| **clk20ns_pnr_corners2** | **20** | **+1.913** | **+0.011** | **0** | **0** | **6595** | **106** | **0** | **345562** | **48.44%** | **18634** | **67542** | **1061** | **18.97 mW** | **0/0** | **0** |
| clk20ns_slack04 | 20 | -0.131 | +0.076 | 10 | 0 | 8776 | 7 | 19 | 345562 | 51.66% | 19648 | 65826 | 1061 | 19.24 mW | 0/0 | 0 |
| clk21ns | 21 | +0.869 | +0.076 | 0 | 0 | 8776 | 7 | 19 | 345562 | 51.66% | 19648 | 65826 | 1061 | 18.32 mW | 0/0 | 0 |
| clk22ns | 22 | +1.882 | +0.069 | 0 | 0 | 8770 | 5 | 19 | 345562 | 51.66% | 19644 | 65821 | 1061 | 17.49 mW | 0/0 | 0 |

*Note on earlier variant `clk20ns_pnr_corners`: stopped mid-run at step 39 (no `metrics.json`), superseded by `clk20ns_pnr_corners2`.*

## 7. Item 9.4: Pre-Layout Cell Area Overhead (Sentinel Security Wrapper vs AES-128)

Based on pre-layout hierarchical standard-cell synthesis of the production core (`peruri_sentinel_core` from `sim_build/verif/netlist/summary_t1.md`), labelled `(estimasi, pra-layout)`:

| Instance | Module | Std Cells | Flip-Flops | Cell Area (um2) | Share of Area | Functional Role |
|:---|:---|---:|---:|---:|---:|:---|
| `u_aes` | `aes128_core` | 9949 | 390 | 70358.7 | 69.7% | Baseline Cryptographic Engine |
| `u_gate` | `output_release_gate` | 1727 | 426 | 19089.6 | 18.9% | Anti-DFA Output Hold Gate |
| `u_fsm` | `tamper_persist_fsm` | 616 | 94 | 5835.6 | 5.8% | Tamper Controller and CRC NVM Logic |
| `u_vault` | `master_key_vault` | 260 | 129 | 4688.2 | 4.6% | Write-Once Key Storage and Zeroize |
| `u_dpa` | `dpa_hiding_lfsr` | 36 | 20 | 625.6 | 0.6% | DPA Hiding Dummy Cycle Injection |
| `u_trip` | `tripwire_zeroize` | 2 | 1 | 28.8 | <0.1% | Asynchronous Zeroization Trigger |
| Glue logic | Top-level wiring | 57 | 2 | 376.6 | 0.4% | Internal Decoders and Multiplexers |
| **Total** | **`peruri_sentinel_core`** | **12647** | **1062** | **101003.1** | **100.0%** | **Total Synthesized Cell Area** |

### Silicon Overhead Ratio Analysis (Item 9.4)
* **Bare Cryptographic Accelerator Area (AES-128):** 70,358.7 um2 (0.0704 mm2) `(estimasi, pra-layout)`
* **Sentinel Security Wrapper Modules Area (`u_gate` + `u_fsm` + `u_vault` + `u_dpa` + `u_trip` + glue):** 30,644.4 um2 (0.0306 mm2) `(estimasi, pra-layout)`
* **Silicon Area Overhead Ratio over Bare AES:**
  $$\text{Area Overhead} = \frac{30644.4 \text{ um}^2}{70358.7 \text{ um}^2} \times 100\% = \mathbf{+43.55\%} \quad (\approx +43.6\%)$$
* **Security Share of Total Core:** Security wrapper modules account for 30.3% of the total synthesized core cell area, while AES-128 comprises 69.7%.
* **Architectural Rationale:** The +43.55% overhead is significantly more compact than conventional hardware duplication techniques such as Dual-Rail Precharge Logic (WDDL), which typically introduce 200% to 300% silicon area penalties.

## 8. Item 11.3: Post-Layout Core Utilisation and Free Area Breakdown

Based on the sign-off layout metrics from `final/metrics.json` labelled `(estimasi, pasca-layout)`:

* **Die Dimensions and Area:**
  - Total die area: 345,562 um2 (0.3456 mm2), meeting the proposal target (<0.35 mm2)
  - Exact die bounding box: `[0.0, 0.0, 582.51, 593.23]` um (582.51 um width x 593.23 um height)
* **Core Dimensions and Area:**
  - Total core area: 326,338 um2 (0.3263 mm2)
  - Exact core bounding box: `[5.52, 10.88, 576.84, 582.08]` um (571.32 um width x 571.20 um height)
* **Physical Cell Counts and Area in `clk20ns_pnr_corners2`:**
  - Placed standard cells (`design__instance__count__stdcell`): **18,634 cells** (area: 158,082 um2)
  - Core utilisation (`design__instance__utilization`): **48.44%**
  - Free core area: **168,256 um2 (51.56% of active core area)**
  - Fill and decap cells (`design__instance__count__class:fill_cell`): **48,908 cells** occupying the 168,256 um2 free core area
  - Total instances (`design__instance__count`): **67,542** (18,634 standard cells + 48,908 fill cells)
  - Placed standard-cell breakdown: 10,291 multi-input combinational cells, 4,664 tap cells, 2,021 timing repair buffers, 23 hold buffers, and 1,061 sequential flip-flops
* **Physical Cell Counts and Area in `clk20ns` / `clk21ns`:**
  - Placed standard cells: **19,648 cells** (area: 168,592 um2)
  - Core utilisation: **51.66%**
  - Free core area: **157,746 um2 (48.34% of active core area)**
  - Fill cells: **46,178 cells**
  - Total instances: **65,826** (19,648 standard cells + 46,178 fill cells)
  - Placed standard-cell breakdown: includes 4,664 tap cells, 3,044 timing repair buffers, 615 hold buffers, and 1,061 sequential flip-flops

### Reconciliation of Core Utilisation (48.44% vs 51.66%)

The baseline runs (`clk20ns`, `clk21ns`) utilized 51.66% of the core area with 19,648 standard cells. When tuning `PL_RESIZER_HOLD_SLACK_MARGIN: 0.02` and `PNR_CORNERS` in `clk20ns_pnr_corners2`, OpenROAD's resizer eliminated over-buffering on hold paths, reducing hold buffer count from 615 down to 23 and timing repair buffer count from 3,044 down to 2,021. Consequently, standard cell count decreased by 1,014 cells (from 19,648 to 18,634), reducing standard cell area from 168,592 um2 to 158,082 um2 and shifting core utilisation from 51.66% down to 48.44%. The resulting additional free core space was populated by 2,730 additional fill and decap cells (48,908 vs 46,178), resulting in a total instance count of 67,542.

### Floorplan Rationale and I/O Pin Count

1. **Perimeter Pad Pitch and I/O Count:** The core routes 460 signal pins (`floorplan__design__io: 460`), or 462 total pins including `VPWR` and `VGND` power supplies (`design__io: 462`). Sizing the core to provide 51.56% free area ensures sufficient die perimeter for standard I/O pad pitch without routing congestion.
2. **Congestion-Free Routing:** Providing 51.56% free routing channel area prevents metal congestion on lower routing layers (met1 to met3), achieving zero DRC violations (Magic and KLayout) and zero LVS errors.
3. **Internal Power Stability:** Free core area is fully filled with decap cells (`sky130_fd_sc_hd__decap_3`) and fill cells, providing distributed on-chip capacitance that keeps internal supply voltage stable (worst-case IR drop stays at nominal 1.80 V).
