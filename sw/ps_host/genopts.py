"""genopts.py - the shared command-line options of the gen_kernels*.py header generators.

    --kroot DIR   kernel images: DIR/{apps,suite2,rodinia,rivec,sync}/<name>.hex (.svh for sync);
                  default kernels/ (the committed 8-lane images)
    --out DIR     where the header is written; default sw/ps_host (the committed headers)

sw/ps_host/build_kernels_lanes.py builds every suite for another lane count into
build_kernels_l<L>/ and runs the generators with these options into sw/ps_host/gen_l<L>/.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def parse():
    kroot = os.path.join(HERE, '..', '..', 'kernels')
    out = HERE
    a = sys.argv[1:]
    while a:
        k = a.pop(0)
        if k == '--kroot':
            kroot = os.path.abspath(a.pop(0))
        elif k == '--out':
            out = os.path.abspath(a.pop(0))
        else:
            sys.exit(f'unknown option {k}')
    os.makedirs(out, exist_ok=True)
    return kroot, out
