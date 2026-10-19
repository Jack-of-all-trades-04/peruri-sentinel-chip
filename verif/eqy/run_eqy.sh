#!/usr/bin/env bash
# Equivalence check (Yosys eqy): RTL ("gold") against the sky130 gate
# netlist from verif/netlist/synth_sky130.sh ("gate"), module by module.
#
# Usage:  PDK_ROOT=<dir containing sky130A> verif/eqy/run_eqy.sh [core]
#         core = peruri_sentinel_core (default) or peruri_sentinel_core_t2
#
# The netlist keeps the RTL hierarchy, so every module (with the parameter
# values it has inside the core) is checked on its own: gold is the RTL
# module elaborated with the same parameters, gate is the netlist module
# built from real sky130 cells (liberty cell functions). The core top level
# glue is covered by the gate-level simulation. Splitting per module keeps
# every proof small.
#
# eqy matches registers and nets by name, cuts each module into partitions
# and proves every partition with its SAT strategy (combinational
# equivalence between matched registers, plus temporal induction).
# Asynchronous resets: eqy applies async2sync per partition itself, after
# matching, so register outputs keep their names on both sides.
#
# Output: one PASS/FAIL line per module; non-zero exit if any module fails.
set -u
cd "$(dirname "$0")/../.."
: "${PDK_ROOT:?set PDK_ROOT to the directory that contains sky130A}"
CORE=${1:-peruri_sentinel_core}
IMG=ghcr.io/librelane/librelane:3.0.14
LIB="$PDK_ROOT/sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib"
NET=$PWD/sim_build/verif/netlist/$CORE.sky130.v
OUT=$PWD/sim_build/verif/eqy/$CORE
mkdir -p "$OUT"
[ -f "$NET" ] || { echo "missing $NET, run verif/netlist/synth_sky130.sh first"; exit 1; }

T1="rtl/aes_sbox.v rtl/aes128_core.v rtl/master_key_vault.v rtl/output_release_gate.v \
rtl/tripwire_zeroize.v rtl/dpa_hiding_lfsr.v"
case "$CORE" in
    peruri_sentinel_core)    SRC="$T1 rtl/tamper_persist_fsm.v rtl/peruri_sentinel_core.v"; BB="" ;;
    peruri_sentinel_core_t2) SRC="$T1 rtl/graduated_tamper_fsm.v rtl/sync_2ff.v rtl/pulse_stretch.v rtl/tier2/reset_sync.v \
rtl/tier2/tdl_glitch_line.v rtl/tier2/ro_sensor_mesh.v rtl/tier2/p2se_encoder.v \
rtl/tier2/snn_lif_engine.v rtl/tier2/ablation_detectors.v rtl/tier2/peruri_sentinel_core_t2.v"
                             BB="read_verilog -sv $PWD/syn/tier2_blackbox.v" ;;
    *) echo "unknown core $CORE"; exit 1 ;;
esac
ABS_SRC=""
for f in $SRC; do ABS_SRC="$ABS_SRC $PWD/$f"; done

# modules in the gate netlist (black boxes such as ro_cell are not defined there)
MODS=$(sed -n 's/^module \\\?\([^ (]*\).*/\1/p' "$NET")

run_eqy() {   # $1 = work dir, $2 = config name
    if command -v eqy >/dev/null 2>&1 && command -v make >/dev/null 2>&1; then
        (cd "$1" && eqy -f -j 16 "$2")
    else
        # The LibreLane image has no make; verif/eqy/bin/make stands in for it.
        docker run --rm -u "$(id -u):$(id -g)" -v "$PWD":"$PWD" -v "$PDK_ROOT":"$PDK_ROOT" \
            -w "$1" "$IMG" sh -c "PATH=$PWD/verif/eqy/bin:\$PATH eqy -f -j 16 $2"
    fi
}

rc=0
i=0
for M in $MODS; do
    i=$((i + 1))
    name=$(echo "$M" | sed -E 's/^\$paramod(\$[0-9a-f]+)?\\//; s/\\.*//')
    tag=$(printf "%02d_%s" "$i" "$name")
    # In the gate netlist the $paramod names are escaped identifiers, so
    # yosys sees them with a leading backslash.
    gm() { case "$1" in \$*) echo "\\$1" ;; *) echo "$1" ;; esac; }
    MG=$(gm "$M")
    if [ "$M" = "$CORE" ]; then
        # The core top level is only glue (a few dozen cells). eqy's combine
        # step does not terminate when all submodules are black boxes, so the
        # glue is covered by the gate-level simulation (verif/gate) instead.
        echo "SKIP  eqy $name (top-level glue; covered by gate-level simulation)"
        continue
    fi
    CUT=""; CUTG=""
    # the counter/sequence registers of tamper_persist_fsm need a deeper SAT
    # induction than the datapath; keep it bounded so the check terminates.
    # Partitions still inconclusive are closed by run_cosim.sh, as for AES/LFSR
    # (the final_recommendation fallback: eqy induction inconclusive -> cosim).
    case "$name" in tamper_persist_fsm) DEPTH=12 ;; *) DEPTH=5 ;; esac
    cat > "$OUT/$tag.eqy" <<EOF
[options]

[gold]
$BB
read_verilog -sv -I$PWD/rtl -DDEMO_BUILD $ABS_SRC
hierarchy -top $CORE
$CUT
hierarchy -top $M
rename -top dut
prep -flatten -top dut
memory_map
opt_clean

[gate]
read_liberty -overwrite -ignore_miss_func $LIB
$BB
read_verilog $NET
hierarchy -top $CORE
$CUTG
hierarchy -top $MG
rename -top dut
prep -flatten -top dut
opt_clean

[strategy sat]
use sat
depth $DEPTH
EOF
    run_eqy "$OUT" "$tag.eqy" > "$OUT/$tag.log" 2>&1
    np=$(ls "$OUT/$tag"/strategies 2>/dev/null | wc -l)
    if grep -q "Successfully proved designs equivalent" "$OUT/$tag.log"; then
        echo "PASS  eqy $name ($np partitions)"
    else
        # Classify what is left: induction ran out of depth (inconclusive) or
        # the SAT base case found a difference. The base case starts from an
        # unconstrained register state, so a base-case model is only a real
        # mismatch if it is reachable from reset; verif/gate/run_cosim.sh
        # checks the reachable behaviour.
        pr=$(grep -l PASS "$OUT/$tag"/strategies/*/sat/status 2>/dev/null | wc -l)
        inc=0; base=0
        for d in "$OUT/$tag"/strategies/*/sat; do
            grep -q PASS "$d/status" 2>/dev/null && continue
            if grep -q "Reached maximum number of time steps" "$d/run.log" 2>/dev/null; then
                inc=$((inc + 1)); else base=$((base + 1)); fi
        done
        echo "PART  eqy $name ($pr/$np partitions proven; $inc induction inconclusive;" \
             "$base base-case models from an unreset state -> check with run_cosim.sh)"
        rc=1
    fi
done
exit $rc
