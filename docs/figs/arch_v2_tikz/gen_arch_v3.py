"""
gen_arch_v3.py -- SIMTiX architecture figure in the style of the reference papers.

    python docs/figs/arch_v2_tikz/gen_arch_v3.py      (writes simtix_arch_v3.tex,
                                                     builds ../simtix_arch_v3.pdf)

Conventions taken from Vortex (MICRO 2021, Fig. 4) and eGPU (FPL 2023, Figs. 1-2):
a small system view with zoom lines into the accelerator; the accelerator drawn
as dashed pipeline-stage columns; architectural state drawn as tables (warp
table, reconvergence stack, register files, contexts, tags, MSHRs); replicated
units as stacked copies; trapezoid dispatch and result multiplexers; black bars
for pipeline registers; bus widths marked with a slash; control feedback as a
labelled bus over the stages; bold sans-serif block names. Coordinates in cm,
drawn at the paper's text width (18 cm).
"""
import os
import shutil
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
NAME = 'simtix_arch_v3'
OUT_TEX = os.path.join(HERE, NAME + '.tex')
OUT_PDF = os.path.join(os.path.dirname(HERE), NAME + '.pdf')

body = []


def emit(s):
    body.append(s)


def c(x, y):
    return f'({x:.3f},{y:.3f})'


def box(name, x0, y0, x1, y1, text, style):
    w, h = x1 - x0, y1 - y0
    emit(f'\\node[{style}, minimum width={w:.3f}cm, minimum height={h:.3f}cm, '
         f'text width={w - 0.10:.3f}cm] ({name}) at {c((x0 + x1) / 2, (y0 + y1) / 2)} '
         f'{{{text}}};')


def shadow(x0, y0, x1, y1, style, n=2, d=0.065):
    """Copies behind a block, offset down and to the right (replicated unit)."""
    for k in range(n, 0, -1):
        emit(f'\\draw[{style}] {c(x0 + k * d, y0 - k * d)} rectangle {c(x1 + k * d, y1 - k * d)};')


def rect(x0, y0, x1, y1, style):
    emit(f'\\draw[{style}] {c(x0, y0)} rectangle {c(x1, y1)};')


def text(x, y, s, style='lbl', anchor='center'):
    emit(f'\\node[{style}, anchor={anchor}] at {c(x, y)} {{{s}}};')


def table(x0, y0, x1, y1, title, cols, rows, widths=None, th=0.27, fill='white',
          hdr=True):
    """A titled grid: cols = header cells, rows = list of row cell lists."""
    if title:
        text((x0 + x1) / 2, y1 - th / 2, title, 'tbltitle')
        y1 -= th
    allrows = ([cols] if hdr else []) + rows
    n = len(allrows)
    rh = (y1 - y0) / n
    widths = widths or [1] * len(cols)
    tot = sum(widths)
    xs = [x0]
    for w in widths:
        xs.append(xs[-1] + (x1 - x0) * w / tot)
    rect(x0, y0, x1, y1, f'tbl, fill={fill}')
    if hdr:
        rect(x0, y1 - rh, x1, y1, 'tbl, fill=black!8')
    for i in range(1, n):
        emit(f'\\draw[tblline] {c(x0, y1 - i * rh)} -- {c(x1, y1 - i * rh)};')
    for j in range(1, len(xs) - 1):
        emit(f'\\draw[tblline] {c(xs[j], y0)} -- {c(xs[j], y1)};')
    for i, r in enumerate(allrows):
        for j, cell in enumerate(r):
            if cell:
                st = 'cellh' if (hdr and i == 0) else 'cell'
                text((xs[j] + xs[j + 1]) / 2, y1 - (i + 0.5) * rh, cell, st)


def trap(x0, y0, x1, y1, narrow, d=0.55, style='mux'):
    """Vertical trapezoid multiplexer; `narrow` is the side with one port."""
    if narrow == 'left':
        pts = [(x0, y0 + d), (x1, y0), (x1, y1), (x0, y1 - d)]
    else:
        pts = [(x0, y0), (x1, y0 + d), (x1, y1 - d), (x0, y1)]
    emit(f'\\draw[{style}] ' + ' -- '.join(c(*p) for p in pts) + ' -- cycle;')


def regbar(x, y0, y1, w=0.07):
    emit(f'\\fill[black] {c(x - w / 2, y0)} rectangle {c(x + w / 2, y1)};')


def hbar(x0, x1, y, h=0.07):
    emit(f'\\fill[black] {c(x0, y - h / 2)} rectangle {c(x1, y + h / 2)};')


def arrow(pts, style='arr', label=None, pos=0.5, side='above', lst='elabel'):
    if label is None:
        emit(f'\\draw[{style}] ' + ' -- '.join(c(*p) for p in pts) + ';')
        return
    segs = list(zip(pts, pts[1:]))
    i = max(range(len(segs)), key=lambda k: abs(segs[k][1][0] - segs[k][0][0]) +
            abs(segs[k][1][1] - segs[k][0][1]))
    pre = ' -- '.join(c(*p) for p in pts[:i + 1])
    post = ' -- '.join(c(*p) for p in pts[i + 1:])
    emit(f'\\draw[{style}] {pre} -- node[{lst}, pos={pos}, {side}] {{{label}}} {post};')


def dot(x, y):
    emit(f'\\fill {c(x, y)} circle (0.045);')


def slash(x, y, label, vertical=True, side='right'):
    """Bus-width mark: a short diagonal stroke and the width."""
    emit(f'\\draw[line width=0.45pt] {c(x - 0.07, y - 0.07)} -- {c(x + 0.07, y + 0.07)};')
    dx, dy = (0.10, -0.08) if vertical else (0.0, 0.14)
    if side == 'left':
        dx = -dx
    text(x + dx, y + dy, label, 'wlabel', 'west' if (vertical and side == 'right') else
         ('east' if vertical else 'south'))


def stage(x0, y0, x1, y1, title):
    rect(x0, y0, x1, y1, 'stagebox')
    text((x0 + x1) / 2, y1 - 0.17, title, 'stagetitle')


# =================================================================== system view
TOPY0, TOPY1 = 9.00, 11.30

box('ddr', 0.00, 10.05, 1.62, 10.85, r'\textbf{DDR4}\\SDRAM', 'memarr')
box('mon', 0.00, 9.12, 1.62, 9.80, r'Power\\monitors', 'offchip')

rect(1.92, TOPY0, 8.12, TOPY1, 'psframe')
text(2.02, TOPY1 - 0.04, r'\textbf{Zynq UltraScale+ processing system}', 'paneltitle', 'north west')
box('ddrc', 2.12, 10.05, 3.72, 10.72, r'\textbf{DDR4}\\\textbf{controller}', 'ctrl')
box('i2c', 2.12, 9.14, 3.72, 9.58, r'\textbf{I$^2$C}', 'ctrl')
shadow(4.05, 9.98, 5.85, 10.78, 'ctrlbox', n=3, d=0.05)
box('a53', 4.05, 9.98, 5.85, 10.78, r'\textbf{Cortex-A53}\\4 cores, 1.2~GHz', 'ctrl')
box('hpm', 6.22, 10.32, 7.98, 10.78, r'M\_AXI\_HPM0\_FPD', 'port')
box('hp0', 6.22, 9.36, 7.98, 9.82, r'S\_AXI\_HP0\_FPD', 'port')
arrow([(5.85 + 0.15, 10.55), (6.22, 10.55)])
arrow([(6.22, 9.59), (6.05, 9.59), (6.05, 9.80), (2.92, 9.80), (2.92, 10.05)], 'darr')
arrow([(2.12, 10.45), (1.62, 10.45)], 'bdarr')
arrow([(2.12, 9.36), (1.62, 9.36)], 'darr')

rect(8.42, TOPY0, 12.82, TOPY1, 'plframe')
text(8.52, TOPY1 - 0.04, r'\textbf{Programmable logic}', 'paneltitle', 'north west')
box('sc', 8.58, 10.25, 10.02, 10.85, r'\textbf{AXI Smart-}\\\textbf{Connect}', 'ctrl')
box('simtix', 10.30, 9.14, 12.66, 10.94,
    r'\textbf{\large SIMTiX}\\[2pt]\texttt{simt\_ps\_top}\\115.4~MHz', 'acc')
arrow([(7.98, 10.55), (8.58, 10.55)])
arrow([(10.02, 10.55), (10.30, 10.55)])
arrow([(10.30, 9.59), (7.98, 9.59)], 'bdarr', label='AXI4, 128 bit', side='below')

# legend (key): two columns of six rows
col1 = [('stagebox', 'pipeline stage'), ('tbl, fill=white', 'architectural state'),
        ('exebox', 'execution unit'), ('memarrbox', 'memory array'),
        ('hlbox', 'line-aggregated AMOs'), ('ctrlbox', 'control logic')]
for i, (st, t) in enumerate(col1):
    y = 11.08 - i * 0.37
    rect(13.05, y - 0.11, 13.45, y + 0.11, st)
    text(13.55, y, t, 'keytext', 'west')
ys = [11.08 - i * 0.37 for i in range(6)]
rect(15.80, ys[0] - 0.11, 16.20, ys[0] + 0.11, 'maskbox')
text(16.30, ys[0], 'status masks', 'keytext', 'west')
regbar(16.00, ys[1] - 0.12, ys[1] + 0.12)
text(16.30, ys[1], 'pipeline register', 'keytext', 'west')
trap(15.86, ys[2] - 0.15, 16.14, ys[2] + 0.15, 'left', d=0.09)
text(16.30, ys[2], 'multiplexer', 'keytext', 'west')
shadow(15.80, ys[3] - 0.11, 16.12, ys[3] + 0.11, 'exebox', n=2, d=0.04)
rect(15.80, ys[3] - 0.11, 16.12, ys[3] + 0.11, 'exebox')
text(16.30, ys[3], 'one copy per lane', 'keytext', 'west')
emit(f'\\draw[line width=0.45pt] (15.93,{ys[4] - 0.07:.3f}) -- (16.07,{ys[4] + 0.07:.3f});')
text(16.30, ys[4], 'bus width (bits)', 'keytext', 'west')
emit(f'\\draw[bus] (15.80,{ys[5]:.3f}) -- (16.20,{ys[5]:.3f});')
text(16.30, ys[5], 'line-wide bus', 'keytext', 'west')

# zoom lines
emit(r'\draw[zoom] (10.30,9.14) -- (0.00,8.58);')
emit(r'\draw[zoom] (12.66,9.14) -- (18.00,8.58);')

# =================================================================== accelerator
rect(0.00, 0.00, 18.00, 8.58, 'accframe')
text(2.05, 8.50, r'\textbf{SIMTiX accelerator}', 'paneltitle', 'north west')

# ---------------------------------------------------------------- host interface
stage(0.12, 0.12, 2.80, 7.95, 'Host interface')
box('axil', 0.25, 6.98, 2.67, 7.52, r'\textbf{AXI4-Lite slave}', 'ctrl')
table(0.50, 4.22, 2.67, 6.78, 'Command registers', ['register'],
      [['KERNEL\\_PC'], ['PARAM (a1)'], ['N'], ['BLOCK'], ['CTRL.GO'], ['STATUS.DONE'],
       ['CYCLES'], ['L1 HITS, MISSES']], hdr=False)
box('disp', 0.50, 3.25, 2.67, 3.92, r'\textbf{Dispatcher}\\launch, completion', 'ctrl')
rect(0.25, 0.30, 2.67, 2.92, 'memarr')
text(1.46, 2.74, r'\textbf{Instruction RAM}', 'tbltitle')
table(0.55, 0.50, 2.37, 2.55, None, ['', '32 bit'],
      [['0', ''], ['1', ''], [r'$\vdots$', ''], ['1023', '']], widths=[1, 2.4], hdr=True,
      fill='white')
arrow([(1.46, 8.58), (1.46, 7.52)])                                     # SmartConnect in
slash(1.46, 8.05, '32')
arrow([(1.58, 6.98), (1.58, 6.78)])                                     # slave -> regs
arrow([(0.36, 6.98), (0.36, 2.92)])                                     # slave -> IRAM
text(0.24, 5.0, 'kernel', 'vlabel')
arrow([(1.58, 4.22), (1.58, 3.92)])                                     # regs -> dispatcher

# ---------------------------------------------------------------- fetch
stage(2.95, 0.12, 6.40, 7.95, 'Fetch (F)')
box('spawn', 3.08, 6.98, 6.00, 7.52, r'\textbf{Spawner}: $\lceil N/L\rceil$ warps, whole blocks', 'ctrl')
table(3.08, 5.48, 6.00, 6.80, 'Warp table', ['warp', 'state', 'base tid'],
      [['0', 'run', '0'], ['1', 'asleep', '8'], ['2', 'store', '16'],
       ['7', 'barrier', '56']], widths=[1, 1.4, 1.4])
shadow(3.08, 3.30, 5.86, 4.78, 'tbl, fill=white', n=3, d=0.045)
table(3.08, 3.30, 5.86, 4.78, None, ['PC', 'RPC', 'mask'],
      [['', '', ''], [r'$\vdots$', r'$\vdots$', r'$\vdots$'], ['', '', '']])
emit(r'\node[tbltitle, align=center] at (4.47,5.10) {Reconvergence stack\\per warp, depth $L$};')
for i, t in enumerate(['runnable warps', 'barrier arrivals',
                       'asleep / waiting (store, AMO, div)']):
    y = 2.78 - i * 0.36
    box(f'm{i}', 3.08, y - 0.15, 6.00, y + 0.15, t, 'mask')
box('sched', 3.08, 1.18, 6.00, 1.72, r'\textbf{Round-robin scheduler}', 'ctrl')
box('fetch', 3.08, 0.30, 6.00, 0.92, r'\textbf{Fetch}: instruction at the\\PC of the selected warp', 'ctrl')
arrow([(4.54, 6.98), (4.54, 6.78)])                                     # spawner -> warp table
arrow([(4.54, 2.07), (4.54, 1.72)])                                     # masks -> scheduler
arrow([(4.54, 1.18), (4.54, 0.92)])                                     # scheduler -> fetch
arrow([(2.67, 3.58), (2.875, 3.58), (2.875, 7.25), (3.08, 7.25)])      # dispatcher -> spawner
text(2.75, 4.07, 'GO', 'wlabel', 'east')
arrow([(2.67, 0.61), (3.08, 0.61)])                                     # IRAM -> fetch
slash(2.81, 0.61, '32', vertical=False)

# ---------------------------------------------------------------- execute
stage(6.55, 0.12, 11.30, 7.95, 'Execute (X)')
regbar(6.475, 0.36, 0.86)                                               # F/X register
arrow([(6.00, 0.61), (6.70, 0.61)])
table(6.68, 4.95, 8.28, 7.55, r'\textbf{Integer RF}', ['', 't0', r'\ldots', 't7'],
      [['r0', '', '', ''], ['r1', '', '', ''], [r'$\vdots$', '', '', ''],
       ['r31', '', '', '']], widths=[1.2, 1, 1, 1])
table(6.68, 2.25, 8.28, 4.75, r'\textbf{FP RF}', ['', 't0', r'\ldots', 't7'],
      [['f0', '', '', ''], ['f1', '', '', ''], [r'$\vdots$', '', '', ''],
       ['f31', '', '', '']], widths=[1.2, 1, 1, 1])
box('dec', 6.68, 0.30, 8.28, 0.92, r'\textbf{Decoder}', 'ctrl')
arrow([(6.95, 0.92), (6.95, 2.25)])
text(6.82, 1.58, 'rs1--rs3', 'vlabel')
box('sb', 7.10, 1.08, 8.06, 2.12, r'\textbf{Score-}\\\textbf{board}\\pending\\registers', 'ctrl')
arrow([(7.10, 2.06), (6.00, 2.06)])                                     # hazard -> warp sleeps
text(6.58, 2.15, 'sleep', 'wlabel', 'south')
arrow([(7.58, 0.92), (7.58, 1.08)])                                     # decoder -> scoreboard
trap(8.46, 2.35, 8.74, 7.40, 'left', d=0.9)                            # dispatch
text(8.60, 4.90, 'dispatch', 'vlabel')
arrow([(8.28, 6.10), (8.46, 6.10)])
arrow([(8.28, 3.45), (8.46, 3.45)])
units = [('alu', 6.64, 7.40, r'\textbf{ALU}: branch,\\address, Zba,\\Zbb, Zicond', True),
         ('mul', 5.92, 6.47, r'\textbf{Integer MUL}\\(DSP)', True),
         ('dot', 5.12, 5.67, r'\textbf{INT8 dot}\\(\texttt{pdot8})', True),
         ('fpu', 4.02, 4.87, r'\textbf{FPU}\\FP32/FP16\\5-stage FMA', True),
         ('shf', 3.22, 3.77, r'\textbf{Shuffle}\\crossbar', False),
         ('sfu', 2.42, 2.97, r'\textbf{Div / sqrt}\\shared', False)]
RQ = ('mul', 'dot', 'fpu', 'shf')                                        # units with a result queue
for nm, y0, y1, t, rep in units:
    if rep:
        shadow(8.94, y0, 10.52, y1, 'exebox', n=2, d=0.05)
    box(nm, 8.94, y0, 10.52, y1, t, 'exe')
    arrow([(8.74, (y0 + y1) / 2), (8.94, (y0 + y1) / 2)])
    if nm in RQ:
        emit(f'\\draw[line] {c(10.62 if rep else 10.52, (y0 + y1) / 2)} -- {c(10.64, (y0 + y1) / 2)};')
    else:
        arrow([(10.52 + (0.10 if rep else 0), (y0 + y1) / 2), (10.86, (y0 + y1) / 2)])
rect(10.64, 3.22, 10.80, 6.47, 'tbl, fill=white')                       # result queues
for k in range(1, 12):
    emit(f'\\draw[tblline] {c(10.64, 3.22 + k * 0.27)} -- {c(10.80, 3.22 + k * 0.27)};')
emit(r'\node[vlabel, fill=white, inner sep=0.3pt] at (10.72,4.85) {result queues};')
for y in (6.20, 5.40, 4.45, 3.50):
    emit(f'\\draw[line] {c(10.80, y)} -- {c(10.86, y)};')
text(10.80, 7.47, r'$\times 8$', 'wlabel')
trap(10.86, 2.35, 11.14, 7.40, 'right', d=0.9)                         # result mux
text(11.00, 4.90, 'results', 'vlabel')
box('arb', 8.46, 0.30, 11.14, 1.48, r'\textbf{Write arbiter}\\load write-back first;\\'
    r'queues hold, an ALU write re-issues', 'ctrl')
arrow([(11.00, 2.35), (11.00, 1.48)])                                   # results -> arbiter
arrow([(8.46, 1.20), (8.18, 1.20), (8.18, 2.25)])                       # arbiter -> RFs
text(8.33, 1.74, 'write back', 'vlabel')

# ---------------------------------------------------------------- memory engine
stage(11.45, 0.12, 15.10, 7.95, 'Memory engine')
table(11.66, 5.95, 14.97, 7.55, 'Contexts (two per warp)',
      ['ctx', 'addresses', 'store data', 'pending'],
      [['0', '', '', ''], ['1', '', '', ''], [r'$\vdots$', '', '', ''], ['15', '', '', '']],
      widths=[0.6, 1.5, 1.5, 1.1])
arrow([(11.14, 6.90), (11.66, 6.90)], 'bus')                           # memory instruction
slash(11.30, 6.90, r'$64L$', vertical=False)
regbar(11.57, 6.66, 7.14)                                               # input register
box('coal', 11.58, 5.05, 14.97, 5.72,
    r'\textbf{Coalescer}: one line request per cycle\\(chosen, then formed); 16 tags', 'ctrl')
arrow([(13.27, 5.95), (13.27, 5.72)])
box('ldret', 11.58, 3.98, 14.97, 4.72, r'\textbf{Load return}: word extract per lane', 'ctrl')
rect(11.58, 1.62, 14.97, 3.72, 'hl')
text(13.27, 3.56, r'\textbf{Line-aggregated AMOs}', 'tbltitle')
table(11.80, 2.98, 14.75, 3.32, None, ['w0', 'w1', 'w2', 'w3', 'w4', 'w5', 'w6', 'w7'],
      [], hdr=True, fill='white')
text(13.27, 2.82, 'line buffer (one read per line)', 'cell')
box('rnd', 11.80, 1.80, 13.10, 2.58, r'rounds: lanes\\on distinct words', 'exe')
box('aalu', 13.30, 1.80, 14.75, 2.58, r'AMO ALU: 1 (\emph{ser})\\or $L$ (\emph{par})', 'exe')
box('scr', 11.58, 0.30, 14.97, 1.40,
    r'\textbf{Scratchpad} (LUTRAM)\\64 words per warp + block-shared region', 'memarr')
arrow([(11.58, 4.35), (11.37, 4.35), (11.37, 0.89), (11.14, 0.89)], 'bus')  # -> arbiter
text(11.255, 1.92, 'load data', 'vlabel')
# resume and branch feedback bus over the stages
arrow([(12.10, 7.55), (12.10, 8.22), (6.20, 8.22), (6.20, 2.78), (6.00, 2.78)])
arrow([(10.30, 7.34), (10.30, 8.22)], 'line')
hbar(10.16, 10.44, 7.76)                                                # stage B register
text(10.50, 7.76, 'B', 'wlabel', 'west')
dot(10.30, 8.22)
dot(6.20, 4.04)
arrow([(6.20, 4.04), (5.86 + 0.14, 4.04)])
text(8.10, 8.22, r'branch (B): retarget $\mid$ push $\mid$ pop', 'buslabel')
text(11.25, 8.22, r'load done, resume', 'buslabel')

# ---------------------------------------------------------------- L1 and AXI
stage(15.25, 0.12, 17.88, 7.95, 'L1 data cache, AXI4')
box('axi', 15.38, 6.62, 17.52, 7.52, r'\textbf{AXI4 master}\\read ID = tag\\all writes one ID', 'ctrl')
arrow([(16.45, 7.52), (16.45, 8.58)], 'bdarr')
slash(16.45, 8.05, '128')
arrow([(14.97, 5.38), (15.52, 5.38)], 'bus')                            # request
regbar(15.40, 5.12, 5.64)
text(15.47, 5.82, 'input reg.', 'wlabel', 'east')
table(15.55, 4.48, 17.52, 6.40, r'\textbf{Tags} (LUTRAM)', ['set', 'w0', r'\ldots', 'w3'],
      [['0', '', '', ''], [r'$\vdots$', '', '', ''], ['511', '', '', '']],
      widths=[1.3, 1, 1, 1])
shadow(15.55, 3.05, 17.38, 4.20, 'memarrbox', n=3, d=0.045)
box('data', 15.55, 3.05, 17.38, 4.20, r'\textbf{Data}: 4 ways\\16 KB each, block RAM', 'memarr')
table(15.55, 1.58, 17.52, 2.80, r'\textbf{MSHRs}', ['', 'line', 'waiting'],
      [['0', '', ''], [r'$\vdots$', '', ''], ['15', '', '']], widths=[0.6, 1.3, 1.3])
box('l1note', 15.38, 0.25, 17.62, 1.40,
    r'64~KB, 512 sets, write-\\through; a read miss\\waits for a write\\to its line', 'note')
arrow([(17.52, 2.14), (17.64, 2.14), (17.64, 6.62 + 0.20), (17.52, 6.62 + 0.20)], 'darr')
text(17.77, 4.40, 'miss, write / fill', 'vlabelr')
arrow([(15.55, 3.70), (15.17, 3.70), (15.17, 4.35), (14.97, 4.35)], 'bus')    # responses
dot(15.17, 3.70)
arrow([(15.17, 3.70), (15.17, 3.15), (14.75, 3.15)], 'arr')
slash(15.17, 3.86, r'$32L$', vertical=True, side='left')

TEMPLATE = r"""%% generated by gen_arch_v3.py -- do not edit by hand
\documentclass[10pt]{standalone}
\usepackage{helvet}
\renewcommand{\familydefault}{\sfdefault}
\usepackage{amsmath,amssymb}
\usepackage{tikz}
\usetikzlibrary{arrows.meta}
\definecolor{cstage}{HTML}{FFF8E1}
\definecolor{cctrl}{HTML}{D6E0EC}
\definecolor{cctrlb}{HTML}{3B5675}
\definecolor{cexe}{HTML}{FFE699}
\definecolor{cexeb}{HTML}{7F6000}
\definecolor{cmask}{HTML}{D9EAD3}
\definecolor{cmaskb}{HTML}{38761D}
\definecolor{cmem}{HTML}{F4CCCC}
\definecolor{cmemb}{HTML}{CC0000}
\definecolor{chl}{HTML}{FCE4D6}
\definecolor{chlb}{HTML}{C55A11}
\newcommand{\fs}{\fontsize{6.4}{7.4}\selectfont}
\newcommand{\fss}{\fontsize{5.8}{6.6}\selectfont}
\begin{document}
\begin{tikzpicture}[x=1cm, y=1cm,
  base/.style={align=center, font=\fs, inner sep=1pt, line width=0.5pt},
  ctrl/.style={base, draw=cctrlb, fill=cctrl},  ctrlbox/.style={draw=cctrlb, fill=cctrl, line width=0.5pt},
  exe/.style={base, draw=cexeb, fill=cexe},     exebox/.style={draw=cexeb, fill=cexe, line width=0.5pt},
  mask/.style={base, draw=cmaskb, fill=cmask, font=\fss}, maskbox/.style={draw=cmaskb, fill=cmask, line width=0.5pt},
  memarr/.style={base, draw=cmemb, fill=cmem, dashed, rounded corners=2pt},
  memarrbox/.style={draw=cmemb, fill=cmem, dashed, rounded corners=2pt, line width=0.5pt},
  hl/.style={draw=chlb, fill=chl, line width=1.2pt, rounded corners=2pt},
  hlbox/.style={draw=chlb, fill=chl, line width=1.2pt},
  acc/.style={base, draw=black, fill=cctrl, line width=1.1pt, rounded corners=2pt},
  port/.style={base, draw=black!70, fill=white, font=\fss\ttfamily},
  offchip/.style={base, draw=black!70, fill=black!6, rounded corners=2pt},
  note/.style={base, draw=black!40, fill=white, dashed, font=\fss},
  tbl/.style={draw=black, line width=0.5pt}, tblline/.style={draw=black!70, line width=0.35pt},
  cell/.style={font=\fss, inner sep=0.5pt}, cellh/.style={font=\fss\bfseries, inner sep=0.5pt},
  tbltitle/.style={font=\fs, inner sep=0.5pt},
  stagebox/.style={draw=black!55, dashed, fill=cstage, rounded corners=3pt, line width=0.6pt},
  stagetitle/.style={font=\fs\bfseries, inner sep=0.5pt},
  psframe/.style={draw=black!60, fill=black!5, rounded corners=4pt, line width=0.6pt},
  plframe/.style={draw=black!60, fill=blue!5, rounded corners=4pt, line width=0.6pt},
  accframe/.style={draw=black!75, fill=blue!3, rounded corners=4pt, line width=0.8pt},
  paneltitle/.style={font=\fs, inner sep=1pt},
  mux/.style={draw=black, fill=black!15, line width=0.6pt},
  lbl/.style={font=\fs, inner sep=0.5pt},
  elabel/.style={font=\fss, inner sep=1pt},
  wlabel/.style={font=\fss, inner sep=0.5pt},
  keytext/.style={font=\fss, inner sep=0.5pt},
  buslabel/.style={font=\fss, fill=blue!3, inner sep=1pt},
  vlabel/.style={font=\fss, rotate=90, inner sep=0.5pt},
  vlabelr/.style={font=\fss, rotate=-90, inner sep=0.5pt},
  zoom/.style={draw=black!45, line width=0.4pt},
  line/.style={line width=0.55pt},
  arr/.style={-{Latex[length=1.4mm, width=1.0mm]}, line width=0.55pt},
  darr/.style={{Latex[length=1.4mm, width=1.0mm]}-{Latex[length=1.4mm, width=1.0mm]}, line width=0.55pt},
  bus/.style={-{Latex[length=1.8mm, width=1.5mm]}, line width=1.1pt},
  bdarr/.style={{Latex[length=1.8mm, width=1.5mm]}-{Latex[length=1.8mm, width=1.5mm]}, line width=1.1pt}]
%s
\end{tikzpicture}
\end{document}
"""


def main():
    with open(OUT_TEX, 'w', encoding='utf-8', newline='\n') as f:
        f.write(TEMPLATE % '\n'.join(body))
    subprocess.run(['pdflatex', '-interaction=nonstopmode', NAME + '.tex'], cwd=HERE,
                   check=True, stdout=subprocess.DEVNULL)
    shutil.copyfile(os.path.join(HERE, NAME + '.pdf'), OUT_PDF)
    print('wrote', OUT_PDF)


if __name__ == '__main__':
    main()
