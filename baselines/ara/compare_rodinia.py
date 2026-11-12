"""compare_rodinia.py - Rodinia on SIMTiX v3, CVA6, Ara and Vortex, all measured on the ZCU102.

    python baselines/ara/compare_rodinia.py            (from the repository root)

Reads the three Rodinia board logs (the board scripts' `rodinia` argument, RD_ONLY host
builds; docs/rodinia_plan.md) and writes docs/rodinia_results.csv:
  docs/zcu102_board_run_rodinia_simtix.txt  SIMTiX v3, BOARD rows
  docs/zcu102_board_run_rodinia_ara.txt     Ara 2 lanes + CVA6, ARAK rows (cva6 and ara)
  docs/zcu102_board_run_rodinia_vortex.txt  Vortex 3.0, VXB rows
plus the RDULP / RDREL lines (largest error of CVA6 and Ara against the A53 reference in
the kernels with division or square root) and RDITER (kmeans iterations).

Times are the accelerator's wall-clock time in microseconds as each host prints it
(kernel time plus the cache flushes the run needs); cycles are each machine's own clock.
A speed-up "X over SIMTiX" is time(X) / time(SIMTiX). Geometric means are taken over the
benchmarks (one size each: the last size listed in BENCH).
"""
import csv
import math
import os

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
LOGS = {m: os.path.join(ROOT, 'docs', f'zcu102_board_run_rodinia_{m}.txt') for m in ('simtix', 'ara', 'vortex')}
OUT = os.path.join(ROOT, 'docs', 'rodinia_results.csv')
# Later Ara/CVA6 runs of single benchmarks (Ara host built with rd_sel=<mask>); their rows
# replace the full run's rows of the same benchmark.
ARA_EXTRA = [os.path.join(ROOT, 'docs', 'zcu102_board_run_rodinia_ara_hs3d.txt')]

# (report name, sizes); the paper table uses the last size of each
BENCH = [('pathfinder', [100000]), ('backprop', [524288]), ('bfs', [65536]),
         ('hotspot', [512, 1024]), ('nn', [42764]), ('hotspot3d', [512]),
         ('gaussian', [1024]), ('kmeans', [494020])]


def read():
    sx, ak, vx, tol, iters = {}, {}, {}, {}, {}
    for line in open(LOGS['simtix'], errors='replace'):
        p = line.strip().split(',')
        if p[0] == 'BOARD' and len(p) >= 9 and p[1] != 'kernel':
            sx[(p[1], int(p[2]))] = dict(cyc=int(p[3]), us=float(p[4]), a53=float(p[5]), err=int(p[8]))
        elif p[0] == 'RDITER' and len(p) == 5:
            iters[('simtix', p[1], int(p[2]))] = int(p[4])
    lines = []
    for f in [LOGS['ara']] + [f for f in ARA_EXTRA if os.path.isfile(f)]:
        lines += open(f, errors='replace').read().splitlines()
    # The Ara/CVA6 clock from the rows themselves (cycles / us). The host's us column
    # overflowed 32 bits above 429 s before 2026-11-11, so us is recomputed from cycles.
    rat = sorted(int(p[4]) / float(p[5]) for p in (l.strip().split(',') for l in lines)
                 if p[0] == 'ARAK' and p[1] != 'app' and p[4] != 'skip' and int(p[4]) > 0
                 and 1000.0 < float(p[5]) < 4e8)
    mhz = rat[len(rat) // 2]
    for line in lines:
        p = line.strip().split(',')
        if p[0] == 'ARAK' and p[1] != 'app':
            # a later file (ARA_EXTRA) replaces the row; a timed-out run has 0 cycles
            ak[(p[1], int(p[2]), p[3])] = None if p[4] == 'skip' else \
                dict(cyc=int(p[4]), us=int(p[4]) / mhz, a53=float(p[6]), err=int(p[8]))
        elif p[0] in ('RDULP', 'RDREL') and len(p) == 5:
            # RDULP,<app>,<n>,<mode>,<max ulp>   RDREL,<app>,<n>,<mode>,<max row-relative error x 1e9>
            # (gaussian prints gaussian_a and gaussian_m: the larger is kept)
            key = (p[1].split('_')[0], int(p[2]), 'cva6' if p[3] == '0' else 'ara')
            val = int(p[4]) * (1 if p[0] == 'RDULP' else 1e-9)
            if key not in tol or val > tol[key][1]:
                tol[key] = (p[0], val)
        elif p[0] == 'RDITER' and len(p) == 5:
            iters[('cva6' if p[3] == '0' else 'ara', p[1], int(p[2]))] = int(p[4])
    for line in open(LOGS['vortex'], errors='replace'):
        p = line.strip().split(',')
        if p[0] == 'VXB' and len(p) >= 9 and p[1] != 'app':
            vx[(p[1], int(p[2]))] = None if p[3] == 'skip' else \
                dict(cyc=int(p[3]), us=float(p[4]), a53=float(p[5]), err=int(p[8]))
        elif p[0] == 'RDITER' and len(p) == 5:
            iters[('vortex', p[1], int(p[2]))] = int(p[4])
    # The SIMTiX/Vortex hosts summed kernel cycles in 32 bits before 2026-11-11 (Vortex's
    # kmeans, 8.05e9 cycles, printed as 3.76e9); the printed time is right. Add back the
    # wraps: the clock is the median cycles/us of the rows (each host's time includes
    # a little launch overhead, far below one wrap).
    for d in (sx, vx):
        r = sorted(x['cyc'] / x['us'] for x in d.values() if x and x['us'] > 1000.0)
        mhz = r[len(r) // 2]
        for x in d.values():
            if x:
                x['cyc'] += round((x['us'] * mhz - x['cyc']) / 2 ** 32) * 2 ** 32
    return sx, ak, vx, tol, iters


def main():
    sx, ak, vx, tol, iters = read()
    rows, missing = [], []
    for app, sizes in BENCH:
        for n in sizes:
            s = sx.get((app, n))
            c, a, v = ak.get((app, n, 'cva6')), ak.get((app, n, 'ara')), vx.get((app, n))
            if s is None:
                missing.append(f'{app} {n} (SIMTiX)')
                continue
            ratio = lambda x: '%.2f' % (x['us'] / s['us']) if x and not x['err'] and x['cyc'] else ''
            terr = lambda m: '' if (app, n, m) not in tol else                 ('%d ulp' % tol[(app, n, m)][1]) if tol[(app, n, m)][0] == 'RDULP' else ('%.2e rel' % tol[(app, n, m)][1])
            rows.append({
                'app': app, 'size': n,
                'simtix_us': '%.1f' % s['us'], 'simtix_cycles': s['cyc'], 'simtix_errors': s['err'],
                'cva6_us': '%.1f' % c['us'] if c else '', 'cva6_cycles': c['cyc'] if c else '',
                'cva6_errors': c['err'] if c else '', 'cva6_max_error': terr('cva6'),
                'ara_us': '%.1f' % a['us'] if a else '', 'ara_cycles': a['cyc'] if a else '',
                'ara_errors': a['err'] if a else '', 'ara_max_error': terr('ara'),
                'vortex_us': '%.1f' % v['us'] if v else '', 'vortex_cycles': v['cyc'] if v else '',
                'vortex_errors': v['err'] if v else '',
                'a53_O2_us': '%.1f' % s['a53'],
                'cva6_over_simtix': ratio(c), 'ara_over_simtix': ratio(a), 'vortex_over_simtix': ratio(v),
                'a53_over_simtix': '%.2f' % (s['a53'] / s['us']),
            })
    with open(OUT, 'w', newline='') as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    print('wrote', OUT)
    if missing:
        print('missing:', ', '.join(missing))
    big = {a: s[-1] for a, s in BENCH}
    g = lambda xs: math.exp(sum(map(math.log, xs)) / len(xs)) if xs else float('nan')
    for k in ('cva6_over_simtix', 'ara_over_simtix', 'vortex_over_simtix', 'a53_over_simtix'):
        xs = [float(r[k]) for r in rows if r['size'] == big[r['app']] and r[k]]
        print('%-20s geomean %.2fx over %d benchmarks' % (k, g(xs), len(xs)))
    for k, it in sorted(iters.items()):
        print('iterations: %s %s %d: %d' % (k + (it,)))
    errs = [(r['app'], r['size'], m) for r in rows for m in ('simtix', 'cva6', 'ara', 'vortex')
            if r[m + '_errors'] not in ('', 0)]
    print('runs with wrong words:', errs if errs else 'none')


if __name__ == '__main__':
    main()
