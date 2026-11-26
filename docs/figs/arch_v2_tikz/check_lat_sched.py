#!/usr/bin/env python3
"""check_lat_sched.py - validate lat_sched.py (the issue-rule model of the latency figure)
against the RTL.

Replays kernels/figs/issue_rules.S on four warps with lat_sched.simulate and compares, cycle
by cycle, the issues and the held-back X cycles with the RTL issue trace
traces/rules4_issue.txt (fig_trace.py rules4: the board top under xsim, board configuration).
Warp k is spawned in cycle k (traces/rules4_fig.txt) and can be fetched from cycle k + 1.
Exits 1 on any difference.  Usage: python check_lat_sched.py
"""
import os
import sys

from lat_sched import ALL, FPU, simulate

HERE = os.path.dirname(os.path.abspath(__file__))
L = 8
PROG = [("fmadd", FPU, []), ("add", 0, []), ("fmadd", FPU, [0]), ("add", 0, []),
        ("fmul", FPU, [2]), ("fadd", FPU, []), ("fadd", FPU, [4, 5]), ("ecall", 0, ALL)]


def main():
    spawn = {}
    for line in open(os.path.join(HERE, "traces", "rules4_fig.txt")):
        p = line.split()
        if p and p[0] == 'S':
            spawn[int(p[2])] = int(p[1])
    rtl_i, rtl_h = set(), set()
    for line in open(os.path.join(HERE, "traces", "rules4_issue.txt")):
        p = line.split()
        if p and p[0] == 'I':
            rtl_i.add((int(p[1]), int(p[2]) // L))
        elif p and p[0] == 'X':
            rtl_h.add((int(p[1]), int(p[2]) // L))
    nw = len(spawn)
    iss, st, _ = simulate({w: PROG for w in range(nw)}, 200, {w: spawn[w] + 1 for w in range(nw)})
    mod_i = {(t, w) for t, (w, _) in iss.items()}
    mod_h = {(t, w) for w in st for t, s in st[w].items() if s == 'H'}
    ok = mod_i == rtl_i and mod_h == rtl_h
    print(f"{nw} warps, {len(rtl_i)} issues and {len(rtl_h)} held-back X cycles in the RTL trace")
    for name, a, b in (("issues", mod_i, rtl_i), ("held back", mod_h, rtl_h)):
        if a != b:
            print(f"  {name}: model only {sorted(a - b)}, RTL only {sorted(b - a)}")
    print("PASS: the model reproduces the RTL cycle by cycle" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
