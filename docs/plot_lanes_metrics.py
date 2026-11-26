#!/usr/bin/env python3
"""plot_lanes_metrics.py - throughput, lane utilization and memory bandwidth at 4, 8, 16 lanes.

Board-size simulation of the board configuration (8 warps, 16 MSHRs, 16 tags; an L1 of
2,048 lines; one divide/square-root unit per eight lanes), board inputs, every output
checked. Reads the per-launch counters of sim/run_lanes_board.sh (AXICOUNT=1 build):
    build_b4/<suite>/<case>/sim_l4_w8_k32_axi.log, build_b8/.../sim_l8_w8_axi.log,
    build_b16/.../sim_l16_w8_s2_k128_axi.log
APPCSV lines give the cycles, the warp instructions and their active lanes; AXICSV lines the
bytes the accelerator read and wrote over its AXI4 master. Three rows per figure, in the
style of Ara's performance and utilization plots:
  (a) throughput: lane operations (active lanes of the issued warp instructions) per cycle;
  (b) lane utilization: active lanes / (L x warp instructions), as a dot plot;
  (c) memory bandwidth, mirrored: bytes read per cycle upwards from zero and bytes written
      per cycle downwards.
No peak lines (authors' request).
    docs/figs/lanes_metrics_paper.pdf   applications, Rodinia, RiVEC
    docs/figs/lanes_metrics_supp.pdf    suite 2 and the synchronization kernels
Writes docs/lanes_metrics.csv.  Usage:  python docs/plot_lanes_metrics.py
"""
import glob
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..'))
sys.path.insert(0, HERE)
import plot_style  # noqa: E402
from plot_style import plt, INK, MUTED, RAMP3  # noqa: E402
from plot_lanes_suites import ORDER, NAME, SIZE  # noqa: E402

LANES = (4, 8, 16)
LOG = {4: 'sim_l4_w8_k32_axi.log', 8: 'sim_l8_w8_axi.log', 16: 'sim_l16_w8_s2_k128_axi.log'}
PORT = 16                                   # bytes per cycle per direction (128-bit AXI4)
TITLE = {'apps': 'Applications', 'rodinia': 'Rodinia', 'rivec': 'RiVEC', 'suite2': 'Suite 2',
         'sync': 'Synchronization'}


def counters(log):
    """(cycles, warp instructions, active lanes, bytes read, bytes written) of a passing run"""
    c = [0, 0, 0, 0, 0]
    n = 0
    ok = False
    for line in open(log, errors='replace'):
        f = line.strip().split(',')
        if f[0] == 'APPCSV':
            c[0] += int(f[4])
            c[1] += int(f[7])
            c[2] += int(f[8])
            n += 1
        elif f[0] == 'AXICSV':
            c[3] += int(f[3])
            c[4] += int(f[4])
        elif '[tb_apps] PASS' in line:
            ok = True
    return c if n and ok else None


def collect(suite):
    rows = []
    cases = {os.path.basename(os.path.dirname(p))
             for p in glob.glob(os.path.join(ROOT, 'build_b8', suite, '*', 'apps.manifest'))}
    for k in ORDER[suite]:
        ks = [f'{k}_{n}' for n in (1024, 16384, 262144)] if suite == 'sync' else [k]
        for case in ks:
            if case not in cases:
                continue
            m = {}
            for L in LANES:
                p = os.path.join(ROOT, f'build_b{L}', suite, case, LOG[L])
                m[L] = counters(p) if os.path.isfile(p) else None
            if not all(m.values()):
                print(f'  missing: {suite}/{case}')
                continue
            if suite == 'sync':
                lab = f'{NAME.get(k, k)} {SIZE[int(case.rsplit("_", 1)[1])]}'
            else:
                lab = NAME.get(k, k)
            met = {}
            for L in LANES:
                cyc, ins, act, rd, wr = m[L]
                met[L] = (act / cyc, act / (L * ins), rd / cyc, wr / cyc)
            rows.append((lab, met, case))
    return rows


def gmean(v):
    return math.exp(sum(map(math.log, v)) / len(v))


def figure(suites, out, height):
    data = [(s, collect(s)) for s in suites]
    fig, (axt, axu, axb) = plt.subplots(3, 1, figsize=(7.16, height), sharex=True,
                                        gridspec_kw={'height_ratios': [1.15, 0.7, 1.3],
                                                     'hspace': 0.12})
    bw, x, xs, labels, bounds = 0.27, 0.0, [], [], []
    for s, rows in data:
        start = x
        for lab, m, _ in rows:
            # (b) is a dot plot: one marker per lane count, joined so a fall reads as a slope
            axu.plot([x + (j - 1) * bw for j in range(3)], [m[L][1] for L in LANES],
                     color='#a8a8a8', lw=0.7, zorder=2, solid_capstyle='round')
            for j, L in enumerate(LANES):
                bx = x + (j - 1) * bw
                thr, util, rd, wr = m[L]
                axt.bar(bx, thr, bw * 0.92, color=RAMP3[j], lw=0, zorder=2,
                        label=f'{L} lanes' if not xs else None)
                axu.plot(bx, util, 'o', ms=3.1, mfc=RAMP3[j], mec=RAMP3[2], mew=0.4, zorder=3)
                axb.bar(bx, rd, bw * 0.92, color=RAMP3[j], lw=0, zorder=2)      # read: up
                axb.bar(bx, -wr, bw * 0.92, color=RAMP3[j], lw=0, zorder=2)     # written: down
            xs.append(x)
            labels.append(lab)
            x += 1
        bounds.append((start, x - 1, TITLE[s]))
        x += 0.8

    rtop = max(m[L][2] for _, rows in data for _, m, _ in rows for L in LANES) * 1.25
    wbot = max(m[L][3] for _, rows in data for _, m, _ in rows for L in LANES) * 1.25
    axb.axhline(0, color=INK, lw=0.6, zorder=3)
    for y, t in ((rtop / 2, 'read ↑'), (-wbot / 2, 'written ↓')):
        axb.text(1.005, y, t, ha='left', va='center', fontsize=7, color=INK,
                 transform=axb.get_yaxis_transform())
    for a, b, name in bounds:
        axt.text((a + b) / 2, 1.005, name, ha='center', va='bottom', fontsize=7.5, color=INK,
                 transform=axt.get_xaxis_transform())
        if b < xs[-1]:
            for ax in (axt, axu, axb):
                ax.axvline(b + 0.9, color='#d6d6d6', lw=0.6, zorder=0)
    axt.set_ylim(0, 18.5)
    axt.set_yticks([0, 4, 8, 12, 16])
    axt.set_ylabel('Lane operations\nper cycle')
    lo = min(0.5, math.floor(min(m[L][1] for _, rows in data for _, m, _ in rows
                                 for L in LANES) * 4) / 4)          # zoom to the data range
    axu.set_ylim(lo, 1.0 + (1.0 - lo) * 0.42)
    axu.set_yticks([v / 4 for v in range(int(lo * 4), 5)])
    axu.set_ylabel('Lane\nutilization')
    axb.set_ylim(-wbot, rtop)
    yt = list(range(-int(wbot // 4) * 4, int(rtop) + 1, 4))
    axb.set_yticks(yt)
    axb.set_yticklabels([str(abs(v)) for v in yt])
    axb.set_ylabel('Memory bandwidth\n(B/cycle)')
    axb.set_xlim(-0.6, x - 0.6 - 0.8 + 0.6)
    axb.set_xticks(xs)
    axb.set_xticklabels(labels, rotation=55, ha='right', rotation_mode='anchor', fontsize=6.5)
    axb.tick_params(axis='x', length=0, pad=2)
    axb.set_xlabel('Benchmark', labelpad=2)
    for ax, t in zip((axt, axu, axb), 'abc'):
        plot_style.panel_tag(ax, t)
    axt.legend(loc='lower left', bbox_to_anchor=(0.0, 1.07), ncol=3, handlelength=1.3,
               columnspacing=1.2, borderaxespad=0.1)
    fig.savefig(out)
    fig.savefig(out.replace('.pdf', '.png'), dpi=200)
    plt.close(fig)
    print('written', out)
    return data


def main():
    plot_style.apply()
    allrows = []
    allrows += figure(('apps', 'rodinia', 'rivec'), os.path.join(HERE, 'figs', 'lanes_metrics_paper.pdf'), 3.6)
    allrows += figure(('suite2', 'sync'), os.path.join(HERE, 'figs', 'lanes_metrics_supp.pdf'), 4.2)
    with open(os.path.join(HERE, 'lanes_metrics.csv'), 'w', newline='\n') as f:
        f.write('suite,case,' + ','.join(f'laneops_per_cycle_{L}L,lane_util_{L}L,read_B_per_cycle_{L}L,'
                                         f'write_B_per_cycle_{L}L' for L in LANES) + '\n')
        for s, rows in allrows:
            for lab, m, case in rows:
                f.write(f'{s},{case},' + ','.join(','.join(f'{v:.3f}' for v in m[L]) for L in LANES) + '\n')
            print(f'{s:8s} ' + ' | '.join(
                f'{L}L thr {gmean([m[L][0] for _, m, _ in rows]):.2f} util {gmean([m[L][1] for _, m, _ in rows]):.2f}'
                f' rd+wr {sum(m[L][2] + m[L][3] for _, m, _ in rows) / len(rows):.2f}' for L in LANES))


if __name__ == '__main__':
    main()
