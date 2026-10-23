"""
amo_sweep.py -- line-aggregated AMOs against one read-modify-write per lane.

    python sim/amo_sweep.py            (writes docs/amo_agg.csv)

Runs tb_sync in xsim with AGG = 0 and AGG = 1 under each memory configuration
and collects the SYNCCSV rows of every kernel:
    config,agg,kernel,N,block_log2,cycles,gmem_txns,scratch_txns
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
SRC = run_xsim.POOL + [run_xsim.A + 'l1_dcache.sv', run_xsim.A + 'axi_line_master.sv',
                       'tests/tb_sync.sv']
OUT = os.path.join(run_xsim.ROOT, 'docs', 'amo_agg.csv')


def one(cfg, agg):
    name = f'amo_{cfg}_agg{agg}'
    run_xsim.TESTS[name] = ('tb_sync', SRC, [], False, CONFIGS[cfg] + [f'AGG={agg}'])
    ok, msg = run_xsim.run_test(name)
    log = os.path.join(run_xsim.BUILD, name, 'xsim.log')
    rows = {}   # xsim's log can repeat its last lines: keep one row per run
    if os.path.isfile(log):
        for line in open(log, encoding='utf-8', errors='replace'):
            if line.startswith('SYNCCSV,'):
                f = line.strip().split(',')[1:]
                rows[tuple(f[:3])] = [cfg, agg] + f
    return name, ok, msg, list(rows.values())


def main():
    jobs = [(c, a) for c in CONFIGS for a in (0, 1)]
    rows, fails = [], 0
    with cf.ThreadPoolExecutor(max_workers=4) as ex:
        for name, ok, msg, r in ex.map(lambda j: one(*j), jobs):
            print(f"{'PASS' if ok else 'FAIL'}  {name:16s} {msg}", flush=True)
            fails += not ok
            rows += r
    with open(OUT, 'w', newline='') as fh:
        w = csv.writer(fh, lineterminator='\n')
        w.writerow(['config', 'agg', 'kernel', 'N', 'block_log2', 'cycles',
                    'gmem_txns', 'scratch_txns'])
        w.writerows(rows)
    print(f'wrote {OUT} ({len(rows)} rows)\n')
    cyc = {(r[0], r[1], r[2], r[3], r[4]): (int(r[5]), int(r[6])) for r in rows}
    print(f"{'kernel':12s} {'config':6s} {'agg0':>7s} {'agg1':>7s} {'speedup':>7s} "
          f"{'txn0':>5s} {'txn1':>5s}")
    for (c, a, k, n, b), (t1, x1) in sorted(cyc.items(), key=lambda kv: (kv[0][2], kv[0][0])):
        if a == 1 and (c, 0, k, n, b) in cyc and k in ('histogram', 'hist_shared',
                                                        'amo_contend', 'amo_test'):
            t0, x0 = cyc[(c, 0, k, n, b)]
            print(f'{k:12s} {c:6s} {t0:7d} {t1:7d} {t0 / t1:7.2f} {x0:5d} {x1:5d}')
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
