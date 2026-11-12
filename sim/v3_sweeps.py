"""
v3_sweeps.py -- app_sweep.py and amo_sweep.py in the v3 configuration.

    python sim/v3_sweeps.py [apps] [amo]       (default: both)

The same runs as sim/app_sweep.py (small inputs) and sim/amo_sweep.py, with the v3
defines added to every run (8 warps, 64 KB L1, 16 MSHRs, 16 tags), into
docs/apps_agg_v3.csv and docs/amo_agg_v3.csv. The variants are named base_v3,
ser_v3 and par_v3, so the runs get their own xsim build directories.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_xsim   # noqa: E402
import app_sweep  # noqa: E402
import amo_sweep  # noqa: E402

V3 = ['SIMTIX_NUM_WARPS=8', 'SIMTIX_L1_KB=64', 'SIMTIX_L1_MSHR=16', 'SIMTIX_MEM_TAGS=16']
DOCS = os.path.join(run_xsim.ROOT, 'docs')


def v3(variants):
    """Rename the variants; their generics are unchanged."""
    return {k + '_v3': v for k, v in variants.items()}


_run_test = run_xsim.run_test


def run_test_v3(name, defines=(), plusargs=()):
    """run_xsim.run_test with the v3 defines on every compile of a *_v3 test."""
    if name.endswith('_v3'):
        defines = list(defines) + V3
    return _run_test(name, defines=defines, plusargs=plusargs)


run_xsim.run_test = run_test_v3


def main():
    what = sys.argv[1:] or ['apps', 'amo']
    rc = 0
    if 'apps' in what:
        app_sweep.VARIANTS = v3(app_sweep.VARIANTS)
        app_sweep.OUT = os.path.join(DOCS, 'apps_agg_v3.csv')
        sys.argv = [sys.argv[0], '--size', 'small']
        rc |= app_sweep.main()
    if 'amo' in what:
        amo_sweep.VARIANTS = v3(amo_sweep.VARIANTS)
        amo_sweep.OUT = os.path.join(DOCS, 'amo_agg_v3.csv')
        rc |= amo_sweep.main()
    return rc


if __name__ == '__main__':
    sys.exit(main())
