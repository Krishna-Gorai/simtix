"""
board_sim.py -- SIMTiX on the board host's input sets, in simulation.

    python sim/board_sim.py [--size board|dram] [--lat 24 48] [--only APP ...] [--out CSV]
                            [--warps N] [--define NAME=VALUE ...]

The board host (sw/ps_host/apps.c) runs two input sets: medium ("board") and
DRAM-sized ("dram"). On a board without the accelerator (sw/a53_zcu102) the A53
side is measured on the board and the SIMTiX side comes from here: the board top
(simt_ps_top) in xsim, driven as the A53 drives it, with an AXI4 DDR4 model of
--lat cycles of latency (out of order, ready stalls). Each run writes
build_apps_<size>/ (sim/gen_apps.py) and appends its rows to
docs/board_sim.csv (or --out):
    size,lat,case,launch,threads,cycles,l1_hits,l1_misses,insns,active
Rows of the same size, latency and case are replaced, so a run with --warps other
than 4 (SIMTIX_NUM_WARPS) or any --define (e.g. SIMTIX_L1_KB=64,
SIMTIX_L1_MSHR=8, SIMTIX_MEM_TAGS=16) should write its own --out file.
"""
import argparse
import csv
import os
import subprocess
import sys

import run_xsim

ROOT = run_xsim.ROOT
OUT = os.path.join(ROOT, 'docs', 'board_sim.csv')
HDR = ['size', 'lat', 'case', 'launch', 'threads', 'cycles', 'l1_hits', 'l1_misses', 'insns',
       'active']


def one(size, lat, only, warps=4, defines=()):
    words_lg = 24 if size == 'dram' else 20
    data = os.path.join(ROOT, f'build_apps_{size}')
    cmd = [sys.executable, os.path.join(ROOT, 'sim', 'gen_apps.py'), '--size', size,
           '--words-lg', str(words_lg), '--out', data]
    if only:
        cmd += ['--only'] + only
    subprocess.run(cmd, check=True)
    tag = ''.join('_' + d.split('=')[0].replace('SIMTIX_', '').lower() + d.split('=')[-1]
                  for d in defines)
    name = f'apps_{size}_l{lat}' + (f'_w{warps}' if warps != 4 else '') + tag
    defs = ([f'SIMTIX_NUM_WARPS={warps}'] if warps != 4 else []) + list(defines)
    run_xsim.TESTS[name] = ('tb_apps', run_xsim.PS + ['tests/tb_apps.sv'], [], False,
                            ['AGG=1', 'APAR=0', f'MEM_LAT={lat}', f'WORDS_LG={words_lg}'])
    ok, msg = run_xsim.run_test(name, defines=defs,
                                plusargs=[f'MANIFEST={data}/apps.manifest'.replace('\\', '/')])
    rows = {}
    log = os.path.join(run_xsim.BUILD, name, 'xsim.log')
    if os.path.isfile(log):
        for line in open(log, encoding='utf-8', errors='replace'):
            if line.startswith('APPCSV,'):
                f = line.strip().split(',')[1:]
                rows[tuple(f[:2])] = [size, str(lat)] + f
    return ok, msg, list(rows.values())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--size', default='board', choices=('board', 'dram'))
    ap.add_argument('--lat', type=int, nargs='+', default=[24])
    ap.add_argument('--only', nargs='*')
    ap.add_argument('--warps', type=int, default=4, help='hardware warps (SIMTIX_NUM_WARPS)')
    ap.add_argument('--define', nargs='*', default=[], help='extra Verilog defines NAME=VALUE')
    ap.add_argument('--out', default=OUT, help='CSV to merge into (default docs/board_sim.csv)')
    args = ap.parse_args()
    out = os.path.abspath(args.out)
    fails = 0
    for lat in args.lat:
        ok, msg, rows = one(args.size, lat, args.only, args.warps, args.define)
        print(f"{'PASS' if ok else 'FAIL'}  {args.size} lat {lat}  {msg}", flush=True)
        fails += not ok
        old = []
        if os.path.isfile(out):
            with open(out, newline='') as fh:
                old = list(csv.reader(fh))[1:]
        done = {(r[0], r[1], r[2]) for r in rows}
        old = [r for r in old if (r[0], r[1], r[2]) not in done]
        with open(out, 'w', newline='') as fh:
            w = csv.writer(fh, lineterminator='\n')
            w.writerow(HDR)
            w.writerows(sorted(old + rows, key=lambda r: (r[0], int(r[1]), r[2])))
        tot = {}
        for r in rows:
            tot[r[2]] = tot.get(r[2], 0) + int(r[5])
        for case, cyc in sorted(tot.items()):
            print(f'  {case:26s} {cyc:12d} cycles', flush=True)
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
