#!/usr/bin/env python3
"""plot_machines_suites.py - SIMTiX against CVA6, Ara and Vortex on the ZCU102, one figure per suite.

All times measured on the board. For each benchmark (at its largest board input) the bars give
SIMTiX's speed-up over each machine, machine time / SIMTiX time, for the eight-lane SIMTiX of the
paper (115.37 MHz); a black tick on each bar gives the same ratio for the 16-lane SIMTiX (100 MHz).
CVA6 and Ara at 78.95 MHz, Vortex at 125 MHz (Table of machines). Sources:
  applications: docs/ara_cva6_simtix_comparison.csv (SIMTiX's best kernel variant, as in the paper)
  suite 2:      docs/zcu102_board_run_v3_s2.txt (SIMTiX), zcu102_board_run_ara_s2.txt (CVA6, Ara)
  Rodinia:      docs/rodinia_results.csv;   RiVEC: docs/rivec_results.csv
  16 lanes:     docs/zcu102_board_run_l16_{main,rodinia,rivec}.txt
Excluded: Ara MLP and Smith-Waterman (wrong outputs on the board);
Vortex has no suite-2 ports. Suite-2 Black-Scholes on CVA6 and Ara (dagger): bit-exact checks
differ from SIMTiX's in the last bits (their shared divider's rounding, as for RiVEC Black-Scholes).
Writes docs/machines_suites.csv and docs/figs/machines_{apps,suite2,rodinia,rivec}.pdf (.png).
Usage:  python docs/plot_machines_suites.py
"""
import csv
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import plot_style  # noqa: E402
from plot_style import plt, INK, MUTED  # noqa: E402

MACH = [('cva6', 'CVA6', '#2a78d6'), ('ara', 'Ara', '#eb6834'), ('vortex', 'Vortex', '#1baf7a')]
NAME = {
    'gemm': 'GEMM', 'spmv': 'SpMV', 'stencil': 'Stencil', 'kmeans': 'k-means', 'bfs': 'BFS',
    'scan': 'Scan', 'mlp': 'MLP', 'conv8': 'CNN', 'embag': 'Emb. bag', 'hashj': 'Hash join',
    'mandel': 'Mandelbrot', 'swat': 'Smith-W.', 'hotspot': 'Hotspot', 'jacobi2d': 'Jacobi-2D',
    'backprop': 'Backprop', 'blackscholes': 'Black-Scholes', 'pathfinder': 'Pathfinder',
    'pagerank': 'PageRank', 'cc': 'Conn. comp.', 'atax': 'ATAX', 'bicg': 'BiCG', 'sort': 'Radix sort',
    'hotspot3d': 'Hotspot3D', 'nn': 'NN', 'gaussian': 'Gaussian', 'axpy': 'AXPY', 'matmul': 'Matmul',
    'jacobi': 'Jacobi-2D', 'lavamd': 'LavaMD'}


def board(name, start=None):
    """BOARD rows of a SIMTiX board log: {(kernel, N): us}, from the line `start` on."""
    out, on = {}, start is None
    for line in open(os.path.join(HERE, name), encoding='utf-8', errors='replace'):
        line = line.replace('\x00', '').strip()
        if start and line.startswith(start):
            on = True
        if on and line.startswith('BOARD,') and not line.startswith('BOARD,kernel'):
            f = line.split(',')
            out.setdefault((f[1], int(f[2])), float(f[4]))
    return out


def fgpu_suite2():
    """FGPU's suite-2 times {(bench, N): us} from its suites 1+2 board log (FGB rows; the
    applications' rows come from ara_cva6_simtix_comparison.csv)"""
    out, path = {}, os.path.join(HERE, 'zcu102_board_run_apps_fgpu.txt')
    if not os.path.isfile(path):
        return out
    s2 = ('pathfinder', 'hotspot', 'jacobi2d', 'atax', 'bicg', 'pagerank', 'cc', 'backprop', 'sort',
          'blackscholes')
    for line in open(path, encoding='utf-8', errors='replace'):
        f = line.replace('\x00', '').strip().split(',')
        if f[0] == 'FGB' and len(f) >= 9 and f[1] in s2 and f[3] != 'skip' and not int(f[8]):
            out.setdefault((f[1], int(f[2])), float(f[4]))
    return out


def collect():
    """rows: (suite, bench, N, simtix8_us, simtix16_us, {machine: us or None}, {machine: note});
    the machine dict also holds 'fgpu' (FGPU, docs/fgpu_plan.md), which MACH, the CSV and the bar
    figures of this script leave out (plot_machines_alt.py's heatmap shows it)"""
    rows = []
    l16 = board('zcu102_board_run_l16_main.txt')
    fg2 = fgpu_suite2()
    for x in csv.DictReader(open(os.path.join(HERE, 'ara_cva6_simtix_comparison.csv'))):
        n = int(x['size'])
        t = {'cva6': float(x['cva6_us']), 'vortex': float(x['vortex_us'])}
        t['fgpu'] = float(x['fgpu_us']) if x.get('fgpu_us') and not int(x['fgpu_errors'] or 0) else None
        note = {}
        if x['ara_status'] == 'ok':
            t['ara'] = float(x['ara_us'])
        else:
            t['ara'] = None
            note['ara'] = 'wrong output' if 'FAIL' in x['ara_status'] else 'deadlock'
        rows.append(('apps', x['app'], n, float(x['simtix_us']), l16[(x['simtix_kernel'], n)], t, note))
    s8 = board('zcu102_board_run_v3_s2.txt')
    ak = {}
    for line in open(os.path.join(HERE, 'zcu102_board_run_ara_s2.txt'), encoding='utf-8', errors='replace'):
        line = line.replace('\x00', '').strip()
        if line.startswith('ARAK,') and not line.startswith('ARAK,app'):
            f = line.split(',')
            ak[(f[1], int(f[2]), f[3])] = (float(f[5]), int(f[8]))
    S2 = ['hotspot', 'jacobi2d', 'backprop', 'blackscholes', 'pathfinder', 'pagerank', 'cc',
          'atax', 'bicg', 'sort']           # the log also holds the applications' runs
    for (k, n, core) in sorted({(a, b, c) for a, b, c in ak}, key=lambda z: (S2.index(z[0]) if z[0] in S2 else 99, z[1])):
        if core != 'cva6' or k not in S2:
            continue
        t, note = {'vortex': None, 'fgpu': fg2.get((k, n))}, {'vortex': 'no port'}
        for m in ('cva6', 'ara'):
            us, err = ak[(k, n, m)]
            t[m] = us
            if err:
                note[m] = 'dagger'
        rows.append(('suite2', k, n, s8[(k, n)], l16[(k, n)], t, note))
    for suite, f, log, start in (('rodinia', 'rodinia_results.csv', 'zcu102_board_run_l16_rodinia.txt', 'RODINIA,suite,start'),
                                 ('rivec', 'rivec_results.csv', 'zcu102_board_run_l16_rivec.txt', 'RIVEC,suite,start')):
        r16 = board(log, start)
        for x in csv.DictReader(open(os.path.join(HERE, f))):
            n = int(x['size'])
            t = {m: float(x[f'{m}_us']) if x[f'{m}_us'] else None for m, _, _ in MACH}
            t['fgpu'] = float(x['fgpu_us']) if x.get('fgpu_us') and not int(x['fgpu_errors'] or 0) else None
            rows.append((suite, x['app'], n, float(x['simtix_us']), r16[(x['app'], n)], t, {}))
    with open(os.path.join(HERE, 'machines_suites.csv'), 'w', newline='\n') as f:
        f.write('suite,benchmark,N,simtix8_us,simtix16_us,cva6_us,ara_us,vortex_us,'
                'cva6_over_simtix8,ara_over_simtix8,vortex_over_simtix8,'
                'cva6_over_simtix16,ara_over_simtix16,vortex_over_simtix16,notes\n')
        for s, k, n, t8, t16, t, note in rows:
            r8 = [f'{t[m] / t8:.3f}' if t.get(m) else '' for m, _, _ in MACH]
            r16 = [f'{t[m] / t16:.3f}' if t.get(m) else '' for m, _, _ in MACH]
            f.write(f'{s},{k},{n},{t8:.1f},{t16:.1f},' + ','.join(f'{t[m]:.1f}' if t.get(m) else '' for m, _, _ in MACH)
                    + ',' + ','.join(r8) + ',' + ','.join(r16) + ',' + ';'.join(f'{m}:{v}' for m, v in note.items()) + '\n')
    return rows


def gmean(v):
    return math.exp(sum(map(math.log, v)) / len(v))


def plot(suite, rows):
    best = {}
    for r in rows:
        if r[0] == suite and (r[1] not in best or r[2] > best[r[1]][2]):
            best[r[1]] = r
    keys = list(best)
    mach = [m for m in MACH if any(best[k][5].get(m[0]) for k in keys)]
    wide = len(keys) + 1 > 9
    fig, ax = plt.subplots(figsize=(7.16 if wide else 3.5, 2.5))
    nm = len(mach)
    bw = 0.78 / nm
    xs = []
    allv = []
    gm8, gm16 = {}, {}
    for m, _, _ in mach:
        v8 = [best[k][5][m] / best[k][3] for k in keys if best[k][5].get(m)]
        v16 = [best[k][5][m] / best[k][4] for k in keys if best[k][5].get(m)]
        gm8[m], gm16[m] = gmean(v8), gmean(v16)
    for i, k in enumerate(keys + ['_gm']):
        x = i + (0.7 if k == '_gm' else 0.0)
        xs.append(x)
        for j, (m, mname, col) in enumerate(mach):
            xb = x + (j - (nm - 1) / 2) * bw
            if k == '_gm':
                v8, v16, note = gm8[m], gm16[m], None
            else:
                _, _, _, t8, t16, t, nd = best[k]
                note = nd.get(m)
                if not t.get(m):
                    ax.text(xb, 1.04, 'n/a', ha='center', va='bottom', fontsize=4.8, color=MUTED,
                            rotation=90)
                    continue
                v8, v16 = t[m] / t8, t[m] / t16
            allv += [v8, v16]
            # bars grow from 1x (parity) up to the speed-up, or down when the machine is faster
            ax.bar(xb, abs(v8 - 1.0), bw * 0.9, bottom=min(v8, 1.0), color=col, linewidth=0, zorder=2)
            ax.plot([xb - bw * 0.42, xb + bw * 0.42], [v16, v16], color=INK, lw=1.1, zorder=3,
                    solid_capstyle='butt')
            lab = f'{v8:.1f}' if v8 < 9.95 else f'{v8:.0f}'
            if note == 'dagger':
                lab += '†'
            ytxt = max(v8, v16, 1.0) * 1.14
            ax.text(xb, ytxt, lab, ha='center', va='bottom', fontsize=5.0, color=INK, rotation=90, zorder=4)
    ax.set_yscale('log')
    ax.axhline(1.0, color=INK, lw=0.7, zorder=1)
    lo = min(0.4, min(allv) / 1.5)
    hi = max(allv) * 2.6
    ax.set_ylim(lo, hi)
    ticks = [t for t in (0.5, 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000) if lo <= t <= hi]
    ax.set_yticks(ticks)
    ax.set_yticklabels([f'{t:g}×' for t in ticks])
    ax.minorticks_off()
    ax.axvline((xs[-2] + xs[-1]) / 2, color='#cfcfcf', lw=0.6, zorder=0)
    ax.set_xticks(xs)
    ax.set_xticklabels([NAME.get(k, k) for k in keys] + ['Geomean'], rotation=40, ha='right',
                       rotation_mode='anchor', fontsize=6.8)
    ax.tick_params(axis='x', length=0, pad=3)
    ax.set_xlim(xs[0] - 0.6, xs[-1] + 0.6)
    ax.set_ylabel('Speed-up of SIMTiX')
    hs = [plt.Rectangle((0, 0), 1, 1, color=c) for _, _, c in mach]
    hs.append(plt.Line2D([0], [0], color=INK, lw=1.1))
    ax.legend(hs, [n for _, n, _ in mach] + ['16-lane SIMTiX'], loc='lower left',
              bbox_to_anchor=(0.0, 1.0), ncol=len(hs), handlelength=1.2, columnspacing=1.0,
              borderaxespad=0.1)
    out = os.path.join(HERE, 'figs', f'machines_{suite}.pdf')
    fig.savefig(out)
    fig.savefig(out.replace('.pdf', '.png'), dpi=200)
    plt.close(fig)
    print(f'{suite}: {len(keys)} benchmarks; geomean over ' +
          ', '.join(f'{n} {gm8[m]:.2f}x (16L {gm16[m]:.2f}x)' for m, n, _ in mach) + f' -> {out}')


def main():
    plot_style.apply()
    rows = collect()
    for s in ('apps', 'suite2', 'rodinia', 'rivec'):
        plot(s, rows)


if __name__ == '__main__':
    main()
