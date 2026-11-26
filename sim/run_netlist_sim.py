"""run_netlist_sim.py - tb_ps_top on a gate-level funcsim netlist of simt_ps_wrap (the routed
board design: create_bd_ps.tcl finish writes reports_ps<sfx>/simt_0_routed_funcsim.v), the check
that caught the v3 mis-synthesis before the board did (docs/lanes16_plan.md, phase 6).

    python sim/run_netlist_sim.py fpga/reports_ps_zcu102_l16/simt_0_routed_funcsim.v \
        --define SIMTIX_NUM_LANES=16 --define SIMTIX_NUM_WARPS=8 --define SIMTIX_L1_KB=128 \
        --define SIMTIX_L1_MSHR=16 --define SIMTIX_MEM_TAGS=16 [--generic N=1024] [--generic MEM_LATE=1]

The defines must be the build's (the testbench's checks and the package widths follow them; the
netlist itself has none). PS_WRAP=log2(tags)+1 and NETLIST are added. Builds in
build_xsim/netlist/; prints PASS/FAIL like run_xsim.py.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_xsim as rx   # noqa: E402  (tool(), run(), ROOT, BUILD, INCDIRS)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('netlist')
    ap.add_argument('--define', action='append', default=[])
    ap.add_argument('--generic', action='append', default=[])
    a = ap.parse_args()
    tags = int(next((d.split('=')[1] for d in a.define if d.startswith('SIMTIX_MEM_TAGS=')), '8'))
    idw = (tags - 1).bit_length() + 1
    defines = a.define + [f'PS_WRAP={idw}', 'NETLIST']
    lanes = next((d.split('=')[1] for d in a.define if d.startswith('SIMTIX_NUM_LANES=')), '8')
    wd = os.path.join(rx.BUILD, 'netlist')
    os.makedirs(wd, exist_ok=True)

    def opt(fname, lines):
        with open(os.path.join(wd, fname), 'w') as fh:
            fh.writelines(l + '\n' for l in lines)
        return ['-f', fname]
    ab = lambda p: os.path.join(rx.ROOT, p)
    incs = [p + '/l' + lanes if (p == 'kernels/sync' and lanes != '8') else p for p in rx.INCDIRS]
    inc = sum((['-i', ab(p)] for p in incs), [])
    dopt = opt('defines.opt', [f'-d "{d}"' for d in defines])
    steps = [
        ('xvlog_net', [rx.tool('xvlog')] + [os.path.abspath(a.netlist)]),
        ('xvlog_sv', [rx.tool('xvlog'), '-sv'] + dopt + inc +
         [ab('rtl/accel/simtix_pkg.sv'), ab('tests/axi_mem_model.sv'), ab('tests/tb_ps_top.sv')]),
        ('xelab', [rx.tool('xelab'), '-debug', 'off', '-timescale', '1ns/1ps', 'tb_ps_top', 'glbl',
                   '-L', 'unisims_ver', '-L', 'secureip', '-s', 'sim'] +
         (opt('generics.opt', [f'-generic_top "{g}"' for g in a.generic]) if a.generic else [])),
        ('xsim', [rx.tool('xsim'), 'sim', '-R']),
    ]
    for tag, cmd in steps:
        print(f'{tag} ...', flush=True)
        if rx.run(cmd, wd, os.path.join(wd, tag + '.log')) != 0:
            print(f'FAIL  {tag} failed (see build_xsim/netlist/{tag}.log)')
            return 1
    out = open(os.path.join(wd, 'xsim.log'), encoding='utf-8', errors='replace').read()
    ok = 'PASS' in out and 'FAIL' not in out and 'Fatal' not in out
    lines = [l for l in out.splitlines() if 'PASS' in l or 'FAIL' in l or 'config 0x' in l]
    print('\n'.join(lines[-6:]))
    print('PASS  netlist' if ok else 'FAIL  netlist')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
