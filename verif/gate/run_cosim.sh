#!/usr/bin/env bash
# RTL vs sky130 gate-netlist co-simulation of peruri_sentinel_core
# (verif/gate/tb_cosim.v). The netlist modules are copied with a gl_ prefix
# so both versions can live in one simulation.
#
# Usage: PDK_ROOT=<dir containing sky130A> verif/gate/run_cosim.sh [cycles] [seeds]
set -eu
cd "$(dirname "$0")/../.."
: "${PDK_ROOT:?set PDK_ROOT to the directory that contains sky130A}"
CYC=${1:-200000}
SEEDS=${2:-4}
IMG=ghcr.io/librelane/librelane:3.0.14
CELLS=$PDK_ROOT/sky130A/libs.ref/sky130_fd_sc_hd/verilog
O=sim_build/verif/gate/cosim
mkdir -p "$O"

D() {
    if command -v iverilog >/dev/null 2>&1; then sh -c "$1"
    else docker run --rm -u "$(id -u):$(id -g)" -v "$PWD":"$PWD" -v "$PDK_ROOT":"$PDK_ROOT" -w "$PWD" "$IMG" sh -c "$1"; fi
}

python3 - sim_build/verif/netlist/peruri_sentinel_core.sky130.v "$O/core_gl_prefixed.v" <<'EOF'
import re, sys
src = open(sys.argv[1]).read()
names = re.findall(r"^module\s+(\S+?)\s*\(", src, re.M)
for n in sorted(names, key=len, reverse=True):
    bare = n.lstrip("\\")
    if n.startswith("\\"):
        # escaped identifier (ends at whitespace): \name  ->  \gl_name
        src = src.replace(n + " ", "\\gl_" + bare + " ").replace(n + "(", "\\gl_" + bare + " (")
    else:
        src = re.sub(r"(?<![\w$\\])" + re.escape(n) + r"(?=\s*\(|\s+\w)", "gl_" + n, src)
open(sys.argv[2], "w").write(src)
EOF

T1="rtl/aes_sbox.v rtl/aes128_core.v rtl/master_key_vault.v rtl/output_release_gate.v \
rtl/tamper_persist_fsm.v rtl/tripwire_zeroize.v rtl/dpa_hiding_lfsr.v rtl/peruri_sentinel_core.v rtl/nvm_counter_model.v"
D "iverilog -g2012 -Irtl -DFUNCTIONAL -DDEMO_BUILD -o $O/tb_cosim.vvp $CELLS/primitives.v $CELLS/sky130_fd_sc_hd.v \
   $O/core_gl_prefixed.v $T1 verif/gate/tb_cosim.v" > "$O/build.log" 2>&1 || { tail "$O/build.log"; exit 1; }
rc=0
for s in $(seq 1 "$SEEDS"); do
    D "vvp -n $O/tb_cosim.vvp +CYCLES=$CYC +SEED=$s" > "$O/seed$s.log" 2>&1
    line=$(grep -E "^cosim:" "$O/seed$s.log" || true)
    if grep -q "^PASS tb_cosim" "$O/seed$s.log"; then echo "PASS  cosim seed $s ($line)"
    else echo "FAIL  cosim seed $s"; grep FAIL "$O/seed$s.log" | head -3; rc=1; fi
done
exit $rc
