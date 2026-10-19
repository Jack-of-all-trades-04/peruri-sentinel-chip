#!/usr/bin/env bash
# Harden the Tier 1 production core (peruri_sentinel_core) with LibreLane on
# sky130A. Re-runnable; reads the RTL in place from ../rtl.
#
# Usage:
#   PDK_ROOT=<dir containing sky130A> [CLOCK_PERIOD=18] [RUN_TAG=<name>] \
#   [LIBRELANE=<python with librelane installed>] bash asic/run_flow.sh [extra librelane args]
#
# Needs: Docker (image ghcr.io/librelane/librelane:3.0.14 is pulled by
# LibreLane) and a Python environment with the librelane package.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
: "${PDK_ROOT:?set PDK_ROOT to the directory that contains sky130A}"
CLOCK_PERIOD="${CLOCK_PERIOD:-18}"
RUN_TAG="${RUN_TAG:-clk${CLOCK_PERIOD}ns}"
if [ -z "${LIBRELANE:-}" ]; then
    if python3 -m librelane --version >/dev/null 2>&1; then
        PY="python3"
    elif [ -x "$repo/../.venv/bin/python3" ]; then
        PY="$repo/../.venv/bin/python3"
    else
        PY="python3"
    fi
else
    PY="$LIBRELANE"
fi

cd "$here"
rm -rf "runs/$RUN_TAG"
"$PY" -m librelane --docker-mount "$repo" --docker-no-tty --dockerized --pdk-root "$PDK_ROOT" \
    --run-tag "$RUN_TAG" -c "CLOCK_PERIOD=$CLOCK_PERIOD" "$@" config.yaml

if [ -f "runs/$RUN_TAG/final/metrics.json" ]; then
    echo
    echo "=== key metrics: runs/$RUN_TAG/final/metrics.json ==="
    python3 "$here/summarize_metrics.py" "runs/$RUN_TAG/final/metrics.json"
fi
