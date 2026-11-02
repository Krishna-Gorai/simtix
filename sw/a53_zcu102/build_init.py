"""
build_init.py -- build the ZCU102 PS initialisation program (init/psu_init.elf).

    python sw/a53_zcu102/build_init.py [rev1.1|rev1.0]

Fetches U-Boot's board/xilinx/zynqmp/zynqmp-zcu102-<rev>/psu_init_gpl.c (GPL-2.0+)
into third_party/ (not committed), records its SHA-256, and compiles it with
init/crt0.S and init/init_main.c into an OCM-resident ELF for A53 #0. The board's
JTAG script (run_a53.tcl) loads it first, so that DDR4 and the clocks are up
without a Vivado-generated psu_init (the XCZU9EG is not in Vivado ML Standard).
Compiler: aarch64-none-elf-gcc on PATH, or AARCH64_GCC_DIR.
"""
import hashlib
import os
import shutil
import subprocess
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REV = sys.argv[1] if len(sys.argv) > 1 else 'rev1.1'
URL = ('https://raw.githubusercontent.com/u-boot/u-boot/master/board/xilinx/zynqmp/'
       f'zynqmp-zcu102-{REV}/psu_init_gpl.c')
TP = os.path.join(HERE, 'third_party', f'zcu102-{REV}')
SRC = os.path.join(TP, 'psu_init_gpl.c')
OUT = os.path.join(HERE, 'build')

if shutil.which('aarch64-none-elf-gcc') is None:
    os.environ['PATH'] = os.environ.get(
        'AARCH64_GCC_DIR', r'C:\toolchains\arm-gnu-14.2-aarch64-none-elf\bin') + os.pathsep + \
        os.environ['PATH']

os.makedirs(TP, exist_ok=True)
os.makedirs(OUT, exist_ok=True)
if not os.path.isfile(SRC):
    print('fetching', URL)
    with urllib.request.urlopen(URL) as r, open(SRC, 'wb') as f:
        f.write(r.read())
sha = hashlib.sha256(open(SRC, 'rb').read()).hexdigest()
with open(os.path.join(TP, 'SOURCE.txt'), 'w') as f:
    f.write(f'{URL}\nsha256 {sha}\n')
print(f'psu_init_gpl.c ({REV}) sha256 {sha}')

INIT = os.path.join(HERE, 'init')
elf = os.path.join(OUT, 'psu_init.elf')
cmd = ['aarch64-none-elf-gcc', '-O2', '-mcpu=cortex-a53', '-mstrict-align',
       '-mgeneral-regs-only', '-ffreestanding', '-fno-builtin', '-nostdlib',
       '-nostartfiles', '-Wno-unused-variable', '-Wno-unused-but-set-variable',
       '-I', os.path.join(INIT, 'include'),
       '-T', os.path.join(INIT, 'init.ld'), '-o', elf,
       os.path.join(INIT, 'crt0.S'), os.path.join(INIT, 'init_main.c'), SRC]
subprocess.run(cmd, check=True)
subprocess.run(['aarch64-none-elf-size', elf], check=True)
print('wrote', elf)
