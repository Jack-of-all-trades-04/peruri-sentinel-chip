"""Copy unit_shims.v, replacing each wrapped netlist module name with the
$paramod name that the current netlist actually uses (the hash in the name
changes whenever parameters or sources change).

Usage: fix_shims.py <netlist.v> <unit_shims.v> <out.v> <module> [module ...]
"""
import re
import sys


def is_mod(token, mod):
    # escaped $paramod name whose path contains the module name, e.g.
    #   \$paramod$<hash>\tamper_persist_fsm
    #   \$paramod\output_release_gate\H=s32'...
    return token.startswith("\\$paramod") and ("\\" + mod) in token and (
        token.endswith("\\" + mod) or ("\\" + mod + "\\") in token)


net, src, out, mods = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
netnames = re.findall(r"^module (\S+)", open(net).read(), re.M)
shims = open(src).read()
for mod in mods:
    found = [t for t in netnames if is_mod(t, mod)]
    if len(found) != 1:
        print(f"FAIL  netlist module for {mod}: {found}")
        sys.exit(1)
    tokens = [t for t in re.findall(r"(\\\$paramod\S+)", shims) if is_mod(t, mod)]
    if not tokens:
        print(f"FAIL  shim for {mod} not found in {src}")
        sys.exit(1)
    for t in set(tokens):
        shims = shims.replace(t + " ", found[0] + " ")
open(out, "w").write(shims)
