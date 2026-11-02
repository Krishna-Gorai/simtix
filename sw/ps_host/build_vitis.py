"""
build_vitis.py -- build the SIMTiX v2 A53 host program with the Vitis Python API.

    vitis -s sw/ps_host/build_vitis.py [zcu102|zcu104] [path/to/.xsa]

Creates (or recreates) the workspace of the board, sw/ps_host/ws_zcu102 (the
default) or sw/ps_host/ws (ZCU104), with
  simtix_plat : a standalone platform for psu_cortexa53_0 from the .xsa
                (default: fpga/simtix_ps_zcu102.xsa or fpga/simtix_ps.xsa, written
                by fpga/create_bd_ps.tcl)
  ps_host     : the host application (main.c, apps.c, power.c, kernels.h), built -O2;
                for the ZCU104 with -DSIMTIX_BOARD_ZCU104 (power.c's monitor table)
and prints the path of the resulting ELF.
"""
import os
import shutil
import stat
import sys

import vitis

HERE = os.path.dirname(os.path.abspath(__file__))
ARGS = sys.argv[1:]
BOARD = 'zcu104' if 'zcu104' in ARGS else 'zcu102'
SFX = '' if BOARD == 'zcu104' else '_' + BOARD
XSAS = [a for a in ARGS if a.lower().endswith('.xsa')]
XSA = os.path.abspath(XSAS[0] if XSAS else
                      os.path.join(HERE, '..', '..', 'fpga', f'simtix_ps{SFX}.xsa'))
WS = os.path.join(HERE, 'ws' + SFX)
print(f'board {BOARD}, platform {XSA}, workspace {WS}')

# The BSP build calls aarch64-none-elf-gcc by name. Installs without the Zynq
# UltraScale+ software tools lack it: fall back to the Arm GNU toolchain.
if shutil.which('aarch64-none-elf-gcc') is None:
    gcc_dir = os.environ.get('AARCH64_GCC_DIR',
                             r'C:\toolchains\arm-gnu-14.2-aarch64-none-elf\bin')
    os.environ['PATH'] = gcc_dir + os.pathsep + os.environ['PATH']

if not os.path.isfile(XSA):
    sys.exit(f'no hardware platform at {XSA}; run fpga/create_bd_ps.tcl -tclargs build {BOARD}')
if os.path.isdir(WS):
    # the generated SDT headers are read-only
    shutil.rmtree(WS, onexc=lambda f, p, e: (os.chmod(p, stat.S_IWRITE), f(p)))

client = vitis.create_client()
client.set_workspace(path=WS)

platform = client.create_platform_component(
    name='simtix_plat', hw_design=XSA, os='standalone',
    cpu='psu_cortexa53_0', domain_name='standalone_a53',
    no_boot_bsp=True, generate_dtb=False)   # JTAG boot via psu_init.tcl: no FSBL/PMUFW, no DT
platform.build()

xpfm = client.find_platform_in_repos('simtix_plat')
app = client.create_app_component(name='ps_host', platform=xpfm,
                                  domain='standalone_a53', template='empty_application')
app.import_files(from_loc=HERE, files=['main.c', 'apps.c', 'power.c', 'power.h', 'kernels.h'],
                 dest_dir_in_cmp='src')
app.set_app_config(key='USER_COMPILE_OPTIMIZATION_LEVEL', values='-O2')
# xil_printf -> con_printf (main.c): the console also goes to DDR, for run_board.tcl
defs = ['xil_printf=con_printf'] + (['SIMTIX_BOARD_ZCU104'] if BOARD == 'zcu104' else [])
app.set_app_config(key='USER_COMPILE_DEFINITIONS', values=defs)
app.build()

elf = os.path.join(WS, 'ps_host', 'build', 'ps_host.elf')
print('ELF:', elf if os.path.isfile(elf) else '(not found -- see the build log above)')
vitis.dispose()
