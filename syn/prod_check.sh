#!/usr/bin/env bash
# Production-build check (called by yosys_check.sh / yosys_check_t2.sh).
#   $1 core top, $2 source list (compiled WITHOUT DEMO_BUILD)
# Fails if
#   - the demo key constant survives preprocessing,
#   - any demo-only port exists on the core,
#   - the key vault does not hold the key in 128 flip-flops,
#   - the design has latches, combinational loops or multipliers.
set -eu
cd "$(dirname "$0")/.."
TOP=$1; SRC=$2
IMG=ghcr.io/librelane/librelane:3.0.14
run() { if command -v yosys >/dev/null 2>&1; then sh -c "$1"; else
        docker run --rm -v "$PWD":"$PWD" -w "$PWD" "$IMG" sh -c "$1"; fi; }

# 1. no demo key in the preprocessed production sources
mkdir -p sim_build; run "iverilog -E -Irtl -o sim_build/prod_pp_$TOP.v $SRC"
if sed "s,//.*,," "sim_build/prod_pp_$TOP.v" | grep -qiE "DEMO_KEY|000102030405060708090a0b0c0d0e0f"; then
    echo "FAIL production $TOP: demo key constant present"; exit 1
fi

# 2-4. ports, vault, structure
FORBID="fault_en fault_round fault_byte fault_mask debug_unlock sentinel_en round_idx \
sentinel_en_sys sentinel_en_sen debug_unlock_sen fsm_mask_sen harness_alarm ewma_alarm fixed_alarm"
SEL=""; for p in $FORBID; do SEL="$SEL $TOP/i:$p $TOP/o:$p"; done
run "yosys -q -p 'read_verilog -sv -Irtl $SRC; synth -top $TOP; \
  select -assert-none $SEL; \
  select -assert-any $TOP/w:key_wr_en $TOP/w:key_wr_data; \
  select -assert-count 128 master_key_vault/w:key_to_cipher %ci1 master_key_vault/t:*DFF* %i; \
  flatten; check -assert; select -assert-none t:\$dlatch t:\$_DLATCH_*; select -assert-none t:\$mul'" \
  || { echo "FAIL production $TOP"; exit 1; }
echo "production $TOP: OK (no demo ports, no demo key, vault 128 FF, no latches/loops/multipliers)"
