"""
build_vitis_vortex.py -- build the A53 host for Vortex with the Vitis Python API.

    vitis -s baselines/vortex/host/build_vitis_vortex.py [path/to/.xsa]

Workspace baselines/vortex/host/ws_zcu102 with the platform vx_plat (standalone,
psu_cortexa53_0, from baselines/vortex/vortex_ps_zcu102.xsa by default) and the
application vx_host: main_vortex.c, vx_image.h (gen_vxbin.py) and SIMTiX's
sw/ps_host/apps.c, power.c, power.h, kernels.h, built -O2 with -DSIMTIX_VORTEX and
-Dxil_printf=con_printf (as sw/ps_host/build_vitis.py).
"""
import os
import shutil
import stat
import sys

import vitis

HERE = os.path.dirname(os.path.abspath(__file__))
PSHOST = os.path.normpath(os.path.join(HERE, '..', '..', '..', 'sw', 'ps_host'))
XSAS = [a for a in sys.argv[1:] if a.lower().endswith('.xsa')]
XSA = os.path.abspath(XSAS[0] if XSAS else os.path.join(HERE, '..', 'vortex_ps_zcu102.xsa'))
WS = os.path.join(HERE, 'ws_zcu102')
print(f'platform {XSA}, workspace {WS}')

if shutil.which('aarch64-none-elf-gcc') is None:
    gcc_dir = os.environ.get('AARCH64_GCC_DIR',
                             r'C:\toolchains\arm-gnu-14.2-aarch64-none-elf\bin')
    os.environ['PATH'] = gcc_dir + os.pathsep + os.environ['PATH']

if not os.path.isfile(XSA):
    sys.exit(f'no hardware platform at {XSA}; run create_bd_vortex.tcl -tclargs build')
if not os.path.isfile(os.path.join(HERE, 'vx_image.h')):
    sys.exit('no vx_image.h; run gen_vxbin.py <kernel.vxbin> first')
if os.path.isdir(WS):
    shutil.rmtree(WS, onexc=lambda f, p, e: (os.chmod(p, stat.S_IWRITE), f(p)))

client = vitis.create_client()
client.set_workspace(path=WS)
platform = client.create_platform_component(
    name='vx_plat', hw_design=XSA, os='standalone',
    cpu='psu_cortexa53_0', domain_name='standalone_a53',
    no_boot_bsp=True, generate_dtb=False)
platform.build()

xpfm = client.find_platform_in_repos('vx_plat')
app = client.create_app_component(name='vx_host', platform=xpfm,
                                  domain='standalone_a53', template='empty_application')
app.import_files(from_loc=HERE, files=['main_vortex.c', 'vx_image.h'], dest_dir_in_cmp='src')
app.import_files(from_loc=PSHOST, files=['apps.c', 'power.c', 'power.h', 'kernels.h', 'suite2.inc',
                                         'kernels_s2.h', 'rodinia.inc', 'kernels_rd.h'],
                 dest_dir_in_cmp='src')
app.import_files(from_loc=os.path.join(HERE, '..', '..', '..', 'kernels', 'suite2'), files=['s2_ref.h'],
                 dest_dir_in_cmp='src')
app.import_files(from_loc=os.path.join(HERE, '..', '..', '..', 'kernels', 'rodinia'), files=['rd_ref.h'],
                 dest_dir_in_cmp='src')
app.set_app_config(key='USER_COMPILE_OPTIMIZATION_LEVEL', values='-O2')
app.set_app_config(key='USER_COMPILE_DEFINITIONS', values=['xil_printf=con_printf', 'SIMTIX_VORTEX'] +
                   (['RD_ONLY'] if 'rodinia' in sys.argv[1:] else []))   # the Rodinia suite alone
app.build()

elf = os.path.join(WS, 'vx_host', 'build', 'vx_host.elf')
print('ELF:', elf if os.path.isfile(elf) else '(not found -- see the build log above)')
vitis.dispose()
