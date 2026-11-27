#!/usr/bin/env python3
"""plot_machines_alt.py - SIMTiX against CVA6, Ara, Vortex and FGPU, all suites in one figure, two forms:

  docs/figs/machines_dots.pdf     Cleveland dot plot: one row per benchmark (grouped by suite, with
                                  a geometric-mean row per suite), log speed-up axis, one marker per
                                  machine; filled = eight-lane SIMTiX, hollow = 16-lane SIMTiX.
  docs/figs/machines_heatmap.pdf  Fig. 5, annotated heatmap of the FP32 throughput (MFLOP/s, log
                                  viridis): the FP32 operations of each benchmark (the same on
                                  every machine; plot_machines_throughput.bench_list, counted by
                                  SIMTiX's SIMTIX_OPCOUNT counter in simulation) over its time on
                                  the board. Rows = the eight- and 16-lane SIMTiX, CVA6, Ara,
                                  Vortex, FGPU and the A53 (-O2 reference); columns = the 17
                                  benchmarks that compute in FP32, at their largest input; n/a for
                                  Ara's MLP and Smith-W. (wrong outputs). Replaces the speedup heatmap and then
                                  the execution-time heatmap (authors' requests, 2026-11-23); those
                                  are kept as heatmap_speedup() and heatmap_time() (not in the paper).
FGPU (docs/fgpu_plan.md) at 187.48 MHz: times from rodinia_results.csv, rivec_results.csv,
ara_cva6_simtix_comparison.csv (fgpu_us) and zcu102_board_run_apps_fgpu.txt (suite 2).

Same data and rules as docs/plot_machines_suites.py (board times, largest input per benchmark,
Ara's MLP/Smith-Waterman/Mandelbrot and Vortex's suite 2 not available, suite-2 Black-Scholes on
CVA6/Ara daggered). Usage:  python docs/plot_machines_alt.py
"""
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import plot_style  # noqa: E402
from plot_style import plt, INK, MUTED  # noqa: E402
import plot_machines_suites as pms  # noqa: E402
from matplotlib.colors import TwoSlopeNorm, LinearSegmentedColormap  # noqa: E402
from matplotlib.lines import Line2D  # noqa: E402

MACH = [('cva6', 'CVA6', '#2a78d6', 'o'), ('ara', 'Ara', '#eb6834', 's'),
        ('vortex', 'Vortex', '#1baf7a', '^'), ('fgpu', 'FGPU', '#8e44ad', 'D')]
SUITES = [('apps', 'Applications'), ('suite2', 'Suite 2'), ('rodinia', 'Rodinia'), ('rivec', 'RiVEC')]
ORDER = {
    'apps': ['gemm', 'conv8', 'stencil', 'mlp', 'swat', 'embag', 'kmeans', 'mandel', 'scan',
             'spmv', 'bfs', 'hashj'],
    'suite2': ['hotspot', 'jacobi2d', 'backprop', 'pathfinder', 'pagerank', 'cc', 'atax', 'bicg',
               'sort', 'blackscholes'],
    'rodinia': ['hotspot3d', 'hotspot', 'backprop', 'kmeans', 'gaussian', 'pathfinder', 'bfs', 'nn'],
    'rivec': ['matmul', 'lavamd', 'axpy', 'jacobi', 'pathfinder', 'spmv', 'blackscholes'],
}


def table():
    """[(suite, label, {m: (r8, r16, note)}) ...] with a geometric-mean row after each suite."""
    rows = pms.collect()
    out = []
    for s, sname in SUITES:
        best = {}
        for r in rows:
            if r[0] == s and (r[1] not in best or r[2] > best[r[1]][2]):
                best[r[1]] = r
        for k in ORDER[s]:
            _, _, _, t8, t16, t, note = best[k]
            vals = {}
            for m, _, _, _ in MACH:
                if t.get(m):
                    vals[m] = (t[m] / t8, t[m] / t16, note.get(m))
                else:
                    vals[m] = (None, None, note.get(m))
            out.append((s, plot_style.bench_label(s, k, pms.NAME.get(k, k)), vals))
        gm = {}
        for m, _, _, _ in MACH:
            v8 = [r[2][m][0] for r in out if r[0] == s and r[2][m][0]]
            v16 = [r[2][m][1] for r in out if r[0] == s and r[2][m][1]]
            gm[m] = (pms.gmean(v8), pms.gmean(v16), 'gm') if v8 else (None, None, None)
        out.append((s, 'Geometric mean', gm))
    return out


def dots(rows):
    fig, axes = plt.subplots(1, 2, figsize=(7.16, 4.35), sharex=True)
    split = [('apps', 'rodinia'), ('suite2', 'rivec')]          # balanced: 23 and 21 rows
    ytop = []
    for ax, suites in zip(axes, split):
        sel = [r for r in rows if r[0] in suites]
        y, ys, labels, heads = 0.0, [], [], []
        for i, (s, lab, vals) in enumerate(sel):
            if i == 0 or sel[i - 1][0] != s:
                heads.append((y, dict(SUITES)[s]))
                y += 1.1
            if lab == 'Geometric mean':
                y += 0.25
            ys.append(y)
            labels.append(lab)
            if lab == 'Geometric mean':
                ax.axhspan(y - 0.5, y + 0.5, color='#eef2f8', zorder=0, lw=0)
            for j, (m, _, col, mk) in enumerate(MACH):
                r8, r16, note = vals[m]
                if r8 is None:
                    continue
                yy = y + (j - (len(MACH) - 1) / 2) * 0.2
                ax.plot([r8, r16], [yy, yy], color=col, lw=0.7, alpha=0.55, zorder=2,
                        solid_capstyle='butt')
                ax.plot(r16, yy, marker=mk, ms=3.6, mfc='white', mec=col, mew=0.9, zorder=3,
                        linestyle='none')
                ax.plot(r8, yy, marker=mk, ms=3.8, color=col, mec=col, zorder=4, linestyle='none')
                if note == 'dagger':
                    ax.text(r8 * 0.86, yy, '†', ha='right', va='center', fontsize=6, color=col)
            y += 1.0
        ax.set_xscale('log')
        ax.axvline(1.0, color=INK, lw=0.7, zorder=1)
        ax.set_yticks(ys)
        ax.set_yticklabels(labels, fontsize=6.8)
        for t in ax.get_yticklabels():
            if t.get_text() == 'Geometric mean':
                t.set_fontweight('bold')
        for yh, name in heads:
            ax.text(0.0, yh + 0.15, name, transform=ax.get_yaxis_transform(), ha='right', va='center',
                    fontsize=7.6, fontweight='bold', color=INK)
            ax.axhline(yh + 0.55, color='#cfcfcf', lw=0.6, zorder=0)
        ytop.append(y)
        ax.tick_params(axis='y', length=0, pad=2)
        ax.grid(True, axis='x', which='major')
        ax.grid(False, axis='y')
        ax.set_xlim(0.22, 600)
        ax.set_xticks([0.25, 0.5, 1, 2, 5, 10, 20, 50, 100, 200, 500])
        ax.set_xticklabels(['0.25', '0.5', '1', '2', '5', '10', '20', '50', '100', '200', '500'])
        ax.minorticks_off()
        ax.set_xlabel('Speedup of SIMTiX (machine time / SIMTiX time)')
        ax.spines['left'].set_visible(False)
    for ax in axes:                                   # equal row spacing in both panels
        ax.set_ylim(max(ytop) - 0.3, -0.6)
    hs = [Line2D([0], [0], marker=mk, color=col, linestyle='none', ms=4.2, label=name)
          for _, name, col, mk in MACH]
    hs += [Line2D([0], [0], marker='o', mfc=INK, mec=INK, linestyle='none', ms=4, label='8-lane SIMTiX'),
           Line2D([0], [0], marker='o', mfc='white', mec=INK, linestyle='none', ms=4, label='16-lane SIMTiX')]
    fig.subplots_adjust(wspace=0.42, top=0.94)
    fig.legend(handles=hs, loc='upper center', bbox_to_anchor=(0.5, 1.0), ncol=6, handlelength=1.0,
               columnspacing=1.4, borderaxespad=0.0)
    out = os.path.join(HERE, 'figs', 'machines_dots.pdf')
    fig.savefig(out)
    fig.savefig(out.replace('.pdf', '.png'), dpi=200)
    plt.close(fig)
    print('written', out)


def lum_text(rgba):
    r, g, b = rgba[:3]
    return 'white' if 0.2126 * r + 0.7152 * g + 0.0722 * b < 0.5 else INK


TCOLS = [('s8', '8L'), ('s16', '16L'), ('cva6', 'CVA6'), ('ara', 'Ara'),
         ('vortex', 'Vortex'), ('fgpu', 'FGPU'), ('a53', 'A53')]


def a53_times():
    """{(suite, app, N): A53 -O2 reference time in us} from the three result CSVs"""
    import csv
    out = {}
    for suite, fn in (('apps', 'ara_cva6_simtix_comparison.csv'), ('rodinia', 'rodinia_results.csv'),
                      ('rivec', 'rivec_results.csv')):
        for r in csv.DictReader(open(os.path.join(HERE, fn))):
            if r.get('a53_O2_us'):
                out[(suite, r['app'], int(r['size']))] = float(r['a53_O2_us'])
    return out


def fmt_ms(v):
    if v < 0.1:
        return f'{v:.3f}'
    if v < 10:
        return f'{v:.2f}'
    if v < 100:
        return f'{v:.1f}'
    return f'{v:,.0f}'


def heatmap_time():
    """Fig. 5: measured execution time of every machine, largest input per benchmark."""
    from matplotlib.colors import LogNorm
    rows = pms.collect()
    a53 = a53_times()
    best = {}
    for r in rows:
        if r[0] != 'suite2' and ((r[0], r[1]) not in best or r[2] > best[(r[0], r[1])][2]):
            best[(r[0], r[1])] = r
    tab = []                                          # (suite, label, {col: ms or None})
    for s, _ in SUITES:
        if s == 'suite2':
            continue
        for k in ORDER[s]:
            _, _, n, t8, t16, t, note = best[(s, k)]
            v = {'s8': t8, 's16': t16, 'a53': a53.get((s, k, n))}
            for m, _, _, _ in MACH:
                v[m] = t.get(m)
            tab.append((s, plot_style.bench_label(s, k, pms.NAME.get(k, k)), {c: (x / 1000.0 if x else None) for c, x in v.items()}))
    allv = [x for _, _, v in tab for x in v.values() if x]
    lo = 10 ** math.floor(math.log10(min(allv)))
    hi = 10 ** math.ceil(math.log10(max(allv)))
    cmap = plt.get_cmap('viridis')
    norm = LogNorm(vmin=lo, vmax=hi)
    fig, axes = plt.subplots(1, 2, figsize=(7.16, 3.2))
    split = [('apps',), ('rodinia', 'rivec')]
    xc = [c + (0.25 if c >= 2 else 0.0) for c in range(len(TCOLS))]   # gap after SIMTiX
    ymax = []
    for ax, suites in zip(axes, split):
        sel = [r for r in tab if r[0] in suites]
        y, ys, labels, heads = 0.0, [], [], []
        for i, (s, lab, vals) in enumerate(sel):
            if i == 0 or sel[i - 1][0] != s:
                heads.append((y, dict(SUITES)[s]))
                y += 1.0
            ys.append(y)
            labels.append(lab)
            for (c, _), x in zip(TCOLS, xc):
                v = vals[c]
                if v is None:
                    ax.add_patch(plt.Rectangle((x - 0.47, y - 0.47), 0.94, 0.94, color='#e9e9e9', lw=0))
                    ax.text(x, y, 'n/a', ha='center', va='center', fontsize=5.6, color=MUTED)
                    continue
                rgba = cmap(norm(v))
                ax.add_patch(plt.Rectangle((x - 0.47, y - 0.47), 0.94, 0.94, color=rgba, lw=0))
                ax.text(x, y, fmt_ms(v), ha='center', va='center', fontsize=5.8, color=lum_text(rgba))
            y += 1.0
        for yh, name in heads:
            ax.text(-0.6, yh, name, ha='right', va='center', fontsize=7.6, fontweight='bold', color=INK)
        ax.set_xlim(-0.55, xc[-1] + 0.55)
        ymax.append(y)
        ax.set_yticks(ys)
        ax.set_yticklabels(labels, fontsize=6.8)
        ax.set_xticks(xc)
        ax.set_xticklabels([n for _, n in TCOLS], fontsize=6.6)
        ax.xaxis.tick_top()
        ax.tick_params(length=0, pad=2)
        for sp in ax.spines.values():
            sp.set_visible(False)
        ax.grid(False)
        ax.text((xc[0] + xc[1]) / 2, -1.45, 'SIMTiX', ha='center', va='bottom', fontsize=6.8,
                color=INK)
        ax.plot([xc[0] - 0.4, xc[1] + 0.4], [-1.42, -1.42], color=INK, lw=0.5, clip_on=False)
    for ax in axes:                                   # equal row heights in both panels
        ax.set_ylim(max(ymax) - 0.5, -0.6)
    fig.subplots_adjust(wspace=0.5, top=0.86, bottom=0.02)
    k = min(range(len(axes)), key=lambda i: ymax[i])          # colour bar under the shorter panel
    bb = axes[k].get_position()
    frac = (max(ymax) - ymax[k] - 0.1) / (max(ymax) + 0.1)
    cax = fig.add_axes([bb.x0 + 0.02, bb.y0 + frac * bb.height * 0.40, bb.width - 0.04, 0.026])
    sm = plt.cm.ScalarMappable(norm=norm, cmap=cmap)
    cb = fig.colorbar(sm, cax=cax, orientation='horizontal')
    ticks = [10 ** e for e in range(int(math.log10(lo)), int(math.log10(hi)) + 1)]
    cb.set_ticks(ticks)
    cb.set_ticklabels([f'{t:g}' if t < 1000 else '$10^{%d}$' % round(math.log10(t)) for t in ticks])
    cb.ax.minorticks_off()
    cb.ax.tick_params(labelsize=6.4, length=2)
    cb.outline.set_linewidth(0.5)
    cb.set_label('Execution time (ms)', fontsize=7.0)
    cb.ax.xaxis.set_label_position('top')
    out = os.path.join(HERE, 'figs', 'machines_heatmap_time.pdf')
    fig.savefig(out)
    fig.savefig(out.replace('.pdf', '.png'), dpi=200)
    plt.close(fig)
    print('written', out, 'range %.3f .. %.0f ms' % (min(allv), max(allv)))


TP_ROWS = [('s8', 'SIMTiX, 8 lanes'), ('s16', 'SIMTiX, 16 lanes'), ('cva6', 'CVA6'), ('ara', 'Ara'),
           ('vortex', 'Vortex'), ('fgpu', 'FGPU'), ('a53', 'Cortex-A53')]
TP_LAB = {'GEMM-RB': 'GEMM', 'SpMV-Z': 'SpMV', 'Stencil-RB': 'Stencil'}   # SIMTiX's kernel -> app


def fmt_tp(v):
    if v >= 100:
        return f'{v:,.0f}'
    if v >= 10:
        return f'{v:.1f}'
    return f'{v:.2f}'


def heatmap_throughput():
    """Fig. 5: FP32 throughput of every machine, MFLOP/s = FP32 operations / board time."""
    import csv
    import plot_machines_throughput as pmt
    from matplotlib.colors import LogNorm
    rows = pms.collect()
    a53 = a53_times()
    times = {}
    for s_, k, n, t8, t16, t, note in rows:
        times[(s_, k, n)] = dict({'s8': t8, 's16': t16, 'a53': a53.get((s_, k, n))},
                                 **{m: t.get(m) for m, _, _, _ in MACH})
    cols, keys = [], []                               # (suite, label, N, {row: MFLOP/s}); (key, size)
    for s_, lab, key, n, nfun in pmt.bench_list():
        N = nfun()
        t = times[(s_, key, n)]
        cols.append((s_, plot_style.bench_label(s_, key, TP_LAB.get(lab, lab)), N,
                     {r: (N / t[r] if t.get(r) else None)
                                                   for r, _ in TP_ROWS}))
        keys.append((key, n))
    with open(os.path.join(HERE, 'machines_throughput.csv'), 'w', newline='\n') as f:
        w = csv.writer(f, lineterminator='\n')
        w.writerow(['suite', 'benchmark', 'key', 'size', 'fp32_ops'] + [f'{r}_mflops' for r, _ in TP_ROWS])
        for (s_, lab, N, v), (key, n) in zip(cols, keys):
            w.writerow([s_, lab, key, n, N] + [f'{v[r]:.3f}' if v[r] else '' for r, _ in TP_ROWS])
    allv = [x for _, _, _, v in cols for x in v.values() if x]
    lo, hi = 2.0, 2000.0                              # the data: 2.9 .. 1,564 MFLOP/s
    assert lo <= min(allv) and max(allv) <= hi
    cmap = plt.get_cmap('viridis')
    norm = LogNorm(vmin=lo, vmax=hi)
    fig, ax = plt.subplots(figsize=(7.16, 2.3))
    x, xs, heads = 0.0, [], []
    for i, (s_, lab, _, v) in enumerate(cols):
        if i and cols[i - 1][0] != s_:
            x += 0.35
        if i == 0 or cols[i - 1][0] != s_:
            heads.append([s_, x, x])
        heads[-1][2] = x
        xs.append(x)
        for y, (r, _) in enumerate(TP_ROWS):
            val = v[r]
            if val is None:
                ax.add_patch(plt.Rectangle((x - 0.47, y - 0.46), 0.94, 0.92, color='#e9e9e9', lw=0))
                ax.text(x, y, 'n/a', ha='center', va='center', fontsize=5.6, color=MUTED)
                continue
            rgba = cmap(norm(val))
            ax.add_patch(plt.Rectangle((x - 0.47, y - 0.46), 0.94, 0.92, color=rgba, lw=0))
            ax.text(x, y, fmt_tp(val), ha='center', va='center', fontsize=5.6, color=lum_text(rgba))
        x += 1.0
    for s_, a, b in heads:
        ax.text((a + b) / 2, -0.75, dict(SUITES)[s_], ha='center', va='bottom', fontsize=7.4,
                fontweight='bold', color=INK)
    ax.set_xlim(-0.55, xs[-1] + 0.55)
    ax.set_ylim(len(TP_ROWS) - 0.5, -0.55)
    ax.set_yticks(range(len(TP_ROWS)))
    ax.set_yticklabels([n for _, n in TP_ROWS], fontsize=6.8)
    ax.set_xticks(xs)
    ax.set_xticklabels([c[1] for c in cols], rotation=40, ha='right', rotation_mode='anchor',
                       fontsize=6.8)
    ax.tick_params(length=0, pad=2)
    for sp in ax.spines.values():
        sp.set_visible(False)
    ax.grid(False)
    ax.set_xlabel('Benchmark', labelpad=2)
    fig.subplots_adjust(left=0.135, right=0.885, top=0.9, bottom=0.25)
    cax = fig.add_axes([0.9, 0.25, 0.013, 0.65])
    cb = fig.colorbar(plt.cm.ScalarMappable(norm=norm, cmap=cmap), cax=cax)
    ticks = [3, 10, 30, 100, 300, 1000]
    cb.set_ticks(ticks)
    cb.set_ticklabels([f'{t:,}' for t in ticks])
    cb.ax.minorticks_off()
    cb.ax.tick_params(labelsize=6.4, length=2)
    cb.outline.set_linewidth(0.5)
    cb.set_label('FP32 throughput (MFLOP/s)', fontsize=7.0)
    out = os.path.join(HERE, 'figs', 'machines_heatmap.pdf')
    fig.savefig(out)
    fig.savefig(out.replace('.pdf', '.png'), dpi=200)
    plt.close(fig)
    print('written', out, 'range %.2f .. %.0f MFLOP/s' % (min(allv), max(allv)))
    return cols


def heatmap_speedup(rows):
    """the former Fig. 5 (speedup of SIMTiX), no longer written to the paper's figure"""
    cmap = plt.get_cmap('viridis')
    from matplotlib.colors import Normalize
    norm = Normalize(vmin=-math.log10(32), vmax=math.log10(32), clip=True)   # 1/32x .. 32x, symmetric
    # suite 2 left out of the paper's heatmap (2026-11-19): applications | Rodinia + RiVEC
    fig, axes = plt.subplots(1, 2, figsize=(7.16, 3.65))
    split = [('apps',), ('rodinia', 'rivec')]
    cols = [(m, 0, n) for m, n, _, _ in MACH] + [(m, 1, n) for m, n, _, _ in MACH]
    ymax = []
    for ax, suites in zip(axes, split):
        sel = [r for r in rows if r[0] in suites]
        y, ys, labels, heads = 0.0, [], [], []
        for i, (s, lab, vals) in enumerate(sel):
            if i == 0 or sel[i - 1][0] != s:
                heads.append((y, dict(SUITES)[s]))
                y += 1.0
            ys.append(y)
            labels.append(lab)
            for c, (m, which, _) in enumerate(cols):
                v = vals[m][which]
                note = vals[m][2]
                x = c + (0.25 if which else 0.0)
                if v is None:
                    ax.add_patch(plt.Rectangle((x - 0.47, y - 0.47), 0.94, 0.94, color='#e9e9e9', lw=0))
                    ax.text(x, y, 'n/a', ha='center', va='center', fontsize=5.6, color=MUTED)
                    continue
                lv = math.log10(v)
                rgba = cmap(norm(lv))
                ax.add_patch(plt.Rectangle((x - 0.47, y - 0.47), 0.94, 0.94, color=rgba, lw=0))
                txt = f'{v:.2f}' if v < 1 else (f'{v:.1f}' if v < 9.95 else f'{v:.0f}')
                if note == 'dagger':
                    txt += '†'
                ax.text(x, y, txt, ha='center', va='center', fontsize=6.0,
                        color=lum_text(rgba),
                        fontweight='bold' if lab == 'Geometric mean' else 'normal')
            if lab == 'Geometric mean':
                ax.add_patch(plt.Rectangle((-0.5, y - 0.5), len(cols) + 0.25, 1.0, fill=False,
                                           ec=INK, lw=0.6))
            y += 1.0
        for yh, name in heads:
            ax.text(-0.6, yh, name, ha='right', va='center', fontsize=7.6, fontweight='bold', color=INK)
        ax.set_xlim(-0.55, len(cols) - 0.45 + 0.25)
        ymax.append(y)
        ax.set_yticks(ys)
        ax.set_yticklabels(labels, fontsize=6.8)
        for t in ax.get_yticklabels():
            if t.get_text() == 'Geometric mean':
                t.set_fontweight('bold')
        ax.set_xticks([c + (0.25 if w else 0.0) for c, (_, w, _) in enumerate(cols)])
        ax.set_xticklabels([n for _, _, n in cols], fontsize=6.8)
        ax.xaxis.tick_top()
        ax.tick_params(length=0, pad=2)
        for sp in ax.spines.values():
            sp.set_visible(False)
        ax.grid(False)
        nm = len(MACH)
        ax.text((nm - 1) / 2, -1.55, '8-lane SIMTiX over', ha='center', va='bottom', fontsize=7.0,
                color=INK, transform=ax.transData)
        ax.text(nm + (nm - 1) / 2 + 0.25, -1.55, '16-lane SIMTiX over', ha='center', va='bottom',
                fontsize=7.0, color=INK, transform=ax.transData)
    for ax in axes:                                   # equal row heights in both panels
        ax.set_ylim(max(ymax) - 0.5, -0.6)
    fig.subplots_adjust(wspace=0.55, top=0.88, bottom=0.02)
    k = min(range(len(axes)), key=lambda i: ymax[i])          # colour bar under the shorter panel
    bb = axes[k].get_position()
    frac = (max(ymax) - ymax[k] - 0.1) / (max(ymax) + 0.1)
    cax = fig.add_axes([bb.x0 + 0.02, bb.y0 + frac * bb.height * 0.42, bb.width - 0.04, 0.022])
    sm = plt.cm.ScalarMappable(norm=norm, cmap=cmap)
    cb = fig.colorbar(sm, cax=cax, orientation='horizontal', extend='both', extendfrac=0.04)
    ticks = [1 / 32, 1 / 8, 0.5, 1, 2, 8, 32]
    cb.set_ticks([math.log10(t) for t in ticks])
    cb.set_ticklabels(['1/32', '1/8', '1/2', '1', '2', '8', '32'])
    cb.ax.tick_params(labelsize=6.4, length=2)
    cb.outline.set_linewidth(0.5)
    cb.ax.axvline(0.0, color='white', lw=0.8)
    cb.set_label('Speedup of SIMTiX (below 1: the other machine is faster)', fontsize=7.0)
    cb.ax.xaxis.set_label_position('top')
    out = os.path.join(HERE, 'figs', 'machines_heatmap_speedup.pdf')
    fig.savefig(out)
    fig.savefig(out.replace('.pdf', '.png'), dpi=200)
    plt.close(fig)
    print('written', out)


def main():
    plot_style.apply()
    rows = table()
    dots(rows)
    heatmap_time()
    heatmap_throughput()


if __name__ == '__main__':
    main()
