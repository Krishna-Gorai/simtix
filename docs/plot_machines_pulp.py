#!/usr/bin/env python3
"""plot_machines_pulp.py - SIMTiX against CVA6, Ara and Vortex, in the plotting style of the PULP
papers (Ara, TVLSI 2020; Ara2's relative-throughput plot; Spatz/MemPool rooflines):

  * full box frame, ticks inside, light grid; log2 axis with power-of-two ticks;
  * one marker shape AND colour per machine, open markers (Spatz/MemPool rooflines);
  * a bold reference line (here parity, 1x) with the region below it lightly shaded
    ("the other machine is faster"), as the rooflines shade the region under the peak;
  * kernel names as rotated tick labels; key values (geometric means) printed on the plot;
  * one boxed legend below the panels.

One panel per suite (applications, suite 2, Rodinia, RiVEC), each benchmark at its largest board
input. Open markers: the eight-lane SIMTiX; small filled markers joined by a thin line: the
16-lane SIMTiX. Same data and exclusions as docs/plot_machines_suites.py.
Writes docs/figs/machines_pulp.pdf (.png).  Usage:  python docs/plot_machines_pulp.py
"""
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import plot_style  # noqa: E402
from plot_style import plt, INK, MUTED  # noqa: E402
import plot_machines_alt as pma  # noqa: E402
from matplotlib.lines import Line2D  # noqa: E402

MACH = [('cva6', 'CVA6', '#1f5fae', 'o'), ('ara', 'Ara', '#d4542a', 's'),
        ('vortex', 'Vortex', '#168a5f', '^')]
OFF = {'cva6': -0.22, 'ara': 0.0, 'vortex': 0.22}
TICKS = [0.25, 0.5, 1, 2, 4, 8, 16, 32, 64, 128, 256, 512]


def style_axis(ax):
    for sp in ax.spines.values():
        sp.set_visible(True)
        sp.set_color(INK)
        sp.set_linewidth(0.6)
    ax.tick_params(direction='in', which='both', top=False, right=True, length=2.5, width=0.6)
    ax.grid(True, axis='y', color='#e3e3e3', lw=0.5)
    ax.grid(False, axis='x')


def panel(ax, rows, suite, title):
    sel = [r for r in rows if r[0] == suite]
    xs, labels, gml = [], [], []
    for i, (_, lab, vals) in enumerate(sel):
        gm = lab == 'Geometric mean'
        x = i + (0.6 if gm else 0.0)
        xs.append(x)
        labels.append('Geomean' if gm else lab)
        for m, _, col, mk in MACH:
            r8, r16, note = vals[m]
            if r8 is None:
                continue
            xx = x + OFF[m]
            ax.plot([xx, xx], [r8, r16], color=col, lw=0.7, alpha=0.7, zorder=2)
            ax.plot(xx, r16, marker=mk, ms=2.6, color=col, mec=col, linestyle='none', zorder=3)
            ax.plot(xx, r8, marker=mk, ms=4.6 if not gm else 5.4, mfc='white', mec=col, mew=1.0,
                    linestyle='none', zorder=4)
            if note == 'dagger':
                ax.text(xx + 0.13, r8, '†', ha='left', va='center', fontsize=6, color=col)
            if gm:
                gml.append([r8, f'{r8:.1f}×', col, x])
    # geometric-mean values: at least a factor 1.4 apart on the log axis, top-down
    gml.sort(key=lambda g: -g[0])
    for i in range(1, len(gml)):
        gml[i][0] = min(gml[i][0], gml[i - 1][0] / 1.4)
    for y, txt, col, x in gml:
        ax.text(x + 0.62, y, txt, ha='left', va='center', fontsize=5.9, color=col)
    ax.set_yscale('log', base=2)
    lo, hi = 0.25, 512
    ax.axhspan(lo, 1.0, color='#f4eceb', zorder=0, lw=0)
    ax.axhline(1.0, color=INK, lw=1.2, zorder=1)
    ax.set_ylim(lo, hi)
    ax.set_yticks(TICKS)
    ax.set_yticklabels([f'{t:g}' for t in TICKS], fontsize=6.6)
    ax.minorticks_off()
    ax.axvline((xs[-2] + xs[-1]) / 2, color=MUTED, lw=0.6, ls=(0, (3, 2)), zorder=1)
    ax.set_xticks(xs)
    ax.set_xticklabels(labels, rotation=90, fontsize=6.6)
    for t in ax.get_xticklabels():
        if t.get_text() == 'Geomean':
            t.set_fontweight('bold')
    ax.set_xlim(xs[0] - 0.6, xs[-1] + 1.6)
    style_axis(ax)
    ax.text(0.0, 1.03, title, transform=ax.transAxes, ha='left', va='bottom', fontsize=7.6,
            fontweight='bold', color=INK)
    ax.text(0.012, 0.028, 'other machine faster', transform=ax.transAxes, ha='left', va='bottom',
            fontsize=5.8, color='#a0605a', style='italic')


def main():
    plot_style.apply()
    rows = pma.table()
    fig, axes = plt.subplots(2, 2, figsize=(7.16, 5.0),
                             gridspec_kw={'width_ratios': [13.6, 11.6], 'hspace': 0.72, 'wspace': 0.14})
    for ax, (s, t) in zip(axes.flat, [('apps', '(a) Applications'), ('suite2', '(b) Suite 2'),
                                      ('rodinia', '(c) Rodinia'), ('rivec', '(d) RiVEC')]):
        panel(ax, rows, s, t)
    for ax in axes[:, 0]:
        ax.set_ylabel('Speed-up of SIMTiX')
    hs = [Line2D([0], [0], marker=mk, mfc='white', mec=col, mew=1.0, linestyle='none', ms=5,
                 label=f'{name}') for _, name, col, mk in MACH]
    hs += [Line2D([0], [0], marker='o', mfc='white', mec=INK, mew=1.0, linestyle='none', ms=5,
                  label='8-lane SIMTiX (open)'),
           Line2D([0], [0], marker='o', color=INK, ms=2.6, linestyle='-', lw=0.7,
                  label='16-lane SIMTiX (filled)')]
    leg = fig.legend(handles=hs, loc='lower center', bbox_to_anchor=(0.5, -0.005), ncol=5,
                     frameon=True, fancybox=False, edgecolor=INK, handlelength=1.6,
                     columnspacing=1.6, borderpad=0.45)
    leg.get_frame().set_linewidth(0.6)
    fig.subplots_adjust(bottom=0.17, top=0.955, left=0.07, right=0.985)
    out = os.path.join(HERE, 'figs', 'machines_pulp.pdf')
    fig.savefig(out)
    fig.savefig(out.replace('.pdf', '.png'), dpi=200)
    print('written', out)


if __name__ == '__main__':
    main()
