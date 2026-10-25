"""
lane_sweep.py -- the application suite on 4-, 8- and 16-lane accelerators.

    python sim/lane_sweep.py [--lanes 4 8 16] [--size small]   (writes docs/lanes_apps.csv)

For each lane count L (4 warps, the board configuration AGG = 1, APAR = 0):
assembles the kernels for L lanes (kernels/apps/build.py --lanes L; the 8-lane
images are kernels/apps/*.hex), writes the cases (sim/gen_apps.py --lanes L) into
build_apps_l<L>/, and runs tests/tb_apps.sv in xsim with SIMTIX_NUM_LANES = L.
The L1 stays 16 KB and 4-way; its line is L words. Collects the APPCSV rows:
    lanes,case,launch,threads,cycles,l1_hits,l1_misses,insns
RISC-V GCC: riscv-none-elf-gcc on PATH, or RISCV_GCC.
"""
import argparse
import csv
import os
import subprocess
import sys

import run_xsim

ROOT = run_xsim.ROOT
OUT = os.path.join(ROOT, 'docs', 'lanes_apps.csv')


def one(lanes, size):
    data = os.path.join(ROOT, f'build_apps_l{lanes}')
    kdir = os.path.join(ROOT, 'kernels', 'apps')
    if lanes != 8:
        kdir = os.path.join(data, 'kernels')
        subprocess.run([sys.executable, os.path.join(ROOT, 'kernels', 'apps', 'build.py'),
                        '--lanes', str(lanes), '--out', kdir], check=True)
    subprocess.run([sys.executable, os.path.join(ROOT, 'sim', 'gen_apps.py'), '--size', size,
                    '--lanes', str(lanes), '--kdir', kdir, '--out', data], check=True)
    name = f'apps_l{lanes}'
    run_xsim.TESTS[name] = ('tb_apps', run_xsim.PS + ['tests/tb_apps.sv'], [], False,
                            ['AGG=1', 'APAR=0'])
    ok, msg = run_xsim.run_test(name, defines=[f'SIMTIX_NUM_LANES={lanes}'],
                                plusargs=[f'MANIFEST={data}/apps.manifest'.replace('\\', '/')])
    rows = {}   # xsim's log can repeat its last lines: keep one row per launch
    log = os.path.join(run_xsim.BUILD, name, 'xsim.log')
    if os.path.isfile(log):
        for line in open(log, encoding='utf-8', errors='replace'):
            if line.startswith('APPCSV,'):
                f = line.strip().split(',')[1:]
                rows[tuple(f[:2])] = [lanes] + f
    return ok, msg, list(rows.values())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--lanes', type=int, nargs='+', default=[4, 8, 16])
    ap.add_argument('--size', default='small')
    args = ap.parse_args()
    rows, fails = [], 0
    for lanes in args.lanes:       # one at a time: a 16-lane xsim run is large
        ok, msg, r = one(lanes, args.size)
        print(f"{'PASS' if ok else 'FAIL'}  {lanes:2d} lanes  {msg}", flush=True)
        fails += not ok
        rows += r
    old = []
    if os.path.isfile(OUT):        # keep the lane counts this run did not repeat
        with open(OUT, newline='') as fh:
            old = [r for r in csv.reader(fh)][1:]
        old = [r for r in old if int(r[0]) not in args.lanes]
    rows = sorted(old + [[str(x) for x in r] for r in rows], key=lambda r: int(r[0]))
    with open(OUT, 'w', newline='') as fh:
        w = csv.writer(fh, lineterminator='\n')
        w.writerow(['lanes', 'case', 'launch', 'threads', 'cycles', 'l1_hits', 'l1_misses',
                    'insns'])
        w.writerows(rows)
    print(f'wrote {OUT} ({len(rows)} rows)\n')
    tot = {}
    for lanes, case, _, _, cyc, *_ in rows:
        tot[(int(lanes), case)] = tot.get((int(lanes), case), 0) + int(cyc)
    ls = sorted({l for l, _ in tot})
    print(f"{'case':22s}" + ''.join(f' {str(l) + " lanes":>10s}' for l in ls))
    for case in sorted({c for _, c in tot}):
        print(f'{case:22s}' + ''.join(f' {tot.get((l, case), 0):10d}' for l in ls))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
