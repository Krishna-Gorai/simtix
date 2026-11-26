#!/usr/bin/env python3
"""plot_ideality.py - raw throughput ideality of SIMTiX's kernels, in the style of Ara2
(Perotti et al., IEEE Trans. Comput., 2024, Figs. 5 and 6).

Raw throughput ideality = achieved useful operations per cycle / peak per cycle, with the peak
2L FP32 FLOP (an FMA counts 2), 4L INT8 MAC (pdot8) or L lane operations per cycle for L lanes
(the metric of each kernel as in docs/plot_throughput.py).

Reads docs/throughput_sweep.csv (sim/throughput_sweep.py, then --reparse for the L1 columns)
and writes
  docs/figs/ideality_heatmap.pdf  one heatmap per lane count: kernels x problem size, the
                                  ideality written in each cell (Ara2 Fig. 5); the sizes of a
                                  kernel are aligned on its board input (rightmost column)
  docs/figs/ideality_bars.pdf     ideality of each kernel at its board input for 4, 8 and 16
                                  lanes, with the average, and the L1 read miss rate at 8 lanes
                                  on a second axis (Ara2 Fig. 6)
Usage:  python docs/plot_ideality.py [--csv docs/throughput_sweep.csv]
"""
import argparse
import collections
import csv
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import plot_style  # noqa: E402
from plot_style import plt, INK, MUTED  # noqa: E402
import numpy as np  # noqa: E402

OUT = os.path.join(HERE, 'figs')
# app: (name, size symbol, metric)
APPS = [('gemm', 'GEMM', 'n', 'flop'), ('gemmrb', 'GEMM-RB', 'n', 'flop'),
        ('stencil', 'Stencil', 'side', 'flop'), ('stencilrb', 'Stencil-RB', 'side', 'flop'),
        ('embag', 'Embedding bag', 'bags', 'flop'), ('spmv', 'SpMV', 'rows', 'flop'),
        ('spmvz', 'SpMV-Z', 'rows', 'flop'), ('conv8', 'CNN (INT8)', 'side', 'mac8'),
        ('mlp', 'MLP (INT8)', 'batch', 'mac8'), ('kmeans', 'k-means', 'points', 'laneops'),
        ('kmeansu', 'k-means-U', 'points', 'laneops'), ('bfs', 'BFS', 'vertices', 'laneops'),
        ('scan', 'Scan', 'elements', 'laneops'), ('scanseg', 'Segm. scan', 'elements', 'laneops'),
        ('hashj', 'Hash join', 'probes', 'laneops')]
PEAK = {'flop': 2, 'mac8': 4, 'laneops': 1}
LANES = [4, 8, 16]
BLUES = ['#9ec5f0', '#2a78d6', '#0d3a73']                 # 4, 8, 16 lanes: light to dark
GOLD = '#d29a00'


def k(v):
    return '%dk' % (v // 1024) if v >= 1024 and v % 1024 == 0 else str(v)


def load(path):
    d = collections.defaultdict(dict)
    for r in csv.DictReader(open(path)):
        d[(r['app'], int(r['lanes']))][int(r['size'])] = r
    return d


def ideality(r, met, lanes):
    return int(r[met]) / int(r['cycles']) / (PEAK[met] * lanes)


def lum_text(rgba):
    r, g, b = rgba[:3]
    return 'white' if 0.2126 * r + 0.7152 * g + 0.0722 * b < 0.5 else INK


def heatmap(d, lanes_list):
    ncol = max(len({s for L in lanes_list for s in d.get((a, L), {})}) for a, *_ in APPS)
    fig, axes = plt.subplots(1, len(lanes_list), figsize=(7.16, 3.55), sharey=True)
    cmap = plt.get_cmap('viridis')
    for p, (ax, L) in enumerate(zip(np.atleast_1d(axes), lanes_list)):
        m = np.full((len(APPS), ncol), np.nan)
        for i, (app, name, sym, met) in enumerate(APPS):
            sizes = sorted({s for LL in lanes_list for s in d.get((app, LL), {})})
            off = ncol - len(sizes)                       # right-align on the board input
            for j, s in enumerate(sizes):
                r = d.get((app, L), {}).get(s)
                if r:
                    m[i, off + j] = ideality(r, met, L)
        ax.imshow(np.ma.masked_invalid(m), cmap=cmap, vmin=0, vmax=1, aspect='auto')
        for i in range(m.shape[0]):
            for j in range(m.shape[1]):
                v = m[i, j]
                if np.isnan(v):
                    continue
                ax.text(j, i, '%.2f' % v, ha='center', va='center', fontsize=5.6,
                        color=lum_text(cmap(v)))
        ax.set_xticks(range(ncol))
        ax.set_xticklabels(['S%d' % (c + 1) for c in range(ncol - 1)] + ['board'], fontsize=6.5)
        ax.tick_params(length=0)
        ax.grid(False)
        for sp in ax.spines.values():
            sp.set_visible(False)
        ax.set_xlabel('(%s) %d lanes: problem size' % (chr(97 + p), L), fontsize=7, labelpad=3)
        if p == 0:
            labels = []
            for app, name, sym, met in APPS:
                sizes = sorted({s for LL in lanes_list for s in d.get((app, LL), {})})
                labels.append('%s, %s %s–%s' % (name, sym, k(sizes[0]), k(sizes[-1])) if sizes else name)
            ax.set_yticks(range(len(APPS)))
            ax.set_yticklabels(labels, fontsize=6.3)
    fig.tight_layout(w_pad=0.4, rect=(0, 0, 0.93, 1))
    cax = fig.add_axes([0.945, 0.2, 0.012, 0.7])
    sm = plt.cm.ScalarMappable(cmap=cmap, norm=plt.Normalize(0, 1))
    cb = fig.colorbar(sm, cax=cax)
    cb.ax.tick_params(labelsize=6.2, length=2)
    cb.outline.set_visible(False)
    cb.set_label('raw throughput ideality', fontsize=6.8)
    out = os.path.join(OUT, 'ideality_heatmap.pdf')
    fig.savefig(out)
    fig.savefig(out.replace('.pdf', '.png'), dpi=200)
    print('wrote', out)


def bars(d, lanes_list):
    names, vals, miss = [], {L: [] for L in lanes_list}, []
    for app, name, sym, met in APPS:
        sizes = sorted({s for L in lanes_list for s in d.get((app, L), {})})
        if not sizes:
            continue
        big = sizes[-1]
        names.append(name)
        for L in lanes_list:
            r = d.get((app, L), {}).get(big)
            vals[L].append(ideality(r, met, L) if r else np.nan)
        r8 = d.get((app, 8), {}).get(big)
        if r8 and 'l1_misses' in r8 and r8['l1_misses'] not in ('', None):
            acc = int(r8['l1_hits']) + int(r8['l1_misses'])
            miss.append(100 * int(r8['l1_misses']) / acc if acc else np.nan)
        else:
            miss.append(np.nan)
    names.append('AVG')
    for L in lanes_list:
        vals[L].append(np.nanmean(vals[L]))
    miss.append(np.nan)
    x = np.arange(len(names))
    w = 0.8 / len(lanes_list)
    fig, ax = plt.subplots(figsize=(7.16, 2.35))
    for q, L in enumerate(lanes_list):
        ax.bar(x + (q - (len(lanes_list) - 1) / 2) * w, vals[L], w, color=BLUES[q], label='%d lanes' % L,
               zorder=2, edgecolor='white', linewidth=0.4)
    ax.set_ylim(0, 1.0)
    ax.set_ylabel('Raw throughput ideality')
    ax.set_xticks(x)
    ax.set_xticklabels(names, rotation=35, ha='right', rotation_mode='anchor')
    ax.tick_params(axis='x', length=0)
    ax.axvline(len(names) - 1.5, color='#bbbbbb', lw=0.5, ls=':', zorder=1)
    ax2 = ax.twinx()
    mm = np.array(miss)
    if not np.all(np.isnan(mm)):
        ax2.plot(x, mm, color=GOLD, marker='D', markersize=3.2, lw=0.9, zorder=3,
                 label='L1 read miss rate, 8 lanes')
        ax2.set_ylim(0, max(np.nanmax(mm) * 1.15, 10))
        ax2.set_ylabel('L1 read miss rate (%)', color=GOLD)
        ax2.tick_params(axis='y', colors=GOLD)
        ax2.spines['right'].set_visible(True)
        ax2.spines['right'].set_color(GOLD)
        ax2.grid(False)
    h1, l1 = ax.get_legend_handles_labels()
    h2, l2 = ax2.get_legend_handles_labels()
    ax.legend(h1 + h2, l1 + l2, loc='upper center', ncol=4, bbox_to_anchor=(0.5, 1.17),
              fontsize=7, columnspacing=1.6)
    fig.tight_layout()
    out = os.path.join(OUT, 'ideality_bars.pdf')
    fig.savefig(out)
    fig.savefig(out.replace('.pdf', '.png'), dpi=200)
    print('wrote', out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--csv', default=os.path.join(HERE, 'throughput_sweep.csv'))
    a = ap.parse_args()
    plot_style.apply()
    d = load(a.csv)
    lanes = [L for L in LANES if any(key[1] == L for key in d)]
    heatmap(d, lanes)
    bars(d, lanes)


if __name__ == '__main__':
    main()
