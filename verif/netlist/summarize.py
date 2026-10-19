"""Per-module netlist summary from a hierarchical sky130 gate netlist.

Usage: python3 verif/netlist/summarize.py <liberty.lib> <netlist.v> [<netlist.v> ...]

For every netlist, prints a Markdown table with one row per instance under
the top module: standard cells, flip-flops and cell area, each counted
including submodules (so the 20 aes_sbox instances are inside aes128_core).
Numbers are pre-layout (estimasi).
"""
import re
import sys

FF_RE = re.compile(r"sky130_fd_sc_hd__(df|edf|sdf|dl|dfb)")


def liberty_areas(path):
    areas, cell = {}, None
    for line in open(path):
        m = re.match(r"\s*cell\s*\(\s*\"?([\w]+)\"?\s*\)", line)
        if m:
            cell = m.group(1)
            continue
        m = re.match(r"\s*area\s*:\s*([\d.]+)", line)
        if m and cell and cell not in areas:
            areas[cell] = float(m.group(1))
    return areas


def parse_netlist(path):
    """Return ({module: [(celltype, instname)]}, top) from a yosys netlist."""
    mods, cur, order, pending = {}, None, [], None
    text = open(path).read()
    for line in text.splitlines():
        s = line.strip()
        m = re.match(r"module\s+(\S+?)\s*\(", s)
        if m:
            cur = m.group(1).lstrip("\\")
            mods[cur] = []
            order.append(cur)
            continue
        if s.startswith("endmodule"):
            cur = None
            continue
        if cur is None:
            continue
        m = re.match(r"(\\?\S+)\s+#\($", s)          # parameterized instance: "type #("
        if m:
            pending = m.group(1).lstrip("\\")
            continue
        m = re.match(r"\)\s+(\\?\S+)\s*\($", s)      # ") name (" closes the parameter list
        if m and pending:
            mods[cur].append((pending, m.group(1).lstrip("\\")))
            pending = None
            continue
        m = re.match(r"(\\?\S+)\s+(\\?\S+)\s*\($", s)
        if m and m.group(1) not in ("input", "output", "wire", "reg", "assign", "inout"):
            mods[cur].append((m.group(1).lstrip("\\"), m.group(2).lstrip("\\")))
    # top = module never instantiated
    used = {t for v in mods.values() for t, _ in v}
    tops = [m for m in order if m not in used]
    return mods, tops[0]


def totals(mod, mods, areas, memo):
    if mod in memo:
        return memo[mod]
    cells = ff = 0
    area = 0.0
    bb = 0
    for typ, _ in mods.get(mod, []):
        if typ in mods:
            c, f, a, b = totals(typ, mods, areas, memo)
            cells, ff, area, bb = cells + c, ff + f, area + a, bb + b
        elif typ in areas:
            cells += 1
            area += areas[typ]
            if FF_RE.search(typ):
                ff += 1
        else:
            bb += 1          # black box (e.g. ro_cell)
    memo[mod] = (cells, ff, area, bb)
    return memo[mod]


def short(name):
    name = re.sub(r"^\$paramod\$[0-9a-f]+\\", "", name)
    name = re.sub(r"^\$paramod\\", "", name)
    return name.split("\\")[0]


def main():
    areas = liberty_areas(sys.argv[1])
    for path in sys.argv[2:]:
        mods, top = parse_netlist(path)
        memo = {}
        c, f, a, b = totals(top, mods, areas, memo)
        print(f"### {top}\n")
        print("| Instance | Module | Std cells | Flip-flops | Cell area (um^2) | Share of area |")
        print("|---|---|---:|---:|---:|---:|")
        rows = []
        glue = [0, 0, 0.0]
        for typ, inst in mods[top]:
            if typ in mods:
                ci, fi, ai, bi = totals(typ, mods, areas, memo)
                rows.append((inst, short(typ), ci, fi, ai, bi))
            elif typ in areas:
                glue[0] += 1
                glue[2] += areas[typ]
                if FF_RE.search(typ):
                    glue[1] += 1
        for inst, typ, ci, fi, ai, bi in sorted(rows, key=lambda r: -r[4]):
            extra = f" (+{bi} black box)" if bi else ""
            print(f"| {inst} | {typ}{extra} | {ci} | {fi} | {ai:.1f} | {100 * ai / a:.1f}% |")
        print(f"| (glue logic in {top}) | | {glue[0]} | {glue[1]} | {glue[2]:.1f} | {100 * glue[2] / a:.1f}% |")
        print(f"| **Total** | | **{c}** | **{f}** | **{a:.1f}** | 100% |\n")
        print(f"Total cell area: {a / 1e6:.4f} mm^2 (cells only, before placement; "
              f"die area after place and route is larger, typically at 40-60% utilization).")
        if b:
            print(f"Black boxes not counted: {b} (ring oscillator cells, hand-placed in an ASIC).")
        print()


if __name__ == "__main__":
    main()
