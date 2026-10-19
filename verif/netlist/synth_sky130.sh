#!/usr/bin/env bash
# Synthesize the Sentinel cores to SkyWater sky130_fd_sc_hd standard cells
# with Yosys and print a netlist summary (cell count and cell area per
# module). The netlists are also the "gate" side of the equivalence check
# (verif/eqy) and the input of the gate-level tests (verif/gate).
#
# Usage:  PDK_ROOT=<dir containing sky130A> verif/netlist/synth_sky130.sh
#
# Outputs (sim_build/verif/netlist/):
#   <top>.sky130.v      flat-per-module gate netlist (hierarchy kept)
#   <top>.stat.txt      yosys stat with liberty areas
#   summary.md          table per instance (cells, flip-flops, area incl. submodules)
#
# Numbers are pre-layout (estimasi): no placement, no clock tree, no
# buffering for wire load. Use the LibreLane flow for post-layout numbers.
set -eu
cd "$(dirname "$0")/../.."
: "${PDK_ROOT:?set PDK_ROOT to the directory that contains sky130A}"
IMG=ghcr.io/librelane/librelane:3.0.14
LIB_REL=sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
LIB="$PDK_ROOT/$LIB_REL"
OUT=sim_build/verif/netlist
mkdir -p "$OUT"

Y() {
    if command -v yosys >/dev/null 2>&1; then
        yosys "$@"
    else
        docker run --rm -u "$(id -u):$(id -g)" -v "$PWD":"$PWD" -v "$PDK_ROOT":"$PDK_ROOT" \
            -w "$PWD" "$IMG" yosys "$@"
    fi
}

synth_one() {   # $1 top, $2 source list, $3 extra commands before synth, $4 output tag, $5 defines
    top=$1; src=$2; pre=$3; tag=${4:-$1}; defs=${5--DDEMO_BUILD}
    cat > "$OUT/$tag.ys" <<EOF
read_liberty -lib $LIB
read_verilog -sv -I$PWD/rtl $defs $src
$pre
synth -nofsm -top $top
dfflibmap -liberty $LIB -dont_use *lpflow*
abc -liberty $LIB -dont_use *lpflow*
hilomap -singleton -hicell sky130_fd_sc_hd__conb_1 HI -locell sky130_fd_sc_hd__conb_1 LO
setundef -zero
opt_clean -purge
check -assert
tee -o $OUT/$tag.stat.txt stat -liberty $LIB
write_verilog -noattr -noexpr $OUT/$tag.sky130.v
EOF
    Y -q -s "$OUT/$tag.ys" > "$OUT/$tag.log" 2>&1 || { tail -20 "$OUT/$tag.log"; exit 1; }
    echo "synth $tag: OK"
}

# Tier 1 core (AES + gate + FSM + vault + tripwire + DPA LFSR)
synth_one peruri_sentinel_core "rtl/aes_sbox.v rtl/aes128_core.v rtl/master_key_vault.v \
rtl/output_release_gate.v rtl/tamper_persist_fsm.v rtl/tripwire_zeroize.v \
rtl/dpa_hiding_lfsr.v rtl/peruri_sentinel_core.v" ""

# Tier 2 core (adds TDL, RO mesh, P2SE, LIF, CDC). ro_cell is a black box:
# in an ASIC it is a hand-placed inverter ring, not synthesized logic.
synth_one peruri_sentinel_core_t2 "rtl/aes_sbox.v rtl/aes128_core.v rtl/master_key_vault.v \
rtl/output_release_gate.v rtl/graduated_tamper_fsm.v rtl/tripwire_zeroize.v \
rtl/dpa_hiding_lfsr.v rtl/sync_2ff.v rtl/pulse_stretch.v rtl/tier2/reset_sync.v \
rtl/tier2/tdl_glitch_line.v rtl/tier2/ro_sensor_mesh.v rtl/tier2/p2se_encoder.v \
rtl/tier2/snn_lif_engine.v rtl/tier2/ablation_detectors.v rtl/tier2/peruri_sentinel_core_t2.v \
syn/tier2_blackbox.v" ""

# Tier 1 core, production build (no DEMO_BUILD): the netlist that is hardened
synth_one peruri_sentinel_core "rtl/aes_sbox.v rtl/aes128_core.v rtl/master_key_vault.v \
rtl/output_release_gate.v rtl/tamper_persist_fsm.v rtl/tripwire_zeroize.v \
rtl/dpa_hiding_lfsr.v rtl/peruri_sentinel_core.v" "" peruri_sentinel_core_prod " "

python3 verif/netlist/summarize.py "$LIB" "$OUT/peruri_sentinel_core.sky130.v" \
    "$OUT/peruri_sentinel_core_t2.sky130.v" "$OUT/peruri_sentinel_core_prod.sky130.v" > "$OUT/summary.md"
cat "$OUT/summary.md"
