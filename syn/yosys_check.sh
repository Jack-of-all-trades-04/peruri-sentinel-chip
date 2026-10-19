#!/usr/bin/env bash
# Generic synthesis check with Yosys: no latches, no combinational loops,
# no multipliers. Also prints a rough Cyclone V cell estimate.
# Real resource numbers come from Quartus.
set -eu
cd "$(dirname "$0")/.."
IMG=ghcr.io/librelane/librelane:3.0.14
Y="yosys"
command -v yosys >/dev/null 2>&1 || Y="docker run --rm -v $PWD:$PWD -w $PWD $IMG yosys"

$Y -q -p "read_verilog -sv -Irtl -DDEMO_BUILD rtl/*.v; synth -top de10_nano_top -flatten; check -assert; \
          select -assert-none t:\$dlatch t:\$_DLATCH_*; select -assert-none t:\$mul; tee -o sim_build_syn_generic.txt stat"
echo "generic synth: OK (no latches, no loops, no multipliers)"
$Y -q -p "read_verilog -sv -Irtl -DDEMO_BUILD rtl/*.v; synth_intel_alm -family cyclonev -top de10_nano_top; tee -o sim_build_syn_cyclonev.txt stat" >/dev/null
awk '{n=0; for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/) n=$i} /MISTRAL_ALUT/ {alut+=n} /MISTRAL_FF/ {ff+=n} END {print "ALUT", alut+0; print "FF", ff+0}' sim_build_syn_cyclonev.txt
echo "(estimasi from yosys synth_intel_alm; use the Quartus fitter report for real numbers)"

# ---------------- production build (no DEMO_BUILD) ----------------
# The demo ports and the demo key must not exist, and the key vault must
# hold the key in 128 real flip-flops (in the demo build the constant key
# folds into logic).
PROD="rtl/aes_sbox.v rtl/aes128_core.v rtl/master_key_vault.v rtl/output_release_gate.v \
rtl/tamper_persist_fsm.v rtl/tripwire_zeroize.v rtl/dpa_hiding_lfsr.v rtl/peruri_sentinel_core.v"
bash syn/prod_check.sh peruri_sentinel_core "$PROD"
