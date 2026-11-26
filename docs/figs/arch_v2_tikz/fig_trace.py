#!/usr/bin/env python3
"""fig_trace.py - RTL cycle traces for the paper's operation figures.

Assembles kernels/figs/{saxpy,divergence}.S, runs tests/tb_figtrace.sv on the board top
(simt_ps_top) under xsim in the board configuration (8 lanes, 8 warps, 64 KiB L1, 16
MSHRs, 16 tags; 24-cycle deterministic AXI4 memory model) with the warp pool's issue
trace on, checks the kernels' results, and copies both traces to traces/<run>_{fig,issue}.txt:

  saxpy1      SAXPY, N = 8 (one warp)           -> gen_pipe_fig.py   (pipeline)
  div         divergence.S, N = 8 (one warp)    -> gen_div_fig.py    (divergence)
  saxpy92     SAXPY, N = 92 (12 warps, the last  -> gen_launch_fig.py (kernel to hardware)
              with four lanes)
  rules4      issue_rules.S, N = 32 (4 warps)    -> check_lat_sched.py (validates lat_sched.py,
                                                  the model of gen_lat_fig.py)

Usage:  python fig_trace.py [run ...]
"""
import os
import shutil
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'sim'))
import run_xsim as rx  # noqa: E402

KDIR = os.path.join(ROOT, 'kernels', 'figs')
TDIR = os.path.join(HERE, 'traces')
GCC = os.environ.get('RISCV_GCC', r'C:\toolchains\xpack-riscv-none-elf-gcc-15.2.0-1\bin'
                                  r'\riscv-none-elf-gcc.exe')
RUNS = {'saxpy1': ['KERN=0', 'N=8'], 'div': ['KERN=1', 'N=8'], 'saxpy92': ['KERN=0', 'N=92'],
        'rules4': ['KERN=2', 'N=32']}


def assemble(name):
    src, elf, binf = (os.path.join(KDIR, name + e) for e in ('.S', '.elf', '.bin'))
    subprocess.run([GCC, '-march=rv32imaf', '-mabi=ilp32', '-nostdlib', '-nostartfiles',
                    '-Wl,-Ttext=0', '-o', elf, src], check=True)
    objcopy = os.path.join(os.path.dirname(GCC), os.path.basename(GCC).replace('gcc', 'objcopy'))
    subprocess.run([objcopy, '-O', 'binary', elf, binf], check=True)
    data = open(binf, 'rb').read()
    words = [struct.unpack('<I', data[i:i + 4])[0] for i in range(0, len(data), 4)]
    assert len(words) <= 64, name
    with open(os.path.join(KDIR, name + '.svh'), 'w', newline='\n') as f:
        f.writelines("        mem[at+%d] = 32'h%08x;\n" % (k, w) for k, w in enumerate(words))
    os.remove(binf)
    os.remove(elf)
    print(f'{name}: {len(words)} words')


def main(argv):
    for k in ('saxpy', 'divergence', 'issue_rules'):
        assemble(k)
    rx.INCDIRS.append('kernels/figs')
    os.makedirs(TDIR, exist_ok=True)
    for run in (argv or list(RUNS)):
        name = 'fig_' + run
        rx.TESTS[name] = ('tb_figtrace', rx.PS + ['tests/tb_figtrace.sv'], [], False, RUNS[run])
        ok, msg = rx.run_test(name, defines=rx.B34 + ['SIMTIX_ISSUE_TRACE'])
        print(f"{'PASS' if ok else 'FAIL'}  {run:8s} {msg}", flush=True)
        if not ok:
            return 1
        wd = os.path.join(rx.BUILD, name)
        for src, dst in (('fig_trace.txt', 'fig'), ('issue_trace.txt', 'issue')):
            shutil.copy(os.path.join(wd, src), os.path.join(TDIR, f'{run}_{dst}.txt'))
        out = open(os.path.join(wd, 'xsim.log'), errors='replace').read()
        print('  ' + next((l for l in out.splitlines() if l.startswith('FIGCSV')), ''))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
