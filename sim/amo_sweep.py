"""
amo_sweep.py -- line-aggregated AMOs against one read-modify-write per lane.

    python sim/amo_sweep.py            (writes docs/amo_agg.csv)

Runs tb_sync in xsim under each memory configuration with three AMO variants:
    base   AGG = 0             one read-modify-write per lane
    ser    AGG = 1, APAR = 0   one per line, lanes applied one per cycle
    par    AGG = 1, APAR = 1   one per line, lanes on distinct words in parallel
and collects the SYNCCSV rows of every kernel:
    config,variant,kernel,N,block_log2,cycles,gmem_txns,scratch_txns
"""
import concurrent.futures as cf
import csv
import os
import sys

import run_xsim

CONFIGS = {   # memory configurations of tb_sync (see its parameters)
    'lat0':  [],
    'lat7':  ['MEM_LAT=7', 'MEM_STALL=1'],
    'l1':    ['MEM_LAT=20', 'MEM_STALL=1', 'MEM_OOO=1', 'L1=1'],
    'axi':   ['MEM_LAT=24', 'MEM_STALL=1', 'MEM_OOO=1', 'L1=1', 'AXI=1'],
}
VARIANTS = {'base': ['AGG=0'], 'ser': ['AGG=1', 'APAR=0'], 'par': ['AGG=1', 'APAR=1']}
SRC = run_xsim.POOL + [run_xsim.A + 'l1_dcache.sv', run_xsim.A + 'axi_line_master.sv',
                       'tests/tb_sync.sv']
OUT = os.path.join(run_xsim.ROOT, 'docs', 'amo_agg.csv')
SHOW = ('histogram', 'hist_shared', 'amo_contend', 'amo_test')


def one(cfg, var):
    name = f'amo_{cfg}_{var}'
    run_xsim.TESTS[name] = ('tb_sync', SRC, [], False, CONFIGS[cfg] + VARIANTS[var])
    ok, msg = run_xsim.run_test(name)
    log = os.path.join(run_xsim.BUILD, name, 'xsim.log')
    rows = {}   # xsim's log can repeat its last lines: keep one row per run
    if os.path.isfile(log):
        for line in open(log, encoding='utf-8', errors='replace'):
            if line.startswith('SYNCCSV,'):
                f = line.strip().split(',')[1:]
                rows[tuple(f[:3])] = [cfg, var] + f
    return name, ok, msg, list(rows.values())


def main():
    jobs = [(c, v) for c in CONFIGS for v in VARIANTS]
    rows, fails = [], 0
    with cf.ThreadPoolExecutor(max_workers=3) as ex:
        for name, ok, msg, r in ex.map(lambda j: one(*j), jobs):
            print(f"{'PASS' if ok else 'FAIL'}  {name:16s} {msg}", flush=True)
            fails += not ok
            rows += r
    with open(OUT, 'w', newline='') as fh:
        w = csv.writer(fh, lineterminator='\n')
        w.writerow(['config', 'variant', 'kernel', 'N', 'block_log2', 'cycles',
                    'gmem_txns', 'scratch_txns'])
        w.writerows(rows)
    print(f'wrote {OUT} ({len(rows)} rows)\n')
    cyc = {(r[0], r[1], r[2], r[3], r[4]): (int(r[5]), int(r[6])) for r in rows}
    print(f"{'kernel':12s} {'config':6s} {'base':>7s} {'ser':>7s} {'par':>7s} "
          f"{'x ser':>6s} {'x par':>6s} {'txn':>5s} {'txn agg':>7s}")
    for k in SHOW:
        for c in CONFIGS:
            key = [kk for kk in cyc if kk[0] == c and kk[1] == 'base' and kk[2] == k]
            if not key:
                continue
            _, _, _, n, b = key[0]
            t0, x0 = cyc[(c, 'base', k, n, b)]
            t1, x1 = cyc.get((c, 'ser', k, n, b), (0, 0))
            t2, _ = cyc.get((c, 'par', k, n, b), (0, 0))
            print(f'{k:12s} {c:6s} {t0:7d} {t1:7d} {t2:7d} {t0 / max(t1, 1):6.2f} '
                  f'{t0 / max(t2, 1):6.2f} {x0:5d} {x1:7d}')
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
