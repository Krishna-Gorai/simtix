"""throughput_sweep.py - throughput of the 15 application kernels against problem size, at 4,
8 and 16 lanes (the Ara-style throughput plots, docs/plot_throughput.py).

    python sim/throughput_sweep.py [--lanes 4 8 16] [--only gemm spmv ...]

For each lane count L: assembles the kernels for L lanes (kernels/apps/build.py), writes every
kernel at each of its sizes (SWEEP below) into build_apps_tp_l<L>/, and runs tests/tb_apps.sv
in xsim in the board configuration (8 warps, 64 KB L1, 16 MSHRs, 16 tags, 24-cycle AXI4
memory model, aggregated AMOs) with SIMTIX_OPCOUNT, which prints the useful operations of
every launch: FP32 FLOPs (FMA = 2), INT8 MACs and lane operations. Every output word is still
checked. Sizes a lane count cannot run (a kernel's constraint on L) are skipped.
Writes docs/throughput_sweep.csv:
    lanes,app,size,case,launches,cycles,flop,mac8,laneops,insns
"""
import argparse
import collections
import csv
import os
import random
import subprocess
import sys

import run_xsim
import gen_apps as G

ROOT = run_xsim.ROOT
OUT = os.path.join(ROOT, 'docs', 'throughput_sweep.csv')
DEFS = ['SIMTIX_NUM_WARPS=8', 'SIMTIX_L1_KB=64', 'SIMTIX_L1_MSHR=16', 'SIMTIX_MEM_TAGS=16',
        'SIMTIX_OPCOUNT=1']

# app -> (size label, [(size, generator)]); the largest size of each is its board input
SWEEP = {
    'gemm':      ('n', [(n, lambda r, n=n: G.gemm(r, n, n, n)) for n in (16, 32, 64, 128)]),
    'gemmrb':    ('n', [(n, lambda r, n=n: G.gemm(r, n, n, n, blocked=True)) for n in (32, 64, 128)]),
    'spmv':      ('rows', [(n, lambda r, n=n: G.spmv(r, n, n, 16)) for n in (512, 1024, 2048, 4096)]),
    'spmvz':     ('rows', [(n, lambda r, n=n: G.spmv(r, n, n, 16, zba=True)) for n in (512, 1024, 2048, 4096)]),
    'stencil':   ('side', [(n, lambda r, n=n: G.stencil(r, n, n, 4)) for n in (32, 64, 128)]),
    'stencilrb': ('side', [(n, lambda r, n=n: G.stencil(r, n, n, 4, rows=16)) for n in (32, 64, 128)]),
    'kmeans':    ('points', [(n, lambda r, n=n: G.kmeans(r, n, 16)) for n in (1024, 4096, 16384)]),
    'kmeansu':   ('points', [(n, lambda r, n=n: G.kmeans(r, n, 16, two=True)) for n in (1024, 4096, 16384)]),
    'bfs':       ('vertices', [(n, lambda r, n=n: G.bfs(r, n, 8)) for n in (1024, 4096, 16384)]),
    'scan':      ('elements', [(n, lambda r, n=n: G.scan(r, n)) for n in (2048, 8192, 32768, 65536)]),
    'scanseg':   ('elements', [(n, lambda r, n=n: G.scanseg(r, n)) for n in (2048, 8192, 32768, 65536)]),
    'mlp':       ('batch', [(n, lambda r, n=n: G.mlp(r, n, [784, 256, 128, 10])) for n in (4, 8, 16)]),
    'conv8':     ('side', [(n, lambda r, n=n: G.conv8(r, n, n, [16, 32, 32])) for n in (8, 16, 32)]),
    'embag':     ('bags', [(n, lambda r, n=n: G.embag(r, 16384, 32, n, 16)) for n in (64, 128, 256)]),
    'hashj':     ('probes', [(n, lambda r, n=n, s=s: G.hashj(r, s, 2 * n, n))
                             for s, n in ((12, 1024), (14, 4096), (16, 16384))]),
}
SEED = {'gemmrb': 0, 'scanseg': 5, 'stencilrb': 2, 'kmeansu': 3, 'spmvz': 1}


def generate(lanes, apps, data, kdir):
    G.LANES = lanes
    G.WORDS = 1 << 20
    G.place_kernels(kdir)
    cases, meta = [], []
    for app in apps:
        label, sizes = SWEEP[app]
        for size, f in sizes:
            try:
                c = f(random.Random(2027 + SEED.get(app, 0)))
            except AssertionError:
                print(f'  skip {app} {label}={size} at {lanes} lanes (kernel constraint)')
                continue
            if c.img.top - G.DDR_BASE > 4 * G.WORDS:
                print(f'  skip {app} {label}={size}: exceeds the DDR model')
                continue
            cases.append(c)
            meta.append((app, size, c.name))
    os.makedirs(data, exist_ok=True)
    G.write_manifest(cases, data, kdir)
    return meta


def one(lanes, apps):
    data = os.path.join(ROOT, f'build_apps_tp_l{lanes}')
    kdir = os.path.join(ROOT, 'kernels', 'apps')
    if lanes != 8:
        kdir = os.path.join(data, 'kernels')
        subprocess.run([sys.executable, os.path.join(ROOT, 'kernels', 'apps', 'build.py'),
                        '--lanes', str(lanes), '--out', kdir], check=True)
    meta = generate(lanes, apps, data, kdir)
    name = f'apps_tp_l{lanes}'
    run_xsim.TESTS[name] = ('tb_apps', run_xsim.PS + ['tests/tb_apps.sv'], [], False,
                            ['AGG=1', 'APAR=0', 'MEM_LAT=24', 'WORDS_LG=20'])
    ok, msg = run_xsim.run_test(name, defines=[f'SIMTIX_NUM_LANES={lanes}'] + DEFS,
                                plusargs=[f'MANIFEST={data}/apps.manifest'.replace('\\', '/')])
    # pair each OPCOUNT line with the APPCSV line of the same launch (it comes first)
    tot = collections.defaultdict(collections.Counter)
    pend = None
    log = os.path.join(run_xsim.BUILD, name, 'xsim.log')
    seen = set()
    for line in open(log, encoding='utf-8', errors='replace'):
        if line.startswith('OPCOUNT,'):
            pend = dict(kv.split('=') for kv in line.strip().split(',')[1:])
        elif line.startswith('APPCSV,') and pend is not None:
            f = line.strip().split(',')
            key = (f[1], f[2])
            if key in seen:                       # xsim can repeat its last lines
                pend = None
                continue
            seen.add(key)
            t = tot[f[1]]                         # APPCSV,case,launch,threads,cycles,hits,misses,insns,active
            t['cycles'] += int(f[4])
            t['insns'] += int(f[7])
            t['launches'] += 1
            for k in ('flop', 'mac8', 'laneops'):
                t[k] += int(pend[k])
            pend = None
    rows = []
    for app, size, case in meta:
        t = tot.get(case)
        if t:
            rows.append([lanes, app, size, case, t['launches'], t['cycles'], t['flop'], t['mac8'],
                         t['laneops'], t['insns']])
    return ok, msg, rows


def reparse():
    """Recompute cycles, instructions and the L1 read hits and misses of every row of OUT from
    the runs' xsim logs (APPCSV,case,launch,threads,cycles,hits,misses,insns,active)."""
    rows = [r for r in csv.reader(open(OUT, newline=''))]
    hdr, rows = rows[0][:10], [r[:10] for r in rows[1:]]
    hdr += ['l1_hits', 'l1_misses']
    acc = {}
    for lanes in sorted({r[0] for r in rows}):
        log = os.path.join(run_xsim.BUILD, f'apps_tp_l{lanes}', 'xsim.log')
        seen = set()
        for line in open(log, encoding='utf-8', errors='replace'):
            if line.startswith('APPCSV,'):
                f = line.strip().split(',')
                if (f[1], f[2]) in seen:
                    continue
                seen.add((f[1], f[2]))
                a = acc.setdefault((lanes, f[1]), [0, 0, 0, 0])
                a[0] += int(f[4])
                a[1] += int(f[7])
                a[2] += int(f[5])
                a[3] += int(f[6])
    for r in rows:
        cyc, ins, hits, miss = acc[(r[0], r[3])]
        r[5], r[9] = str(cyc), str(ins)
        r += [str(hits), str(miss)]
    with open(OUT, 'w', newline='') as fh:
        w = csv.writer(fh, lineterminator='\n')
        w.writerow(hdr)
        w.writerows(rows)
    print(f'reparsed {len(rows)} rows of {OUT}')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--lanes', type=int, nargs='+', default=[4, 8, 16])
    ap.add_argument('--only', nargs='*', default=list(SWEEP))
    ap.add_argument('--reparse', action='store_true', help='only fix OUT from the existing logs')
    args = ap.parse_args()
    if args.reparse:
        reparse()
        return 0
    hdr = ['lanes', 'app', 'size', 'case', 'launches', 'cycles', 'flop', 'mac8', 'laneops', 'insns']
    old = []
    if os.path.isfile(OUT):
        with open(OUT, newline='') as fh:
            old = [r for r in csv.reader(fh)][1:]
    fails = 0
    for lanes in args.lanes:                      # one at a time: a 16-lane xsim run is large
        ok, msg, rows = one(lanes, args.only)
        print(f"{'PASS' if ok else 'FAIL'}  {lanes:2d} lanes  {msg}  ({len(rows)} cases)", flush=True)
        fails += not ok
        done = {(str(r[0]), r[3]) for r in rows}
        old = [r for r in old if (r[0], r[3]) not in done] + [[str(x) for x in r] for r in rows]
        with open(OUT, 'w', newline='') as fh:    # after each lane count: survives a stop
            w = csv.writer(fh, lineterminator='\n')
            w.writerow(hdr)
            w.writerows(sorted(old, key=lambda r: (int(r[0]), r[1], int(r[2]))))
        print(f'wrote {OUT}', flush=True)
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
