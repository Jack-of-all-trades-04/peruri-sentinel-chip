#!/usr/bin/env python3
"""Print sign-off metrics and summary tables of LibreLane runs (final/metrics.json)."""
import glob
import json
import os
import re
import sys


def parse_metrics(metrics_path):
    run_dir = os.path.dirname(os.path.dirname(os.path.abspath(metrics_path)))
    run_name = os.path.basename(run_dir)
    try:
        with open(metrics_path, "r") as f:
            m = json.load(f)
    except Exception:
        return None

    # Determine clock period from resolved.json or run directory name
    clk = None
    res_path = os.path.join(run_dir, "resolved.json")
    if os.path.isfile(res_path):
        try:
            with open(res_path, "r") as rf:
                clk = json.load(rf).get("CLOCK_PERIOD")
        except Exception:
            pass
    if clk is None:
        match = re.search(r"clk(\d+(?:\.\d+)?)ns", run_name)
        clk = float(match.group(1)) if match else "n/a"

    setup_ws = [v for k, v in m.items() if k.startswith("timing__setup__ws__corner:")]
    hold_ws = [v for k, v in m.items() if k.startswith("timing__hold__ws__corner:")]
    worst_setup = min(setup_ws) if setup_ws else m.get("timing__setup__ws", "n/a")
    worst_hold = min(hold_ws) if hold_ws else m.get("timing__hold__ws", "n/a")

    s_vio = m.get("timing__setup_vio__count", "n/a")
    h_vio = m.get("timing__hold_vio__count", "n/a")
    slew_vio = m.get("design__max_slew_violation__count", "n/a")
    cap_vio = m.get("design__max_cap_violation__count", "n/a")
    fanout_vio = m.get("design__max_fanout_violation__count", "n/a")
    die_area = m.get("design__die__area", "n/a")
    util = m.get("design__instance__utilization", "n/a")
    util_str = f"{util*100:.2f}%" if isinstance(util, (int, float)) else str(util)
    insts = m.get("design__instance__count", "n/a")
    stdcells = m.get("design__instance__count__stdcell", "n/a")
    ffs = m.get("design__instance__count__class:sequential_cell", "n/a")
    pwr = m.get("power__total", "n/a")
    pwr_str = f"{pwr*1000:.2f} mW" if isinstance(pwr, (int, float)) else str(pwr)
    drc_m = m.get("magic__drc_error__count", "n/a")
    drc_k = m.get("klayout__drc_error__count", "n/a")
    lvs = m.get("design__lvs_error__count", "n/a")

    return {
        "run": run_name,
        "metrics_file": metrics_path,
        "clock": clk,
        "setup_wns": worst_setup,
        "hold_wns": worst_hold,
        "s_vio": s_vio,
        "h_vio": h_vio,
        "slew_vio": slew_vio,
        "cap_vio": cap_vio,
        "fanout_vio": fanout_vio,
        "die_area": die_area,
        "util": util_str,
        "stdcells": stdcells,
        "instances": insts,
        "ffs": ffs,
        "power": pwr_str,
        "drc": f"{drc_m}/{drc_k}",
        "lvs": lvs,
        "raw": m,
    }


def print_single_run_details(data):
    m = data["raw"]

    def g(k, d="n/a"):
        return m.get(k, d)

    print("flow errors        :", g("flow__errors__count"))
    print("flow warnings      :", g("flow__warnings__count"))
    print("die area (um2)     :", g("design__die__area"))
    print("core area (um2)    :", g("design__core__area"))
    print("instance area (um2):", g("design__instance__area"))
    print("utilization (%)    :", g("design__instance__utilization"))
    print("instance count     :", g("design__instance__count"))
    print("  stdcell count    :", g("design__instance__count__stdcell"))
    print("  fill cell count  :", g("design__instance__count__class:fill_cell"))
    print("  flip-flops       :", g("design__instance__count__class:sequential_cell"))
    print("  timing repair buf:", g("design__instance__count__class:timing_repair_buffer"))
    print("  hold buffer count:", g("design__instance__count__hold_buffer"))
    print("DRC magic          :", g("magic__drc_error__count"))
    print("DRC klayout        :", g("klayout__drc_error__count"))
    print("LVS errors         :", g("design__lvs_error__count"))
    print("antenna violations :", g("antenna__violating__nets"), "nets /", g("antenna__violating__pins"), "pins")
    print("IR drop worst (V)  :", g("ir__voltage__worst"))
    print("power total (W)    :", g("power__total"))
    print("setup vio (all)    :", g("timing__setup_vio__count"))
    print("hold vio (all)     :", g("timing__hold_vio__count"))
    print("max slew vio (all) :", g("design__max_slew_violation__count"))
    print("max cap vio (all)  :", g("design__max_cap_violation__count"))
    print("max fanout vio(all):", g("design__max_fanout_violation__count"))
    print()
    print("%-24s %12s %12s %8s %8s %10s %10s %10s" % ("corner", "setup WNS ns", "hold WNS ns", "setup#", "hold#", "slew#", "cap#", "fanout#"))
    corners = sorted({re.match(r"timing__setup__ws__corner:(.+)", k).group(1)
                      for k in m if k.startswith("timing__setup__ws__corner:")})
    for c in corners:
        print("%-24s %12s %12s %8s %8s %10s %10s %10s" % (
            c, g("timing__setup__ws__corner:" + c), g("timing__hold__ws__corner:" + c),
            g("timing__setup_vio__count__corner:" + c), g("timing__hold_vio__count__corner:" + c),
            g("design__max_slew_violation__count__corner:" + c), g("design__max_cap_violation__count__corner:" + c),
            g("design__max_fanout_violation__count__corner:" + c)))


def print_table(rows):
    header = "| Run | Clock (ns) | Setup WNS (ns) | Hold WNS (ns) | Setup Vio | Hold Vio | Slew Vio | Cap Vio | Fanout Vio | Die Area (um2) | Core Util | Std Cells | Total Inst | FFs | Total Power | DRC (M/K) | LVS |"
    sep = "|:---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|"
    print(header)
    print(sep)
    for r in rows:
        s_wns_str = f"{r['setup_wns']:+.3f}" if isinstance(r['setup_wns'], (int, float)) else str(r['setup_wns'])
        h_wns_str = f"{r['hold_wns']:+.3f}" if isinstance(r['hold_wns'], (int, float)) else str(r['hold_wns'])
        print(f"| {r['run']} | {r['clock']} | {s_wns_str} | {h_wns_str} | {r['s_vio']} | {r['h_vio']} | {r['slew_vio']} | {r['cap_vio']} | {r['fanout_vio']} | {r['die_area']} | {r['util']} | {r['stdcells']} | {r['instances']} | {r['ffs']} | {r['power']} | {r['drc']} | {r['lvs']} |")


def main():
    args = sys.argv[1:]
    files = []
    if not args:
        files = sorted(glob.glob("runs/*/final/metrics.json"))
        if not files:
            print("No metrics.json files found under runs/*/final/metrics.json")
            sys.exit(1)
    else:
        for a in args:
            if os.path.isdir(a):
                target = os.path.join(a, "final", "metrics.json")
                if os.path.isfile(target):
                    files.append(target)
                else:
                    files.extend(sorted(glob.glob(os.path.join(a, "*/final/metrics.json"))))
            elif os.path.isfile(a):
                files.append(a)
            else:
                expanded = sorted(glob.glob(a))
                files.extend(expanded)

    if len(files) == 1:
        data = parse_metrics(files[0])
        if not data:
            print(f"Error parsing {files[0]}")
            sys.exit(1)
        print_single_run_details(data)
        print("\n=== Table Summary ===")
        print_table([data])
    else:
        rows = []
        for f in files:
            d = parse_metrics(f)
            if d:
                rows.append(d)
        print_table(rows)


if __name__ == "__main__":
    main()
