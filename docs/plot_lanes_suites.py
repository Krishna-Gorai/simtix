#!/usr/bin/env python3
"""plot_lanes_suites.py - performance of SIMTiX at 4, 8 and 16 lanes, one figure per suite.

Board-size simulation of the board configuration (8 warps, 16 MSHRs, 16 tags; the L1 scales
with the lanes to keep 2,048 lines: 32/64/128 KB; one divide/square-root unit per eight lanes),
every output checked. Reads the per-case logs of sim/run_lanes_board.sh:
    build_b4/<suite>/<case>/sim_l4_w8_k32.log, build_b8/.../sim_l8_w8.log,
    build_b16/.../sim_l16_w8_s2_k128.log
(sum of the cycles of a case's kernel launches), writes docs/lanes_scaling.csv and draws, per
suite, the speed-up over 4 lanes (cycles at 4 lanes / cycles at L lanes) of every benchmark at
4, 8 and 16 lanes, with the ideal 2x and 4x and the geometric mean:
    docs/figs/lanes_{sync,apps,suite2,rodinia,rivec}.pdf (and .png)
Usage:  python docs/plot_lanes_suites.py
"""
import csv
import glob
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..'))
sys.path.insert(0, HERE)
import plot_style  # noqa: E402
from plot_style import plt, INK, MUTED, RAMP3  # noqa: E402

CFG = {4: 'sim_l4_w8_k32.log', 8: 'sim_l8_w8.log', 16: 'sim_l16_w8_s2_k128.log'}
SUITES = ['sync', 'apps', 'suite2', 'rodinia', 'rivec']
ORDER = {
    'sync': ['reduce_shfl', 'histogram', 'hist_shared', 'amo_contend'],
    'apps': ['gemm', 'gemmrb', 'stencil', 'stencilrb', 'conv8', 'mlp', 'embag', 'kmeans', 'kmeansu',
             'mandel', 'swat', 'scan', 'scanseg', 'spmv', 'spmvz', 'bfs', 'hashj'],
    'suite2': ['hotspot', 'jacobi2d', 'backprop', 'blackscholes', 'pathfinder', 'pagerank', 'cc',
               'atax', 'bicg', 'sort'],
    'rodinia': ['hotspot', 'hotspot3d', 'backprop', 'kmeans', 'nn', 'gaussian', 'pathfinder', 'bfs'],
    'rivec': ['matmul', 'axpy', 'jacobi', 'blackscholes', 'lavamd', 'pathfinder', 'spmv'],
}
NAME = {
    'reduce_shfl': 'Reduce', 'histogram': 'Histogram', 'hist_shared': 'Hist. (shared)',
    'amo_contend': 'AMO contention', 'gemm': 'GEMM', 'gemmrb': 'GEMM-RB', 'stencil': 'Stencil',
    'stencilrb': 'Stencil-RB', 'conv8': 'CNN', 'mlp': 'MLP', 'embag': 'Emb. bag', 'kmeans': 'k-means',
    'kmeansu': 'k-means-U', 'mandel': 'Mandelbrot', 'swat': 'Smith-W.', 'scan': 'Scan',
    'scanseg': 'Seg. scan', 'spmv': 'SpMV', 'spmvz': 'SpMV-Z', 'bfs': 'BFS', 'hashj': 'Hash join',
    'hotspot': 'Hotspot', 'jacobi2d': 'Jacobi-2D', 'backprop': 'Backprop',
    'blackscholes': 'Black-Scholes', 'pathfinder': 'Pathfinder', 'pagerank': 'PageRank',
    'cc': 'Conn. comp.', 'atax': 'ATAX', 'bicg': 'BiCG', 'sort': 'Radix sort', 'hotspot3d': 'Hotspot3D',
    'nn': 'NN', 'gaussian': 'Gaussian', 'axpy': 'AXPY', 'jacobi': 'Jacobi-2D', 'lavamd': 'LavaMD',
    'matmul': 'Matmul'}
SIZE = {1024: '1K', 16384: '16K', 262144: '256K'}


def cycles(log):
    tot = n = 0
    for line in open(log, errors='replace'):
        if line.startswith('APPCSV,'):
            tot += int(line.split(',')[4])
            n += 1
    ok = any('[tb_apps] PASS' in l for l in open(log, errors='replace'))
    return (tot if n and ok else None)


def gmean(v):
    return math.exp(sum(map(math.log, v)) / len(v))


def collect():
    rows = []
    for suite in SUITES:
        cases = sorted({os.path.basename(os.path.dirname(p))
                        for p in glob.glob(os.path.join(ROOT, 'build_b8', suite, '*', 'apps.manifest'))})
        for case in cases:
            c = {}
            for L, f in CFG.items():
                p = os.path.join(ROOT, f'build_b{L}', suite, case, f)
                c[L] = cycles(p) if os.path.isfile(p) else None
            rows.append((suite, case, c))
    with open(os.path.join(HERE, 'lanes_scaling.csv'), 'w', newline='\n') as f:
        f.write('suite,case,cycles_4L,cycles_8L,cycles_16L,speedup_8L_over_4L,speedup_16L_over_4L,'
                'speedup_16L_over_8L\n')
        for s, case, c in rows:
            ok = all(c[L] for L in CFG)
            f.write(f'{s},{case},{c[4] or ""},{c[8] or ""},{c[16] or ""},'
                    + (f'{c[4] / c[8]:.3f},{c[4] / c[16]:.3f},{c[8] / c[16]:.3f}\n' if ok else ',,\n'))
    return rows


def label(suite, case):
    if suite == 'sync':
        k, n = case.rsplit('_', 1)
        return NAME.get(k, k), SIZE.get(int(n), n)
    return NAME.get(case, case), None


def plot(suite, rows):
    sel = {case: c for s, case, c in rows if s == suite and all(c[L] for L in CFG)}
    if not sel:
        print(f'{suite}: no complete cases yet')
        return
    keys, groups = [], []                       # groups: (first index, last index, kernel name)
    for k in ORDER[suite]:
        if suite == 'sync':
            ks = [f'{k}_{n}' for n in (1024, 16384, 262144) if f'{k}_{n}' in sel]
            if ks:
                groups.append((len(keys), len(keys) + len(ks) - 1, NAME.get(k, k)))
                keys += ks
        elif k in sel:
            keys.append(k)
    sp = {k: {L: sel[k][4] / sel[k][L] for L in CFG} for k in keys}
    g = {L: gmean([sp[k][L] for k in keys]) for L in CFG}
    wide = len(keys) + 1 > 9
    fig, ax = plt.subplots(figsize=(7.16 if wide else 3.5, 2.45 if suite == 'sync' else 2.3))
    bw = 0.26
    xs, gap = [], 0.0
    for i, k in enumerate(keys + ['_gm']):
        if suite == 'sync' and any(i == a for a, _, _ in groups[1:]):
            gap += 0.45                         # space between kernels
        x = i + gap + (0.7 if k == '_gm' else 0.0)
        xs.append(x)
        vals = g if k == '_gm' else sp[k]
        for j, L in enumerate((4, 8, 16)):
            ax.bar(x + (j - 1) * bw, vals[L], bw * 0.92, color=RAMP3[j], linewidth=0, zorder=2,
                   label=f'{L} lanes' if i == 0 else None)
            if L != 4:
                ax.text(x + (j - 1) * bw, vals[L] + 0.07, f'{vals[L]:.2f}', ha='center', va='bottom',
                        fontsize=5.2, color=INK, rotation=90, zorder=4,
                        bbox=dict(boxstyle='square,pad=0.08', fc='white', ec='none'))
    for yv in (2.0, 4.0):
        ax.axhline(yv, color=MUTED, lw=0.6, ls=(0, (3, 2)), zorder=1)
    ax.plot([], [], color=MUTED, lw=0.6, ls=(0, (3, 2)), label='ideal (2\u00d7, 4\u00d7)')
    ax.axvline((xs[-2] + xs[-1]) / 2, color='#cfcfcf', lw=0.6, zorder=0)
    if suite == 'sync':
        ax.set_xticks(xs)
        ax.set_xticklabels([label(suite, k)[1] for k in keys] + ['Geo. mean'], fontsize=6.6)
        ax.tick_params(axis='x', length=0, pad=2)
        for a, b, name in groups:
            ax.text((xs[a] + xs[b]) / 2, -0.105, name, transform=ax.get_xaxis_transform(),
                    ha='center', va='top', fontsize=7.2, color=INK)
            if b < len(keys) - 1:
                ax.axvline((xs[b] + xs[b + 1]) / 2, color='#e4e4e4', lw=0.6, zorder=0)
    else:
        ax.set_xticks(xs)
        ax.set_xticklabels([label(suite, k)[0] for k in keys] + ['Geo. mean'], rotation=40,
                           ha='right', rotation_mode='anchor', fontsize=6.8)
        ax.tick_params(axis='x', length=0, pad=3)
    ax.set_xlim(xs[0] - 0.6, xs[-1] + 0.6)
    top = max(4.7, max(max(sp[k][16] for k in keys), g[16]) + 0.8)
    ax.set_ylim(0, top)
    ax.set_yticks([0, 1, 2, 3, 4])
    ax.set_ylabel('Speedup over 4 lanes')
    ax.set_xlabel({'apps': 'Application', 'rodinia': 'Benchmark', 'rivec': 'Application',
                   'suite2': 'Benchmark', 'sync': 'Kernel and number of threads'}[suite],
                  labelpad=17 if suite == 'sync' else 3)
    hs, ls = ax.get_legend_handles_labels()
    order = [ls.index(f'{L} lanes') for L in (4, 8, 16)] + [i for i, l in enumerate(ls) if 'ideal' in l]
    ax.legend([hs[i] for i in order], [ls[i] for i in order], loc='lower left',
              bbox_to_anchor=(0.0, 1.0), ncol=4, handlelength=1.3, columnspacing=1.1,
              borderaxespad=0.1)
    out = os.path.join(HERE, 'figs', f'lanes_{suite}.pdf')
    if wide:
        fig.savefig(out)
        fig.savefig(out.replace('.pdf', '.png'), dpi=200)
    else:
        # the narrow panels sit side by side in the paper: same margins, no tight crop, so
        # their axes line up whatever the length of their tick labels
        fig.subplots_adjust(left=0.115, right=0.99, bottom=0.30, top=0.89)
        ax.xaxis.set_label_coords(0.5, -0.43)       # same height in both panels
        fig.canvas.draw()
        lo = ax.xaxis.label.get_window_extent().y0 / fig.bbox.height
        assert lo > 0, f'{suite}: x-label clipped ({lo:.3f})'
        fig.savefig(out, bbox_inches=fig.bbox_inches)
        fig.savefig(out.replace(".pdf", ".png"), dpi=200, bbox_inches=fig.bbox_inches)
    plt.close(fig)
    print(f'{suite}: {len(keys)} benchmarks; geomean 8L {g[8]:.2f}x, 16L {g[16]:.2f}x over 4 lanes -> {out}')


def main():
    plot_style.apply()
    rows = collect()
    for s in SUITES:
        plot(s, rows)


if __name__ == '__main__':
    main()
