#!/usr/bin/env bash
# Run the formal checks (SymbiYosys) on the Sentinel security controller.
#
#   sec_ctrl.sby:
#     prove           unbounded proof of every assert (engine abc pdr)
#     reach_release   bounded search: a clean op CAN release ciphertext  (must find a trace)
#     reach_lockdown  bounded search: N alarms CAN reach lockdown + key 0 (must find a trace)
#
#   tamper_persist.sby:
#     tp_prove        unbounded proof: counter monotonic, lockdown sticky, P1-P8
#     tp_bmc_wrap     bounded search (depth 40): boot selects newest copy across 255->0 (P9)
#     tp_reach_wrap   bounded search (depth 40): P9 check state is reachable (must find a trace)
#     tp_reach_lock   bounded search (depth 60): lockdown is reachable (must find a trace)
#     tp_reach_clean  bounded search (depth 60): clean commit is reachable (must find a trace)
#
# The LibreLane image has no SMT solver, so sby cannot turn an abc
# counterexample into a VCD itself (option "aigsmt none"). This script
# replays the witness with "yosys sim" instead and names the failing assert.
#
# Usage: verif/formal/run_formal.sh      (prints PASS/FAIL per task)
set -u
cd "$(dirname "$0")/../.."
IMG=ghcr.io/librelane/librelane:3.0.14
OUT=$PWD/sim_build/verif/formal
mkdir -p "$OUT"

D() {
    if command -v sby >/dev/null 2>&1; then
        sh -c "$1"
    else
        docker run --rm -u "$(id -u):$(id -g)" -v "$PWD":"$PWD" -w "$PWD" "$IMG" sh -c "$1"
    fi
}

D "cd verif/formal && sby -f --prefix $OUT/sec_ctrl sec_ctrl.sby" > "$OUT/sby.log" 2>&1

rc=0
for t in prove reach_release reach_lockdown; do
    dir=$OUT/sec_ctrl_$t
    st=$(cat "$dir/status" 2>/dev/null | awk '{print $1}')
    yw=$(ls "$dir"/engine_0/trace.aiw 2>/dev/null | head -1)
    if [ "$t" = prove ]; then
        if [ "$st" = PASS ]; then
            echo "PASS  $t (all asserts proven, unbounded)"
        else
            echo "FAIL  $t ($st)"; rc=1
            [ -n "$yw" ] && D "yosys -q -p 'read_rtlil $dir/model/design_prep.il; sim -r $yw -map $dir/model/design_aiger.aim -clock clk -assert -vcd $dir/cex.vcd'" 2>&1 \
                | grep -m1 "Assertion" | sed 's/^/      /'
        fi
    else
        # expect fail: a trace must exist and must reach the target state
        if [ -n "$yw" ]; then
            D "yosys -q -p 'read_rtlil $dir/model/design_prep.il; sim -r $yw -map $dir/model/design_aiger.aim -clock clk -vcd $dir/trace.vcd'" >/dev/null 2>&1
            echo "PASS  $t (target state reached, trace: sim_build/verif/formal/sec_ctrl_$t/trace.vcd)"
        else
            echo "FAIL  $t (target state not reached: proof would be vacuous)"; rc=1
        fi
    fi
done

# ---------------- persistent tamper counter (P1-1) ----------------
D "cd verif/formal && sby -f --prefix $OUT/tp tamper_persist.sby" > "$OUT/tp.log" 2>&1
pst=$(cat "$OUT/tp_prove/status" 2>/dev/null | awk '{print $1}')
wst=$(cat "$OUT/tp_bmc_wrap/status" 2>/dev/null | awk '{print $1}')
rwst=$(cat "$OUT/tp_reach_wrap/status" 2>/dev/null | awk '{print $1}')
rst=$(cat "$OUT/tp_reach_lock/status" 2>/dev/null | awk '{print $1}')
cst=$(cat "$OUT/tp_reach_clean/status" 2>/dev/null | awk '{print $1}')
if [ "$pst" = PASS ]; then echo "PASS  tp_prove (counter monotonic, lockdown sticky, bounded; unbounded)"; else echo "FAIL  tp_prove ($pst)"; rc=1; fi
if [ "$wst" = PASS ]; then echo "PASS  tp_bmc_wrap (boot selects newest copy across seq wrap 255->0, depth 40)"; else echo "FAIL  tp_bmc_wrap ($wst)"; rc=1; fi
if [ "$rwst" = FAIL ]; then echo "PASS  tp_reach_wrap (trace reached: P9 check not vacuous)"; else echo "FAIL  tp_reach_wrap ($rwst)"; rc=1; fi
if [ "$rst" = FAIL ]; then echo "PASS  tp_reach_lock (lockdown reachable: proof not vacuous)"; else echo "FAIL  tp_reach_lock ($rst)"; rc=1; fi
if [ "$cst" = FAIL ]; then echo "PASS  tp_reach_clean (clean commit reachable: P7 not vacuous)"; else echo "FAIL  tp_reach_clean ($cst)"; rc=1; fi

exit $rc
