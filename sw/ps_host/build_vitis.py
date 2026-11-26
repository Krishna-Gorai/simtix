"""
build_vitis.py -- build the SIMTiX v2 A53 host program with the Vitis Python API.

    vitis -s sw/ps_host/build_vitis.py [zcu102|zcu104] [lanes<L>] [rodinia|rivec] [path/to/.xsa]

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
# lanes<L> (L != 8): the host for the L-lane accelerator: headers from gen_l<L>/
# (build_kernels_lanes.py L), -DSIMTIX_LANES=L, the board design built with tagl<L>
# (fpga/simtix_ps_zcu102_l<L>.xsa) and its own workspace ws_zcu102_l<L>
LANES = next((int(a[5:]) for a in ARGS if a.startswith('lanes') and a[5:].isdigit()), 8)
LSFX = '' if LANES == 8 else f'_l{LANES}'
XSAS = [a for a in ARGS if a.lower().endswith('.xsa')]
XSA = os.path.abspath(XSAS[0] if XSAS else
                      os.path.join(HERE, '..', '..', 'fpga', f'simtix_ps{SFX}{LSFX}.xsa'))
WS = os.path.join(HERE, 'ws' + SFX + LSFX)
HDRS = HERE if LANES == 8 else os.path.join(HERE, f'gen_l{LANES}')
if LANES != 8 and not os.path.isfile(os.path.join(HDRS, 'kernels.h')):
    sys.exit(f'no headers in {HDRS}; run python sw/ps_host/build_kernels_lanes.py {LANES}')
print(f'lanes {LANES}, kernel headers from {HDRS}')
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
app.import_files(from_loc=HERE, files=['main.c', 'apps.c', 'power.c', 'power.h',
                                       'suite2.inc', 'rodinia.inc', 'rivec.inc'],
                 dest_dir_in_cmp='src')
app.import_files(from_loc=HDRS, files=['kernels.h', 'kernels_s2.h', 'kernels_rd.h', 'kernels_rv.h'],
                 dest_dir_in_cmp='src')
app.import_files(from_loc=os.path.join(HERE, '..', '..', 'kernels', 'suite2'), files=['s2_ref.h'],
                 dest_dir_in_cmp='src')
app.import_files(from_loc=os.path.join(HERE, '..', '..', 'kernels', 'rodinia'), files=['rd_ref.h'],
                 dest_dir_in_cmp='src')
app.import_files(from_loc=os.path.join(HERE, '..', '..', 'kernels', 'rivec'), files=['rv_ref.h'],
                 dest_dir_in_cmp='src')
app.set_app_config(key='USER_COMPILE_OPTIMIZATION_LEVEL', values='-O2')
# xil_printf -> con_printf (main.c): the console also goes to DDR, for run_board.tcl
defs = ['xil_printf=con_printf'] + (['SIMTIX_BOARD_ZCU104'] if BOARD == 'zcu104' else [])
defs += ['RD_ONLY'] if 'rodinia' in ARGS else []          # the Rodinia suite alone (rodinia.inc)
defs += ['RV_ONLY'] if 'rivec' in ARGS else []            # RiVEC batch 1 alone (rivec.inc)
defs += ['PW_ONLY'] if 'power' in ARGS else []            # the power pass alone (docs/power_plan.md)
defs += [f'SIMTIX_LANES={LANES}'] if LANES != 8 else []   # apps.c, main.c, s2_ref.h
app.set_app_config(key='USER_COMPILE_DEFINITIONS', values=defs)
app.build()

elf = os.path.join(WS, 'ps_host', 'build', 'ps_host.elf')
print('ELF:', elf if os.path.isfile(elf) else '(not found -- see the build log above)')
vitis.dispose()
