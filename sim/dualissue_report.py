"""dualissue_report.py - summarise the dual-issue opportunity counter (SIMTIX_DUALISSUE_COUNT).

    python sim/dualissue_report.py <xsim.log> [--csv out.csv]

warp_pool.sv prints one DUALISSUE line per launch, just before tb_apps prints that launch's
APPCSV line; this script pairs them, sums the launches of each application, and reports:
  IPC       = issued / cycles (single issue, as built)
  opp %     = cycles with a dual-issue opportunity / cycles
  bound     = cycles / max(cycles - opp, issued / 2): the speed-up a second issue slot could
              give if every opportunity saved one cycle; an upper bound, since a real second
              slot changes the schedule (warps run ahead and then wait for memory sooner)
  IPC bound = issued / max(cycles - opp, issued / 2)
and the class pairs behind the opportunities.
"""
import argparse
import collections
import csv
import math
import re


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('log')
    ap.add_argument('--csv')
    a = ap.parse_args()
    apps = collections.OrderedDict()
    pend = None
    for line in open(a.log, encoding='utf-8', errors='replace'):
        if line.startswith('DUALISSUE,'):
            kv = dict(f.split('=', 1) for f in line.strip().split(',')[1:])
            pend = kv
        elif line.startswith('APPCSV,') and pend is not None:
            case = line.split(',')[1]
            s = apps.setdefault(case, collections.Counter())
            for k, v in pend.items():
                if k != 'pc':
                    s[k] += int(v)
            s['launches'] += 1
            pend = None
    rows = []
    print('%-28s %8s %6s %6s %6s %7s %9s  %s' % ('application', 'launch', 'IPC', 'opp%', 'unk%',
                                               'bound', 'IPC bnd', 'top pairs'))
    g = []
    for case, s in apps.items():
        cyc, iss, opp = s['cycles'], s['issued'], s['opp']
        dual = max(cyc - opp, iss / 2)
        bound = cyc / dual
        pairs = sorted(((k, v) for k, v in s.items() if '+' in k), key=lambda kv: -kv[1])[:3]
        print('%-28s %8d %6.2f %5.1f%% %5.2f%% %6.2fx %9.2f  %s' % (
            case, s['launches'], iss / cyc, 100 * opp / cyc, 100 * s['unknown'] / cyc, bound,
            iss / dual, ', '.join('%s %.0f%%' % (k, 100 * v / max(opp, 1)) for k, v in pairs)))
        g.append(bound)
        rows.append({'app': case, 'launches': s['launches'], 'cycles': cyc, 'issued': iss,
                     'ipc': '%.3f' % (iss / cyc), 'opp': opp, 'unknown': s['unknown'],
                     'bound': '%.3f' % bound, 'ipc_bound': '%.3f' % (iss / dual),
                     **{k: v for k, v in s.items() if '+' in k}})
    if g:
        print('geometric mean of the bound over %d applications: %.2fx'
              % (len(g), math.exp(sum(map(math.log, g)) / len(g))))
    if a.csv and rows:
        keys = sorted({k for r in rows for k in r}, key=lambda k: (k not in rows[0], k))
        with open(a.csv, 'w', newline='') as f:
            w = csv.DictWriter(f, fieldnames=keys)
            w.writeheader()
            w.writerows(rows)


if __name__ == '__main__':
    main()
