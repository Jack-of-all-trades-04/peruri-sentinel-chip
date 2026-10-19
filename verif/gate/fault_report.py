"""Summarize the stuck-at fault campaign.

Usage: python3 fault_report.py faults.csv runs_dir [unit_faults.csv unit_runs_dir ...]

The first pair is the board-level campaign (tb_de10_nano_top + security
monitor). Further pairs are unit-level campaigns (tb_output_release_gate,
tb_tamper_fsm) on the same netlist modules; a fault counts as detected if
any campaign detects it. Leak / no-lock come from the board campaign.

Per fault: detected (testbench FAIL or no PASS line), leak (wrong
ciphertext released with the Sentinel ON), no-lock (no zeroize or no
lockdown after N attacks). Prints a Markdown table per module and lists
the undetected faults that also break the protection (the dangerous ones).
"""
import collections
import csv
import os
import re
import sys


def unit_detected():
    """(module, net, stuck) -> detected by some unit testbench run."""
    det = {}
    pairs = sys.argv[3:]
    for k in range(0, len(pairs) - 1, 2):
        for f in csv.DictReader(open(pairs[k])):
            p = os.path.join(pairs[k + 1], f"{f['id']}.log")
            txt = open(p).read() if os.path.exists(p) else ""
            hit = re.search(r"^PASS tb_", txt, re.M) is None
            key = (f["module"], f["net"], f["stuck"])
            det[key] = det.get(key, False) or hit
    return det


def main():
    faults = list(csv.DictReader(open(sys.argv[1])))
    runs = sys.argv[2]
    udet = unit_detected()
    per = collections.defaultdict(lambda: collections.Counter())
    dangerous, silent = [], []
    for f in faults:
        p = os.path.join(runs, f"{f['id']}.log")
        txt = open(p).read() if os.path.exists(p) else ""
        passed = re.search(r"^PASS tb_", txt, re.M) is not None
        if udet.get((f["module"], f["net"], f["stuck"])):
            passed = False          # a unit testbench detects this fault
        m = re.search(r"FSTAT leak=(\d+) zeroized=(\d+) locked=(\d+)", txt)
        leak = int(m.group(1)) if m else 0
        nolock = (m is None) or m.group(2) != "1" or m.group(3) != "1"
        c = per[f["module"]]
        c["total"] += 1
        if not passed:
            c["detected"] += 1
        if leak:
            c["leak"] += 1
        if nolock:
            c["nolock"] += 1
        if passed and (leak or nolock):
            dangerous.append((f, leak, nolock))
        if passed and not (leak or nolock):
            silent.append(f)
    print("| Module | Faults | Detected by tests | Fault coverage | Leak (Sentinel ON) | No zeroize/lockdown | Undetected AND dangerous |")
    print("|---|---:|---:|---:|---:|---:|---:|")
    tot = collections.Counter()
    for mod, c in sorted(per.items()):
        d = sum(1 for x in dangerous if x[0]["module"] == mod)
        tot.update(c)
        tot["dang"] += d
        print(f"| {mod} | {c['total']} | {c['detected']} | {100.0 * c['detected'] / c['total']:.1f}% "
              f"| {c['leak']} | {c['nolock']} | {d} |")
    print(f"| **Total** | **{tot['total']}** | **{tot['detected']}** | "
          f"**{100.0 * tot['detected'] / tot['total']:.1f}%** | **{tot['leak']}** | **{tot['nolock']}** | **{tot['dang']}** |")
    print()
    print(f"Undetected faults with no security effect (redundant or unobservable logic): {len(silent)}")
    print()
    print("Undetected AND dangerous faults (first 30):\n")
    for f, leak, nolock in dangerous[:30]:
        print(f"- {f['module']} {f['net']} stuck-at-{f['stuck']}: leak={leak} no-lock={int(nolock)}")
    print()
    print("Undetected, no security effect (first 30):\n")
    for f in silent[:30]:
        print(f"- {f['module']} {f['net']} stuck-at-{f['stuck']}")


if __name__ == "__main__":
    main()
