"""build_kernels_lanes.py - every kernel suite and the host's kernel headers for a lane count.

    python sw/ps_host/build_kernels_lanes.py 16

Assembles kernels/{apps,suite2,rodinia,rivec} (build.py --lanes L --out) into
build_kernels_l<L>/<suite>/ and the sync kernels (kernels/sync/build.py --lanes L, written to
kernels/sync/l<L>/ and copied to build_kernels_l<L>/sync/), then runs the four header
generators (gen_kernels*.py --kroot build_kernels_l<L> --out sw/ps_host/gen_l<L>). The
committed 8-lane headers in sw/ps_host are not touched. Each generator checks that its kernels
fit the 4 KB instruction RAM. RISC-V GCC: riscv-none-elf-gcc on PATH, or RISCV_GCC.
"""
import glob
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))


def run(cmd):
    print('$', ' '.join(os.path.relpath(c, ROOT) if os.path.isabs(c) else c for c in cmd), flush=True)
    subprocess.run(cmd, check=True)


def main():
    lanes = int(sys.argv[1]) if len(sys.argv) > 1 else 16
    kroot = os.path.join(ROOT, f'build_kernels_l{lanes}')
    out = os.path.join(HERE, f'gen_l{lanes}')
    for suite in ('apps', 'suite2', 'rodinia', 'rivec'):
        run([sys.executable, os.path.join(ROOT, 'kernels', suite, 'build.py'), '--lanes', str(lanes),
             '--out', os.path.join(kroot, suite)])
    run([sys.executable, os.path.join(ROOT, 'kernels', 'sync', 'build.py'), '--lanes', str(lanes)])
    sdir = os.path.join(ROOT, 'kernels', 'sync') if lanes == 8 else \
        os.path.join(ROOT, 'kernels', 'sync', f'l{lanes}')
    os.makedirs(os.path.join(kroot, 'sync'), exist_ok=True)
    for f in glob.glob(os.path.join(sdir, '*.svh')) + glob.glob(os.path.join(sdir, '*.hex')):
        shutil.copy(f, os.path.join(kroot, 'sync'))
    for g in ('gen_kernels', 'gen_kernels_s2', 'gen_kernels_rd', 'gen_kernels_rv'):
        run([sys.executable, os.path.join(HERE, g + '.py'), '--kroot', kroot, '--out', out])
    print(f'headers for {lanes} lanes in {out}')


if __name__ == '__main__':
    main()
