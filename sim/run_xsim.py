"""
run_xsim.py -- run the SIMTiX self-checking regression under Vivado xsim.

    python sim/run_xsim.py              # every test of `make test`
    python sim/run_xsim.py pool chip    # just these
    python sim/run_xsim.py --list

Mirrors the `test` target of sim/Makefile (Verilator, used by CI) so the
regression also runs on a Windows host without Verilator or make. Tests that
check against the DPI-C IEEE reference compile tests/fpu_ref.c with xsc.
A test passes when xsim exits 0 and its log contains "PASS" and no "FAIL".
"""
import glob, os, shutil, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VIVADO_BIN = os.environ.get('VIVADO_BIN', r'C:\Xilinx\xic\2025.1\Vivado\bin')
BUILD = os.path.join(ROOT, 'build_xsim')

A = 'rtl/accel/'
PKG = [A + 'simtix_pkg.sv']
POOL = PKG + [A + 'simt_fpu.sv', A + 'fp_divsqrt.sv', A + 'mem_engine.sv', A + 'warp_pool.sv']
ACCEL = PKG + [A + 'mmio_regs.sv', A + 'simt_fpu.sv', A + 'fp_divsqrt.sv', A + 'mem_engine.sv', A + 'warp_pool.sv', A + 'simt_accel.sv']
CPU_ALL = sorted(glob.glob(os.path.join(ROOT, 'rtl/cpu/*.v')))
CPU_SOC = [os.path.relpath(p, ROOT) for p in CPU_ALL if not p.endswith('top.v')]
CPU_CHIP = [p for p in CPU_SOC if not p.endswith(('riscv_soc.v', 'instr_mem.v', 'data_mem.v'))]
SOC = ACCEL + ['rtl/soc/soc_top.sv']
PS = ACCEL + [A + 'l1_dcache.sv', A + 'axi_line_master.sv', 'rtl/soc/simt_ps_top.sv',
             'tests/axi_mem_model.sv']
CHIP = ACCEL + ['rtl/soc/shared_mem.sv', 'rtl/soc/weight_rom.sv', 'rtl/soc/cpu_driver_rom.sv',
                'rtl/soc/driver_rom.sv', 'rtl/soc/chip_top.sv']

# name: (top module, SystemVerilog sources, Verilog-2001 sources, uses DPI reference
#        [, top-level parameter overrides])
TESTS = {
    'accel':     ('tb_simt_accel', ACCEL + ['tests/tb_simt_accel.sv'], [], False),
    'lane':      ('tb_lane', PKG + [A + 'lane.sv', 'tests/tb_lane.sv'], [], False),
    'warp':      ('tb_warp', PKG + [A + 'warp.sv', 'tests/tb_warp.sv'], [], False),
    'pool':      ('tb_warp_pool', POOL + ['tests/tb_warp_pool.sv'], [], False),
    'pdot8':     ('tb_pdot8', POOL + ['tests/tb_pdot8.sv'], [], False),
    'qgemm':     ('tb_qgemm', POOL + ['tests/tb_qgemm.sv'], [], False),
    'requant':   ('tb_requant', POOL + ['tests/tb_requant.sv'], [], False),
    'qgemv':     ('tb_qgemv', POOL + ['tests/tb_qgemv.sv'], [], False),
    'fp':        ('tb_fp', POOL + ['tests/tb_fp.sv'], [], False),
    'fpu':       ('tb_fpu', PKG + [A + 'simt_fpu.sv', A + 'fp_divsqrt.sv', 'tests/tb_fpu.sv'], [], True),
    'divsqrt':   ('tb_divsqrt', PKG + [A + 'fp_divsqrt.sv', 'tests/tb_divsqrt.sv'], [], True),
    'fparith':   ('tb_fparith', POOL + ['tests/tb_fparith.sv'], [], True),
    'fpfma':     ('tb_fpfma', POOL + ['tests/tb_fpfma.sv'], [], True),
    'fparith16': ('tb_fparith16', POOL + ['tests/tb_fparith16.sv'], [], True),
    'fpdivsqrt': ('tb_fpdivsqrt', POOL + ['tests/tb_fpdivsqrt.sv'], [], True),
    'fpkernels': ('tb_fpkernels', POOL + ['tests/tb_fpkernels.sv'], [], True),
    'soc':       ('tb_soc_top', SOC + ['tests/tb_soc_top.sv'], CPU_SOC, False),
    'chip':      ('tb_chip_top', CHIP + ['tests/tb_chip_top.sv'], CPU_CHIP, False),
    'sync':      ('tb_sync', POOL + ['tests/tb_sync.sv'], [], False),
    'sync_lat':  ('tb_sync', POOL + ['tests/tb_sync.sv'], [], False, ['MEM_LAT=7', 'MEM_STALL=1']),
    'sync_ooo':  ('tb_sync', POOL + ['tests/tb_sync.sv'], [], False,
                  ['MEM_LAT=4', 'MEM_STALL=1', 'MEM_OOO=1']),
    'sync_l1':   ('tb_sync', POOL + [A + 'l1_dcache.sv', 'tests/tb_sync.sv'], [], False,
                  ['MEM_LAT=20', 'MEM_STALL=1', 'MEM_OOO=1', 'L1=1']),
    'sync_l1s':  ('tb_sync', POOL + [A + 'l1_dcache.sv', 'tests/tb_sync.sv'], [], False,
                  ['MEM_LAT=20', 'MEM_STALL=1', 'MEM_OOO=1', 'L1=1', 'L1_SETS=2']),
    'ps':        ('tb_ps_top', PS + ['tests/tb_ps_top.sv'], [], False),
    'sync_axi':  ('tb_sync', POOL + [A + 'l1_dcache.sv', A + 'axi_line_master.sv', 'tests/tb_sync.sv'],
                  [], False, ['MEM_LAT=24', 'MEM_STALL=1', 'MEM_OOO=1', 'L1=1', 'AXI=1']),
}
# Include directories for `include in testbenches (kernel .svh images).
INCDIRS = ['kernels/sync']


def tool(name):
    return os.path.join(VIVADO_BIN, name + ('.bat' if os.name == 'nt' else ''))


def run(cmd, cwd, log):
    env = dict(os.environ)
    env.pop('NoDefaultCurrentDirectoryInExePath', None)   # breaks Vivado's process spawn
    with open(log, 'w', encoding='utf-8', errors='replace') as fh:
        return subprocess.run(cmd, cwd=cwd, stdout=fh, stderr=subprocess.STDOUT, env=env).returncode


def run_test(name):
    top, sv, v, dpi, *gen = TESTS[name]
    wd = os.path.join(BUILD, name)
    shutil.rmtree(wd, ignore_errors=True)
    os.makedirs(wd)
    ab = lambda ps: [os.path.join(ROOT, p) for p in ps]
    steps = []
    if v:
        steps.append(('xvlog_v', [tool('xvlog')] + ab(v)))
    inc = sum((['-i', p] for p in ab(INCDIRS)), [])
    steps.append(('xvlog_sv', [tool('xvlog'), '-sv'] + inc + ab(sv)))
    elab = [tool('xelab'), '-debug', 'off', top, '-s', 'sim']
    if gen:
        # Through an options file: cmd.exe splits a .bat argument at '='.
        with open(os.path.join(wd, 'generics.opt'), 'w') as fh:
            fh.writelines(f'-generic_top "{g}"\n' for g in gen[0])
        elab += ['-f', 'generics.opt']
    if dpi:
        steps.append(('xsc', [tool('xsc'), os.path.join(ROOT, 'tests', 'fpu_ref.c')]))
        elab += ['-sv_lib', 'dpi']
    steps.append(('xelab', elab))
    steps.append(('xsim', [tool('xsim'), 'sim', '-R']))
    for tag, cmd in steps:
        if run(cmd, wd, os.path.join(wd, tag + '.log')) != 0:
            return False, f'{tag} failed (see build_xsim/{name}/{tag}.log)'
    out = open(os.path.join(wd, 'xsim.log'), encoding='utf-8', errors='replace').read()
    passed = 'PASS' in out and 'FAIL' not in out and 'Fatal' not in out
    lines = [l for l in out.splitlines() if 'PASS' in l or 'FAIL' in l]
    return passed, (lines[-1].strip() if lines else 'no PASS/FAIL line')


def main(argv):
    if '--list' in argv:
        print('\n'.join(TESTS))
        return 0
    names = [a for a in argv if not a.startswith('-')] or list(TESTS)
    bad = [n for n in names if n not in TESTS]
    if bad:
        print('unknown test(s):', ', '.join(bad))
        return 2
    fails = 0
    for n in names:
        t0 = time.time()
        ok, msg = run_test(n)
        fails += not ok
        print(f"{'PASS' if ok else 'FAIL'}  {n:10s} {time.time() - t0:6.1f}s  {msg}", flush=True)
    print(f"\n{len(names) - fails}/{len(names)} passed")
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
