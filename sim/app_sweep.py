"""
app_sweep.py -- the application suite under the three AMO variants.

    python sim/app_sweep.py [--size small|large]     (writes docs/apps_agg.csv)

Generates the cases (sim/gen_apps.py), runs tests/tb_apps.sv in xsim with
    base   AGG = 0             one read-modify-write per lane
    ser    AGG = 1, APAR = 0   one per line, one lane per cycle (default)
    par    AGG = 1, APAR = 1   one per line, lanes on distinct words in parallel
and collects the APPCSV rows:
    variant,case,launch,threads,cycles,l1_hits,l1_misses
"""
import argparse
import concurrent.futures as cf
import csv
import os
import subprocess
import sys

import run_xsim

VARIANTS = {'base': ['AGG=0'], 'ser': ['AGG=1', 'APAR=0'], 'par': ['AGG=1', 'APAR=1']}
SRC = run_xsim.PS + ['tests/tb_apps.sv']
OUT = os.path.join(run_xsim.ROOT, 'docs', 'apps_agg.csv')


def one(var):
    name = f'apps_{var}'
    run_xsim.TESTS[name] = ('tb_apps', SRC, [], False, VARIANTS[var])
    ok, msg = run_xsim.run_test(name)
    log = os.path.join(run_xsim.BUILD, name, 'xsim.log')
    rows = {}   # xsim's log can repeat its last lines: keep one row per launch
    if os.path.isfile(log):
        for line in open(log, encoding='utf-8', errors='replace'):
            if line.startswith('APPCSV,'):
                f = line.strip().split(',')[1:]
                rows[tuple(f[:2])] = [var] + f
    return name, ok, msg, list(rows.values())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--size', default='small')
    args = ap.parse_args()
    subprocess.run([sys.executable, os.path.join(run_xsim.ROOT, 'sim', 'gen_apps.py'),
                    '--size', args.size], check=True)
    rows, fails = [], 0
    with cf.ThreadPoolExecutor(max_workers=3) as ex:
        for name, ok, msg, r in ex.map(one, VARIANTS):
            print(f"{'PASS' if ok else 'FAIL'}  {name:10s} {msg}", flush=True)
            fails += not ok
            rows += r
    with open(OUT, 'w', newline='') as fh:
        w = csv.writer(fh, lineterminator='\n')
        w.writerow(['variant', 'case', 'launch', 'threads', 'cycles', 'l1_hits', 'l1_misses'])
        w.writerows(rows)
    print(f'wrote {OUT} ({len(rows)} rows)\n')
    tot = {}
    for v, case, _, _, cyc, _, _ in rows:
        tot[(v, case)] = tot.get((v, case), 0) + int(cyc)
    print(f"{'case':22s} {'base':>8s} {'ser':>8s} {'par':>8s} {'x ser':>6s} {'x par':>6s}")
    for case in sorted({c for _, c in tot}):
        b, s, p = (tot.get((v, case), 0) for v in VARIANTS)
        print(f'{case:22s} {b:8d} {s:8d} {p:8d} {b / max(s, 1):6.2f} {b / max(p, 1):6.2f}')
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
