"""gen_lanes_board.py - the board-size cases of every suite for another lane count (phase 4 of
docs/lanes16_plan.md), for sim/run_lanes_board.sh (Verilator, WSL).

    python sim/gen_lanes_board.py 16 [--suites apps suite2 rodinia rivec]

Needs build_kernels_l<L>/ (python sw/ps_host/build_kernels_lanes.py L). Writes, one case per
manifest (so a failure names its case and a long suite can be resumed),
    build_b<L>/<suite>/<app>/apps.manifest
with the board inputs (gen_*.py --size board, WORDS_LG = 25 as the 8-lane board-size runs) and
paths rewritten for WSL (C:/ -> /mnt/c/).
"""
import argparse
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..'))
sys.path.insert(0, HERE)

# suite -> (generator, its application names at --size board)
SUITES = {
    'apps':    ('gen_apps.py', ['gemm', 'spmv', 'stencil', 'kmeans', 'bfs', 'scan', 'mlp', 'gemmrb',
                                'scanseg', 'stencilrb', 'kmeansu', 'spmvz', 'conv8', 'embag', 'hashj',
                                'mandel', 'swat']),
    'suite2':  ('gen_suite2.py', None),
    'rodinia': ('gen_rodinia.py', None),
    'rivec':   ('gen_rivec.py', None),
}


def app_names(gen):
    mod = __import__(gen[:-3])
    return list(mod.APPS)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('lanes', type=int)
    ap.add_argument('--suites', nargs='*', default=list(SUITES))
    ap.add_argument('--only', nargs='*', help='application names (all if omitted)')
    ap.add_argument('--force', action='store_true', help='regenerate cases already generated')
    a = ap.parse_args()
    kroot = os.path.join(ROOT, f'build_kernels_l{a.lanes}')
    if not os.path.isdir(kroot):
        sys.exit(f'no {kroot}: run python sw/ps_host/build_kernels_lanes.py {a.lanes}')
    for suite in a.suites:
        gen, names = SUITES[suite]
        names = names or app_names(gen)
        for app in names:
            if a.only and app not in a.only:
                continue
            out = os.path.join(ROOT, f'build_b{a.lanes}', suite, app)
            done = os.path.join(out, 'generated.ok')     # written last: a stopped run resumes
            if os.path.isfile(done) and not a.force:
                print(f'== {suite}/{app} (already generated)', flush=True)
                continue
            cmd = [sys.executable, os.path.join(HERE, gen), '--size', 'board', '--words-lg', '25',
                   '--lanes', str(a.lanes), '--out', out, '--only', app]
            cmd += (['--kdir', os.path.join(kroot, 'apps')] if suite == 'apps' else ['--kroot', kroot])
            print(f'== {suite}/{app}', flush=True)
            subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL)
            man = os.path.join(out, 'apps.manifest')
            txt = open(man).read().replace('C:/', '/mnt/c/').replace('C:\\', '/mnt/c/').replace('\\', '/')
            open(man, 'w', newline='\n').write(txt)
            open(done, 'w').write('ok\n')
    print('done')


if __name__ == '__main__':
    main()
