"""compare_simtix.py - SIMTiX v3 vs Ara, CVA6 and Vortex, all measured on the ZCU102.

    python baselines/ara/compare_simtix.py            (from the repository root)

Reads the three board logs and writes docs/ara_cva6_simtix_comparison.csv:
  docs/zcu102_board_run_v3_apps3.txt  SIMTiX v3 (serial AMO, default build), 115.37 MHz,
                                      BOARD rows (accel cycles, us, A53 -O2 us)
  docs/zcu102_board_run_ara.txt       Ara 2 lanes + CVA6, 78.95 MHz, ARAK rows
  docs/zcu102_board_run_vortex.txt    Vortex 3.0, 1 core 8 warps x 8 threads, 125 MHz, VXB rows
Same inputs (apps_ara.c and the Vortex host draw them as sw/ps_host/apps.c), same A53
reference loops. Vortex runs the base kernels (SIMTiX's apps ported in
baselines/vortex/simtix_apps), so it is also compared with SIMTiX's base kernel.
For SIMTiX the best variant of the same computation is used (gemmrb, spmvz, stencilrb,
kmeansu, scanseg give the same outputs as gemm, spmv, stencil, kmeans, scan); the
base kernel's time is kept in its own column.
"""
import csv
import math
import os

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
SX_LOG = os.path.join(ROOT, 'docs', 'zcu102_board_run_v3_apps3.txt')
ARA_LOG = os.path.join(ROOT, 'docs', 'zcu102_board_run_ara.txt')
VX_LOG = os.path.join(ROOT, 'docs', 'zcu102_board_run_vortex.txt')
OUT = os.path.join(ROOT, 'docs', 'ara_cva6_simtix_comparison.csv')

APPS = [('gemm', [64, 256], 'gemmrb'), ('spmv', [4096, 65536], 'spmvz'),
        ('stencil', [128, 512], 'stencilrb'), ('kmeans', [16384, 262144], 'kmeansu'),
        ('bfs', [16384, 262144], None), ('scan', [65536, 1048576], 'scanseg'),
        ('mlp', [16, 256], None), ('conv8', [32, 128], None), ('embag', [256, 4096], None),
        ('hashj', [16, 22], None), ('mandel', [256, 1024], None), ('swat', [2048, 16384], None)]


def read():
    sx, ak, vx = {}, {}, {}
    for line in open(SX_LOG):
        p = line.strip().split(',')
        if p[0] == 'BOARD' and len(p) >= 9 and p[1] != 'kernel':
            sx[(p[1], int(p[2]))] = dict(cyc=int(p[3]), us=float(p[4]), a53=float(p[5]), err=int(p[8]))
    for line in open(ARA_LOG):
        p = line.strip().split(',')
        if p[0] == 'ARAK' and p[1] != 'app':
            ak[(p[1], int(p[2]), p[3])] = None if p[4] == 'skip' else \
                dict(cyc=int(p[4]), us=float(p[5]), a53=float(p[6]), err=int(p[8]))
    for line in open(VX_LOG):
        p = line.strip().split(',')
        if p[0] == 'VXB' and len(p) >= 9 and p[1] != 'app':
            vx[(p[1], int(p[2]))] = dict(cyc=int(p[3]), us=float(p[4]), a53=float(p[5]), err=int(p[8]))
    return sx, ak, vx


def main():
    sx, ak, vx = read()
    rows = []
    for app, sizes, var in APPS:
        for n in sizes:
            base = sx[(app, n)]
            alt = sx.get((var, n)) if var else None
            best, bname = (alt, var) if alt and alt['us'] < base['us'] else (base, app)
            cva6, ara, vort = ak[(app, n, 'cva6')], ak[(app, n, 'ara')], vx[(app, n)]
            if ara is None:
                ara_state = 'skip (deadlocks Ara)'
            elif ara['err']:
                ara_state = 'FAIL (%d wrong words)' % ara['err']
            else:
                ara_state = 'ok'
            ok = ara is not None and not ara['err']
            rows.append({
                'app': app, 'size': n,
                'simtix_kernel': bname, 'simtix_us': '%.1f' % best['us'], 'simtix_cycles': best['cyc'],
                'simtix_base_us': '%.1f' % base['us'],
                'ara_us': '%.1f' % ara['us'] if ara else '', 'ara_cycles': ara['cyc'] if ara else '',
                'ara_status': ara_state,
                'cva6_us': '%.1f' % cva6['us'], 'cva6_cycles': cva6['cyc'],
                'a53_O2_us': '%.1f' % base['a53'],
                'ara_over_simtix_time': '%.2f' % (ara['us'] / best['us']) if ok else '',
                'ara_over_simtix_cycles': '%.2f' % (ara['cyc'] / best['cyc']) if ok else '',
                'cva6_over_simtix_time': '%.1f' % (cva6['us'] / best['us']),
                'vortex_us': '%.1f' % vort['us'], 'vortex_cycles': vort['cyc'],
                'vortex_over_simtix_time': '%.2f' % (vort['us'] / best['us']),
                'vortex_over_simtix_cycles': '%.2f' % (vort['cyc'] / best['cyc']),
                'vortex_over_simtix_base_time': '%.2f' % (vort['us'] / base['us']),
                'vortex_over_simtix_base_cycles': '%.2f' % (vort['cyc'] / base['cyc']),
                'simtix_errors': best['err'], 'cva6_errors': cva6['err'], 'vortex_errors': vort['err'],
            })
    with open(OUT, 'w', newline='') as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    big = {a: s[-1] for a, s, _ in APPS}
    g = lambda xs: math.exp(sum(map(math.log, xs)) / len(xs))
    rt = [float(r['ara_over_simtix_time']) for r in rows if r['size'] == big[r['app']] and r['ara_over_simtix_time']]
    rc = [float(r['ara_over_simtix_cycles']) for r in rows if r['size'] == big[r['app']] and r['ara_over_simtix_cycles']]
    cv = [float(r['cva6_over_simtix_time']) for r in rows if r['size'] == big[r['app']]]
    vg = {k: [float(r[k]) for r in rows if r['size'] == big[r['app']]]
          for k in ('vortex_over_simtix_time', 'vortex_over_simtix_cycles',
                    'vortex_over_simtix_base_time', 'vortex_over_simtix_base_cycles')}
    print('wrote', OUT)
    print('large sizes: SIMTiX vs Ara geomean %.2fx time, %.2fx per cycle (%d apps); vs CVA6 %.1fx time (%d apps)'
          % (g(rt), g(rc), len(rt), g(cv), len(cv)))
    print('large sizes: SIMTiX best vs Vortex %.2fx time, %.2fx per cycle; same (base) kernel %.2fx time, '
          '%.2fx per cycle (%d apps); Vortex errors %d'
          % (g(vg['vortex_over_simtix_time']), g(vg['vortex_over_simtix_cycles']),
             g(vg['vortex_over_simtix_base_time']), g(vg['vortex_over_simtix_base_cycles']),
             len(vg['vortex_over_simtix_time']), sum(r['vortex_errors'] for r in rows)))


if __name__ == '__main__':
    main()
