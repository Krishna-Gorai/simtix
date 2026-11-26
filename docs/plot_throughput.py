#!/usr/bin/env python3
"""plot_throughput.py - throughput of each application kernel against problem size, at 4, 8
and 16 lanes, in the style of Ara's performance plots (Cavalcante et al., TVLSI 2020).

Reads docs/throughput_sweep.csv (sim/throughput_sweep.py: the board configuration in
simulation, 8 warps, 64 KB L1, 16 MSHRs, 24-cycle AXI4 memory). One panel per kernel:
x = problem size (log axis), y = useful operations per cycle:
  FP32 FLOP/cycle (an FMA counts 2)     GEMM, GEMM-RB, SpMV, SpMV-Z, stencil, stencil-RB,
                                        embedding bag
  INT8 MAC/cycle (pdot8: 4 per lane)    MLP, CNN
  lane operations/cycle                 k-means, k-means-U (integer), BFS, scan, segmented scan, hash join
Solid lines: 4, 8, 16 lanes; dashed lines of the same colour: that lane count's peak
(2L FLOP, 4L MAC or L lane operations per cycle).
Produces docs/figs/throughput.pdf (and .png).  Usage:  python docs/plot_throughput.py
"""
import collections
import csv
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import plot_style  # noqa: E402
from plot_style import plt, INK, MUTED  # noqa: E402

CSV = os.path.join(HERE, 'throughput_sweep.csv')
OUT = os.path.join(HERE, 'figs', 'throughput.pdf')
LANES = [(4, '#86b6ef', 'o'), (8, '#2a78d6', 's'), (16, '#104281', '^')]
# app: (panel name, size label, metric)
APPS = [('gemm', 'GEMM', '$n$ ($n^3$)', 'flop'), ('gemmrb', 'GEMM-RB', '$n$ ($n^3$)', 'flop'),
        ('stencil', 'Stencil', 'grid side', 'flop'), ('stencilrb', 'Stencil-RB', 'grid side', 'flop'),
        ('embag', 'Embedding bag', 'bags', 'flop'),
        ('spmv', 'SpMV', 'rows', 'flop'), ('spmvz', 'SpMV-Z', 'rows', 'flop'),
        ('conv8', 'CNN (INT8)', 'image side', 'mac8'), ('mlp', 'MLP (INT8)', 'batch', 'mac8'),
        ('kmeans', 'k-means', 'points', 'laneops'),
        ('kmeansu', 'k-means-U', 'points', 'laneops'), ('bfs', 'BFS', 'vertices', 'laneops'),
        ('scan', 'Scan', 'elements', 'laneops'), ('scanseg', 'Segmented scan', 'elements', 'laneops'),
        ('hashj', 'Hash join', 'probes', 'laneops')]
UNIT = {'flop': 'FLOP/cycle', 'mac8': 'MAC/cycle', 'laneops': 'lane-op/cycle'}
PEAK = {'flop': 2, 'mac8': 4, 'laneops': 1}               # per lane per cycle


def fmt_size(v):
    return '%dk' % (v // 1024) if v >= 1024 and v % 1024 == 0 else str(v)


def main():
    plot_style.apply()
    data = collections.defaultdict(list)
    for r in csv.DictReader(open(CSV)):
        data[(r['app'], int(r['lanes']))].append(r)
    fig, axes = plt.subplots(3, 5, figsize=(7.16, 5.2))
    for k, (app, name, xl, met) in enumerate(APPS):
        ax = axes[k // 5][k % 5]
        xs_all = set()
        ymax = 0
        for lanes, col, mk in LANES:
            rows = sorted(data.get((app, lanes), []), key=lambda r: int(r['size']))
            if not rows:
                continue
            xs = [int(r['size']) for r in rows]
            ys = [int(r[met]) / int(r['cycles']) for r in rows]
            xs_all.update(xs)
            ax.plot(xs, ys, color=col, marker=mk, markersize=3.2, lw=1.1, zorder=3,
                    label=f'{lanes} lanes' if k == 0 else None)
            peak = PEAK[met] * lanes
            ax.axhline(peak, color=col, lw=0.8, ls=(0, (3, 2)), zorder=2)
            ymax = max(ymax, peak)
        ax.set_xscale('log', base=2)
        if xs_all:
            ticks = sorted(xs_all)
            ax.set_xticks(ticks)
            ax.set_xticklabels([fmt_size(v) for v in ticks], fontsize=6.2)
            ax.set_xlim(min(ticks) / 1.25, max(ticks) * 1.25)
        ax.minorticks_off()
        ax.set_ylim(0, ymax * 1.08 if ymax else 1)
        from matplotlib.ticker import MaxNLocator
        ax.yaxis.set_major_locator(MaxNLocator(nbins=4, integer=True))
        ax.tick_params(axis='y', labelsize=6.2)
        ax.set_xlabel(f'({chr(97 + k)}) {name}, {xl}', fontsize=7, labelpad=2)
        ax.set_ylabel(UNIT[met], fontsize=6.5, labelpad=1)
    h, l = axes[0][0].get_legend_handles_labels()
    from matplotlib.lines import Line2D
    h.append(Line2D([], [], color=MUTED, lw=0.8, ls=(0, (3, 2))))
    l.append('peak (same colour)')
    fig.legend(h, l, loc='upper center', ncol=4, bbox_to_anchor=(0.5, 1.02), handlelength=2.0,
               columnspacing=1.6, fontsize=7)
    fig.tight_layout(h_pad=0.9, w_pad=0.6, rect=(0, 0, 1, 0.97))
    fig.savefig(OUT)
    fig.savefig(OUT.replace('.pdf', '.png'), dpi=200)
    print('wrote', OUT)


if __name__ == '__main__':
    main()
