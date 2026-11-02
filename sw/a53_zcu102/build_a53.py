"""
build_a53.py -- build the A53 reference program for the ZCU102 (build/a53_apps_<opt>.elf).

    python sw/a53_zcu102/build_a53.py [O2|O3]

O2 (the default) is the board host's own build: -O2, generic ARMv8 tuning, as
Vitis built ps_host. O3 adds -mcpu=cortex-a53 and lets GCC vectorize with NEON;
both are IEEE-exact (no -ffast-math, and apps.c forbids contracting a multiply
and an add into an FMA), so they compute the same results.

Compiles a53_main.c with sw/ps_host/apps.c (-DSIMTIX_A53_ONLY) and power.c (the
ZCU102 monitor table) against the standalone A53 BSP of the board-host workspace
(sw/ps_host/ws, built by sw/ps_host/build_vitis.py zcu104): the processing system
of the XCZU7EV and the XCZU9EG is the same, and the program sets up the two board
differences itself (the I2C0 controller and the measured system-counter clock).
The flags and libraries are those Vitis used for ps_host. Compiler:
aarch64-none-elf-gcc on PATH, or AARCH64_GCC_DIR.
"""
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
HOST = os.path.join(HERE, '..', 'ps_host')
BSP = os.path.join(HOST, 'ws', 'simtix_plat', 'export', 'simtix_plat', 'sw', 'standalone_a53')
LSCRIPT = os.path.join(HOST, 'ws', 'ps_host', 'src', 'lscript.ld')
OUT = os.path.join(HERE, 'build')
OPT = sys.argv[1] if len(sys.argv) > 1 else 'O2'
FLAGS = {'O2': ['-O2'], 'O3': ['-O3', '-mcpu=cortex-a53']}[OPT]
BUILD = ' '.join(FLAGS)

if shutil.which('aarch64-none-elf-gcc') is None:
    os.environ['PATH'] = os.environ.get(
        'AARCH64_GCC_DIR', r'C:\toolchains\arm-gnu-14.2-aarch64-none-elf\bin') + os.pathsep + \
        os.environ['PATH']
for p in (BSP, LSCRIPT):
    if not os.path.exists(p):
        raise SystemExit(f'missing {p}: build the board-host workspace first '
                         '(vitis -s sw/ps_host/build_vitis.py zcu104)')

os.makedirs(OUT, exist_ok=True)
elf = os.path.join(OUT, f'a53_apps_{OPT}.elf')
inc = os.path.join(BSP, 'include')
cmd = ['aarch64-none-elf-gcc', '-DSDT', '-DSIMTIX_A53_ONLY', f'-specs={os.path.join(BSP, "Xilinx.spec")}',
       f'-DA53_BUILD="{BUILD}"', '-isystem', inc, '-I', inc, '-I', HOST, '-Wall', '-Wextra',
       *FLAGS, '-g3', '-U__clang__',
       os.path.join(HERE, 'a53_main.c'), os.path.join(HOST, 'apps.c'), os.path.join(HOST, 'power.c'),
       '-Wl,--wrap=outbyte', '-Wl,-T', f'-Wl,{LSCRIPT}', '-L', os.path.join(BSP, 'lib'),
       '-Wl,--start-group,-lxilstandalone', '-lxiltimer', '-lxil', '-lgcc', '-lc', '-Wl,--end-group',
       '-o', elf]
subprocess.run(cmd, check=True)
subprocess.run(['aarch64-none-elf-size', elf], check=True)
print('wrote', elf)
