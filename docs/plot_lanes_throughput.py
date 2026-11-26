#!/usr/bin/env python3
"""plot_lanes_throughput.py - throughput of every benchmark at 4, 8 and 16 lanes.

Board-size simulation of the board configuration at each lane count (8 warps, 16 MSHRs, 16 tags,
an L1 of 2,048 lines: 32/64/128 KB, one divide/square-root unit per eight lanes), every output
checked; the per-case logs of sim/run_lanes_board.sh (see plot_lanes_suites.py). Each launch prints
APPCSV,<case>,<tag>,<threads>,<cycles>,<L1 hits>,<L1 misses>,<warp instructions>,<active lanes>.

Throughput = lane operations per cycle = sum of active lanes of the issued warp instructions /
cycles, over all launches of a case (thread instructions executed per cycle). Peak = L.
Ideality = throughput / L (= IPC x lane utilization).

Outputs:
  docs/lanes_throughput.csv
  docs/figs/lanes_throughput.pdf          PULP style (Ara Figs. 5-6): log2 axis, a peak line per
                                          lane count with the region under it shaded, one marker
                                          shape per lane count stacked per benchmark
  docs/figs/lanes_throughput_heatmap.pdf  Ara2 style: cell = throughput, colour = fraction of peak
Usage:  python docs/plot_lanes_throughput.py
"""
import glob
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import plot_style  # noqa: E402
from plot_style import plt, INK, MUTED  # noqa: E402
import plot_lanes_suites as pls  # noqa: E402
from matplotlib.lines import Line2D  # noqa: E402
from matplotlib.colors import LinearSegmentedColormap  # noqa: E402

LANES = (4, 8, 16)
COL = {4: '#86b6ef', 8: '#2a78d6', 16: '#104281'}       # RAMP3, as in the other lane figures
MK = {4: 's', 8: '^', 16: 'o'}
TITLE = {'apps': 'Applications', 'sync': 'Synchronization kernels', 'suite2': 'Suite 2',
         'rodinia': 'Rodinia', 'rivec': 'RiVEC'}


def tp(log):
    cyc = act = 0
    ok = False
    for line in open(log, errors='replace'):
        if line.startswith('APPCSV,'):
            f = line.strip().split(',')
            cyc += int(f[4])
            act += int(f[8])
        if '[tb_apps] PASS' in line:
            ok = True
    return act / cyc if ok and cyc else None


def gmean(v):
    return math.exp(sum(map(math.log, v)) / len(v))


def collect():
    """{suite: [(label, {L: lane-ops/cycle})]} in the order of plot_lanes_suites.ORDER."""
    data = {}
    for suite in pls.SUITES:
        found = {os.path.basename(os.path.dirname(p))
                 for p in glob.glob(os.path.join(pls.ROOT, 'build_b8', suite, '*', 'apps.manifest'))}
        keys = []
        for k in pls.ORDER[suite]:
            if suite == 'sync':
                keys += [f'{k}_{n}' for n in (1024, 16384, 262144) if f'{k}_{n}' in found]
            elif k in found:
                keys.append(k)
        rows = []
        for case in keys:
            v = {}
            for L in LANES:
                p = os.path.join(pls.ROOT, f'build_b{L}', suite, case, pls.CFG[L])
                v[L] = tp(p) if os.path.isfile(p) else None
            if all(v.values()):
                name, size = pls.label(suite, case)
                rows.append((f'{name} {size}' if size else name, case, v))
        data[suite] = rows
    with open(os.path.join(HERE, 'lanes_throughput.csv'), 'w', newline='\n') as f:
        f.write('suite,case,laneops_per_cycle_4L,laneops_per_cycle_8L,laneops_per_cycle_16L,'
                'ideality_4L,ideality_8L,ideality_16L\n')
        for s, rows in data.items():
            for _, case, v in rows:
                f.write(f'{s},{case},' + ','.join(f'{v[L]:.3f}' for L in LANES) + ','
                        + ','.join(f'{v[L] / L:.3f}' for L in LANES) + '\n')
    return data


def style_axis(ax):
    for sp in ax.spines.values():
        sp.set_visible(True)
        sp.set_color(INK)
        sp.set_linewidth(0.6)
    ax.tick_params(direction='in', which='both', right=True, length=2.5, width=0.6)
    ax.grid(False)


SHORT = {'Hist. (shared)': 'Hist. (shared)', 'AMO contention': 'AMO contention'}


def chains(ax, rows, title, grouped=False):
    gm = {L: gmean([v[L] for _, _, v in rows]) for L in LANES}
    items = [(lab, v) for lab, _, v in rows] + [('Geomean', gm)]
    xs, gap, groups = [], 0.0, []                # groups (sync): (first, last, kernel name)
    for i, (lab, _) in enumerate(items):
        if grouped and lab != 'Geomean':
            kern = rows[i][1].rsplit('_', 1)[0]
            if not groups or groups[-1][2] != kern:
                if groups:
                    gap += 0.5
                groups.append([i, i, kern])
            groups[-1][1] = i
        xs.append(i + gap + (0.7 if lab == 'Geomean' else 0.0))
    lo, hi = 0.25, 26
    for L in LANES:                              # peak lines, region under each roof shaded
        ax.axhspan(lo, L, color=COL[L], alpha=0.07, lw=0, zorder=0)
        ax.axhline(L, color=COL[L], lw=1.1, zorder=1)
    for x, (lab, v) in zip(xs, items):
        ax.plot([x, x], [v[4], v[16]], color='#8a8a8a', lw=0.6, zorder=2)
        for L in LANES:
            ax.plot(x, v[L], marker=MK[L], ms=4.2 if lab != 'Geomean' else 5.0, mfc=COL[L],
                    mec=INK, mew=0.5, linestyle='none', zorder=3)
    for L in LANES:
        ax.text(xs[-1] + 0.32, gm[L], f'{gm[L]:.1f}', ha='left', va='center', fontsize=6.0,
                color=COL[L] if L != 4 else '#4a86c8', fontweight='bold')
    ax.axvline((xs[-2] + xs[-1]) / 2, color=MUTED, lw=0.6, ls=(0, (3, 2)), zorder=1)
    ax.set_yscale('log', base=2)
    ax.set_ylim(lo, hi)
    ticks = [0.25, 0.5, 1, 2, 4, 8, 16]
    ax.set_yticks(ticks)
    ax.set_yticklabels([f'{t:g}' for t in ticks], fontsize=6.6)
    ax.minorticks_off()
    ax.set_xticks(xs)
    if grouped:                                  # sizes as ticks, kernel names below
        ax.set_xticklabels([lab.rsplit(' ', 1)[1] if lab != 'Geomean' else 'Geomean'
                            for lab, _ in items], fontsize=6.2)
        for a, b, kern in groups:
            name = pls.NAME.get(kern, kern).replace(' (', '\n(').replace('AMO c', 'AMO\nc')
            ax.text((xs[a] + xs[b]) / 2, -0.09, name, transform=ax.get_xaxis_transform(),
                    ha='center', va='top', fontsize=6.8, color=INK, linespacing=0.95)
            if b < len(rows) - 1:
                ax.axvline((xs[b] + xs[b + 1]) / 2, color='#c8c8c8', lw=0.5, zorder=1)
    else:
        ax.set_xticklabels([lab for lab, _ in items], rotation=90, fontsize=6.4)
    for t in ax.get_xticklabels():
        if t.get_text() == 'Geomean':
            t.set_fontweight('bold')
    ax.set_xlim(xs[0] - 0.7, xs[-1] + 1.3)
    style_axis(ax)
    ax.tick_params(axis='x', length=0, pad=2)
    ax.text(0.0, 1.03, title, transform=ax.transAxes, ha='left', va='bottom', fontsize=7.6,
            fontweight='bold', color=INK)
    return gm


def figure_chains(data):
    fig = plt.figure(figsize=(7.16, 7.1))
    gs = fig.add_gridspec(3, 2, height_ratios=[1, 1, 1], hspace=0.95, wspace=0.12,
                          width_ratios=[11.6, 9.6])
    axes = {'apps': fig.add_subplot(gs[0, :]), 'suite2': fig.add_subplot(gs[1, 0]),
            'rodinia': fig.add_subplot(gs[1, 1]), 'sync': fig.add_subplot(gs[2, 0]),
            'rivec': fig.add_subplot(gs[2, 1])}
    letters = {'apps': 'a', 'suite2': 'b', 'rodinia': 'c', 'sync': 'd', 'rivec': 'e'}
    gms = {}
    for s, ax in axes.items():
        gms[s] = chains(ax, data[s], f'({letters[s]}) {TITLE[s]}', grouped=(s == 'sync'))
    for s in ('apps', 'suite2', 'sync'):
        axes[s].set_ylabel('Lane operations per cycle')
    hs = [Line2D([0], [0], color=COL[L], lw=1.1, marker=MK[L], mfc=COL[L], mec=INK, mew=0.5,
                 ms=4.6, label=f'{L} lanes (marker) and peak {L} (line)') for L in LANES]
    leg = fig.legend(handles=hs, loc='lower center', bbox_to_anchor=(0.5, 0.0), ncol=3,
                     frameon=True, fancybox=False, edgecolor=INK, handlelength=2.2,
                     columnspacing=1.8, borderpad=0.45)
    leg.get_frame().set_linewidth(0.6)
    fig.subplots_adjust(top=0.965, bottom=0.115, left=0.075, right=0.985)
    out = os.path.join(HERE, 'figs', 'lanes_throughput.pdf')
    fig.savefig(out)
    fig.savefig(out.replace('.pdf', '.png'), dpi=200)
    plt.close(fig)
    print('written', out)
    return gms


CMAPS = {
    'blue': LinearSegmentedColormap.from_list('blue', ['#f7fbff', '#c6dbef', '#6baed6', '#2171b5',
                                                       '#08306b']),
    'green': LinearSegmentedColormap.from_list('green', ['#f7fcf5', '#c7e9c0', '#74c476',
                                                         '#238b45', '#00441b']),
    'viridis': plt.get_cmap('viridis'),
    'warm': LinearSegmentedColormap.from_list('warm', ['#ffffcc', '#fed976', '#fd8d3c', '#e31a1c',
                                                       '#800026']),
}
DEFAULT_CMAP = 'viridis'                  # chosen by the authors, 2026-11-20


def text_color(rgba):
    """white text on dark cells, ink on light ones (relative luminance)"""
    r, g, b = rgba[:3]
    return 'white' if 0.2126 * r + 0.7152 * g + 0.0722 * b < 0.5 else INK


def figure_heatmap(data, cname=DEFAULT_CMAP, suffix=''):
    cmap = CMAPS[cname]
    split = [('apps',), ('sync', 'rivec'), ('suite2', 'rodinia')]
    fig, axes = plt.subplots(1, 3, figsize=(7.16, 4.7))
    ymax = []
    for ax, suites in zip(axes, split):
        y, ys, labels = 0.0, [], []
        for s in suites:
            rows = data[s]
            ax.text(-0.62, y, TITLE[s] if s != 'sync' else 'Synchronization', ha='right',
                    va='center', fontsize=7.4, fontweight='bold', color=INK)
            y += 1.0
            gm = {L: gmean([v[L] for _, _, v in rows]) for L in LANES}
            for lab, _, v in rows + [('Geometric mean', None, gm)]:
                ys.append(y)
                labels.append(lab)
                for c, L in enumerate(LANES):
                    idl = v[L] / L
                    rgba = cmap(min(idl, 1.0))
                    ax.add_patch(plt.Rectangle((c - 0.47, y - 0.47), 0.94, 0.94,
                                               color=rgba, lw=0))
                    ax.text(c, y, f'{v[L]:.1f}' if v[L] >= 1 else f'{v[L]:.2f}', ha='center',
                            va='center', fontsize=5.9, color=text_color(rgba),
                            fontweight='bold' if lab == 'Geometric mean' else 'normal')
                if lab == 'Geometric mean':
                    ax.add_patch(plt.Rectangle((-0.5, y - 0.5), 3.0, 1.0, fill=False, ec=INK,
                                               lw=0.6))
                y += 1.0
        ymax.append(y)
        ax.set_yticks(ys)
        ax.set_yticklabels(labels, fontsize=6.5)
        for t in ax.get_yticklabels():
            if t.get_text() == 'Geometric mean':
                t.set_fontweight('bold')
        ax.set_xticks(range(3))
        ax.set_xticklabels([f'{L} lanes' for L in LANES], fontsize=6.8)
        ax.xaxis.tick_top()
        ax.tick_params(length=0, pad=2)
        ax.set_xlim(-0.55, 2.55)
        for sp in ax.spines.values():
            sp.set_visible(False)
        ax.grid(False)
    for ax in axes:
        ax.set_ylim(max(ymax) - 0.5, -0.6)
    fig.subplots_adjust(wspace=0.95, top=0.94, bottom=0.11, left=0.10, right=0.985)
    cax = fig.add_axes([0.30, 0.045, 0.40, 0.018])
    sm = plt.cm.ScalarMappable(cmap=cmap, norm=plt.Normalize(0, 1))
    cb = fig.colorbar(sm, cax=cax, orientation='horizontal')
    cb.set_ticks([0, 0.25, 0.5, 0.75, 1.0])
    cb.set_ticklabels(['0', '25%', '50%', '75%', '100%'])
    cb.ax.tick_params(labelsize=6.4, length=2)
    cb.outline.set_linewidth(0.5)
    cb.set_label('Fraction of the peak of L lane operations per cycle (cell: lane operations '
                 'per cycle)', fontsize=6.8)
    out = os.path.join(HERE, 'figs', f'lanes_throughput_heatmap{suffix}.pdf')
    fig.savefig(out)
    fig.savefig(out.replace('.pdf', '.png'), dpi=200)
    plt.close(fig)
    print('written', out)


def main():
    plot_style.apply()
    data = collect()
    gms = figure_chains(data)
    figure_heatmap(data)                               # viridis
    for s, g in gms.items():
        print(f'{s:8s} {len(data[s]):2d} cases  geomean lane-ops/cycle ' +
              '  '.join(f'{L}L {g[L]:5.2f} ({g[L] / L:4.0%})' for L in LANES))


if __name__ == '__main__':
    main()
