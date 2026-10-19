#!/usr/bin/env bash
# Run the latency and clock-attack metrics testbench with Icarus Verilog.
# Uses iverilog from PATH; falls back to the LibreLane docker image.
set -eu
cd "$(dirname "$0")/../.."
IMG=ghcr.io/librelane/librelane:3.0.14

run() {
    if command -v iverilog >/dev/null 2>&1; then
        sh -c "$1"
    else
        docker run --rm -v "$PWD":"$PWD" -w "$PWD" "$IMG" sh -c "$1"
    fi
}

mkdir -p sim_build/verif/metrics
SRC="rtl/*.v rtl/tier2/*.v sim/tier2/models/*.v"
run "iverilog -g2012 -Irtl -DDEMO_BUILD -o sim_build/verif/metrics/tb_latency_metrics.vvp verif/metrics/tb_latency_metrics.v $SRC && vvp -n sim_build/verif/metrics/tb_latency_metrics.vvp"
