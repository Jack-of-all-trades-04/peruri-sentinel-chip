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
    # Build per testbench: a line "// BUILD: prod" compiles the production
    # build (no DEMO_BUILD), "// BUILD: both" runs it in both builds, and
    # anything else is a demo-build test.
    b=$(sed -n 's,^// BUILD: *\([a-z]*\).*,\1,p' "$tb" | head -1)
    case "$b" in prod) builds="prod" ;; both) builds="demo prod" ;; *) builds="demo" ;; esac
    for bd in $builds; do
    def=""; srcs="$SRC"
    if [ "$bd" = demo ]; then def="-DDEMO_BUILD"
    else srcs=$(ls $SRC | grep -v de10_nano_top | tr '\n' ' '); fi
    out=$(run "iverilog -g2012 -Irtl $def -o sim_build/${name}_$bd.vvp $tb $srcs 2>&1 && vvp -n sim_build/${name}_$bd.vvp" 2>&1)
    if echo "$out" | grep -q "^PASS $name"; then
        echo "PASS  $name ($bd)"
    else
        echo "FAIL  $name ($bd)"
        echo "$out" | grep -E "FAIL|error|Error" | sed 's/^/      /'
        fail=1
    fi
    done
done
echo "waveform: sim_build/tb_*.vcd (GTKWave atau Surfer)"
exit $fail
