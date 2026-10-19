"""Summarize a Verilator coverage.dat per RTL file and coverage type.

Usage: python3 verif/coverage/summarize.py sim_build/verif/coverage/merged.dat

A coverage point counts as hit when its count is > 0. Points are grouped by
source file (only files under rtl/) and by Verilator type:
  line   - statement / block executed
  branch - each side of if/case taken
  toggle - each signal bit toggled 0->1 and 1->0
Testbench and simulation-model files are left out.

Coverage is per module, merged over all instances and all testbenches: a
point counts as hit if any instance of that module hit it in any test.
"""
import collections
import re
import sys


def parse(path):
    points = {}                                          # point id -> hit
    for raw in open(path, encoding="latin-1"):
        if not raw.startswith("C '"):
            continue
        m = re.match(r"C '(.*)' (\d+)\s*$", raw.rstrip("\n"))
        if not m:
            continue
        body, count = m.group(1), int(m.group(2))
        fields = {}
        for kv in body.split("\x01"):
            if "\x02" in kv:
                k, v = kv.split("\x02", 1)
                fields[k] = v
        f = fields.get("f", "")
        if "/rtl/" not in "/" + f and not f.startswith("rtl/"):
            continue
        f = f[f.find("rtl/"):]
        page = fields.get("page", "")
        typ = page.split("/")[0].replace("v_", "")
        if typ not in ("line", "branch", "toggle", "expr"):
            continue
        pid = (f, typ, fields.get("l", "?"), fields.get("n", ""), fields.get("o", ""))
        points[pid] = points.get(pid, False) or count > 0
    stats = collections.defaultdict(lambda: [0, 0])     # (file, type) -> [hit, total]
    missed = collections.defaultdict(list)               # (file, type) -> [(line, comment)]
    for (f, typ, line, _col, comment), hit in points.items():
        stats[(f, typ)][1] += 1
        if hit:
            stats[(f, typ)][0] += 1
        else:
            missed[(f, typ)].append((line, comment))
    return stats, missed


def pct(h, t):
    return f"{100.0 * h / t:5.1f}%" if t else "  n/a"


def main():
    stats, missed = parse(sys.argv[1])
    files = sorted({f for f, _ in stats})
    types = ["line", "branch", "expr", "toggle"]
    print("| RTL file | Line | Branch | Expression | Toggle |")
    print("|---|---:|---:|---:|---:|")
    tot = collections.defaultdict(lambda: [0, 0])
    for f in files:
        cells = []
        for t in types:
            h, n = stats.get((f, t), [0, 0])
            tot[t][0] += h
            tot[t][1] += n
            cells.append(f"{pct(h, n)} ({h}/{n})" if n else "n/a")
        print(f"| {f} | " + " | ".join(cells) + " |")
    print("| **Total** | " + " | ".join(
        f"**{pct(*tot[t])}** ({tot[t][0]}/{tot[t][1]})" if tot[t][1] else "n/a" for t in types) + " |")
    print()
    print("Uncovered line/branch points outside aes_sbox (first 40):\n")
    n = 0
    for (f, t), lst in sorted(missed.items()):
        if t not in ("line", "branch") or f.endswith("aes_sbox.v"):
            continue
        for line, comment in lst:
            print(f"- {f}:{line} ({t}) {comment}")
            n += 1
            if n >= 40:
                return


if __name__ == "__main__":
    main()
