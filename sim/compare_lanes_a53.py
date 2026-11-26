"""compare_lanes_a53.py - the A53, the 8-lane SIMTiX board design and the 16-lane design, per case.

    python sim/compare_lanes_a53.py [--f16 100] [--cfg l16_w8_s2]

A53 (-O2) and 8-lane SIMTiX times are MEASURED on the ZCU102 (v3 board design at 115.37 MHz):
  applications and suite 2: docs/zcu102_board_run_v3_apps3.txt / _v3_s2.txt, the medium input of
    each kernel (the first BOARD row), which is the board-size simulation case;
  Rodinia / RiVEC: docs/rodinia_results.csv / rivec_results.csv (hotspot: the 512 row).
The 16-lane time is PROJECTED: the measured 8-lane time x (16-lane cycles / 8-lane cycles from the
board-size simulations, docs/lanes16_cycles.csv) x (115.37 / f16). Where the board ran more
iterations than the simulation (hotspot3d, gaussian, kmeans; RiVEC jacobi, pathfinder,
blackscholes, lavamd), this assumes the cycle ratio of the simulated iterations holds for all.
--cfg picks the 16-lane column (l16_w8 = one divide/sqrt core; l16_w8_s2 = two, used where that
run has the case, else l16_w8). Writes docs/lanes16_vs_a53.csv.
"""
import argparse
import csv
import math
import os

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
DOCS = os.path.join(ROOT, 'docs')
F8 = 115.37


def board_rows(path):
    """First BOARD row of each kernel: (accel_us, a53_us)."""
    out = {}
    for line in open(path, encoding='utf-8', errors='replace'):
        line = line.replace('\x00', '').strip()
        if line.startswith('BOARD,') and not line.startswith('BOARD,kernel'):
            f = line.split(',')
            out.setdefault(f[1], (float(f[4]), float(f[5])))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--f16', type=float, default=100.0, help='16-lane clock in MHz')
    ap.add_argument('--cfg', default='l16_w8_s2')
    a = ap.parse_args()
    cyc = {x['case']: x for x in csv.DictReader(open(os.path.join(DOCS, 'lanes16_cycles.csv')))}
    meas = {}
    apps = board_rows(os.path.join(DOCS, 'zcu102_board_run_v3_apps3.txt'))
    s2 = board_rows(os.path.join(DOCS, 'zcu102_board_run_v3_s2.txt'))
    for case in cyc:
        suite, app = case.split('/')
        if suite == 'apps' and app in apps:
            meas[case] = apps[app]
        elif suite == 'suite2' and app in s2:
            meas[case] = s2[app]
    for suite, f in (('rodinia', 'rodinia_results.csv'), ('rivec', 'rivec_results.csv')):
        for x in csv.DictReader(open(os.path.join(DOCS, f))):
            key = f"{suite}/{x['app']}"
            if key in meas:                      # hotspot: keep the first (512) row
                continue
            meas[key] = (float(x['simtix_us']), float(x['a53_O2_us']))
    rows = []
    for case in sorted(cyc):
        if case not in meas:
            continue
        x = cyc[case]
        c8 = float(x['cycles_l8_w8'])
        used = a.cfg if x.get(f'cycles_{a.cfg}') else 'l16_w8'
        c16 = float(x[f'cycles_{used}'])
        t8, ta53 = meas[case]
        t16 = t8 * (c16 / c8) * (F8 / a.f16)
        rows.append([case, ta53, t8, t16, ta53 / t8, ta53 / t16, t8 / t16, used])
    out = os.path.join(DOCS, 'lanes16_vs_a53.csv')
    with open(out, 'w', newline='\n') as f:
        f.write(f'case,a53_us,simtix8_us_measured,simtix16_us_projected_{a.f16:g}MHz,'
                'speedup8_vs_a53,speedup16_vs_a53,speedup16_vs_8,cfg16\n')
        for r in rows:
            f.write(','.join([r[0]] + [f'{v:.3f}' for v in r[1:7]] + [r[7]]) + '\n')
    print(f'16 lanes at {a.f16:g} MHz (8 lanes measured at {F8} MHz); speed-up = A53 time / SIMTiX time')
    print(f"{'case':22s} {'A53 us':>11s} {'8L us':>11s} {'16L us':>11s} {'8L/A53':>7s} {'16L/A53':>8s} {'16L/8L':>7s}")
    for r in rows:
        mark = '' if r[7] == a.cfg else ' (1 div/sqrt core)'
        print(f'{r[0]:22s} {r[1]:11.1f} {r[2]:11.1f} {r[3]:11.1f} {r[4]:7.2f} {r[5]:8.2f} {r[6]:7.2f}{mark}')
    g = lambda v: math.exp(sum(map(math.log, v)) / len(v))
    for suite in ('apps', 'suite2', 'rodinia', 'rivec', ''):
        s = [r for r in rows if r[0].startswith(suite)]
        if s:
            print(f"  {suite or 'ALL':8s} n={len(s):2d}  geomean vs A53: 8 lanes {g([r[4] for r in s]):.2f}x, "
                  f"16 lanes {g([r[5] for r in s]):.2f}x;  faster than A53: 8 lanes {sum(r[4] > 1 for r in s)}, "
                  f"16 lanes {sum(r[5] > 1 for r in s)}")


if __name__ == '__main__':
    main()
