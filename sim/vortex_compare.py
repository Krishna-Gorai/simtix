"""
vortex_compare.py -- SIMTiX and Vortex cycles and instructions on the application suite.

    python sim/vortex_compare.py [--simtix docs/apps_agg.csv] [--variant ser]
                                 [--out docs/vortex_apps.csv] NAME=build_vortex/RUN.csv ...

SIMTiX numbers are the per-launch rows of app_sweep.py's CSV for one AMO variant
(default ser, the board configuration); Vortex numbers are the APPCSV lines that
baselines/vortex/run_apps.sh collects, one file per Vortex setting. Both run the same
gen_apps.py cases, so the launches line up by (case, launch). Instructions are warp
instructions on both (SIMTiX: issued, reconvergence pops excluded; Vortex: retired,
its split/join/predicate instructions included).

Prints, per case, the cycles and instructions of each machine and their ratios
(Vortex / SIMTiX), then IPC. Writes one row per (case, launch) and a 'total' row per
case: case, launch, simtix_cycles, simtix_insns, then <run>_cycles, <run>_insns.
"""
import argparse
import csv
import os
import sys
from collections import OrderedDict

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))


def read_simtix(path, variant):
    rows = OrderedDict()
    with open(path, newline='') as f:
        for r in csv.DictReader(f):
            if r['variant'] == variant:
                rows[(r['case'], r['launch'])] = (int(r['cycles']), int(r.get('insns') or 0))
    return rows


def read_vortex(path):
    rows = OrderedDict()
    with open(path, newline='') as f:
        for line in f:
            p = line.strip().split(',')
            if len(p) >= 6 and p[0] == 'APPCSV' and p[1] == 'vortex' and p[3] != 'total':
                rows[(p[2], p[3])] = (int(p[5]), int(p[6]) if len(p) > 6 else 0)
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--simtix', default=os.path.join(ROOT, 'docs', 'apps_agg.csv'))
    ap.add_argument('--variant', default='ser')
    ap.add_argument('--out', default=os.path.join(ROOT, 'docs', 'vortex_apps.csv'))
    ap.add_argument('runs', nargs='+', help='NAME=path to an APPCSV file')
    args = ap.parse_args()

    machines = OrderedDict([('simtix', read_simtix(args.simtix, args.variant))])
    for spec in args.runs:
        name, path = spec.split('=', 1)
        machines[name] = read_vortex(path)
    simtix = machines['simtix']
    for name, rows in list(machines.items())[1:]:
        missing = [k for k in simtix if k not in rows]
        extra = [k for k in rows if k not in simtix]
        if missing or extra:
            sys.exit(f'{name}: launches differ from SIMTiX (missing {missing[:3]}, extra {extra[:3]})')

    cases = OrderedDict()
    for (case, launch) in simtix:
        cases.setdefault(case, []).append(launch)

    def total(rows, case):
        c = sum(rows[(case, l)][0] for l in cases[case])
        i = sum(rows[(case, l)][1] for l in cases[case])
        return c, i

    with open(args.out, 'w', newline='') as f:
        w = csv.writer(f, lineterminator='\n')
        w.writerow(['case', 'launch'] + [f'{m}_{q}' for m in machines for q in ('cycles', 'insns')])
        for case, launches in cases.items():
            for launch in launches:
                w.writerow([case, launch] + [v for rows in machines.values()
                                             for v in rows[(case, launch)]])
            w.writerow([case, 'total'] + [v for rows in machines.values()
                                          for v in total(rows, case)])

    vx = list(machines)[1:]
    print(f"{'case':20s} {'SIMTiX cyc':>10s} {'insns':>8s}" +
          ''.join(f' | {n[:12]:>12s} {"x cyc":>6s} {"x ins":>6s}' for n in vx))
    for case in cases:
        sc, si = total(simtix, case)
        line = f'{case:20s} {sc:10d} {si:8d}'
        for n in vx:
            c, i = total(machines[n], case)
            line += f' | {c:12d} {c / sc:6.2f} {(i / si if si else 0):6.2f}'
        print(line)
    print(f"\n{'IPC (warp instr / cycle)':24s}" + ''.join(f' {m[:12]:>12s}' for m in machines))
    for case in cases:
        print(f'{case:24s}' + ''.join(
            f' {(lambda c, i: i / c if c else 0)(*total(machines[m], case)):12.3f}'
            for m in machines))
    print('x = Vortex / SIMTiX; wrote', args.out)


if __name__ == '__main__':
    main()
