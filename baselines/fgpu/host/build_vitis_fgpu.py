"""
build_vitis_fgpu.py -- build the A53 host for FGPU with the Vitis Python API (phase 0 step 4).

    vitis -s baselines/fgpu/host/build_vitis_fgpu.py [rodinia|rivec|apps] [path/to/.xsa]

Workspace baselines/fgpu/host/ws_zcu102[_rodinia|_rivec|_apps] (outside git) with the platform fg_plat (standalone,
psu_cortexa53_0, from baselines/fgpu/fgpu_ps_zcu102.xsa by default) and the application
fg_host: main_fgpu.c and fgpu_image.h (gen_fgpu_image.py), built -O2 with
-Dxil_printf=con_printf. As baselines/vortex/host/build_vitis_vortex.py.
"""
import os
import shutil
import stat
import sys

import vitis

HERE = os.path.dirname(os.path.abspath(__file__))
XSAS = [a for a in sys.argv[1:] if a.lower().endswith('.xsa')]
XSA = os.path.abspath(XSAS[0] if XSAS else os.path.join(HERE, '..', 'fgpu_ps_zcu102.xsa'))
SUITES = [a for a in sys.argv[1:] if a in ('rodinia', 'rivec', 'apps', 'sorttest')]
# one workspace per host (phase 0, Rodinia, RiVEC), so building one keeps the others' ELFs
WS = os.path.join(HERE, 'ws_zcu102' + (f'_{SUITES[0]}' if SUITES else ''))
print(f'platform {XSA}, workspace {WS}')

if shutil.which('aarch64-none-elf-gcc') is None:
    gcc_dir = os.environ.get('AARCH64_GCC_DIR',
                             r'C:\toolchains\arm-gnu-14.2-aarch64-none-elf\bin')
    os.environ['PATH'] = gcc_dir + os.pathsep + os.environ['PATH']

if not os.path.isfile(XSA):
    sys.exit(f'no hardware platform at {XSA}; run create_bd_fgpu.tcl -tclargs build')
if not os.path.isfile(os.path.join(HERE, 'fgpu_image.h')):
    sys.exit('no fgpu_image.h; run gen_fgpu_image.py first')
if os.path.isdir(WS):
    shutil.rmtree(WS, onexc=lambda f, p, e: (os.chmod(p, stat.S_IWRITE), f(p)))

client = vitis.create_client()
client.set_workspace(path=WS)
platform = client.create_platform_component(
    name='fg_plat', hw_design=XSA, os='standalone',
    cpu='psu_cortexa53_0', domain_name='standalone_a53',
    no_boot_bsp=True, generate_dtb=False)
platform.build()

xpfm = client.find_platform_in_repos('fg_plat')
app = client.create_app_component(name='fg_host', platform=xpfm,
                                  domain='standalone_a53', template='empty_application')
app.import_files(from_loc=HERE, files=['main_fgpu.c', 'fgpu_image.h'], dest_dir_in_cmp='src')
defs = ['xil_printf=con_printf']
suite = SUITES
if suite:
    # phase 1: the Rodinia suite through SIMTiX's host (sw/ps_host/apps.c, SIMTIX_FGPU backend):
    # the same inputs, A53 references and checks as the SIMTiX, Vortex, CVA6 and Ara runs
    PSHOST = os.path.normpath(os.path.join(HERE, '..', '..', '..', 'sw', 'ps_host'))
    KER = os.path.normpath(os.path.join(HERE, '..', '..', '..', 'kernels'))
    app.import_files(from_loc=PSHOST, files=['apps.c', 'power.c', 'power.h', 'kernels.h', 'suite2.inc',
                                             'kernels_s2.h', 'rodinia.inc', 'kernels_rd.h', 'rivec.inc',
                                             'kernels_rv.h'], dest_dir_in_cmp='src')
    app.import_files(from_loc=os.path.join(KER, 'suite2'), files=['s2_ref.h'], dest_dir_in_cmp='src')
    app.import_files(from_loc=os.path.join(KER, 'rodinia'), files=['rd_ref.h'], dest_dir_in_cmp='src')
    app.import_files(from_loc=os.path.join(KER, 'rivec'), files=['rv_ref.h'], dest_dir_in_cmp='src')
    # apps: suite 1 (phase 2) and the rest of run_apps (suite 2 skips until its FGPU image)
    defs += ['SIMTIX_FGPU', 'FG_SUITE'] + {'rodinia': ['RD_ONLY'], 'rivec': ['RV_ONLY'], 'apps': [],
                                            'sorttest': ['FG_SORT_TEST']}[suite[0]]   # sorttest: suite 2's sort alone, launch pauses
defs += ['PW_ONLY'] if 'power' in sys.argv[1:] else []   # the power pass alone (docs/power_plan.md)
app.set_app_config(key='USER_COMPILE_OPTIMIZATION_LEVEL', values='-O2')
app.set_app_config(key='USER_COMPILE_DEFINITIONS', values=defs)
app.build()

elf = os.path.join(WS, 'fg_host', 'build', 'fg_host.elf')
print('ELF:', elf if os.path.isfile(elf) else '(not found -- see the build log above)')
vitis.dispose()
