"""
gen_arch_v2.py -- SIMTiX v2 architecture figure (board system + accelerator).

    python docs/figs/arch_v2_tikz/gen_arch_v2.py      (writes simtix_arch_v2.tex,
                                                     builds ../simtix_arch_v2.pdf)

The figure is a standalone TikZ picture drawn at the paper's text width (18 cm)
in Times, so the paper includes it at scale 1. Coordinates are in cm; every
block is placed explicitly so that no arrow crosses a block.
"""
import os
import shutil
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_TEX = os.path.join(HERE, 'simtix_arch_v2.tex')
OUT_PDF = os.path.join(os.path.dirname(HERE), 'simtix_arch_v2.pdf')

body = []


def emit(s):
    body.append(s)


def box(name, x0, y0, x1, y1, text, style='blk', extra=''):
    """A block filling the rectangle (x0, y0)-(x1, y1)."""
    w, h = x1 - x0, y1 - y0
    emit(f'\\node[{style}, minimum width={w:.3f}cm, minimum height={h:.3f}cm, '
         f'text width={w - 0.12:.3f}cm{extra}] ({name}) at ({(x0 + x1) / 2:.3f},'
         f'{(y0 + y1) / 2:.3f}) {{{text}}};')


def stack(name, x0, y0, x1, y1, text, style, n=2, d=0.07):
    """A block with n copies drawn behind it, offset up and to the right."""
    for k in range(n, 0, -1):
        emit(f'\\draw[{style}box] ({x0 + k * d:.3f},{y0 + k * d:.3f}) rectangle '
             f'({x1 + k * d:.3f},{y1 + k * d:.3f});')
    box(name, x0, y0, x1, y1, text, style)


def frame(name, x0, y0, x1, y1, label, style, lstyle='flabel'):
    emit(f'\\draw[{style}] ({x0:.3f},{y0:.3f}) rectangle ({x1:.3f},{y1:.3f});')
    if label:
        emit(f'\\node[{lstyle}, anchor=north west] at ({x0 + 0.06:.3f},{y1 - 0.03:.3f}) '
             f'{{{label}}};')


def arrow(pts, style='arr', label=None, lpos='midway', lopt='above'):
    """A polyline arrow; a label goes on its longest segment."""
    if not label:
        emit(f'\\draw[{style}] ' + ' -- '.join(f'({x:.3f},{y:.3f})' for x, y in pts) + ';')
        return
    segs = list(zip(pts, pts[1:]))
    i = max(range(len(segs)), key=lambda k: abs(segs[k][1][0] - segs[k][0][0]) +
            abs(segs[k][1][1] - segs[k][0][1]))
    pre = ' -- '.join(f'({x:.3f},{y:.3f})' for x, y in pts[:i + 1])
    post = ' -- '.join(f'({x:.3f},{y:.3f})' for x, y in pts[i + 1:])
    emit(f'\\draw[{style}] {pre} -- node[elabel, {lpos}, {lopt}] {{{label}}} {post};')


# ---------------------------------------------------------------- frames
frame('dev', 0.00, 0.95, 18.00, 13.02,
      r'AMD Zynq UltraScale+ XCZU7EV on the ZCU104 board', 'devframe', 'dlabel')
frame('ps', 0.12, 1.10, 3.55, 12.65, r'\textbf{Processing system (PS)}', 'psframe')
frame('acc', 4.40, 1.10, 17.88, 12.65,
      r'\textbf{SIMTiX} (\texttt{simt\_ps\_top}), programmable logic, 100~MHz', 'accframe')

# ---------------------------------------------------------------- PS
box('a53', 0.30, 10.80, 3.38, 12.20,
    r'4 Cortex-A53 cores, 1.2~GHz\\host program (bare metal)\\L1 and L2 caches', 'ps')
box('hpm', 0.30, 9.95, 3.38, 10.45, r'M\_AXI\_HPM0\_FPD', 'port')
box('seq', 0.30, 4.35, 3.38, 9.55,
    r'\textbf{Launch sequence}\\[2pt]'
    r'1\enspace write the kernel into the\\\phantom{1}\enspace instruction RAM\\[1pt]'
    r'2\enspace write PC, parameter block,\\\phantom{1}\enspace $N$ and block size\\[1pt]'
    r'3\enspace clean the data cache\\[1pt]'
    r'4\enspace set GO (invalidates the L1)\\[1pt]'
    r'5\enspace poll DONE\\[1pt]'
    r'6\enspace invalidate the data cache\\[1pt]'
    r'7\enspace read cycle and L1 counters', 'note')
box('hp0', 0.30, 2.85, 3.38, 3.65, r'S\_AXI\_HP0\_FPD\\128-bit slave port', 'port')
box('i2c', 0.30, 1.28, 1.55, 2.45, r'I$^2$C\\controller', 'ps')
box('ddrc', 1.73, 1.28, 3.38, 2.45, r'DDR4 memory\\controller', 'ps')

# off chip
box('mon', 0.05, 0.02, 2.28, 0.78, r'Power monitors:\\INA226, 2 IRPS5401', 'off')
box('ddr', 2.42, 0.02, 4.90, 0.78, r'DDR4 SDRAM (kernel data)', 'off')
emit(r'\node[olabel, anchor=west] at (5.05,0.40) {on the board, off chip};')

# SmartConnect between PS and PL
emit(r'\node[ctl, minimum width=2.60cm, minimum height=0.48cm, rotate=90] (sc) '
     r'at (3.975,10.90) {AXI SmartConnect};')

# ---------------------------------------------------------------- row A: host interface
box('axil', 4.58, 11.82, 10.40, 12.24, r'\textbf{AXI4-Lite slave}: address decode', 'ctl')
box('regs', 4.58, 10.36, 7.88, 11.66,
    r'\textbf{Command registers, dispatcher}\\[1pt]kernel PC, parameter block,\\'
    r'$N$, block size, GO, DONE,\\cycles, L1 hits and misses', 'ctl')
box('iram', 8.05, 10.36, 10.40, 11.66,
    r'\textbf{Kernel instruction}\\\textbf{RAM}, 1,024 $\times$ 32 bit', 'sto')

# legend
lx, ly = 10.75, 12.10
legend = [('ctl', 'control and host interface'), ('iss', 'warp control and issue'),
          ('exe', 'execution units'), ('sto', 'storage (LUTRAM, block RAM)'),
          ('mem', 'memory path'), ('hl', 'line-aggregated AMOs')]
for i, (st, txt) in enumerate(legend):
    x = lx + (i % 2) * 3.55
    y = ly - (i // 2) * 0.32
    emit(f'\\draw[{st}box] ({x:.3f},{y - 0.11:.3f}) rectangle ({x + 0.34:.3f},{y + 0.11:.3f});')
    emit(f'\\node[lgtext, anchor=west] at ({x + 0.40:.3f},{y:.3f}) {{{txt}}};')
emit(r'\node[lgtext, anchor=west, align=left] at (10.75,10.98) {stacked blocks: one copy '
     r'per warp, lane or context;\\$W=4$ warps, $L=8$ lanes; RF: register file};')

# ---------------------------------------------------------------- warp pool
frame('wp', 4.55, 5.22, 17.78, 10.25,
      '', 'wpframe')
emit(r'\node[flabel, anchor=north east] at (17.72,10.22) {\textbf{Warp pool}: $W$ warps of '
     r'$L$ threads, two-stage pipeline (F, X)};')
box('spawn', 4.70, 8.92, 8.05, 9.88,
    r'\textbf{Spawner}\\$\lceil N/L\rceil$ warps into free slots;\\a block of $2^b$ '
    r'warps spawns whole', 'iss')
stack('slots', 4.70, 6.92, 7.91, 8.58,
      r'\textbf{Warp slot}\\state, base thread ID\\[1pt]reconvergence stack, depth $L$:\\'
      r'frames of PC, reconvergence\\PC and active mask', 'iss')
box('sched', 4.70, 5.36, 8.05, 6.50,
    r'\textbf{Round-robin scheduler}\\[1pt]block barrier (\texttt{bar}): a warp waits\\'
    r'until its whole block arrives', 'iss')
box('F', 8.28, 5.36, 9.40, 9.88,
    r'\textbf{F}\\[4pt]fetch at\\the PC of\\the selected\\warp', 'iss')
box('X', 9.60, 5.36, 11.30, 9.88,
    r'\textbf{X}\\[4pt]decode\\[3pt]operand read\\[3pt]branch: retarget, push or pop the '
    r'stack\\[3pt]write back, or park the warp on a multi-cycle unit', 'iss')
frame('rf', 11.50, 7.36, 13.18, 9.88, '', 'rfframe')
box('irf', 11.60, 8.68, 13.08, 9.78, r'\textbf{Integer RF}\\LUTRAM\\2 read, 1 write', 'sto')
box('frf', 11.60, 7.46, 13.08, 8.56, r'\textbf{FP RF}\\LUTRAM\\3 read, 1 write', 'sto')
box('arb', 11.50, 5.36, 13.18, 6.98,
    r'\textbf{Write arbiter}\\memory write-back first; a displaced write re-issues', 'iss')

# lanes
stack('lane', 13.60, 7.25, 17.48, 9.74, '', 'exe', n=2, d=0.07)
emit(r'\node[font=\fsz\bfseries] at (15.54,9.50) {Lane (8 copies)};')
box('alu', 13.72, 8.34, 15.48, 9.28, r'Integer ALU,\\branch compare,\\address', 'exein')
box('fpu', 15.60, 8.34, 17.36, 9.28, r'FPU: FP32/FP16,\\5-stage FMA', 'exein')
box('mul', 13.72, 7.37, 15.48, 8.22, r'Integer\\multiplier (DSP)', 'exein')
box('dot', 15.60, 7.37, 17.36, 8.22, r'INT8 dot product\\(\texttt{pdot8})', 'exein')
box('shfl', 13.98, 5.36, 15.72, 6.62,
    r'\textbf{Shuffle crossbar}\\\texttt{idx}, \texttt{up},\\\texttt{down}, \texttt{xor}', 'exe')
box('sfu', 15.88, 5.36, 17.62, 6.62,
    r'\textbf{Shared divide and square root}\\lanes in turn', 'exe')

# ---------------------------------------------------------------- memory row
box('axi', 4.58, 1.30, 6.72, 4.86,
    r'\textbf{AXI4 master}\\[3pt]line $\to$ INCR burst\\of $32L/128$ beats\\[2pt]'
    r'AXI ID = request tag\\[2pt]read beats collected\\per ID\\[2pt]AR, R, AW, W, B;\\'
    r'error flag', 'mem')
frame('l1', 6.92, 1.30, 9.88, 4.86, r'\textbf{L1 data cache}, 16~KB, 4-way', 'memframe')
box('inreg', 7.04, 3.82, 9.76, 4.46, r'input register + skid entry', 'mem')
box('tags', 7.04, 2.66, 8.34, 3.66, r'tags in\\LUTRAM', 'sto')
box('data', 8.46, 2.66, 9.76, 3.66, r'data: 4 ways\\in block RAM', 'sto')
box('mshr', 7.04, 1.42, 9.76, 2.50,
    r'4 MSHRs; write-through,\\no write-allocate;\\invalidated at GO', 'mem')

frame('me', 10.30, 1.30, 17.78, 4.86, '', 'memframe')
emit(r'\node[flabel, anchor=north west] at (10.62,4.84) {\textbf{Memory engine}};')
stack('ctx', 10.42, 3.14, 12.92, 4.36,
      r'\textbf{Context} (one per warp):\\lane addresses, store data,\\pending-lane mask', 'mem')
box('coal', 10.42, 1.42, 13.06, 2.92,
    r'\textbf{Coalescer}\\one request per cycle:\\the lowest pending lane\\'
    r'and the lanes in its line;\\8 tags in flight', 'mem')
box('ldret', 13.26, 3.74, 15.90, 4.56, r'\textbf{Load return}\\words to the RF', 'mem')
box('amo', 13.26, 1.42, 15.90, 3.56,
    r'\textbf{Line-aggregated AMOs}\\[2pt]one read per line\\into a line buffer\\'
    r'lanes applied in rounds,\\in serial lane order\\1 AMO ALU (\emph{ser})\\'
    r'or $L$ ALUs (\emph{par})\\one masked write', 'hl')
box('scr', 16.06, 1.42, 17.66, 4.56,
    r'\textbf{Scratchpad}\\(LUTRAM)\\[3pt]64 words\\per warp and\\a block-shared\\region\\[3pt]'
    r'one lane\\per cycle', 'sto')

# ---------------------------------------------------------------- arrows
arrow([(1.84, 10.80), (1.84, 10.45)])                                 # A53 -> HPM0
arrow([(3.38, 10.20), (3.735, 10.20)])                                  # HPM0 -> SC
arrow([(4.215, 12.03), (4.58, 12.03)])                                # SC -> AXI-Lite slave
arrow([(6.30, 11.82), (6.30, 11.66)])                                 # slave -> regs
arrow([(9.30, 11.82), (9.30, 11.66)])                                 # slave -> IRAM
arrow([(6.30, 10.40), (6.30, 9.88)], label='GO', lpos='pos=0.45', lopt='right')
arrow([(8.84, 10.40), (8.84, 9.88)], label='instruction', lpos='pos=0.45', lopt='right')
arrow([(6.30, 8.92), (6.30, 8.72)])                                   # spawn -> slots
arrow([(6.30, 6.50), (6.30, 6.92)], style='darr')                    # sched <-> slots
arrow([(8.05, 5.93), (8.28, 5.93)])                                   # sched -> F
arrow([(9.40, 7.62), (9.60, 7.62)])                                   # F -> X
arrow([(11.30, 9.23), (11.60, 9.23)], style='darr')                  # X <-> int RF
arrow([(11.30, 8.01), (11.60, 8.01)], style='darr')                  # X <-> FP RF
arrow([(13.08, 9.23), (13.60, 9.23)])                                 # RF -> lanes
arrow([(13.08, 8.01), (13.60, 8.01)])
arrow([(13.80, 7.25), (13.80, 6.80), (13.18, 6.80)], label='results',
      lpos='pos=0.5', lopt='right')                                   # lanes -> arbiter
arrow([(12.34, 6.98), (12.34, 7.36)])                                 # arbiter -> RFs
arrow([(10.45, 5.36), (10.45, 4.50)], style='bus',
      label='memory instruction', lpos='pos=0.30', lopt='right')     # X -> contexts
arrow([(11.67, 3.14), (11.67, 2.92)])                                 # contexts -> coalescer
arrow([(14.44, 4.56), (14.44, 5.04), (12.70, 5.04), (12.70, 5.36)], style='bus',
      label='load data', lpos='pos=0.5', lopt='above')                # load return -> arbiter
arrow([(10.30, 3.10), (9.88, 3.10)], style='bdarr')                   # engine <-> L1
arrow([(6.92, 3.10), (6.72, 3.10)], style='bdarr')                    # L1 <-> AXI master
arrow([(4.58, 3.25), (3.38, 3.25)], style='bdarr')                    # AXI master <-> HP0
emit(r'\node[elabel, align=center] at (3.975,3.82) {AXI4\\128 bit};')
emit(r'\node[elabel, align=center, fill=white, inner sep=0.5pt] at (10.09,3.80) '
     r'{line\\port};')
emit(r'\node[elabel, align=center, fill=white, inner sep=0.5pt] at (10.09,2.45) '
     r'{$32L$\\bit};')
arrow([(1.84, 2.85), (1.84, 2.45)], style='darr')                    # HP0 <-> DDRC
arrow([(2.55, 1.28), (2.55, 0.78)], style='bdarr')                   # DDRC <-> DDR4
arrow([(0.925, 1.28), (0.925, 0.78)], style='darr')                  # I2C <-> monitors

TEMPLATE = r"""%% generated by gen_arch_v2.py -- do not edit by hand
\documentclass[10pt]{standalone}
\usepackage{mathptmx}
\usepackage{tikz}
\usetikzlibrary{arrows.meta}
\definecolor{cctl}{HTML}{FFF2CC}
\definecolor{ciss}{HTML}{DDEBF7}
\definecolor{cexe}{HTML}{E4DFEC}
\definecolor{csto}{HTML}{E2EFDA}
\definecolor{cmem}{HTML}{FBE5D6}
\definecolor{chl}{HTML}{F8CBAD}
\definecolor{chlb}{HTML}{C55A11}
\definecolor{cps}{HTML}{EDEDED}
\newcommand{\fsz}{\fontsize{6.5}{7.5}\selectfont}
\begin{document}
\begin{tikzpicture}[x=1cm, y=1cm,
  base/.style={draw=black!70, rounded corners=1.2pt, align=center, font=\fsz,
               inner sep=1.2pt, line width=0.45pt},
  ctl/.style={base, fill=cctl},   ctlbox/.style={base, fill=cctl},
  iss/.style={base, fill=ciss},   issbox/.style={base, fill=ciss},
  exe/.style={base, fill=cexe},   exebox/.style={base, fill=cexe},
  exein/.style={base, fill=white},
  sto/.style={base, fill=csto},   stobox/.style={base, fill=csto},
  mem/.style={base, fill=cmem},   membox/.style={base, fill=cmem},
  hl/.style={base, fill=chl, draw=chlb, line width=1.1pt},
  hlbox/.style={base, fill=chl, draw=chlb, line width=1.1pt},
  ps/.style={base, fill=cps},
  port/.style={base, fill=white, font=\fsz\ttfamily},
  note/.style={base, fill=white, draw=black!45, dashed, align=left},
  off/.style={base, fill=white, draw=black!60},
  devframe/.style={draw=black!55, line width=0.5pt, dash pattern=on 3pt off 1.5pt},
  psframe/.style={draw=black!60, fill=black!3, rounded corners=2pt},
  accframe/.style={draw=black!80, fill=blue!2, rounded corners=2pt, line width=0.7pt},
  wpframe/.style={draw=black!55, fill=white, rounded corners=2pt},
  memframe/.style={draw=black!55, fill=white, rounded corners=2pt},
  rfframe/.style={draw=black!45, fill=white, rounded corners=1.5pt},
  flabel/.style={font=\fsz, inner sep=1pt},
  dlabel/.style={font=\fsz\itshape, inner sep=1pt},
  olabel/.style={font=\fsz\itshape, inner sep=1pt},
  lgtext/.style={font=\fsz, inner sep=0.5pt},
  elabel/.style={font=\fsz, inner sep=1pt},
  arr/.style={-{Latex[length=1.5mm, width=1.1mm]}, line width=0.55pt},
  darr/.style={{Latex[length=1.5mm, width=1.1mm]}-{Latex[length=1.5mm, width=1.1mm]},
               line width=0.55pt},
  bus/.style={-{Latex[length=1.9mm, width=1.6mm]}, line width=1.1pt},
  bdarr/.style={{Latex[length=1.9mm, width=1.6mm]}-{Latex[length=1.9mm, width=1.6mm]},
                line width=1.1pt}]
%s
\end{tikzpicture}
\end{document}
"""


def main():
    with open(OUT_TEX, 'w', encoding='utf-8', newline='\n') as f:
        f.write(TEMPLATE % '\n'.join(body))
    subprocess.run(['pdflatex', '-interaction=nonstopmode', 'simtix_arch_v2.tex'],
                   cwd=HERE, check=True, stdout=subprocess.DEVNULL)
    shutil.copyfile(os.path.join(HERE, 'simtix_arch_v2.pdf'), OUT_PDF)
    print('wrote', OUT_PDF)


if __name__ == '__main__':
    main()
