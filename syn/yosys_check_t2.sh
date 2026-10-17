#!/usr/bin/env bash
# Synthesis check of the Tier 2 top with Yosys: no latches, no combinational
# loops, no multipliers. sys_pll (Quartus IP) and ro_cell (intentional ring
# oscillator loop) are black boxes, see syn/tier2_blackbox.v.
# Prints a rough Cyclone V cell estimate; real numbers come from Quartus.
set -eu
cd "$(dirname "$0")/.."
IMG=ghcr.io/librelane/librelane:3.0.14
Y="yosys"
command -v yosys >/dev/null 2>&1 || Y="docker run --rm -v $PWD:$PWD -w $PWD $IMG yosys"

READ="read_verilog -sv syn/tier2_blackbox.v rtl/*.v rtl/tier2/*.v"

$Y -q -p "$READ; synth -top de10_nano_top_t2 -flatten; check -assert; \
          select -assert-none t:\$dlatch t:\$_DLATCH_*; select -assert-none t:\$mul; \
          tee -o sim_build_syn_t2_generic.txt stat"
echo "generic synth (Tier 2): OK (no latches, no loops, no multipliers)"
$Y -q -p "$READ; synth_intel_alm -family cyclonev -top de10_nano_top_t2; tee -o sim_build_syn_t2_cyclonev.txt stat" >/dev/null
awk '{n=0; for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/) n=$i} /MISTRAL_ALUT/ {alut+=n} /MISTRAL_FF/ {ff+=n} END {print "ALUT", alut+0; print "FF", ff+0}' sim_build_syn_t2_cyclonev.txt
echo "(estimasi from yosys synth_intel_alm; use the Quartus fitter report for real numbers)"
