#!/usr/bin/env python3
"""plot_machines_throughput.py - FP32 throughput of SIMTiX, CVA6, Ara and Vortex on the ZCU102.

Throughput = N / T, with N the FP32 operations of a benchmark (FMA = 2; add, sub, mul, div,
sqrt = 1) and T the time measured on the board. Every machine performs the same sequence of
FP32 operations per output (the benchmark rules of the paper), so one N serves all four.

N is counted by SIMTiX's useful-operation counter (warp_pool.sv, SIMTIX_OPCOUNT) in board-size
simulation of the 8-lane board design (sim/run_lanes_board.sh with OPCOUNT=1):
  build_b8/{rodinia,rivec}/<app>/sim_l8_w8_ops.log, build_dram8/apps/<kernel>/sim_l8_w8_ops.log
Where the simulation ran fewer iterations or a smaller size than the board, N is scaled by a
formula that this script first checks against the simulated count (exact equality):
  hotspot 512^2 -> 1024^2 (14 FLOPs per cell), hotspot3D 2 -> 100 iterations (17 per cell),
  gaussian 256 -> 1024, kmeans 65,536 points x 1 iteration -> 494,020 x 37 (510 per point),
  jacobi-2d 2 -> 2,000 steps (5 per interior point), blackscholes 1 -> 100 runs,
  lavaMD 2 -> 1,000 home boxes (constant FLOPs per particle pair; box pairs 20 -> 21,952).
Integer benchmarks (bfs, both pathfinders, hash join, scan, ...) have no FP32 work: not plotted.

Peaks (MFLOP/s, FMA = 2): CVA6 2 x 78.95, Ara 8 x 78.95, Vortex 16 x 125, SIMTiX 16 x 115.37
(8 lanes) and 32 x 100 (16 lanes).
Writes docs/machines_throughput.csv, docs/figs/machines_throughput.pdf (dot plot with peak
lines) and docs/figs/machines_throughput_heatmap.pdf (MFLOP/s, colour = fraction of peak).
Usage:  python docs/plot_machines_throughput.py
"""
import csv
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..'))
sys.path.insert(0, HERE)
import plot_style  # noqa: E402
from plot_style import plt, INK, MUTED  # noqa: E402
from matplotlib.lines import Line2D  # noqa: E402
from matplotlib.colors import LinearSegmentedColormap  # noqa: E402

LOG = 'sim_l8_w8_ops.log'
MACH = [  # key, label, colour, marker, peak MFLOP/s, column of machines_suites.csv
    ('cva6', 'CVA6', '#1f5fae', 'o', 2 * 78.95, 'cva6_us'),
    ('ara', 'Ara', '#d4542a', 's', 8 * 78.95, 'ara_us'),
    ('vortex', 'Vortex', '#168a5f', '^', 16 * 125.0, 'vortex_us'),
    ('simtix8', 'SIMTiX, 8 lanes', '#111111', 'D', 16 * 115.37, 'simtix8_us'),
    ('simtix16', 'SIMTiX, 16 lanes', '#7a4fb5', 'D', 32 * 100.0, 'simtix16_us'),
]


def ops(path):
    """sum of flop over the launches of a passing simulation log"""
    flop = 0
    ok = False
    for line in open(path, errors='replace'):
        if line.startswith('OPCOUNT,'):
            kv = dict(x.split('=') for x in line.strip().split(',')[1:])
            flop += int(kv['flop'])
        if '[tb_apps] PASS' in line:
            ok = True
    if not ok:
        raise SystemExit(f'{path}: simulation did not pass')
    return flop


def gauss_flop(n):
    """fan1: one division per row below the pivot; fan2: one FMA (2) per element of those
    rows from the pivot column to b"""
    return sum((n - 1 - t) + 2 * (n - 1 - t) * (n + 1 - t) for t in range(n - 1))


def lava_box_pairs(b1d, nhome):
    def nb(i):
        return 2 if (i == 0 or i == b1d - 1) else 3
    pairs = 0
    for box in range(nhome):
        i, j, k = box // (b1d * b1d), (box // b1d) % b1d, box % b1d
        pairs += nb(i) * nb(j) * nb(k)
    return pairs


def check(name, got, want):
    if got != want:
        raise SystemExit(f'{name}: simulated {got} FLOP, formula {want}: scaling not exact')
    print(f'  check {name:22s} simulated = formula = {got:,}')


# (suite, label, benchmark key in machines_suites.csv, board N column value, log dir, N function)
def bench_list():
    b8 = os.path.join(ROOT, 'build_b8')
    dr = os.path.join(ROOT, 'build_dram8', 'apps')
    L = []

    def exact(d):
        return lambda: ops(os.path.join(d, LOG))

    for lab, key, n, kern in (('GEMM-RB', 'gemm', 256, 'gemmrb'), ('SpMV-Z', 'spmv', 65536, 'spmvz'),
                              ('Stencil-RB', 'stencil', 512, 'stencilrb'),
                              ('Emb. bag', 'embag', 4096, 'embag')):
        L.append(('apps', lab, key, n, exact(os.path.join(dr, kern))))

    def mandel():
        """8 FLOPs per iteration (3 mul, 2 add, 1 sub, 1 FMA) and 4 per pixel (2 FMAs for c);
        the gold output is each pixel's iteration count. Checked exactly on the simulated
        256^2 case, applied to the 1024^2 board input (sim/gen_apps.py --size dram)."""
        def formula(gold):
            iters = [int(line.split()[1], 16) for line in open(gold)]
            return 8 * sum(iters) + 4 * len(iters)
        check('Mandelbrot 256^2', ops(os.path.join(ROOT, 'build_b8', 'apps', 'mandel', LOG)),
              formula(os.path.join(ROOT, 'build_b8', 'apps', 'mandel', 'mandel_256x256x256.gold')))
        return formula(os.path.join(dr, 'mandel', 'mandel_1024x1024x256.gold'))

    L.append(('apps', 'Mandelbrot', 'mandel', 1024, mandel))
    rd = lambda a: os.path.join(b8, 'rodinia', a, LOG)   # noqa: E731
    rv = lambda a: os.path.join(b8, 'rivec', a, LOG)     # noqa: E731

    def hotspot():
        s = ops(rd('hotspot'))
        check('hotspot 512^2 x 2', s, 14 * 512 * 512 * 2)
        return 14 * 1024 * 1024 * 2

    def hotspot3d():
        s = ops(rd('hotspot3d'))
        check('hotspot3D 2 iterations', s, 17 * 512 * 512 * 8 * 2)
        return s * 50

    def gaussian():
        s = ops(rd('gaussian'))
        check('gaussian 256', s, gauss_flop(256))
        return gauss_flop(1024)

    def kmeans():
        s = ops(rd('kmeans'))
        check('kmeans 65,536 points', s, 510 * 65536)
        return 510 * 494020 * 37

    def jacobi():
        s = ops(rv('jacobi'))
        check('jacobi-2d 2 steps', s, 5 * 254 * 254 * 2 * 2)
        return s * 1000

    def lavamd():
        # less one FADD per thread (lavamd_rv.S makes the constant 2.0 with fadd f9, f9, f9):
        # SIMTiX's setup, not the benchmark's work; 2 home boxes of 96 particles simulated
        s = ops(rv('lavamd')) - 2 * 96
        p_sim, p_all = lava_box_pairs(10, 2), lava_box_pairs(10, 1000)
        per = s / (p_sim * 96 * 96)
        if per != int(per):
            raise SystemExit(f'lavaMD: {s} FLOP not a whole number per particle pair')
        print(f'  check lavaMD                 {int(per)} FLOP per particle pair, box pairs '
              f'{p_sim} -> {p_all}')
        return int(per) * p_all * 96 * 96

    L += [('rodinia', 'Backprop', 'backprop', 524288, exact(os.path.dirname(rd('backprop')))),
          ('rodinia', 'Hotspot', 'hotspot', 1024, hotspot),
          ('rodinia', 'NN', 'nn', 42764, exact(os.path.dirname(rd('nn')))),
          ('rodinia', 'Hotspot3D', 'hotspot3d', 512, hotspot3d),
          ('rodinia', 'Gaussian', 'gaussian', 1024, gaussian),
          ('rodinia', 'k-means', 'kmeans', 494020, kmeans),
          ('rivec', 'Matmul', 'matmul', 512, exact(os.path.dirname(rv('matmul')))),
          ('rivec', 'AXPY', 'axpy', 2097152, exact(os.path.dirname(rv('axpy')))),
          ('rivec', 'SpMV', 'spmv', 85623, exact(os.path.dirname(rv('spmv')))),
          ('rivec', 'Jacobi-2D', 'jacobi', 256, jacobi),
          ('rivec', 'Black-Scholes', 'blackscholes', 65536, lambda: ops(rv('blackscholes')) * 100),
          ('rivec', 'LavaMD', 'lavamd', 1000, lavamd)]
    return L


def collect():
    times = {}
    for r in csv.DictReader(open(os.path.join(HERE, 'machines_suites.csv'))):
        times[(r['suite'], r['benchmark'], int(r['N']))] = r
    rows = []
    for suite, lab, key, n, nfun in bench_list():
        N = nfun()
        t = times[(suite, key, n)]
        tp = {}
        for m, _, _, _, peak, col in MACH:
            us = float(t[col]) if t[col] else None
            tp[m] = (N / us if us else None)            # FLOP per microsecond = MFLOP/s
        rows.append((suite, lab, N, tp))
    with open(os.path.join(HERE, 'machines_throughput.csv'), 'w', newline='\n') as f:
        f.write('suite,benchmark,flop,' + ','.join(f'{m}_mflops' for m, *_ in MACH) + ','
                + ','.join(f'{m}_frac_peak' for m, *_ in MACH) + '\n')
        for s, lab, N, tp in rows:
            f.write(f'{s},{lab},{N},' + ','.join(f'{tp[m]:.2f}' if tp[m] else '' for m, *_ in MACH)
                    + ',' + ','.join(f'{tp[m] / pk:.4f}' if tp[m] else '' for m, _, _, _, pk, _ in MACH)
                    + '\n')
    return rows


def gmean(v):
    return math.exp(sum(map(math.log, v)) / len(v))


TITLE = {'apps': 'Applications', 'rodinia': 'Rodinia', 'rivec': 'RiVEC'}


def figure_dots(rows):
    fig, ax = plt.subplots(figsize=(7.16, 3.3))
    x, xs, labels, seps, heads = 0.0, [], [], [], []
    OFF = dict(zip([m for m, *_ in MACH], (-0.30, -0.15, 0.0, 0.15, 0.30)))
    for si, suite in enumerate(('apps', 'rodinia', 'rivec')):
        sel = [r for r in rows if r[0] == suite]
        if si:
            seps.append(x - 0.75)
        x0 = x
        for _, lab, _, tp in sel:
            for m, _, col, mk, _, _ in MACH:
                if tp[m] is None:
                    continue
                hollow = m == 'simtix16'
                ax.plot(x + OFF[m], tp[m], marker=mk, ms=4.4 if m.startswith('simtix') else 4.0,
                        mfc='white' if hollow else col, mec=col, mew=0.9, linestyle='none', zorder=3)
            xs.append(x)
            labels.append(lab)
            x += 1.0
        heads.append(((x0 + x - 1.0) / 2, TITLE[suite]))
        x += 0.5
    for m, name, col, mk, peak, _ in MACH:
        ax.axhline(peak, color=col, lw=0.9, ls=(0, (4, 2)), zorder=1)
    ax.set_yscale('log')
    ax.set_ylim(1, 6000)
    ticks = [1, 3, 10, 30, 100, 300, 1000, 3000]
    ax.set_yticks(ticks)
    ax.set_yticklabels([f'{t:g}' for t in ticks])
    ax.minorticks_off()
    for s in seps:
        ax.axvline(s, color=MUTED, lw=0.6, ls=(0, (3, 2)), zorder=1)
    for xc, name in heads:
        ax.text(xc, 4300, name, ha='center', va='center', fontsize=7.4, fontweight='bold', color=INK)
    ax.set_xticks(xs)
    ax.set_xticklabels(labels, rotation=90, fontsize=6.8)
    ax.set_xlim(xs[0] - 0.6, xs[-1] + 0.6)
    ax.set_ylabel('FP32 throughput (MFLOP/s)')
    for sp in ax.spines.values():
        sp.set_visible(True)
        sp.set_color(INK)
        sp.set_linewidth(0.6)
    ax.tick_params(direction='in', which='both', right=True, length=2.5, width=0.6)
    ax.tick_params(axis='x', length=0, pad=2)
    ax.grid(True, axis='y', color='#e6e6e6', lw=0.5)
    hs = [Line2D([0], [0], marker=mk, mfc='white' if m == 'simtix16' else col, mec=col, mew=0.9,
                 color=col, lw=0.9, ls=(0, (4, 2)), ms=4.4, label=name)
          for m, name, col, mk, _, _ in MACH]
    leg = fig.legend(handles=hs, loc='lower center', bbox_to_anchor=(0.5, 0.0), ncol=5,
                     frameon=True, fancybox=False, edgecolor=INK, handlelength=2.4,
                     columnspacing=1.4, borderpad=0.4)
    leg.get_frame().set_linewidth(0.6)
    fig.subplots_adjust(top=0.98, bottom=0.36, left=0.08, right=0.99)
    out = os.path.join(HERE, 'figs', 'machines_throughput.pdf')
    fig.savefig(out)
    fig.savefig(out.replace('.pdf', '.png'), dpi=200)
    plt.close(fig)
    print('written', out)


def text_color(rgba):
    r, g, b = rgba[:3]
    return 'white' if 0.2126 * r + 0.7152 * g + 0.0722 * b < 0.5 else INK


def figure_heatmap(rows):
    cmap = plt.get_cmap('viridis')
    norm = plt.matplotlib.colors.LogNorm(vmin=0.01, vmax=1.0, clip=True)
    fig, ax = plt.subplots(figsize=(3.5, 4.6))
    y, ys, labels = 0.0, [], []
    for suite in ('apps', 'rodinia', 'rivec'):
        sel = [r for r in rows if r[0] == suite]
        ax.text(-0.62, y, TITLE[suite], ha='right', va='center', fontsize=7.4, fontweight='bold',
                color=INK)
        y += 1.0
        gm = {m: gmean([r[3][m] for r in sel if r[3][m]]) for m, *_ in MACH}
        for lab, tp in [(r[1], r[3]) for r in sel] + [('Geometric mean', gm)]:
            ys.append(y)
            labels.append(lab)
            for c, (m, _, _, _, peak, _) in enumerate(MACH):
                v = tp[m]
                if v is None:
                    ax.add_patch(plt.Rectangle((c - 0.47, y - 0.47), 0.94, 0.94, color='#e9e9e9', lw=0))
                    ax.text(c, y, 'n/a', ha='center', va='center', fontsize=5.4, color=MUTED)
                    continue
                rgba = cmap(norm(v / peak))
                ax.add_patch(plt.Rectangle((c - 0.47, y - 0.47), 0.94, 0.94, color=rgba, lw=0))
                ax.text(c, y, f'{v:.0f}' if v >= 10 else f'{v:.1f}', ha='center', va='center',
                        fontsize=5.8, color=text_color(rgba),
                        fontweight='bold' if lab == 'Geometric mean' else 'normal')
            if lab == 'Geometric mean':
                ax.add_patch(plt.Rectangle((-0.5, y - 0.5), len(MACH), 1.0, fill=False, ec=INK, lw=0.6))
            y += 1.0
    ax.set_yticks(ys)
    ax.set_yticklabels(labels, fontsize=6.5)
    for t in ax.get_yticklabels():
        if t.get_text() == 'Geometric mean':
            t.set_fontweight('bold')
    ax.set_xticks(range(len(MACH)))
    ax.set_xticklabels(['CVA6', 'Ara', 'Vortex', 'SIMTiX\n8 lanes', 'SIMTiX\n16 lanes'], fontsize=6.6)
    ax.xaxis.tick_top()
    ax.tick_params(length=0, pad=2)
    ax.set_xlim(-0.55, len(MACH) - 0.45)
    ax.set_ylim(y - 0.5, -0.6)
    for sp in ax.spines.values():
        sp.set_visible(False)
    ax.grid(False)
    fig.subplots_adjust(top=0.93, bottom=0.12, left=0.30, right=0.98)
    cax = fig.add_axes([0.34, 0.05, 0.60, 0.016])
    cb = fig.colorbar(plt.cm.ScalarMappable(norm=norm, cmap=cmap), cax=cax, orientation='horizontal')
    cb.set_ticks([0.01, 0.03, 0.1, 0.3, 1.0])
    cb.set_ticklabels(['1%', '3%', '10%', '30%', '100%'])
    cb.ax.tick_params(labelsize=6.2, length=2)
    cb.outline.set_linewidth(0.5)
    cb.set_label('Fraction of the machine’s FP32 peak (cell: MFLOP/s)', fontsize=6.6)
    out = os.path.join(HERE, 'figs', 'machines_throughput_heatmap.pdf')
    fig.savefig(out)
    fig.savefig(out.replace('.pdf', '.png'), dpi=200)
    plt.close(fig)
    print('written', out)


def main():
    plot_style.apply()
    rows = collect()
    figure_dots(rows)
    figure_heatmap(rows)
    print(f'\n{"":16s}' + ''.join(f'{name:>18s}' for _, name, *_ in MACH))
    for suite in ('apps', 'rodinia', 'rivec', None):
        sel = [r for r in rows if suite is None or r[0] == suite]
        line = f'{TITLE.get(suite, "All"):16s}'
        for m, _, _, _, peak, _ in MACH:
            v = [r[3][m] for r in sel if r[3][m]]
            g = gmean(v)
            line += f'{g:9.1f} ({g / peak:5.1%})'
        print(line)


if __name__ == '__main__':
    main()
