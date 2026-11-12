"""
build_vitis_ara.py -- build the A53 host for Ara + CVA6 with the Vitis Python API.

    vitis -s baselines/ara/host/build_vitis_ara.py [path/to/.xsa]

Workspace baselines/ara/host/ws_zcu102 with the platform ara_plat (standalone,
psu_cortexa53_0, from baselines/ara/ara_ps_zcu102.xsa by default) and the application
ara_host (main.c, apps_ara.c, ../kernels/ak.h, ara_progs.h from gen_progs.py), built -O2. As sw/ps_host/build_vitis.py.
"""
import os
import shutil
import stat
import sys

import vitis

HERE = os.path.dirname(os.path.abspath(__file__))
XSAS = [a for a in sys.argv[1:] if a.lower().endswith('.xsa')]
XSA = os.path.abspath(XSAS[0] if XSAS else os.path.join(HERE, '..', 'ara_ps_zcu102.xsa'))
WS = os.path.join(HERE, 'ws_zcu102')
print(f'platform {XSA}, workspace {WS}')

if shutil.which('aarch64-none-elf-gcc') is None:
    gcc_dir = os.environ.get('AARCH64_GCC_DIR',
                             r'C:\toolchains\arm-gnu-14.2-aarch64-none-elf\bin')
    os.environ['PATH'] = gcc_dir + os.pathsep + os.environ['PATH']

if not os.path.isfile(XSA):
    sys.exit(f'no hardware platform at {XSA}; run create_bd_ara.tcl -tclargs build')
if os.path.isdir(WS):
    shutil.rmtree(WS, onexc=lambda f, p, e: (os.chmod(p, stat.S_IWRITE), f(p)))

client = vitis.create_client()
client.set_workspace(path=WS)
platform = client.create_platform_component(
    name='ara_plat', hw_design=XSA, os='standalone',
    cpu='psu_cortexa53_0', domain_name='standalone_a53',
    no_boot_bsp=True, generate_dtb=False)
platform.build()

xpfm = client.find_platform_in_repos('ara_plat')
app = client.create_app_component(name='ara_host', platform=xpfm,
                                  domain='standalone_a53', template='empty_application')
app.import_files(from_loc=HERE, files=['main.c', 'apps_ara.c', 'ara_progs.h'], dest_dir_in_cmp='src')
app.import_files(from_loc=os.path.join(HERE, '..', 'kernels'), files=['ak.h'], dest_dir_in_cmp='src')
app.import_files(from_loc=os.path.join(HERE, '..', '..', '..', 'sw', 'ps_host'), files=['suite2.inc', 'rodinia.inc'],
                 dest_dir_in_cmp='src')
app.import_files(from_loc=os.path.join(HERE, '..', '..', '..', 'kernels', 'suite2'), files=['s2_ref.h'],
                 dest_dir_in_cmp='src')
app.import_files(from_loc=os.path.join(HERE, '..', '..', '..', 'kernels', 'rodinia'), files=['rd_ref.h'],
                 dest_dir_in_cmp='src')
app.set_app_config(key='USER_COMPILE_OPTIMIZATION_LEVEL', values='-O2')
if 'rodinia' in sys.argv[1:]:                             # the Rodinia suite alone (rodinia.inc)
    app.set_app_config(key='USER_COMPILE_DEFINITIONS', values=['RD_ONLY'])
# rd_sel=<mask>: only those Rodinia benchmarks (RD_SEL in rodinia.inc). Vitis kept only the
# first of several USER_COMPILE_DEFINITIONS, so the mask goes into src/rd_cfg.h, written on
# every build (all benchmarks when no rd_sel is given).
args = sys.argv[1:]                                     # vitis.bat splits rd_sel=0x40 at the '='
sel = ([a.split('=', 1)[1] for a in args if a.lower().startswith('rd_sel=')] +
       [args[i + 1] for i, a in enumerate(args[:-1]) if a.lower() == 'rd_sel'] or ['0x1FFu'])[0]
with open(os.path.join(WS, 'ara_host', 'src', 'rd_cfg.h'), 'w') as f:
    f.write(f'/* rd_cfg.h - written by build_vitis_ara.py */\n#define RD_SEL {sel}\n')
app.build()

elf = os.path.join(WS, 'ara_host', 'build', 'ara_host.elf')
print('ELF:', elf if os.path.isfile(elf) else '(not found -- see the build log above)')
vitis.dispose()
