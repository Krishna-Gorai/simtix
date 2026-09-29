"""
gen_chip_top.py -- block-level diagram of the SIMTiX chip_top SoC (TikZ).

    python gen_chip_top.py        # writes simtix_chip_top.tex, verifies, builds PDF + PNG

Source of truth: rtl/soc/chip_top.sv, rtl/soc/shared_mem.sv, rtl/soc/weight_rom.sv,
rtl/accel/simt_accel.sv, rtl/accel/warp_pool.sv. Uses the verified drawing engine
of ../datapath_tikz/dp_engine.py: the build stops on any overlap or collision.
"""
import os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'datapath_tikz'))
from dp_engine import Fig  # noqa: E402

f = Fig()
W_ = f.wire
BR = '\\\\'


def t(*lines):
    return BR.join(lines)


# ============================================================================ frames
f.group(4, 4, 290, 182, r'chip\_top: SIMTiX system-on-chip', 'nw', pt=8, fill='groupfill')
f.group(9, 86, 78, 134, 'RISC-V host CPU (5-stage RV32I)', 'ne', pt=7)
f.group(152, 46, 286, 176, r'simt\_accel: SIMT accelerator', 'nw', pt=7.5, fill='groupfill2')
f.group(156, 52, 282, 136, r'warp\_pool: SIMT engine, 4 warps $\times$ 8 lanes', 'ne', pt=7, fill='groupfill')
f.group(60, 8, 286, 40, r'Shared memory: 16 KB, 8 distributed-RAM banks (bank b holds word b of every 256-bit line); the accelerator line write has priority',
        'sw', pt=6.5, fill='groupfill')

# ============================================================================ host CPU
ROM = f.box('rom', 9, 148, 69, 18, t('Driver instruction ROM', r'vadd demo: cpu\_driver\_rom', r'MNIST demo: driver\_rom (1 K words)'),
            'mem', pt=7)
STG = []
for i, nm in enumerate(['IF', 'ID', 'EX', 'MEM', 'WB']):
    x = 13 + i * 13
    STG.append(f.box('st_' + nm, x, 100, 9, 14, nm, 'alu', pt=7, bold_first=True))
for a, b in zip(STG, STG[1:]):
    W_('pipe_' + a.name, [a.R(107), b.L(107)], style='bus')
IF, MEMS = STG[0], STG[3]
W_('pcf', [IF.T(15), ROM.B(15)])
W_('instrf', [ROM.B(20), IF.T(20)])
f.label('PC', 14.5, 131, 'east', pt=6.5)
f.label('instr', 20.5, 131, 'west', pt=6.5)
f.stub('memready', MEMS.T(56.5), 'up', 4.5, r'mem\_ready (stall)', pt=6)

# ============================================================================ address decode, result, weight store, read mux
X_BUS = 146                     # vertical leg of the host data bus up to the MMIO page
Y_TRUNK = 78
MMIO = f.box('mmio', 158, 144, 42, 24, t('MMIO registers', r'KERNEL\_PC, BASE\_A/B/C, N', r'CTRL.GO, STATUS, CYCLES'), 'mem', pt=7)
DISP = f.box('disp', 214, 144, 60, 24, t('Dispatcher FSM', r'IDLE $\to$ LAUNCH $\to$ RUN $\to$ DONE', 'cycle counter'), 'ctl', pt=7)
DEC = f.box('dec', 98, 146, 38, 22, t('Address decode', 'addr[31:28]', r'0x8 MMIO $\cdot$ 0x9 result', r'0xA weights $\cdot$ else shared'), 'ctl', pt=6.5)
RES = f.reg('res', 106, 115, 26, 11, 'Result register', pt=6.5)
WROM = f.box('wrom', 100, 82, 40, 16, t('Weight store (BRAM)', '256 KB, MNIST demo', r'sync read $\to$ 1-cycle stall'), 'mem', pt=6.5)
RMUX = f.mux('rmux', 82, [106, 92, 86], sel='top', ins=['', '', ''], w=6, flip=True)
f.stub('rmux_s', RMUX.selpt, 'up', 3.2, 'sel', pt=6)

# host data bus: MEM stage -> trunk -> MMIO page, with taps to every target
W_('hbus', [MEMS.B(54.5), (54.5, Y_TRUNK), (X_BUS, Y_TRUNK), (X_BUS, 158), MMIO.L(158)], style='bus')
W_('hbus', [(X_BUS, 156), DEC.R(156)], style='bus')
W_('hbus', [(X_BUS, 120.5), RES.R(120.5)], style='bus')
W_('hbus', [(118, Y_TRUNK), WROM.B(118)], style='bus')
f.label(r'host data bus: addr, wdata, we, funct3', 120, Y_TRUNK - 0.4, 'north', pt=6.5)

# read-data return: MMIO status / weight word / shared-memory word -> CPU
W_('rd_mmio', [MMIO.L(149), (150, 149), (150, 106), RMUX.inp[0]])
f.label('MMIO rdata', 124, 106.35, 'south', pt=6)
W_('rd_wrom', [WROM.L(92), RMUX.inp[1]])
W_('rdata', [RMUX.out, (58.5, RMUX.out[1]), MEMS.B(58.5)], style='bus')
f.label('rdata', 70, RMUX.out[1] + 0.35, 'south', pt=6.5)

# chip pins
W_('p_result', [RES.L(118.5), (91, 118.5), (91, 190)], style='bus')
W_('p_done', [RES.L(123), (94, 123), (94, 190)])
f.label('result[31:0]', 90.5, 190.3, 'south east', pt=7, bold=True)
f.label('done', 94.5, 190.3, 'south west', pt=7, bold=True)
W_('clk', [(-8, 60), (4, 60)])
f.label('clk, rst', -8.3, 60, 'east', pt=7, bold=True)

# ============================================================================ accelerator: MMIO, dispatcher
W_('go', [MMIO.R(163), DISP.L(163)])
f.label('GO', 207, 163.35, 'south', pt=6)
W_('status', [DISP.L(149), MMIO.R(149)])
f.label('status', 207, 148.6, 'north', pt=6)

# ============================================================================ warp_pool
SCH = f.box('sch', 160, 104, 22, 20, t('Warp scheduler', '+ SIMT stacks'), 'ctl', pt=6.5)
FD = f.box('fd', 187, 104, 20, 20, t('Fetch', r'\& decode'), 'ctl', pt=6.5)
RF = f.box('rf', 212, 104, 22, 20, t('VRF + FRF', 'LUTRAM', 'per lane'), 'mem', pt=6.5)
EX = f.box('ex', 239, 104, 40, 20, t(r'Execute $\times$8 lanes', 'integer ALU', '5-stage FPU'), 'alu', pt=6.5, rep=True)
W_('w_sf', [SCH.R(114), FD.L(114)])
W_('w_fr', [FD.R(114), RF.L(114)])
W_('w_re', [RF.R(114), EX.L(114)], style='bus')
WB = f.box('wb', 210, 78, 22, 18, t('Write-back', 'arbiters'), 'ctl', pt=6.5)
ENG = f.box('eng', 236, 78, 20, 18, t(r'MUL $\cdot$ pdot8', 'div / sqrt'), 'alu', pt=6.5)
MEME = f.box('meme', 260, 78, 22, 18, t('Memory engine', 'coalescing', '+ scratchpad'), 'ctl', pt=6)
W_('w_park', [EX.B(246), ENG.T(246)], style='bus')
f.label('park', 246.5, 100, 'west', pt=6)
W_('w_ldst', [EX.B(271), MEME.T(271)], style='bus')
f.label('ld/st', 271.5, 100, 'west', pt=6)
W_('w_eng', [ENG.L(87), WB.R(87)], style='bus')
W_('w_mem', [MEME.B(263), (263, 72), (221, 72), WB.B(221)], style='bus')
W_('w_wb', [WB.T(221), RF.B(221)], style='bus')
f.label('write-back', 221.5, 100, 'west', pt=6)
W_('args', [MMIO.B(170), SCH.T(170)])
f.label(r'kernel PC, args', 170.5, 139, 'west', pt=6)
W_('start', [DISP.B(220), (220, 129), (177, 129), SCH.T(177)])
f.label('start', 198, 129.35, 'south', pt=6)
W_('pdone', [(262, 136), DISP.B(262)])
f.label('done', 262.5, 139.5, 'west', pt=6)

# ============================================================================ shared memory
PCPU = f.box('pcpu', 66, 28, 32, 8, 'CPU word port', 'mux', pt=6.5, bold_first=False)
PIF = f.box('pif', 186, 28, 22, 8, 'instr. port', 'mux', pt=6.5, bold_first=False)
PLN = f.box('pln', 250, 28, 32, 8, '256-bit line port', 'mux', pt=6.5, bold_first=False)
for b in range(8):
    x = 66 + b * 27.2
    f.box(f'bank{b}', x, 15, 24, 9, f'bank {b}', 'mem', pt=6.5, bold_first=False)
W_('hbus', [(70, Y_TRUNK), (70, PCPU.y1)], style='bus')
W_('rd_shared', [PCPU.T(93), (93, 86), RMUX.inp[2]])
W_('imem_a', [FD.B(192), PIF.B(192) if False else PIF.T(192)])
W_('imem_d', [PIF.T(201), FD.B(201)])
f.label('fetch addr', 191.5, 55, 'east', pt=6)
f.label('instr', 201.5, 55, 'west', pt=6)
W_('line_w', [MEME.B(270), PLN.T(270)], style='wide')
W_('line_r', [PLN.T(277), MEME.B(277)], style='wide')
f.label('256-bit line', 269.5, 55, 'east', pt=6)

# ============================================================================ notation key
f.frames.append((12, 10, 56, 76))
f.label('Notation', 14, 74.6, 'north west', pt=7, bold=True)
row = 66.5
for kind, txt in (('mem', 'storage'), ('ctl', 'control'), ('alu', 'arithmetic'), ('mux', 'memory port')):
    f.box('key_' + kind, 15, row - 2.2, 9, 4.4, '', kind)
    f.label(txt, 27, row, 'west', pt=6.5)
    row -= 6.4
f.reg('key_reg', 15, row - 2.2, 9, 4.4, '')
f.label('register', 27, row, 'west', pt=6.5)
row -= 6.4
for st, txt in (('sig', 'signal'), ('bus', 'bus / 8 lanes'), ('wide', '256-bit line'), ('ctl', 'stub / control')):
    W_('key_' + st, [(15, row), (24, row)], style=st)
    f.label(txt, 27, row, 'west', pt=6.5)
    row -= 6.4

# ============================================================================ build
if __name__ == '__main__':
    print('compaction x/y:', round(f.compact('x', 5.0), 1), round(f.compact('y', 4.0), 1))
    for w in f.warn:
        print('WARN', w)
    errs = f.verify()
    for e in errs:
        print(e)
    X0, Y0, X1, Y1 = f.extent()
    print(f"extent {X1 - X0:.0f} x {Y1 - Y0:.0f} mm")
    cross = f.emit(os.path.join(HERE, 'simtix_chip_top.tex'))
    print(f"{len(errs)} errors, {len(cross)} crossings")
    for c in cross:
        print('  cross', c)
    if errs:
        sys.exit(1)
    r = subprocess.run(['pdflatex', '-interaction=nonstopmode', '-halt-on-error', 'simtix_chip_top.tex'],
                       cwd=HERE, capture_output=True, text=True)
    if r.returncode:
        print([l for l in r.stdout.splitlines() if l.startswith('!') or l.startswith('l.')][:6])
        sys.exit(1)
    subprocess.run(['pdftoppm', '-png', '-r', '110', '-singlefile', 'simtix_chip_top.pdf', 'preview'], cwd=HERE)
    print('built')
