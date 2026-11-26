#!/usr/bin/env python3
"""plot_power.py - measured board power, energy per run and FP32 MFLOP/s per watt of every
machine on every benchmark (docs/power_plan.md).

Power: the POWER rows of the power runs (sw/ps_host/run_power_all.ps1 ->
docs/power_runs/zcu102_power_<run>_<suite>.txt): per benchmark and phase the average of
each of the ZCU102's 18 INA226 rails; a machine's power on a benchmark is the sum of the
rails while it runs (accel phase; for the Cortex-A53 the a53 phase of the 8-lane SIMTiX run,
its bitstream loaded and idle), as Table V of the paper. CVA6 and Ara come from one run
(rows <app>@cva6, <app>@ara). SIMTiX's applications use its optimized kernels where the
paper does (GEMM-RB, SpMV-Z, Stencil-RB, k-means-U, segmented scan).
Time: the run's measured time of the timing pass (plot_machines_suites.collect, as Fig. 5
and Tables III/IV; the A53's -O2 reference), at each benchmark's largest input.
  energy per run (mJ) = power (W) x time (ms)
  MFLOP/s per watt    = FP32 operations (docs/machines_throughput.csv, Fig. 5) / time / power
Writes docs/power_results.csv and the paper's figures of the two SIMTiX board designs
(authors' choice, 2026-11-26: the power study covers SIMTiX at 8 and 16 lanes only)
  docs/figs/simtix_lanes_power.pdf      (a) system power, (b) dynamic power, every benchmark
  docs/figs/fp32_efficiency.pdf         FP32 MFLOP/s per W of SIMTiX 8/16 lanes, Vortex, FGPU
  docs/figs/simtix_lanes_energy.pdf     energy per run of every benchmark (supplement)
and with --all the earlier every-machine figures:
  docs/figs/machines_power.pdf          (a) system power while each machine runs, (b) dynamic power (system
                                        power less the board's idle power), every benchmark
  docs/figs/machines_perf_per_watt.pdf  FP32 MFLOP/s per W, the layout of Fig. 5
  docs/figs/machines_energy.pdf         energy per run of every benchmark (supplement)
Only the machines with a measurement are drawn (CVA6/Ara once their run is in).
  python docs/plot_power.py [--old]     (--old: the application logs of before the power
                                         runs, to test the script; BFS's power there is low)
"""
import csv
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import plot_style  # noqa: E402
from plot_style import plt, INK, MUTED  # noqa: E402
import plot_machines_suites as pms  # noqa: E402
import plot_machines_alt as pma  # noqa: E402
from matplotlib.colors import LogNorm  # noqa: E402

OLD = '--old' in sys.argv
RUNS = os.path.join(HERE, 'power_runs')
MACH = [('s8', 'SIMTiX, 8 lanes'), ('s16', 'SIMTiX, 16 lanes'), ('cva6', 'CVA6'), ('ara', 'Ara'),
        ('vortex', 'Vortex'), ('fgpu', 'FGPU'), ('a53', 'Cortex-A53')]
SHORT = {'s8': '8L', 's16': '16L', 'cva6': 'CVA6', 'ara': 'Ara', 'vortex': 'Vortex', 'fgpu': 'FGPU',
         'a53': 'A53'}
LOGRUN = {'s8': 'simtix8', 's16': 'simtix16', 'cva6': 'ara', 'ara': 'ara', 'vortex': 'vortex',
          'fgpu': 'fgpu', 'a53': 'simtix8'}
OLDLOG = {'s8': 'zcu102_board_run_v3_s2.txt', 's16': 'zcu102_board_run_l16_main.txt',
          'vortex': 'zcu102_board_run_vortex.txt', 'fgpu': 'zcu102_board_run_apps_fgpu.txt',
          'a53': 'zcu102_board_run_v3_s2.txt'}
SUITES = [('apps', 'Applications'), ('rodinia', 'Rodinia'), ('rivec', 'RiVEC')]
NRAIL = 18


def power_rows(path):
    """{(app, size, phase): board W (sum of the rails)}; warns when a set is not complete"""
    acc = {}
    for line in open(path, errors='replace'):
        line = line.replace('\x00', '').strip()
        if not line.startswith('POWER,') or line.startswith('POWER,app,'):
            continue
        f = line.split(',')
        acc.setdefault((f[1], int(f[2]), f[3]), {})[f[4]] = int(f[6])
    out = {}
    for k, rails in acc.items():
        if len(rails) != NRAIL:
            print(f'  {os.path.basename(path)}: {k} has {len(rails)} rails')
        out[k] = sum(rails.values()) / 1000.0
    return out


def log_of(m, suite):
    if OLD:
        return os.path.join(HERE, OLDLOG[m]) if suite == 'apps' and m in OLDLOG else None
    p = os.path.join(RUNS, f'zcu102_power_{LOGRUN[m]}_{suite}.txt')
    return p if os.path.isfile(p) else None


def collect():
    """[(suite, key, label, size, {machine: (time ms, W, idle W)})] at each benchmark's largest input"""
    rows = pms.collect()
    a53 = pma.a53_times()
    best = {}
    for r in rows:
        if r[0] != 'suite2' and ((r[0], r[1]) not in best or r[2] > best[(r[0], r[1])][2]):
            best[(r[0], r[1])] = r
    kern = {}                                          # SIMTiX's kernel of an application
    for r in csv.DictReader(open(os.path.join(HERE, 'ara_cva6_simtix_comparison.csv'))):
        kern[r['app']] = r['simtix_kernel']
    pw = {}
    for m, _ in MACH:
        for s, _ in SUITES:
            p = log_of(m, s)
            pw[(m, s)] = power_rows(p) if p else {}
    out = []
    for s, _ in SUITES:
        for k in pma.ORDER[s]:
            _, _, n, t8, t16, t, note = best[(s, k)]
            times = {'s8': t8, 's16': t16, 'a53': a53.get((s, k, n)), **{m: t.get(m) for m in
                                                                          ('cva6', 'ara', 'vortex', 'fgpu')}}
            v = {}
            for m, _ in MACH:
                app = kern.get(k, k) if (s == 'apps' and m in ('s8', 's16')) else k
                if m in ('cva6', 'ara'):
                    app = f'{k}@{m}'
                phase = 'a53' if m == 'a53' else 'accel'
                P = pw[(m, s)].get((app, n, phase))
                idle = pw[(m, s)].get((app, n, 'idle'))
                if m == 'ara' and idle is None:                    # idle rows come with @cva6
                    idle = pw[(m, s)].get((f'{k}@cva6', n, 'idle'))
                tm = times[m] / 1000.0 if times.get(m) else None
                v[m] = (tm, P, idle)
            out.append((s, k, pms.NAME.get(k, k), n, v))
    return out


def fp32_ops():
    return {(r['suite'], r['key'], int(r['size'])): (r['benchmark'], int(r['fp32_ops']))
            for r in csv.DictReader(open(os.path.join(HERE, 'machines_throughput.csv')))}


def write_csv(rows, fops):
    with open(os.path.join(HERE, 'power_results.csv'), 'w', newline='\n') as f:
        w = csv.writer(f, lineterminator='\n')
        w.writerow(['suite', 'benchmark', 'size', 'machine', 'time_ms', 'board_W', 'idle_W',
                    'above_idle_W', 'energy_mJ', 'fp32_ops', 'mflops', 'mflops_per_W'])
        for s, k, lab, n, v in rows:
            ops = fops.get((s, k, n), (None, None))[1]
            for m, _ in MACH:
                tm, P, idle = v[m]
                if tm is None or P is None:
                    continue
                e = P * tm
                mf = ops / (tm * 1000.0) if ops else None
                w.writerow([s, k, n, m, f'{tm:.3f}', f'{P:.3f}', f'{idle:.3f}' if idle else '',
                            f'{P - idle:.3f}' if idle else '', f'{e:.3f}', ops or '',
                            f'{mf:.3f}' if mf else '', f'{mf / P:.3f}' if mf else ''])


COLOR = {'s8': '#008300', 's16': '#eda100', 'cva6': '#2a78d6', 'ara': '#eb6834', 'vortex': '#1baf7a',
         'fgpu': '#8e44ad', 'a53': '#e87ba4'}     # fixed per machine (CVA6, Ara, Vortex, FGPU as Fig. 6);
                                                  # checked for CVD/normal separation in this order
                                                  # (validate_palette port) with and without CVA6/Ara


def darker(hexc, f=0.72):
    h = hexc.lstrip('#')
    return '#' + ''.join(f'{int(int(h[i:i + 2], 16) * f):02x}' for i in (0, 2, 4))


def present(rows):
    """the machines with a measurement (CVA6/Ara only once their run is in)"""
    return [(m, n) for m, n in MACH if any(v[m][1] for _, _, _, _, v in rows)]


def fmt(v):
    if v >= 1000:
        return f'{v:,.0f}'
    if v >= 100:
        return f'{v:.0f}'
    if v >= 10:
        return f'{v:.1f}'
    if v >= 1:
        return f'{v:.2f}'
    return f'{v:.3f}'


def bench_axis(rows):
    """x positions of the benchmarks, grouped by suite with a gap; (xs, labels, [(suite, x0, x1)])"""
    x, xs, labels, groups = 0.0, [], [], []
    for i, (s, k, lab, n, v) in enumerate(rows):
        if i and rows[i - 1][0] != s:
            x += 0.6
        if i == 0 or rows[i - 1][0] != s:
            groups.append([s, x, x])
        groups[-1][2] = x
        xs.append(x)
        labels.append(lab)
        x += 1.0
    return xs, labels, groups


def fig_power(rows, out):
    """(a) system power while each machine runs (dots); (b) dynamic power = system power - idle power (bars)"""
    mach = present(rows)
    xs, labels, groups = bench_axis(rows)
    nm = len(mach)
    w = 0.84 / nm
    fig, (axp, axd) = plt.subplots(2, 1, figsize=(7.16, 3.9), sharex=True,
                                   gridspec_kw={'height_ratios': [1.0, 1.0], 'hspace': 0.1})
    for j, (m, name) in enumerate(mach):
        dx = (j - (nm - 1) / 2) * w
        px, pv, dv = [], [], []
        for x, (_, _, _, _, v) in zip(xs, rows):
            tm, P, idle = v[m]
            if P is None:
                continue
            px.append(x + dx)
            pv.append(P)
            dv.append(P - idle)
        axp.plot(px, pv, 'o', ms=3.6, mfc=COLOR[m], mec='white', mew=0.5, zorder=3, label=name)
        axd.bar(px, dv, w * 0.92, color=COLOR[m], edgecolor=darker(COLOR[m]), linewidth=0.35, zorder=3,
                label=name)
    for ax in (axp, axd):
        for s, a, b in groups[:-1]:
            ax.axvline(b + 0.8, color='#d6d6d6', lw=0.6, zorder=0)
        ax.grid(axis='y', color='#e6e6e6', lw=0.5)
        ax.grid(axis='x', visible=False)
    for s, a, b in groups:
        axp.text((a + b) / 2, 1.02, dict(SUITES)[s], ha='center', va='bottom', fontsize=7.5, color=INK,
                 transform=axp.get_xaxis_transform())
    axp.set_ylim(3.0, 6.1)
    axp.set_yticks([3, 4, 5, 6])
    axp.set_ylabel('System power (W)')
    top = max(max(b.get_height() for b in c) for c in axd.containers)
    axd.set_ylim(0, math.ceil(top * 1.15 / 0.5) * 0.5)
    axd.set_ylabel('Dynamic power (W)')
    axd.set_xlim(xs[0] - 0.6, xs[-1] + 0.6)
    axd.set_xticks(xs)
    axd.set_xticklabels(labels, rotation=55, ha='right', rotation_mode='anchor', fontsize=6.5)
    axd.tick_params(axis='x', length=0, pad=2)
    axd.set_xlabel('Benchmark', labelpad=2)
    plot_style.panel_tag(axp, 'a')
    plot_style.panel_tag(axd, 'b')
    axp.legend(loc='lower left', bbox_to_anchor=(0.0, 1.09), ncol=nm, handletextpad=0.3,
               columnspacing=1.3, borderaxespad=0.1, markerscale=1.3)
    fig.savefig(out)
    fig.savefig(out.replace('.pdf', '.png'), dpi=200)
    plt.close(fig)
    print('written', out)


def heat_machines_rows(cols, mach, out, label, lo, hi, ticks, height=2.45):
    """machines as rows, benchmarks as columns (the layout of Fig. 5)"""
    cmap = plt.get_cmap('viridis')
    norm = LogNorm(vmin=lo, vmax=hi)
    fig, ax = plt.subplots(figsize=(7.16, height))
    x, xs, heads = 0.0, [], []
    for i, (s, lab, v) in enumerate(cols):
        if i and cols[i - 1][0] != s:
            x += 0.35
        if i == 0 or cols[i - 1][0] != s:
            heads.append([s, x, x])
        heads[-1][2] = x
        xs.append(x)
        for y, (m, _) in enumerate(mach):
            val = v.get(m)
            if val is None:
                ax.add_patch(plt.Rectangle((x - 0.47, y - 0.46), 0.94, 0.92, color='#e9e9e9', lw=0))
                ax.text(x, y, 'n/a', ha='center', va='center', fontsize=5.6, color=MUTED)
                continue
            rgba = cmap(norm(val))
            ax.add_patch(plt.Rectangle((x - 0.47, y - 0.46), 0.94, 0.92, color=rgba, lw=0))
            ax.text(x, y, fmt(val), ha='center', va='center', fontsize=5.6, color=pma.lum_text(rgba))
        x += 1.0
    for s, a, b in heads:
        ax.text((a + b) / 2, -0.75, dict(SUITES)[s], ha='center', va='bottom', fontsize=7.4,
                fontweight='bold', color=INK)
    ax.set_xlim(-0.55, xs[-1] + 0.55)
    ax.set_ylim(len(mach) - 0.5, -0.55)
    ax.set_yticks(range(len(mach)))
    ax.set_yticklabels([n for _, n in mach], fontsize=6.8)
    ax.set_xticks(xs)
    ax.set_xticklabels([c[1] for c in cols], rotation=40, ha='right', rotation_mode='anchor', fontsize=6.8)
    ax.tick_params(length=0, pad=2)
    for sp in ax.spines.values():
        sp.set_visible(False)
    ax.grid(False)
    ax.set_xlabel('Benchmark', labelpad=2)
    ax.set_ylabel('Machine', labelpad=4)
    fig.subplots_adjust(left=0.155, right=0.885, top=0.9, bottom=0.27)
    cax = fig.add_axes([0.9, 0.27, 0.013, 0.63])
    cb = fig.colorbar(plt.cm.ScalarMappable(norm=norm, cmap=cmap), cax=cax)
    cb.set_ticks(ticks)
    cb.set_ticklabels([f'{t:g}' for t in ticks])
    cb.ax.minorticks_off()
    cb.ax.tick_params(labelsize=6.4, length=2)
    cb.outline.set_linewidth(0.5)
    cb.set_label(label, fontsize=7.0)
    fig.savefig(out)
    fig.savefig(out.replace('.pdf', '.png'), dpi=200)
    plt.close(fig)
    print('written', out)


def heat_bench_rows(rows, mach, out, label, lo, hi, ticks):
    """benchmarks as rows (applications | Rodinia + RiVEC), machines as columns (Fig. S3's layout)"""
    cmap = plt.get_cmap('viridis')
    norm = LogNorm(vmin=lo, vmax=hi)
    fig, axes = plt.subplots(1, 2, figsize=(7.16, 3.35))
    nsim = sum(1 for m, _ in mach if m in ('s8', 's16'))
    xc = [c + (0.25 if c >= nsim else 0.0) for c in range(len(mach))]
    short = {'s8': '8 lanes', 's16': '16 lanes', 'cva6': 'CVA6', 'ara': 'Ara', 'vortex': 'Vortex',
             'fgpu': 'FGPU', 'a53': 'A53'}
    ymax = []
    for pi, (ax, suites) in enumerate(zip(axes, [('apps',), ('rodinia', 'rivec')])):
        sel = [r for r in rows if r[0] in suites]
        y, ys, labels, heads = 0.0, [], [], []
        for i, (s, lab, v) in enumerate(sel):
            if i == 0 or sel[i - 1][0] != s:
                heads.append((y, dict(SUITES)[s]))
                y += 1.0
            ys.append(y)
            labels.append(lab)
            for (m, _), x in zip(mach, xc):
                val = v.get(m)
                if val is None:
                    ax.add_patch(plt.Rectangle((x - 0.47, y - 0.47), 0.94, 0.94, color='#e9e9e9', lw=0))
                    ax.text(x, y, 'n/a', ha='center', va='center', fontsize=5.6, color=MUTED)
                    continue
                rgba = cmap(norm(val))
                ax.add_patch(plt.Rectangle((x - 0.47, y - 0.47), 0.94, 0.94, color=rgba, lw=0))
                ax.text(x, y, fmt(val), ha='center', va='center', fontsize=5.6, color=pma.lum_text(rgba))
            y += 1.0
        for yh, name in heads:
            ax.text(-0.6, yh, name, ha='right', va='center', fontsize=7.6, fontweight='bold', color=INK)
        ax.set_xlim(-0.55, xc[-1] + 0.55)
        ymax.append(y)
        ax.set_yticks(ys)
        ax.set_yticklabels(labels, fontsize=6.8)
        ax.set_xticks(xc)
        ax.set_xticklabels([short[m] for m, _ in mach], fontsize=6.6)
        ax.xaxis.tick_top()
        ax.xaxis.set_label_position('top')
        ax.set_xlabel('Machine', labelpad=12 if nsim else 4)
        ax.tick_params(length=0, pad=2)
        for sp in ax.spines.values():
            sp.set_visible(False)
        ax.grid(False)
        if nsim:
            ax.text((xc[0] + xc[nsim - 1]) / 2, -1.45, 'SIMTiX', ha='center', va='bottom', fontsize=6.8,
                    color=INK)
            ax.plot([xc[0] - 0.4, xc[nsim - 1] + 0.4], [-1.42, -1.42], color=INK, lw=0.5, clip_on=False)
        if pi == 0:
            ax.set_ylabel('Benchmark', labelpad=58)
    for ax in axes:
        ax.set_ylim(max(ymax) - 0.5, -0.6)
    fig.subplots_adjust(wspace=0.55, top=0.8, bottom=0.02, left=0.12)
    k = min(range(len(axes)), key=lambda i: ymax[i])
    bb = axes[k].get_position()
    frac = (max(ymax) - ymax[k] - 0.1) / (max(ymax) + 0.1)
    cax = fig.add_axes([bb.x0 + 0.02, bb.y0 + frac * bb.height * 0.40, bb.width - 0.04, 0.026])
    cb = fig.colorbar(plt.cm.ScalarMappable(norm=norm, cmap=cmap), cax=cax, orientation='horizontal')
    cb.set_ticks(ticks)
    cb.set_ticklabels([f'{t:g}' if t < 1e4 else '$10^{%d}$' % round(math.log10(t)) for t in ticks])
    cb.ax.minorticks_off()
    cb.ax.tick_params(labelsize=6.4, length=2)
    cb.outline.set_linewidth(0.5)
    cb.set_label(label, fontsize=7.0)
    cb.ax.xaxis.set_label_position('top')
    fig.savefig(out)
    fig.savefig(out.replace('.pdf', '.png'), dpi=200)
    plt.close(fig)
    print('written', out)


def decades(vals):
    lo = 10 ** math.floor(math.log10(min(vals)))
    hi = 10 ** math.ceil(math.log10(max(vals)))
    return lo, hi, [10 ** e for e in range(int(round(math.log10(lo))), int(round(math.log10(hi))) + 1)]


LANES_M = [('s8', '8 lanes, 115.37 MHz'), ('s16', '16 lanes, 100 MHz')]   # the two board designs
LCOL = {'s8': '#1f4e79', 's16': '#e6a817'}   # navy / gold (authors' choice from 7 options);
                                              # CVD dE 37.6, normal dE 43.1 (validator port); the gold
                                              # is 2.1:1 on white, so its bars and dots get a dark edge


def _suite_frame(axes, groups, xs):
    for ax in axes:
        for s, a, b in groups[:-1]:
            ax.axvline(b + 0.8, color='#d6d6d6', lw=0.6, zorder=0)
        ax.grid(axis='y', color='#e6e6e6', lw=0.5)
        ax.grid(axis='x', visible=False)
    for s, a, b in groups:
        axes[0].text((a + b) / 2, 1.02, dict(SUITES)[s], ha='center', va='bottom', fontsize=7.5,
                     color=INK, transform=axes[0].get_xaxis_transform())
    axes[-1].set_xlim(xs[0] - 0.6, xs[-1] + 0.6)


def _bench_ticks(ax, xs, labels):
    ax.set_xticks(xs)
    ax.set_xticklabels(labels, rotation=55, ha='right', rotation_mode='anchor', fontsize=6.5)
    ax.tick_params(axis='x', length=0, pad=2)
    ax.set_xlabel('Benchmark', labelpad=2)


def _lane_legend(ax):
    hs = [plt.Rectangle((0, 0), 1, 1, facecolor=LCOL[m], edgecolor=darker(LCOL[m]), lw=0.4)
          for m, _ in LANES_M]
    ax.legend(hs, [n for _, n in LANES_M], loc='lower left', bbox_to_anchor=(0.0, 1.09), ncol=2,
              handlelength=1.2, columnspacing=1.6, borderaxespad=0.1)


def fig_lanes_power(rows, out):
    """Fig. 8: the two SIMTiX board designs on every benchmark: (a) system power, (b) dynamic power."""
    xs, labels, groups = bench_axis(rows)
    w = 0.38
    fig, (a1, a2) = plt.subplots(2, 1, figsize=(7.16, 3.55), sharex=True, gridspec_kw={'hspace': 0.12})
    for j, (m, name) in enumerate(LANES_M):
        dx = (j - 0.5) * w
        px = [x + dx for x in xs]
        sp = [v[m][1] for _, _, _, _, v in rows]
        dp = [v[m][1] - v[m][2] for _, _, _, _, v in rows]
        a1.plot(px, sp, 'o', ms=3.8, mfc=LCOL[m], mec=darker(LCOL[m]), mew=0.5, zorder=3)
        a2.bar(px, dp, w * 0.92, color=LCOL[m], edgecolor=darker(LCOL[m]), lw=0.4, zorder=3)
    _suite_frame((a1, a2), groups, xs)
    a1.set_ylim(3.0, 6.1)
    a1.set_yticks([3, 4, 5, 6])
    a1.set_ylabel('System power (W)')
    a2.set_ylim(0, 2.75)
    a2.set_yticks([0, 0.5, 1.0, 1.5, 2.0, 2.5])
    a2.set_ylabel('Dynamic power (W)')
    _bench_ticks(a2, xs, labels)
    for ax, t in zip((a1, a2), 'ab'):
        plot_style.panel_tag(ax, t)
    _lane_legend(a1)
    fig.savefig(out)
    fig.savefig(out.replace('.pdf', '.png'), dpi=200)
    plt.close(fig)
    print('written', out)


# FP32 energy efficiency against the other soft GPUs (authors' request, 2026-11-26): SIMTiX's
# navy / gold, Vortex and FGPU in their Fig. 6 colours and markers; all six pairs separate
# under CVD (dE >= 9.1) and normal vision (dE >= 19.2), checked with the validator port
EFF_M = [('s8', 'SIMTiX, 8 lanes', '#1f4e79', 'o'), ('s16', 'SIMTiX, 16 lanes', '#e6a817', 'o'),
         ('vortex', 'Vortex', '#1baf7a', '^'), ('fgpu', 'FGPU', '#8e44ad', 'D')]


def fig_fp32_eff(rows, fops, out):
    """FP32 MFLOP/s per W of SIMTiX (8 and 16 lanes), Vortex and FGPU on the 17 FP32 benchmarks,
    in Fig. 5's order, log axis"""
    byk = {(s, k, n): v for s, k, lab, n, v in rows}
    sel = []
    for (s, k, n), (lab5, ops) in fops.items():
        sel.append((s, k, lab5, n, byk[(s, k, n)], ops))
    xs, labels, groups = bench_axis([(s, k, lab, n, v) for s, k, lab, n, v, _ in sel])
    nm = len(EFF_M)
    w = 0.8 / nm
    fig, ax = plt.subplots(figsize=(7.16, 2.55))
    for j, (m, name, col, mk) in enumerate(EFF_M):
        dx = (j - (nm - 1) / 2) * w
        px, py = [], []
        for x, (s, k, lab, n, v, ops) in zip(xs, sel):
            tm, P, _ = v[m]
            if tm and P:
                px.append(x + dx)
                py.append(ops / (tm * 1000.0) / P)
        ax.plot(px, py, linestyle='none', marker=mk, ms=4.0, mfc=col, mec=darker(col), mew=0.5,
                zorder=3, label=name)
    _suite_frame((ax,), groups, xs)
    ax.set_yscale('log')
    ax.set_ylim(1, 600)
    ax.set_yticks([1, 3, 10, 30, 100, 300])
    ax.set_yticklabels(['1', '3', '10', '30', '100', '300'])
    ax.minorticks_off()
    ax.set_ylabel('FP32 energy efficiency\n(MFLOP/s per W)')
    _bench_ticks(ax, xs, labels)
    ax.set_xticklabels(labels, rotation=40, ha='right', rotation_mode='anchor', fontsize=6.8)
    ax.legend(loc='lower left', bbox_to_anchor=(0.0, 1.1), ncol=nm, handletextpad=0.3,
              columnspacing=1.4, borderaxespad=0.1, markerscale=1.2)
    fig.savefig(out)
    fig.savefig(out.replace('.pdf', '.png'), dpi=200)
    plt.close(fig)
    print('written', out)


def fig_lanes_energy(rows, out):
    """Supplement: energy per run of the two SIMTiX board designs on every benchmark (log axis)."""
    xs, labels, groups = bench_axis(rows)
    w = 0.38
    fig, ax = plt.subplots(figsize=(7.16, 2.6))
    for j, (m, name) in enumerate(LANES_M):
        dx = (j - 0.5) * w
        ax.plot([x + dx for x in xs], [v[m][1] * v[m][0] for _, _, _, _, v in rows], 'o', ms=3.8,
                mfc=LCOL[m], mec=darker(LCOL[m]), mew=0.5, zorder=3)
    _suite_frame((ax,), groups, xs)
    ax.set_yscale('log')
    ax.set_ylim(10, 3e5)
    ticks = [10, 100, 1000, 1e4, 1e5]
    ax.set_yticks(ticks)
    ax.set_yticklabels(['10', '100', '1,000', '$10^4$', '$10^5$'])
    ax.minorticks_off()
    ax.set_ylabel('Energy per run (mJ)')
    _bench_ticks(ax, xs, labels)
    _lane_legend(ax)
    fig.savefig(out)
    fig.savefig(out.replace('.pdf', '.png'), dpi=200)
    plt.close(fig)
    print('written', out)


def main():
    plot_style.apply()
    rows = collect()
    fops = fp32_ops()
    write_csv(rows, fops)
    # the paper's figures: the two SIMTiX board designs (authors' choice, 2026-11-26)
    fig_lanes_power(rows, os.path.join(HERE, 'figs', 'simtix_lanes_power.pdf'))
    fig_fp32_eff(rows, fops, os.path.join(HERE, 'figs', 'fp32_efficiency.pdf'))
    fig_lanes_energy(rows, os.path.join(HERE, 'figs', 'simtix_lanes_energy.pdf'))
    for m, name in LANES_M:
        P = [v[m][1] for _, _, _, _, v in rows if v[m][1]]
        print(f'{name:22s} {len(P):2d} benchmarks, system power {min(P):.2f} .. {max(P):.2f} W')
    if '--all' in sys.argv:          # every measured machine (fig_power and the heatmaps)
        mach = present(rows)
        fig_power(rows, os.path.join(HERE, 'figs', 'machines_power.pdf'))
        er = [(s, lab, {m: (v[m][1] * v[m][0] if v[m][0] and v[m][1] else None) for m, _ in mach})
              for s, k, lab, n, v in rows]
        lo, hi, ticks = decades([x for _, _, d in er for x in d.values() if x])
        heat_bench_rows(er, mach, os.path.join(HERE, 'figs', 'machines_energy.pdf'),
                        'Energy per run (mJ)', lo, hi, ticks)
        pr = []
        byk = {(s, k, n): v for s, k, lab, n, v in rows}
        for (s, k, n), (lab5, ops) in fops.items():
            v = byk[(s, k, n)]
            pr.append((s, lab5, {m: (ops / (v[m][0] * 1000.0) / v[m][1] if v[m][0] and v[m][1] else None)
                                 for m, _ in mach}))
        lo, hi, ticks = decades([x for _, _, d in pr for x in d.values() if x])
        heat_machines_rows(pr, mach, os.path.join(HERE, 'figs', 'machines_perf_per_watt.pdf'),
                           'FP32 energy efficiency (MFLOP/s per W)', lo, hi, ticks)


if __name__ == '__main__':
    main()
