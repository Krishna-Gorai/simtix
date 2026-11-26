"""compare_lanes_cycles.py - board-size cycle counts of the 16-lane candidates against the 8-lane
board design (docs/lanes16_plan.md), from the per-case logs of sim/run_lanes_board.sh.

    python sim/compare_lanes_cycles.py [--f8 115.37]

Reads build_b8/<suite>/<app>/sim_l8_w8.log (baseline) and build_b16/<suite>/<app>/sim_l16_w<W>[_c<C>].log
(every 16-lane configuration found), sums the cycles of each case's kernel launches (APPCSV
lines), and writes docs/lanes16_cycles.csv: per case and configuration the cycle speed-up over 8
lanes and the break-even clock, the 16-lane clock above which it beats the 8-lane design at
--f8 MHz (115.37, the v3 board clock): f8 * cycles16 / cycles8. Prints a summary with geometric
means per suite and overall.
"""
import argparse
import glob
import math
import os
import re

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))


def cycles(log):
    """Total cycles of a case's kernel launches, and the number of launches."""
    tot = n = 0
    for line in open(log, errors='replace'):
        if line.startswith('APPCSV,'):
            f = line.strip().split(',')
            tot += int(f[4])
            n += 1
    return tot, n


def gmean(v):
    return math.exp(sum(math.log(x) for x in v) / len(v)) if v else float('nan')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--f8', type=float, default=115.37)
    a = ap.parse_args()
    base = {}
    for log in glob.glob(os.path.join(ROOT, 'build_b8', '*', '*', 'sim_l8_w8.log')):
        case = '/'.join(log.replace('\\', '/').split('/')[-3:-1])
        base[case] = cycles(log)
    cfgs = {}
    for log in glob.glob(os.path.join(ROOT, 'build_b16', '*', '*', 'sim_l16_w*.log')):
        p = log.replace('\\', '/').split('/')
        case = '/'.join(p[-3:-1])
        cfg = re.match(r'sim_(l16_w\d+(?:_[a-z]\d+)*)\.log', p[-1]).group(1)
        cfgs.setdefault(cfg, {})[case] = cycles(log)
    names = sorted(cfgs)
    rows = []
    for case in sorted(base):
        c8, n8 = base[case]
        row = [case, n8, c8]
        for cfg in names:
            c16, n16 = cfgs[cfg].get(case, (0, 0))
            if c16 and c8:                  # whole-application cycles (launch counts may differ: scan)
                row += [c16, c8 / c16, a.f8 * c16 / c8]
            else:
                row += [c16 or '', '', '']
        rows.append(row)
    out = os.path.join(ROOT, 'docs', 'lanes16_cycles.csv')
    with open(out, 'w', newline='\n') as f:
        hdr = ['case', 'launches', 'cycles_l8_w8']
        for cfg in names:
            hdr += [f'cycles_{cfg}', f'speedup_{cfg}', f'breakeven_MHz_{cfg}']
        f.write(','.join(hdr) + '\n')
        for r in rows:
            f.write(','.join(f'{x:.3f}' if isinstance(x, float) else str(x) for x in r) + '\n')
    print(f'{len(rows)} cases with an 8-lane baseline; configurations: {", ".join(names)}; wrote {out}')
    for k, cfg in enumerate(names):
        col = 3 + 3 * k + 1
        sp = {r[0]: r[col] for r in rows if isinstance(r[col], float)}
        print(f'\n{cfg}: {len(sp)} cases compared')
        for suite in ('apps', 'suite2', 'rodinia', 'rivec'):
            v = [s for c, s in sp.items() if c.startswith(suite + '/')]
            if v:
                print(f'  {suite:8s} n={len(v):2d}  geomean {gmean(v):.2f}x  min {min(v):.2f}x  max {max(v):.2f}x'
                      f'  break-even (gmean) {a.f8 / gmean(v):.1f} MHz')
        v = list(sp.values())
        if v:
            print(f'  ALL      n={len(v):2d}  geomean {gmean(v):.2f}x  min {min(v):.2f}x'
                  f'  -> break-even 16-lane clock {a.f8 / gmean(v):.1f} MHz (geomean), '
                  f'{a.f8 / min(v):.1f} MHz (every case)')


if __name__ == '__main__':
    main()
