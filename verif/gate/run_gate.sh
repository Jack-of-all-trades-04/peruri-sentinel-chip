#!/usr/bin/env bash
# Gate-level verification of the Tier 1 core on the sky130 netlist.
#
#   1. Gate-level simulation: tb_de10_nano_top runs on the gate netlist
#      (sky130_fd_sc_hd functional cell models) instead of the RTL core.
#   2. Gate toggle coverage: share of netlist nets in the core that toggle
#      0->1 and 1->0 during that test.
#   3. Stuck-at fault campaign: every cell output net of the security blocks
#      (gate, tamper FSM, tripwire, key vault, DPA LFSR, core glue) is forced
#      to 0 and to 1, one fault per run. For each fault:
#        detected  the testbench reports FAIL (the test notices the defect)
#        leak      a wrong ciphertext was released with the Sentinel ON
#        no-lock   N attacks did not lead to zeroize + lockdown
#   4. The same faults under the unit testbenches (tb_output_release_gate,
#      tb_tamper_fsm) on the netlist modules; a fault is detected if any
#      test detects it.
#
# Usage: PDK_ROOT=<dir containing sky130A> verif/gate/run_gate.sh [jobs]
# Needs sim_build/verif/netlist/peruri_sentinel_core.sky130.v (synth_sky130.sh).
set -eu
cd "$(dirname "$0")/../.."
: "${PDK_ROOT:?set PDK_ROOT to the directory that contains sky130A}"
JOBS=${1:-24}
IMG=ghcr.io/librelane/librelane:3.0.14
CELLS=$PDK_ROOT/sky130A/libs.ref/sky130_fd_sc_hd/verilog
O=sim_build/verif/gate
mkdir -p "$O/runs"

D() {
    if command -v iverilog >/dev/null 2>&1; then
        sh -c "$1"
    else
        docker run --rm -u "$(id -u):$(id -g)" -v "$PWD":"$PWD" -v "$PDK_ROOT":"$PDK_ROOT" \
            -w "$PWD" "$IMG" sh -c "$1"
    fi
}

sed 's/^module peruri_sentinel_core(/module peruri_sentinel_core_gl(/' \
    sim_build/verif/netlist/peruri_sentinel_core.sky130.v > "$O/core_gl.v"
BOARD="rtl/de10_nano_top.v rtl/debounce.v rtl/sync_2ff.v rtl/pulse_stretch.v rtl/nvm_counter_model.v"
LIBV="$CELLS/primitives.v $CELLS/sky130_fd_sc_hd.v"

# unit shims: use the $paramod module names of this netlist
python3 verif/gate/fix_shims.py "$O/core_gl.v" verif/gate/unit_shims.v "$O/unit_shims.v" \
    output_release_gate tamper_persist_fsm master_key_vault || exit 1

# 1 + 2: fault-free gate-level run with a VCD of the core
cat > "$O/dump_core.v" <<'EOF'
module dump_core;
    initial begin
        $dumpfile("sim_build/verif/gate/core_gl.vcd");
        $dumpvars(0, tb_de10_nano_top.dut.u_core.u_gl);
    end
endmodule
EOF
D "iverilog -g2012 -Irtl -DFUNCTIONAL -DDEMO_BUILD -DNO_DUMP -o $O/tb_gl.vvp $LIBV $O/core_gl.v \
   verif/gate/core_gl_shim.v $BOARD sim/tb_de10_nano_top.v $O/dump_core.v && vvp -n $O/tb_gl.vvp" \
   > "$O/gl_sim.log" 2>&1
if grep -q "^PASS tb_de10_nano_top" "$O/gl_sim.log"; then
    echo "PASS  gate-level simulation (tb_de10_nano_top on the sky130 netlist)"
else
    echo "FAIL  gate-level simulation (see $O/gl_sim.log)"; exit 1
fi
python3 verif/gate/toggle_cov.py "$O/core_gl.vcd" > "$O/toggle.md"
grep -E "^\| \*\*Total" "$O/toggle.md" | sed 's/^/      toggle: /'

# 3: stuck-at fault campaign
python3 verif/gate/gen_faults.py "$O/core_gl.v" tb_de10_nano_top.dut.u_core.u_gl "$O/faults" > "$O/faults/gen.log"
NF=$(($(wc -l < "$O/faults/faults.csv") - 1))
D "iverilog -g2012 -Irtl -DFUNCTIONAL -DDEMO_BUILD -DNO_DUMP -o $O/tb_fault.vvp $LIBV $O/core_gl.v \
   verif/gate/core_gl_shim.v $BOARD sim/tb_de10_nano_top.v verif/gate/fault_mon.v $O/faults/fault_inj.v" \
   > "$O/faults/build.log" 2>&1
D "seq 0 $((NF - 1)) | xargs -P $JOBS -I{} sh -c 'vvp -n $O/tb_fault.vvp +FAULT={} 2>&1 | grep -E \"^(PASS|FAIL) tb_|^FSTAT\" > $O/runs/{}.log'"
# 4: the same faults under the unit testbenches (random ciphertexts for the
#    gate; counter, zeroize and lockdown sequences for FSM, tripwire, vault)
UNIT_ARGS=""
for unit in gate fsm; do
    U=$O/unit_$unit; mkdir -p "$U/runs"
    if [ $unit = gate ]; then
        TB=sim/tb_output_release_gate.v
        MAP="output_release_gate=tb_output_release_gate.dut.u_gl"
    else
        TB="sim/tb_tamper_persist.v rtl/nvm_counter_model.v"
        MAP="tamper_persist_fsm=tb_tamper_persist.u_fsm.u_gl tripwire_zeroize=tb_tamper_persist.u_trip master_key_vault=tb_tamper_persist.u_vault.u_gl"
    fi
    python3 verif/gate/gen_faults.py "$O/core_gl.v" --map $MAP "$U" > "$U/gen.log"
    NU=$(($(wc -l < "$U/faults.csv") - 1))
    D "iverilog -g2012 -Irtl -DFUNCTIONAL -DDEMO_BUILD -DNO_DUMP -o $U/tb.vvp $LIBV $O/core_gl.v $O/unit_shims.v \
       $TB $U/fault_inj.v" > "$U/build.log" 2>&1
    D "seq 0 $((NU - 1)) | xargs -P $JOBS -I{} sh -c 'vvp -n $U/tb.vvp +FAULT={} 2>&1 | grep -E \"^(PASS|FAIL) tb_\" > $U/runs/{}.log'"
    UNIT_ARGS="$UNIT_ARGS $U/faults.csv $U/runs"
done
python3 verif/gate/fault_report.py "$O/faults/faults.csv" "$O/runs" $UNIT_ARGS > "$O/fault_report.md"
sed -n '1,30p' "$O/fault_report.md"
