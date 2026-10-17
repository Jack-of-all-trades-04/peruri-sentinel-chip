#!/usr/bin/env bash
# Run every self-checking testbench in sim/ with Icarus Verilog.
# Uses iverilog from PATH; falls back to the LibreLane docker image.
# Exit code is non-zero if any test fails.
set -u
cd "$(dirname "$0")/.."
IMG=ghcr.io/librelane/librelane:3.0.14

run() {
    if command -v iverilog >/dev/null 2>&1; then
        sh -c "$1"
    else
        docker run --rm -v "$PWD":"$PWD" -w "$PWD" "$IMG" sh -c "$1"
    fi
}

mkdir -p sim_build
fail=0
for tb in sim/tb_*.v; do
    name=$(basename "$tb" .v)
    out=$(run "iverilog -g2012 -o sim_build/$name.vvp $tb rtl/*.v 2>&1 && vvp -n sim_build/$name.vvp" 2>&1)
    if echo "$out" | grep -q "^PASS $name"; then
        echo "PASS  $name"
    else
        echo "FAIL  $name"
        echo "$out" | grep -E "FAIL|error" | sed 's/^/      /'
        fail=1
    fi
done
exit $fail
