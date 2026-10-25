"""
vortex_syn.py -- SIMTiX and Vortex synthesis results, and run time and energy per case.

    python sim/vortex_syn.py [--root C:/work/vortex_syn] [--apps docs/vortex_apps.csv]
                             [--out docs/vortex_syn.csv] simtix=simtix_ps_top RUN=BUILD ...

Each NAME=BUILD is a build directory of baselines/vortex/syn/run_syn.ps1 under --root
(synth_summary.csv and power_vectorless.rpt); a build that has not finished is skipped.
Name a Vortex build after its run in vortex_compare.py's CSV (w4_bus128_ip, ...) and
it is paired with that run's cycles: run time is cycles / Fmax of each design, energy
is power x cycles x the constrained clock period (the power report's clock).

Writes one row per build: design, build, period_ns, wns_ns, fmax_mhz, lut, lutram, ff,
bram, uram, dsp, power_w, dynamic_w, static_w. Prints, per case, Vortex / SIMTiX for
cycles, run time and energy.
"""
import argparse
import csv
import math
import os
import re
import sys
from collections import OrderedDict

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
POWER = {'power_w': 'Total On-Chip Power', 'dynamic_w': 'Dynamic', 'static_w': 'Device Static'}


def read_build(path):
    with open(os.path.join(path, 'synth_summary.csv'), newline='') as f:
        r = next(csv.DictReader(f))
    row = {k: r[k] for k in ('period_ns', 'wns_ns', 'fmax_mhz', 'lut', 'lutram', 'ff',
                             'bram', 'uram', 'dsp')}
    with open(os.path.join(path, 'power_vectorless.rpt')) as f:
        text = f.read()
    for key, label in POWER.items():
        m = re.search(r'\|\s*' + label + r' \(W\)\s*\|\s*([0-9.]+)', text)
        row[key] = m.group(1) if m else ''
    return row


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', default='C:/work/vortex_syn')
    ap.add_argument('--apps', default=os.path.join(ROOT, 'docs', 'vortex_apps.csv'))
    ap.add_argument('--out', default=os.path.join(ROOT, 'docs', 'vortex_syn.csv'))
    ap.add_argument('builds', nargs='+', help='NAME=build directory under --root')
    args = ap.parse_args()

    builds = OrderedDict()
    for spec in args.builds:
        name, d = spec.split('=', 1)
        path = os.path.join(args.root, d)
        if not os.path.exists(os.path.join(path, 'power_vectorless.rpt')):
            print(f'{name}: {path} has no results yet, skipped')
            continue
        builds[name] = dict(build=d, **read_build(path))
    if 'simtix' not in builds:
        sys.exit('simtix=<build> is required')

    cols = ['design', 'build', 'period_ns', 'wns_ns', 'fmax_mhz', 'lut', 'lutram', 'ff',
            'bram', 'uram', 'dsp', 'power_w', 'dynamic_w', 'static_w']
    with open(args.out, 'w', newline='') as f:
        w = csv.writer(f, lineterminator='\n')
        w.writerow(cols)
        for name, b in builds.items():
            w.writerow([name] + [b[c] for c in cols[1:]])

    print(f"{'design':16s} {'Fmax':>6s} {'LUT':>7s} {'FF':>7s} {'BRAM':>5s} {'DSP':>4s} {'W':>6s}")
    for name, b in builds.items():
        print(f"{name:16s} {float(b['fmax_mhz']):6.1f} {b['lut']:>7s} {b['ff']:>7s} "
              f"{b['bram']:>5s} {b['dsp']:>4s} {float(b['power_w']):6.3f}")

    with open(args.apps, newline='') as f:
        totals = [r for r in csv.DictReader(f) if r['launch'] == 'total']
    s = builds['simtix']
    paired = [n for n in builds if n != 'simtix' and f'{n}_cycles' in totals[0]]

    def cost(b, cyc):
        """Run time (us) at the design's Fmax, energy (uJ) at the constrained clock."""
        return cyc / float(b['fmax_mhz']), float(b['power_w']) * cyc * float(b['period_ns']) / 1e3

    for n in paired:
        print(f"\n{n} / SIMTiX{'':12s} {'cycles':>7s} {'time':>7s} {'energy':>7s}")
        logs = [[], [], []]
        for r in totals:
            sc, vc = int(r['simtix_cycles']), int(r[f'{n}_cycles'])
            (st, se), (vt, ve) = cost(s, sc), cost(builds[n], vc)
            q = (vc / sc, vt / st, ve / se)
            for l, v in zip(logs, q):
                l.append(math.log(v))
            print(f"{r['case']:28s}" + ''.join(f' {v:7.2f}' for v in q))
        print(f"{'geometric mean':28s}" + ''.join(f' {math.exp(sum(l) / len(l)):7.2f}'
                                                   for l in logs))
    print('wrote', args.out)


if __name__ == '__main__':
    main()
