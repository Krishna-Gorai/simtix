"""
build.py -- assemble the suite-2 kernels (docs/suite2_plan.md) as kernels/apps/build.py
does (rv32imaf + Zba/Zbb/Zicond, one .hex per kernel, here).

    python kernels/suite2/build.py [--lanes L] [--out DIR] [name ...]
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'apps'))
import build as apps_build                               # noqa: E402

apps_build.HERE = HERE                                   # sources: kernels/suite2/<name>.S
KERNELS = ['pathfinder', 'hotspot', 'jacobi2d', 'mv_row', 'mv_col', 'pr_contrib', 'pr_pull', 'cc_step',
           'bp_forward', 'bp_adjust', 'rs_hist', 'rs_scan', 'rs_scatter', 'blackscholes']

if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--lanes', type=int, default=8)
    ap.add_argument('--out', default=HERE)
    ap.add_argument('names', nargs='*')
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    for k in (args.names or KERNELS):
        apps_build.build(k, args.lanes, os.path.abspath(args.out))
