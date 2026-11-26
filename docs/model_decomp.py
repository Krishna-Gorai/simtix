#!/usr/bin/env python3
"""model_decomp.py - split each machine's time ratio over SIMTiX into three factors.

For a benchmark run on SIMTiX (S) and on machine X, with T the time, C the clock cycles,
f the clock frequency and P the peak 32-bit lane operations per cycle:

    T_X / T_S = (C_X / C_S) * (f_S / f_X)                                   (1)
    C_X / C_S = (P_S / P_X) * (eta_S / eta_X)                               (2)

where eta = (operations of the benchmark) / (P * C) is the fraction of the peak that the
machine sustains. The benchmark's operation count cancels in eta_S / eta_X, so (2) defines
the efficiency ratio from measured cycles and the peaks alone:

    eta_S / eta_X = (C_X / C_S) * (P_X / P_S)

Peaks (32-bit lane operations, one FMA counted as one operation, per cycle):
  SIMTiX  8   one warp instruction of 8 lanes per cycle (rtl/accel/warp_pool.sv)
  Vortex  8   one core, warps of 8 threads, one warp instruction per cycle
  Ara     4   2 lanes x 64-bit datapath, FP32/INT32 packed two per lane (Ara's FPU has
              EnableVectors = 1, hardware/src/lane/vmfpu.sv)
  CVA6    1   single-issue scalar core
  FGPU    8   one compute unit of 8 PEs (wavefronts of 64 work-items over 8 cycles); no FMA
Clocks (MHz): SIMTiX 115.37, Vortex 125, Ara and CVA6 78.95, FGPU 187.48.
FGPU has no cycle counter: its cycles are its time (the A53's timer, launch overhead
included) times its clock.

Reads docs/rodinia_results.csv (hotspot at 1024) and docs/rivec_results.csv, and for the
17 applications of the lane study (base and optimized kernels, each at its larger board
input) docs/ara_cva6_simtix_comparison.csv (the other machines) and
docs/lanes16_board_results.csv (SIMTiX's eight-lane board cycles); Ara's MLP and
Smith-Waterman fail, so those two have no Ara row (its Mandelbrot, skipped on 2026-11-08, comes
from the 2026-11-09 run: baselines/ara/compare_simtix.py). Writes
docs/model_decomp.csv and prints the geometric means over the 15 Rodinia and RiVEC
benchmarks (the figures of the text) and over the applications.
"""
import csv
import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))
F = {'simtix': 115.37, 'vortex': 125.0, 'ara': 78.95, 'cva6': 78.95, 'fgpu': 187.48}
P = {'simtix': 8, 'vortex': 8, 'ara': 4, 'cva6': 1, 'fgpu': 8}
SKIP = {('hotspot', 512)}             # one size per benchmark: hotspot at 1024
NAMES = {'jacobi': 'jacobi-2d', 'lavamd': 'lavaMD', 'hotspot3d': 'hotspot3D'}


def gmean(v):
    return math.exp(sum(math.log(x) for x in v) / len(v))


def rows():
    for suite, fn in (('Rodinia', 'rodinia_results.csv'), ('RiVEC', 'rivec_results.csv')):
        for r in csv.DictReader(open(os.path.join(HERE, fn))):
            if (r['app'], int(r['size'])) in SKIP:
                continue
            yield suite, r


APP_OF = {'gemmrb': 'gemm', 'stencilrb': 'stencil', 'kmeansu': 'kmeans', 'scanseg': 'scan',
          'spmvz': 'spmv'}                  # optimized SIMTiX kernel -> application


def app_rows():
    """(kernel, SIMTiX row, machines row) of each application kernel at its larger input"""
    mach = {}
    for r in csv.DictReader(open(os.path.join(HERE, 'ara_cva6_simtix_comparison.csv'))):
        if r['app'] not in mach or int(r['size']) > int(mach[r['app']]['size']):
            mach[r['app']] = r
    sim = {}
    for r in csv.DictReader(open(os.path.join(HERE, 'lanes16_board_results.csv'))):
        if r['suite'] == 'apps' and (r['kernel'] not in sim or int(r['N']) > int(sim[r['kernel']]['N'])):
            sim[r['kernel']] = r
    for k, s in sim.items():
        x = mach[APP_OF.get(k, k)]
        assert int(s['N']) == int(x['size']), k
        yield k, s, x


def factors(m, cs, us_s, cx, us_x):
    cyc = cx / cs
    clk = F['simtix'] / F[m]
    peak = P['simtix'] / P[m]
    return {'time_ratio': us_x / us_s, 'cycle_ratio': cyc, 'clock_factor': clk,
            'peak_factor': peak, 'efficiency_factor': cyc / peak}


def main():
    out, acc = [], {m: {'time': [], 'cyc': [], 'clk': [], 'peak': [], 'eff': []}
                    for m in ('cva6', 'ara', 'vortex', 'fgpu')}
    app_eff = {m: [] for m in acc}
    for suite, r in rows():
        cs = int(r['simtix_cycles'])
        for m in acc:
            cx = int(r[m + '_cycles']) if m != 'fgpu' else float(r['fgpu_us']) * F['fgpu']
            fa = factors(m, cs, float(r['simtix_us']), cx, float(r[m + '_us']))
            for k, n in (('time', 'time_ratio'), ('cyc', 'cycle_ratio'), ('clk', 'clock_factor'),
                         ('peak', 'peak_factor'), ('eff', 'efficiency_factor')):
                acc[m][k].append(fa[n])
            out.append({'suite': suite, 'key': r['app'], 'app': NAMES.get(r['app'], r['app']),
                        'machine': m, **{n: '%.4f' % v for n, v in fa.items()}})
    for k, s, x in app_rows():
        for m in acc:
            if m == 'ara' and x['ara_status'] != 'ok':
                continue                        # Ara's MLP and Smith-W. outputs are wrong
            cx = int(x[m + '_cycles']) if m != 'fgpu' else float(x['fgpu_us']) * F['fgpu']
            fa = factors(m, int(s['cycles_8L']), float(s['us_8L_115MHz']), cx, float(x[m + '_us']))
            app_eff[m].append(fa['efficiency_factor'])
            out.append({'suite': 'Apps', 'key': k, 'app': k, 'machine': m,
                        **{n: '%.4f' % v for n, v in fa.items()}})
    with open(os.path.join(HERE, 'model_decomp.csv'), 'w', newline='') as f:
        w = csv.DictWriter(f, fieldnames=list(out[0]))
        w.writeheader()
        w.writerows(out)
    n = len(acc['ara']['time'])
    print('geometric means over %d benchmarks (machine / SIMTiX):' % n)
    print('%-7s %8s %8s %8s %8s %8s' % ('', 'time', 'cycles', 'clock', 'peak', 'effic.'))
    for m, a in acc.items():
        print('%-7s %8.2f %8.2f %8.2f %8.2f %8.2f' % (m, gmean(a['time']), gmean(a['cyc']),
              gmean(a['clk']), gmean(a['peak']), gmean(a['eff'])))
        lo, hi = min(a['eff']), max(a['eff'])
        print('        efficiency factor range %.2f .. %.2f' % (lo, hi))
    print('applications: efficiency factor, geometric mean and range')
    for m, v in app_eff.items():
        print('%-7s %2d %8.2f   %.2f .. %.2f' % (m, len(v), gmean(v), min(v), max(v)))


if __name__ == '__main__':
    main()
