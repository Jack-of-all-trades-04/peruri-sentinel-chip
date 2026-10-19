"""Gate-level toggle coverage from a VCD of the netlist.

Usage: python3 toggle_cov.py core_gl.vcd [root_scope]

root_scope (default u_gl) is the scope of the netlist top in the VCD; nets
are grouped by the instance directly below it.

A net bit is fully toggled if it went 0->1 and 1->0 at least once. Results
are grouped by the first scope level under the dumped module (u_aes,
u_gate, ...; nets of the core glue are reported as "(core glue)"). Nets
whose name starts with a cell-internal prefix are skipped: only nets of
the netlist modules count, not the internals of the cell models.
"""
import collections
import sys


def main():
    path = sys.argv[1]
    root = sys.argv[2] if len(sys.argv) > 2 else "u_gl"
    scopes, ids = [], {}           # id -> list of (group, name)
    in_defs = True
    last = {}
    rise, fall = collections.Counter(), collections.Counter()
    depth_base = None
    for line in open(path):
        t = line.split()
        if not t:
            continue
        if in_defs:
            if t[0] == "$scope":
                scopes.append(t[2])
                if depth_base is None and t[2] == root:
                    depth_base = len(scopes)
            elif t[0] == "$upscope":
                scopes.pop()
            elif t[0] == "$var":
                width, code, name = int(t[2]), t[3], t[4]
                if depth_base is None or len(scopes) < depth_base:
                    continue
                rel = scopes[depth_base:]
                # only nets declared in netlist modules: the scope path may go
                # through submodule instances (u_gate, ...), never into a cell
                if any(s.startswith("_") for s in rel):
                    continue
                group = rel[0] if rel else "(core glue)"
                for b in range(width):
                    ids.setdefault(code, []).append((group, f"{'.'.join(rel)}.{name}[{b}]", b, width))
            elif t[0] == "$enddefinitions":
                in_defs = False
            continue
        c = line[0]
        if c in "01xz" and len(line.strip()) > 1:
            val, code = line[0], line.strip()[1:]
            bits = val
        elif c == "b":
            val, code = t[0][1:], t[1]
            bits = val
        else:
            continue
        if code not in ids:
            continue
        w = ids[code][0][3]
        bits = bits.rjust(w, bits[0] if bits[0] in "xz" else "0")
        for (group, name, b, _w) in ids[code]:
            v = bits[w - 1 - b]
            p = last.get((code, b))
            if p == "0" and v == "1":
                rise[(group, name)] += 1
            elif p == "1" and v == "0":
                fall[(group, name)] += 1
            last[(code, b)] = v
    groups = collections.defaultdict(lambda: [0, 0])
    seen = set()
    for code, lst in ids.items():
        for (group, name, _b, _w) in lst:
            if (group, name) in seen:
                continue
            seen.add((group, name))
            groups[group][1] += 1
            if rise[(group, name)] and fall[(group, name)]:
                groups[group][0] += 1
    print("| Block (netlist) | Net bits toggled 0->1 and 1->0 | Coverage |")
    print("|---|---:|---:|")
    th = tt = 0
    for g in sorted(groups):
        h, n = groups[g]
        th += h
        tt += n
        print(f"| {g} | {h}/{n} | {100.0 * h / n:.1f}% |")
    print(f"| **Total** | **{th}/{tt}** | **{100.0 * th / tt:.1f}%** |")


if __name__ == "__main__":
    main()
