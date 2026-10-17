#!/usr/bin/env bash
# Run every Tier 2 self-checking testbench (sim/tier2/tb_*.v) with Icarus
# Verilog, using the simulation models in sim/tier2/models/ for the parts
# that only exist on the FPGA (PLL, ring oscillators).
# Uses iverilog from PATH; falls back to the LibreLane docker image.
# Exit code is non-zero if any test fails. Run sim/run_sim.sh for Tier 1.
set -u
cd "$(dirname "$0")/../.."
IMG=ghcr.io/librelane/librelane:3.0.14

run() {
    if command -v iverilog >/dev/null 2>&1; then
        sh -c "$1"
    else
        docker run --rm -v "$PWD":"$PWD" -w "$PWD" "$IMG" sh -c "$1"
    fi
}

SRC="rtl/*.v rtl/tier2/*.v sim/tier2/models/*.v"
mkdir -p sim_build
fail=0
for tb in sim/tier2/tb_*.v; do
    name=$(basename "$tb" .v)
    out=$(run "iverilog -g2012 -o sim_build/$name.vvp $tb $SRC 2>&1 && vvp -n sim_build/$name.vvp" 2>&1)
    if echo "$out" | grep -q "^PASS $name"; then
        echo "PASS  $name"
    else
        echo "FAIL  $name"
        echo "$out" | grep -E "FAIL|error|Error" | sed 's/^/      /'
        fail=1
    fi
done
echo "waveform: sim_build/tb_*.vcd (GTKWave atau Surfer)"
exit $fail
