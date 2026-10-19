#!/usr/bin/env bash
# Code coverage with Verilator: runs the existing self-checking testbenches
# (Tier 1 and Tier 2) with --coverage and reports line, branch and toggle
# coverage per RTL file. Testbench and simulation-model files are excluded
# from the numbers.
#
# Usage: verif/coverage/run_coverage.sh
# Output: sim_build/verif/coverage/{<tb>/, merged.dat, coverage.md, annotated/}
set -u
cd "$(dirname "$0")/../.."
IMG=ghcr.io/librelane/librelane:3.0.14
OUT=sim_build/verif/coverage
rm -rf "$OUT"; mkdir -p "$OUT"

D() {
    if command -v verilator >/dev/null 2>&1; then
        sh -c "$1"
    else
        docker run --rm -u "$(id -u):$(id -g)" -v "$PWD":"$PWD" -w "$PWD" "$IMG" sh -c "$1"
    fi
}

# Verilator generates C++ (in the LibreLane image if needed); the C++ is
# compiled on the host with make + g++, because the image has no make. The
# Verilator runtime (include/, bin/) is copied out of the image once.
if command -v verilator >/dev/null 2>&1; then
    VROOT=$(verilator --getenv VERILATOR_ROOT)
else
    VROOT=$PWD/sim_build/verif/tools/verilator_root
    if [ ! -d "$VROOT/include" ]; then
        mkdir -p "$(dirname "$VROOT")"
        D 'cp -rL "$(dirname "$(dirname "$(readlink -f "$(which verilator)")")")/share/verilator" '"$VROOT"
    fi
fi

VFLAGS="--cc --exe --main --timing --coverage --timescale 1ns/1ps -DNO_DUMP \
-Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD -Wno-MULTIDRIVEN -Irtl"

T1_RTL="rtl/*.v"
T2_RTL="rtl/*.v rtl/tier2/*.v sim/tier2/models/*.v"

fail=0
build_run() {   # $1 tb file, $2 sources (demo build unless the tb says "// BUILD: prod")
    tb=$1; name=$(basename "$tb" .v); src=$2; def="-DDEMO_BUILD"
    b=$(sed -n 's,^// BUILD: *\([a-z]*\).*,\1,p' "$tb" | head -1)
    if [ "$b" = prod ]; then def=""; src=$(ls $src | grep -v de10_nano_top | tr '\n' ' '); fi
    D "verilator $VFLAGS $def --top-module $name --Mdir $OUT/$name -o $name $tb $src" > "$OUT/$name.build.log" 2>&1
    make -s -j 8 -C "$OUT/$name" -f "V$name.mk" VERILATOR_ROOT="$VROOT" >> "$OUT/$name.build.log" 2>&1
    if [ ! -x "$OUT/$name/$name" ]; then
        echo "BUILD FAIL  $name (see $OUT/$name.build.log)"; fail=1; return
    fi
    "$OUT/$name/$name" +verilator+coverage+file+"$OUT/$name.dat" > "$OUT/$name.run.log" 2>&1
    if grep -q "^PASS $name" "$OUT/$name.run.log"; then
        echo "PASS  $name (coverage: $OUT/$name.dat)"
    else
        echo "FAIL  $name"; grep -E "FAIL|Error|error" "$OUT/$name.run.log" | head -3 | sed 's/^/      /'; fail=1
    fi
}

for tb in sim/tb_*.v;       do build_run "$tb" "$T1_RTL"; done
for tb in sim/tier2/tb_*.v; do build_run "$tb" "$T2_RTL"; done

D "verilator_coverage --write $OUT/merged.dat $OUT/*.dat && \
   verilator_coverage --annotate $OUT/annotated --annotate-min 1 $OUT/merged.dat" > "$OUT/merge.log" 2>&1
python3 verif/coverage/summarize.py "$OUT/merged.dat" > "$OUT/coverage.md"
cat "$OUT/coverage.md"
exit $fail
