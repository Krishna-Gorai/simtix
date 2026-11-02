"""
gen_amo_fig.py -- the line-aggregated AMO unit: datapath and timeline.

    python docs/figs/arch_v2_tikz/gen_amo_fig.py     (writes simtix_amo.tex,
                                                    builds ../simtix_amo.pdf)

(a) follows rtl/accel/mem_engine.sv (APAR = 1, with the APAR = 0 differences
noted): lead lane and line compare form the group mask sent with the read; the
returning line loads the line buffer and the remaining-lanes mask; each cycle the
round logic picks the lanes to apply, the word multiplexers return their old
words, the AMO ALUs write the new words back into the buffer, and the touched
words become the byte enables of the one write. (b) is the example of the old
Fig. 2 (lanes 0-7 on words 3,3,5,0,3,5,7,1) as a timeline. Same drawing style as
gen_arch_v3.py; 18 cm wide.
"""
import os
import shutil
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
NAME = 'simtix_amo'
OUT_PDF = os.path.join(os.path.dirname(HERE), NAME + '.pdf')

body = []


def emit(s):
    body.append(s)


def c(x, y):
    return f'({x:.3f},{y:.3f})'


def box(x0, y0, x1, y1, text, style, name=None):
    w, h = x1 - x0, y1 - y0
    nm = f' ({name})' if name else ''
    emit(f'\\node[{style}, minimum width={w:.3f}cm, minimum height={h:.3f}cm, '
         f'text width={w - 0.10:.3f}cm]{nm} at {c((x0 + x1) / 2, (y0 + y1) / 2)} {{{text}}};')


def rect(x0, y0, x1, y1, style):
    emit(f'\\draw[{style}] {c(x0, y0)} rectangle {c(x1, y1)};')


def text(x, y, s, style='lbl', anchor='center'):
    emit(f'\\node[{style}, anchor={anchor}] at {c(x, y)} {{{s}}};')


def shadow(x0, y0, x1, y1, style, n=2, d=0.05):
    for k in range(n, 0, -1):
        rect(x0 + k * d, y0 - k * d, x1 + k * d, y1 - k * d, style)


def arrow(pts, style='arr'):
    emit(f'\\draw[{style}] ' + ' -- '.join(c(*p) for p in pts) + ';')


def dot(x, y):
    emit(f'\\fill {c(x, y)} circle (0.04);')


def cells(x0, y0, x1, y1, labels, fill='white', bold=None):
    """A row of equal cells (a register of one bit or word per lane)."""
    n = len(labels)
    cw = (x1 - x0) / n
    for i, t in enumerate(labels):
        f = fill(i) if callable(fill) else fill
        rect(x0 + i * cw, y0, x0 + (i + 1) * cw, y1, f'tbl, fill={f}')
        if t != '':
            text(x0 + (i + 0.5) * cw, (y0 + y1) / 2, t, 'cell')


def regbar(x0, x1, y, h=0.06):
    emit(f'\\fill[black] {c(x0, y - h / 2)} rectangle {c(x1, y + h / 2)};')


# =================================================================== (a) datapath
H = 7.55                                                           # panel top
rect(-0.10, -0.05, 11.20, H, 'panel')

# request port to the L1, held from the read to the write
box(2.15, 6.98, 11.08, 7.38, r'\textbf{Request port to the L1}: held by this context from the '
    r'read to the write', 'ctrl')

# locked context (architectural state)
text(0.92, 6.58, r'\textbf{Locked context}', 'tbltitle')
rows = [('pending', 5.85), (r'addresses $\times L$', 4.95), ('AMO op', 4.05),
        (r'store data $\times L$', 3.15)]
for t, yc in rows:
    rect(0.00, yc - 0.45, 1.85, yc + 0.45, 'tbl, fill=white')
    text(0.925, yc, t, 'cell')

# lead lane and line compare -> group mask; word offsets
box(2.20, 5.55, 4.45, 6.25, r'\textbf{Lead lane} $\ell$\\lowest pending lane', 'ctrl')
box(2.20, 4.50, 4.45, 5.25, r'\textbf{Line compare} $\times L$\\'
    r'$\mathrm{line}(a_i)=\mathrm{line}(a_\ell)$', 'exe')
cells(2.20, 3.80, 4.45, 4.14, [''] * 8)
text(3.32, 3.66, r'group mask $G$', 'cell', 'north')
box(2.20, 2.55, 4.45, 3.25, r'\textbf{Word offset} $\times L$\\word of each lane', 'exe')
arrow([(1.85, 5.85), (2.20, 5.85)])                                # pending -> lead
arrow([(1.85, 4.95), (2.20, 4.95)])                                # addresses -> compare
dot(2.03, 4.95)
arrow([(2.03, 4.95), (2.03, 2.90), (2.20, 2.90)])                  # addresses -> offset
arrow([(3.32, 5.55), (3.32, 5.25)])                                # lead -> compare
arrow([(3.32, 4.50), (3.32, 4.14)])                                # compare -> G
arrow([(3.32, 6.25), (3.32, 6.98)])                                # read request
text(3.40, 6.62, r'read: line of $\ell$', 'wlabel', 'west')

# round logic
cells(4.95, 5.85, 7.20, 6.19, [''] * 8)
text(6.08, 6.33, r'remaining lanes', 'cell', 'south')
box(4.95, 4.20, 7.20, 5.55, r'\textbf{Round select}\\[2pt]$L(L{-}1)/2$ word\\compares', 'exe')
cells(4.95, 3.45, 7.20, 3.79, [''] * 8)
text(6.08, 3.31, r'round lanes', 'cell', 'north')
text(6.08, 2.92, r'\emph{ser}: the lowest remaining lane', 'cell', 'north')
arrow([(4.45, 3.97), (4.70, 3.97), (4.70, 6.02), (4.95, 6.02)])   # G -> remaining
text(4.62, 5.10, r'on line return', 'vlabel')
arrow([(6.08, 5.85), (6.08, 5.55)])                                # remaining -> round
arrow([(4.45, 2.90), (4.84, 2.90), (4.84, 4.50), (4.95, 4.50)])   # offsets -> round
arrow([(6.08, 4.20), (6.08, 3.79)])                                # round -> round lanes
dot(7.40, 3.62)
arrow([(7.20, 3.62), (7.40, 3.62), (7.40, 6.02), (7.20, 6.02)])   # clear applied lanes
text(7.48, 4.85, 'clear', 'vlabelr')

# line buffer, word multiplexers, ALUs
text(7.75, 6.42, r'\textbf{Line buffer}', 'tbltitle', 'west')
cells(7.75, 5.85, 10.55, 6.19, [f'w{i}' for i in range(8)], fill='cmem')
arrow([(10.05, 6.98), (10.05, 6.19)])                              # line returns
text(10.12, 6.58, 'line', 'wlabel', 'west')
# word multiplexer: L words in at the wide side, the lane's word offset selects
emit(r'\draw[mux] (7.80,5.62) -- (9.15,5.62) -- (8.80,4.98) -- (8.15,4.98) -- cycle;')
emit(r'\node[cell, align=center] at (8.47,5.33) {\textbf{word mux}\\$\times L$};')
arrow([(8.47, 5.85), (8.47, 5.62)])                                # L words in
arrow([(7.52, 5.15), (8.05, 5.15)])                                # select
text(7.55, 5.10, 'offset', 'wlabel', 'north west')
arrow([(8.47, 4.98), (8.47, 4.72), (9.30, 4.72)])                  # old word out
emit(r'\node[wlabel, anchor=west, align=left] at (9.32,4.72) {old words\\to the RF};')
box(7.75, 3.20, 9.20, 4.45, r'\textbf{Data}\\\textbf{select}\\per word', 'exe')
arrow([(7.40, 3.62), (7.75, 3.62)])                                # round lanes -> select
shadow(9.45, 3.20, 10.50, 4.45, 'exebox', n=2, d=0.05)
box(9.45, 3.20, 10.50, 4.45, r'\textbf{AMO}\\\textbf{ALU}\\[2pt]$\times L$ \emph{par}\\$\times 1$ \emph{ser}',
    'exe')
arrow([(9.20, 3.82), (9.45, 3.82)])
arrow([(10.33, 5.85), (10.33, 4.45 + 0.10)])                       # old word into ALU
arrow([(10.60, 3.82), (10.80, 3.82), (10.80, 6.02), (10.55, 6.02)])  # new words
text(10.89, 4.95, 'new words', 'vlabelr')
cells(9.45, 2.48, 10.50, 2.78, [''] * 4, fill='csto')
text(9.38, 2.63, r'touched words', 'cell', 'east')
arrow([(9.97, 3.20 - 0.10), (9.97, 2.78)])
box(9.45, 1.62, 10.50, 2.28, r'\textbf{Masked}\\\textbf{write}', 'ctrl')
arrow([(9.97, 2.48), (9.97, 2.28)])
arrow([(10.50, 1.95), (11.02, 1.95), (11.02, 6.98)])              # write request
# store data from the context, routed under the datapath
arrow([(0.45, 2.70), (0.45, 1.30), (8.05, 1.30), (8.05, 3.20)])
text(0.53, 1.38, 'store data', 'wlabel', 'south west')

# state machine
sx = [(0.55, 'RD'), (2.85, 'WAIT'), (5.35, 'AGG'), (8.00, 'WR')]
for x, s in sx:
    emit(f'\\node[fsm] ({s}) at {c(x, 0.38)} {{{s}}};')
emit(r'\draw[arr] (RD) -- node[wlabel, above] {read sent} (WAIT);')
emit(r'\draw[arr] (WAIT) -- node[wlabel, above] {line returns} (AGG);')
emit(r'\draw[arr] (AGG) -- node[wlabel, above] {no lane left} (WR);')
emit(r'\path (AGG) edge[arr, loop above, min distance=3.5mm, in=60, out=120] (AGG);')
text(5.05, 0.86, r'one round per cycle', 'wlabel', 'east')
emit(r'\draw[arr] (WR.east) -- ++(0.45,0) node[wlabel, anchor=west] {next group};')

# =================================================================== (b) timeline
X0 = 11.50
rect(X0, -0.05, 18.00, H, 'panel')
# the example: lane, word, round
gx0, gw = 12.85, 0.62
labels = ['lane', 'word', 'round']
lw = [3, 3, 5, 0, 3, 5, 7, 1]
rd = [1, 2, 1, 1, 3, 2, 1, 1]
shade = {1: 'blue!12', 2: 'blue!28', 3: 'blue!45'}
for r, (lab, vals) in enumerate(zip(labels, [list(range(8)), lw, rd])):
    y1 = 7.30 - r * 0.42
    text(gx0 - 0.08, y1 - 0.21, lab, 'cell', 'east')
    for i, v in enumerate(vals):
        f = shade[v] if r == 2 else 'white'
        rect(gx0 + i * gw, y1 - 0.42, gx0 + (i + 1) * gw, y1, f'tbl, fill={f}')
        text(gx0 + (i + 0.5) * gw, y1 - 0.21, str(v), 'cell')
emit(f'\\node[cell, anchor=west, align=left] at {c(X0 + 0.15, 5.78)} {{Eight lanes on one '
     f'line: lanes 0, 1 and 4 share word 3,\\\\and lanes 2 and 5 share word 5.}};')

SW = 0.30                                                          # one cycle
T0 = 12.85


def slot(x, y, t, style):
    rect(x, y, x + SW, y + 0.36, style)
    if t:
        text(x + SW / 2, y + 0.18, t, 'cell')


def gap(x, y, n=2):
    emit(f'\\draw[dashed, black!50] {c(x + 0.04, y + 0.18)} -- {c(x + n * SW - 0.04, y + 0.18)};')


# per-lane read-modify-write
y = 4.35
text(T0 - 0.08, y + 0.18, r'per lane', 'cellh', 'east')
x = T0
for i in range(8):
    slot(x, y, 'R', 'membox')
    slot(x + SW, y, 'W', 'membox')
    x += 2 * SW + 0.02
text(T0, y - 0.08, r'16 requests; each read waits for its line', 'cell', 'north west')

# ser
y = 2.95
text(T0 - 0.08, y + 0.18, r'\emph{ser}', 'cellh', 'east')
x = T0
slot(x, y, 'R', 'membox'); x += SW
gap(x, y); x += 2 * SW
for i in range(8):
    slot(x, y, str(i), 'exebox'); x += SW
slot(x, y, 'W', 'membox')
text(T0, y - 0.08, r'2 requests, 8 apply cycles (one lane each)', 'cell', 'north west')

# par
y = 1.55
text(T0 - 0.08, y + 0.18, r'\emph{par}', 'cellh', 'east')
x = T0
slot(x, y, 'R', 'membox'); x += SW
gap(x, y); x += 2 * SW
for r in (1, 2, 3):
    rect(x, y, x + SW, y + 0.36, f'tbl, fill={shade[r]}')
    text(x + SW / 2, y + 0.18, str(r), 'cell')
    x += SW
slot(x, y, 'W', 'membox')
text(T0, y - 0.08, r'2 requests, 3 apply cycles (one round each)', 'cell', 'north west')

emit(f'\\draw[arr] {c(T0, 0.22)} -- {c(17.85, 0.22)} node[wlabel, anchor=south east] '
     f'{{time (not to scale)}};')
# key for (b)
for i, (st, t) in enumerate((('membox', 'request (R read, W write)'),
                             ('exebox', 'apply one lane'))):
    xk = X0 + 0.15 + i * 3.1
    rect(xk, 5.20, xk + 0.30, 5.44, st)
    text(xk + 0.38, 5.32, t, 'keytext', 'west')

# sub-captions
text(5.55, -0.30, r'(a) Datapath of the unit (\emph{par} variant)', 'subcap', 'north')
text(14.72, -0.30, r'(b) One AMO instruction of the example', 'subcap', 'north')

TEMPLATE = r"""%% generated by gen_amo_fig.py -- do not edit by hand
\documentclass[10pt]{standalone}
\usepackage{helvet}
\renewcommand{\familydefault}{\sfdefault}
\usepackage{amsmath,amssymb}
\usepackage{tikz}
\usetikzlibrary{arrows.meta}
\definecolor{cctrl}{HTML}{D6E0EC}
\definecolor{cctrlb}{HTML}{3B5675}
\definecolor{cexe}{HTML}{FFE699}
\definecolor{cexeb}{HTML}{7F6000}
\definecolor{cmem}{HTML}{FBE5D6}
\definecolor{cmemb}{HTML}{C55A11}
\definecolor{csto}{HTML}{E2EFDA}
\newcommand{\fs}{\fontsize{6.4}{7.4}\selectfont}
\newcommand{\fss}{\fontsize{5.8}{6.6}\selectfont}
\begin{document}
\begin{tikzpicture}[x=1cm, y=1cm,
  base/.style={align=center, font=\fs, inner sep=1pt, line width=0.5pt},
  ctrl/.style={base, draw=cctrlb, fill=cctrl},
  exe/.style={base, draw=cexeb, fill=cexe},  exebox/.style={draw=cexeb, fill=cexe, line width=0.5pt},
  membox/.style={draw=cmemb, fill=cmem, line width=0.5pt},
  mux/.style={draw=black, fill=black!12, line width=0.6pt},
  tbl/.style={draw=black, line width=0.45pt},
  cell/.style={font=\fss, inner sep=0.5pt}, cellh/.style={font=\fss\bfseries, inner sep=0.5pt},
  tbltitle/.style={font=\fs, inner sep=0.5pt},
  panel/.style={draw=black!40, dashed, rounded corners=3pt, fill=black!1, line width=0.5pt},
  fsm/.style={draw=cctrlb, fill=cctrl, rounded corners=5pt, font=\fss\bfseries,
              minimum width=0.85cm, minimum height=0.36cm, inner sep=1pt},
  lbl/.style={font=\fs, inner sep=0.5pt},
  wlabel/.style={font=\fss, inner sep=1pt},
  keytext/.style={font=\fss, inner sep=0.5pt},
  subcap/.style={font=\fs, inner sep=1pt},
  vlabel/.style={font=\fss, rotate=90, inner sep=0.5pt},
  vlabelr/.style={font=\fss, rotate=-90, inner sep=0.5pt},
  arr/.style={-{Latex[length=1.4mm, width=1.0mm]}, line width=0.55pt}]
%s
\end{tikzpicture}
\end{document}
"""


def main():
    with open(os.path.join(HERE, NAME + '.tex'), 'w', encoding='utf-8', newline='\n') as f:
        f.write(TEMPLATE % '\n'.join(body))
    subprocess.run(['pdflatex', '-interaction=nonstopmode', NAME + '.tex'], cwd=HERE,
                   check=True, stdout=subprocess.DEVNULL)
    shutil.copyfile(os.path.join(HERE, NAME + '.pdf'), OUT_PDF)
    print('wrote', OUT_PDF)


if __name__ == '__main__':
    main()
