"""
gen_amo_fig.py -- the line-aggregated AMO unit: datapath, the example, and its RTL timing.

    python docs/figs/arch_v2_tikz/gen_amo_fig.py     (writes simtix_amo.tex,
                                                    builds ../simtix_amo.pdf)

(a) The datapath of rtl/accel/mem_engine.sv, one column per phase of the locked context
    (group = AP_RD, apply = AP_AGG, write = AP_WR). The lead lane (lowest pending lane) and the
    line compare form the group mask G, sent with the read of the lead's line; on the line's
    return the line buffer takes the line and the remaining-lanes mask takes G. In each apply
    cycle the round select picks the round's lanes (APAR = 1: every remaining lane whose word no
    lower remaining lane still has, from L(L-1)/2 compares of word offsets; APAR = 0: the lowest
    remaining lane), which are cleared from the remaining lanes. The lane-word crossbar is the
    per-lane word routing of the RTL in both directions: it gives each word the store data of its
    round lane as the AMO ALU's operand v (a_v) and each round lane the old word x (a_old, to the
    register file). The ALUs (one per word for par, one for ser) write f(x, v) back into the
    buffer; the touched words become the byte enables of the one masked write. Every wire is
    connected end to end, junctions are dots, and no two wires cross.
(b) The example (kernels/figs/amo_demo.S): one amoadd.w whose eight lanes add 1 to the words
    3, 3, 5, 0, 3, 5, 7, 1 of one line. The rounds are read from the RTL trace of the parallel
    variant; the line after each round and the values returned follow serial execution, and
    tb_figtrace.sv checks both the final line and every returned value on the RTL.
(c) The example traced on the RTL in the three variants (fig_trace.py runs amo_lane, amo_ser,
    amo_par): the context's requests to the L1, the lanes applied in each cycle and the write
    responses, from the issue of the AMO until its warp resumes; cycles 53-76, the line read from
    DDR4, are an axis break.
"""
import os
import shutil
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
NAME = 'simtix_amo'
OUT_PDF = os.path.join(os.path.dirname(HERE), NAME + '.pdf')
WORDS = [3, 3, 5, 0, 3, 5, 7, 1]                # the example: the word of each lane
L = len(WORDS)

body = []


def emit(s):
    body.append(s)


def c(x, y):
    return f'({x:.3f},{y:.3f})'


def box(x0, y0, x1, y1, text, style):
    w, h = x1 - x0, y1 - y0
    emit(f'\\node[{style}, minimum width={w:.3f}cm, minimum height={h:.3f}cm, '
         f'text width={w - 0.12:.3f}cm] at {c((x0 + x1) / 2, (y0 + y1) / 2)} {{{text}}};')


def rect(x0, y0, x1, y1, style):
    emit(f'\\draw[{style}] {c(x0, y0)} rectangle {c(x1, y1)};')


def text(x, y, s, style='lbl', anchor='center'):
    emit(f'\\node[{style}, anchor={anchor}] at {c(x, y)} {{{s}}};')


def cells(x0, y0, x1, y1, labels, fill='white'):
    n = len(labels)
    cw = (x1 - x0) / n
    for i, t in enumerate(labels):
        rect(x0 + i * cw, y0, x0 + (i + 1) * cw, y1, f'tbl, fill={fill}')
        if t:
            text(x0 + (i + 0.5) * cw, (y0 + y1) / 2, t, 'cell')


def wire(pts, style='arr'):
    emit(f'\\draw[{style}] ' + ' -- '.join(c(*p) for p in pts) + ';')


def dot(x, y):
    emit(f'\\fill {c(x, y)} circle (0.045);')


def shadow(x0, y0, x1, y1, style, n=2, d=0.05):
    for k in range(n, 0, -1):
        rect(x0 + k * d, y0 - k * d, x1 + k * d, y1 - k * d, style)


# ============================================================================ traces
def load(run):
    ev = {}
    for line in open(os.path.join(HERE, 'traces', run + '_fig.txt')):
        p = line.split()
        if len(p) > 1 and p[1].isdigit():
            ev.setdefault(p[0], []).append(p[1:])
    issue = None
    for line in open(os.path.join(HERE, 'traces', run + '_issue.txt')):
        p = line.split()
        if p and p[0] == 'I' and int(p[4], 16) & 0x7f == 0x2f:          # the AMO instruction
            issue = int(p[1])
    park = min(int(e[0]) for e in ev['Z'] if e[1] == '0' and e[2] == '2' and int(e[0]) >= issue)
    resume = min(int(e[0]) for e in ev['Z'] if e[1] == '0' and e[2] == '1' and int(e[0]) > park)
    req = {int(e[0]): ('W' if e[3] == '1' else 'R') for e in ev['Q'] if issue < int(e[0]) < resume}
    hits = {int(e[0]) for e in ev.get('H', [])}
    apply = {}
    for e in ev.get('AM', []):
        if e[1] == '2' and '1' in e[2]:
            apply[int(e[0])] = sorted(L - 1 - i for i, b in enumerate(e[2]) if b == '1')
    ack = sorted(int(e[0]) for e in ev['BR'] if issue < int(e[0]) < resume)
    line_back = min(int(e[0]) for e in ev['A'] if int(e[0]) > issue + 5)
    return dict(issue=issue, resume=resume, req=req, hits=hits, apply=apply, ack=ack,
                line_back=line_back)


VAR = [('amo_lane', 'lane'), ('amo_ser', 'ser'), ('amo_par', 'par')]
T = {short: load(run) for run, short in VAR}
ROUNDS = [T['par']['apply'][k] for k in sorted(T['par']['apply'])]     # lanes of each round

# serial execution of the example: the line after each round and the value each lane gets
line = [0] * L
ret = [None] * L
after = []
for rnd in ROUNDS:
    assert len({WORDS[i] for i in rnd}) == len(rnd)                    # one lane per word
    for i in sorted(rnd):
        ret[i] = line[WORDS[i]]
        line[WORDS[i]] += 1
    after.append(list(line))
ser_ret = [sum(1 for j in range(i) if WORDS[j] == WORDS[i]) for i in range(L)]
assert ret == ser_ret, (ret, ser_ret)                                  # rounds = serial order
assert sorted(sum(ROUNDS, [])) == list(range(L))
rnd_of = {i: k + 1 for k, rnd in enumerate(ROUNDS) for i in rnd}

# ============================================================== (a) datapath (y 6.6 .. -0.6)
box(2.80, 6.20, 17.70, 6.60, r'\textbf{Request port to the L1}: held by the locked '
    r'context from its read to its write', 'ctrl')
for x0, x1, t in ((2.55, 6.10, r'\textbf{Group} (RD)'),
                  (6.30, 14.30, r'\textbf{Apply}, one round per cycle (AGG)'),
                  (14.50, 17.70, r'\textbf{Write} (WR)')):
    rect(x0, 1.00, x1, 6.02, 'stagebox')
    text(x0 + 0.10, 5.84, t, 'stagetitle', 'west')

# locked context (architectural state)
text(0.975, 5.80, r'\textbf{Locked context}', 'tbltitle')
for yc, t in ((5.16, 'pending lanes'), (4.44, r'addresses $\times L$'),
              (3.72, r'store data $\times L$'), (3.00, 'AMO op')):
    rect(0.00, yc - 0.36, 1.95, yc + 0.36, 'tbl, fill=white')
    text(0.975, yc, t, 'cell')
rect(0.00, 2.64, 1.95, 5.52, 'tblthick')

# group: lead lane, line compare -> G; word offsets
box(2.80, 4.85, 5.20, 5.45, r'\textbf{Lead lane} $\ell$\\{\fss lowest pending lane}', 'ctrl')
box(2.80, 3.90, 5.20, 4.70, r'\textbf{Line compare} $\times L$\\'
    r'{\fss $\mathrm{line}(a_i)=\mathrm{line}(a_\ell)$}', 'exe')
cells(2.80, 3.25, 5.20, 3.55, [''] * L, fill='cmask')
text(4.00, 3.12, r'group mask $G$', 'cell', 'north')
box(2.80, 2.05, 5.20, 2.70, r'\textbf{Word offset} $\times L$', 'exe')
wire([(1.95, 5.16), (2.80, 5.16)])                               # pending -> lead lane
dot(2.50, 5.16)
wire([(2.50, 5.16), (2.50, 4.58), (2.80, 4.58)])                 # pending -> compare (mask)
wire([(1.95, 4.40), (2.80, 4.40)])                               # addresses -> compare
dot(2.38, 4.40)
wire([(2.38, 4.40), (2.38, 2.38), (2.80, 2.38)])                 # addresses -> word offset
wire([(4.00, 4.85), (4.00, 4.70)])                               # l -> compare
wire([(4.00, 3.90), (4.00, 3.55)])                               # compare -> G
wire([(4.70, 5.45), (4.70, 6.20)])                               # read request
text(4.78, 5.82, r'read: line of $\ell$', 'wlabel', 'west')
wire([(5.20, 3.40), (5.60, 3.40), (5.60, 5.16), (6.55, 5.16)])   # G -> remaining lanes
text(5.77, 4.28, r'$G$, on line return', 'vlabel')
# word offsets: to the round select and the crossbar
wire([(5.20, 2.38), (9.60, 2.38), (9.60, 2.75)])
dot(6.40, 2.38)
wire([(6.40, 2.38), (6.40, 4.00), (6.55, 4.00)])
text(8.05, 2.38, 'offsets', 'wlabelbg')
# store data and AMO op, along the bottom
wire([(1.95, 3.72), (2.24, 3.72), (2.24, 1.50), (10.20, 1.50), (10.20, 2.75)])
wire([(1.95, 3.00), (2.12, 3.00), (2.12, 1.25), (11.70, 1.25), (11.70, 2.75)])
text(4.00, 1.50, 'store data', 'wlabelbg')
text(7.95, 1.25, 'AMO op', 'wlabelbg')

# apply: remaining lanes, round select, round lanes
cells(6.55, 5.00, 8.45, 5.32, [''] * L, fill='cmask')
text(7.50, 5.48, 'remaining lanes', 'cell')
box(6.55, 3.75, 8.45, 4.70, r'\textbf{Round select}\\{\fss $L(L{-}1)/2$ word}\\{\fss compares}', 'exe')
cells(6.55, 3.05, 8.45, 3.35, [''] * L, fill='cmask')
text(7.50, 2.92, 'round lanes', 'cell', 'north')
wire([(7.50, 5.00), (7.50, 4.70)])
wire([(7.50, 3.75), (7.50, 3.35)])
wire([(8.45, 3.20), (8.72, 3.20)], 'line')
dot(8.72, 3.20)
wire([(8.72, 3.20), (8.72, 5.16), (8.45, 5.16)])                 # clear the applied lanes
text(8.85, 4.25, 'clear', 'vlabelr')
wire([(8.72, 3.20), (9.30, 3.20)])                               # round lanes -> crossbar
# lane-word crossbar, AMO ALUs, line buffer
box(9.30, 2.75, 10.70, 3.65, r'\textbf{Lane--word}\\\textbf{crossbar}', 'exe')
wire([(10.00, 3.65), (10.00, 4.02)])
emit(r'\node[cell, anchor=south, align=center] at (10.000,4.040) {old words\\to the RF};')
shadow(11.20, 2.85, 12.60, 3.75, 'exebox', n=2, d=0.05)
box(11.20, 2.85, 12.60, 3.75, r'\textbf{AMO ALU}\\{\fss $\times L$ \emph{par}, $\times 1$ \emph{ser}}', 'exe')
wire([(10.70, 3.05), (11.20, 3.05)])                             # operand v of each word
text(10.95, 3.08, r'$v$', 'wlabel', 'south')
wire([(11.20, 3.45), (10.70, 3.45)])                             # old word x of each word
text(10.95, 3.48, r'$x$', 'wlabel', 'south')
cells(9.30, 5.00, 13.90, 5.32, [f'w{i}' for i in range(L)], fill='cmem')
text(11.60, 5.48, r'\textbf{Line buffer}', 'cell')
wire([(11.55, 5.00), (11.55, 3.75)])                             # x into the ALU
text(11.62, 4.40, r'$x$', 'wlabel', 'west')
wire([(12.25, 3.75), (12.25, 5.00)])                             # f(x, v) back into the buffer
text(12.32, 4.40, r"$f(x,v)$", 'wlabel', 'west')
wire([(13.60, 6.20), (13.60, 5.32)])                             # the line returns
text(13.68, 5.82, 'line', 'wlabel', 'west')

# write: touched words, masked write
wire([(12.70, 3.30), (14.85, 3.30)])                             # ALU -> touched words
cells(14.85, 3.15, 16.65, 3.45, [''] * L, fill='cmask')
text(15.75, 3.60, 'touched words', 'cell', 'south')
box(14.85, 1.90, 16.65, 2.65, r'\textbf{Masked write}\\{\fss byte enables}', 'ctrl')
wire([(15.75, 3.15), (15.75, 2.65)])
wire([(13.90, 5.16), (17.05, 5.16), (17.05, 2.27), (16.65, 2.27)])   # the line's words
text(15.50, 5.19, 'words', 'wlabel', 'south')
wire([(15.75, 1.90), (15.75, 1.60), (17.40, 1.60), (17.40, 6.20)])   # the write request
text(17.33, 5.82, 'write', 'wlabel', 'east')

# the phase of the locked context
for x, s in ((4.00, 'RD'), (6.40, 'WAIT'), (10.00, 'AGG'), (15.75, 'WR')):
    emit(f'\\node[fsm] ({s}) at {c(x, 0.42)} {{{s}}};')
text(0.05, 0.42, r'\textbf{Phase}', 'cell', 'west')
emit(r'\draw[arr] (RD) -- node[wlabel, above] {read sent} (WAIT);')
emit(r'\draw[arr] (WAIT) -- node[wlabel, above] {line returns} (AGG);')
emit(r'\draw[arr] (AGG) -- node[wlabel, above] {no lane left} (WR);')
emit(r'\path (AGG) edge[arr, loop above, min distance=3.2mm, in=60, out=120] (AGG);')
text(10.40, 0.86, 'one round per cycle', 'wlabel', 'west')
emit(r'\draw[arr] (WR.south) -- ++(0,-0.20) -| node[wlabel, pos=0.25, below] '
     r'{lanes left on other lines: next group} (RD.south);')
emit(r'\draw[arr] (WR.east) -- ++(0.55,0) node[wlabel, anchor=west] {done};')
text(9.0, -0.50, r'(a) Datapath of the unit and the phase of its locked context', 'subcap')

# ======================================================= (b) the example (y -0.95 .. -3.6)
YB = -1.05
text(0.05, YB, r'\textbf{The instruction}, one warp of eight lanes', 'cell', 'west')
rect(0.05, YB - 0.62, 4.95, YB - 0.22, 'codebox')
text(0.20, YB - 0.42, r'amoadd.w\ \ t5, t4, (t3)', 'code', 'west')
emit(f'\\node[cell, anchor=north west, align=left] at {c(0.05, YB - 0.74)} '
     r'{lane $i$: \ $t5_i \leftarrow C[w_i]$, \ then \ $C[w_i] \leftarrow C[w_i] + t4_i$\\[1pt]'
     r'with $t4_i=1$ and $t3_i=\&C[w_i]$; \ $C$: one 32-byte line,\\[1pt]'
     r'zero before the AMO};')


def table(x0, ytop, labw, cw, rh, rows, title):
    """rows: (label, values, fills or None, header?)"""
    text(x0, ytop, title, 'cell', 'west')
    y = ytop - 0.20
    for lab, vals, fills, head in rows:
        text(x0 + labw - 0.08, y - rh / 2, lab, 'cell', 'east')
        for i, v in enumerate(vals):
            f = fills[i] if fills else ('black!8' if head else 'white')
            rect(x0 + labw + i * cw, y - rh, x0 + labw + (i + 1) * cw, y, f'tbl, fill={f}')
            text(x0 + labw + (i + 0.5) * cw, y - rh / 2, str(v), 'cellb' if head else 'cell')
        y -= rh
    rect(x0 + labw, y, x0 + labw + len(rows[0][1]) * cw, ytop - 0.20, 'tblthick')
    return y


RCOL = {1: 'cr1', 2: 'cr2', 3: 'cr3'}
yb_end = table(5.55, YB, 1.55, 0.40, 0.27,
               [(r'lane $i$', list(range(L)), None, True),
                (r'word $w_i$', WORDS, None, False),
                (r'round (\emph{par})', [rnd_of[i] for i in range(L)], [RCOL[rnd_of[i]] for i in range(L)], False),
                (r'returns $t5_i$', ret, None, False)],
               r'\textbf{The lanes}')
rows = [(r'word', [f'w{i}' for i in range(L)], None, True),
        ('after the read', [0] * L, None, False)]
touched = set()
for k, rnd in enumerate(ROUNDS):
    hit = {WORDS[i] for i in rnd}
    touched |= hit
    rows.append((f'round {k + 1}', after[k], [RCOL[k + 1] if w in hit else 'white' for w in range(L)], False))
rows.append(('write enables', [1 if w in touched else 0 for w in range(L)],
             ['cwrite' if w in touched else 'white' for w in range(L)], False))
x0b, labw, cwb, rhb = 11.15, 1.45, 0.40, 0.27
yl_end = table(x0b, YB, labw, cwb, rhb, rows, r'\textbf{The line buffer}, round by round (\emph{par})')
for k, rnd in enumerate(ROUNDS):
    yr = YB - 0.20 - (k + 2.5) * rhb
    text(x0b + labw + L * cwb + 0.10, yr, ('lanes ' if len(rnd) > 1 else 'lane ') + ', '.join(map(str, rnd)),
         'cell', 'west')
yr = YB - 0.20 - (len(ROUNDS) + 2.5) * rhb
text(x0b + labw + L * cwb + 0.10, yr, 'one write', 'cell', 'west')
yb_bot = min(yb_end, yl_end)
text(9.0, yb_bot - 0.30, r'(b) The example: one \texttt{amoadd.w} whose eight lanes fall in one line',
     'subcap')

# ================================================================= (c) timing on the RTL
C0, CB0, CB1 = 47, 53, 76                 # first cycle drawn; cycles CB0..CB1 are an axis break
C1 = max(t['resume'] for t in T.values()) + 1
TX0, TX1, BRK = 2.30, 17.85, 0.55
ncol = (CB0 - C0) + (C1 - CB1 - 1)
CW = (TX1 - TX0 - BRK) / ncol
XB0 = TX0 + (CB0 - C0) * CW                # the break, from XB0 to XB0 + BRK


def X(cyc):
    if cyc < CB0:
        return TX0 + (cyc - C0) * CW
    assert cyc > CB1, cyc
    return XB0 + BRK + (cyc - CB1 - 1) * CW


RH, SH = 0.27, 0.19
ytop = yb_bot - 0.95
issue = T['ser']['issue']
lineb = T['ser']['line_back']
assert all(t['issue'] == issue and t['line_back'] == lineb for t in T.values())
# common events, marked above the axis
for cyc, t, anc in ((issue, r'\texttt{amoadd.w} issues', 'south east'),
                    (lineb, r'the line returns', 'south west')):
    xm = X(cyc) + CW / 2
    emit(f'\\draw[evmark] {c(xm, ytop + 0.20)} -- {c(xm, ytop + 0.03)};')
    text(xm + 0.04, ytop + 0.20, t, 'notec', anc)
ynum = ytop - 0.10
for cyc in list(range(C0, CB0)) + list(range(CB1 + 1, C1)):
    if cyc % 5 == 0:
        text(X(cyc) + CW / 2, ynum, str(cyc), 'cyc')
text(TX0 - 0.10, ynum, 'cycle', 'cyc', 'east')

TITLE = {'lane': r'\textbf{One request per lane} (no aggregation)',
         'ser': r'\textbf{Serial} (\emph{ser}, the default)',
         'par': r'\textbf{Parallel} (\emph{par})'}
y = ynum - 0.04
grid = []
for run, short in VAR:
    t = T[short]
    nreq = len(t['req'])
    if short == 'lane':
        note = f'{nreq} requests; after the first read, every read hits in the L1'
    elif short == 'ser':
        note = f'{nreq} requests; {len(t["apply"])} apply cycles, one lane each'
    else:
        note = f'{nreq} requests; {len(t["apply"])} apply cycles, one round each'
    y -= 0.26
    yhead = y
    text(0.05, yhead, TITLE[short] + ': ' + note, 'cell', 'west')
    y -= 0.13
    yrt = y
    for key in ('req', 'apply', 'ack'):
        y -= RH
        ys = y + (RH - SH) / 2
        text(TX0 - 0.10, ys + SH / 2, key, 'sig', 'east')
        xr = X(t['resume'])
        emit(f'\\draw[wave] {c(TX0, ys + SH / 2)} -- {c(XB0, ys + SH / 2)};')
        emit(f'\\draw[wave] {c(XB0 + BRK, ys + SH / 2)} -- {c(xr, ys + SH / 2)};')
        if key == 'req':
            ev = {cy: (('chit' if v == 'R' and cy + 1 in t['hits'] else
                        'cread' if v == 'R' else 'cwrite'), v) for cy, v in t['req'].items()}
        elif key == 'apply':
            ev = {cy: ((RCOL[k + 1], str(k + 1)) if short == 'par' else ('cexe', str(v[0])))
                  for k, (cy, v) in enumerate(sorted(t['apply'].items()))}
        else:
            ev = {cy: ('cwrite', 'B') for cy in t['ack']}
        for cy, (fill, lab) in sorted(ev.items()):
            xa = X(cy)
            emit(f'\\draw[wave, fill={fill}] {c(xa, ys)} rectangle {c(xa + CW, ys + SH)};')
            text(xa + CW / 2, ys + SH / 2, lab, 'val')
    yrb = y
    for cyc in list(range(C0, CB0)) + list(range(CB1 + 1, t['resume'])):
        if cyc % 5 == 0:
            grid.append(f'\\draw[gridline] {c(X(cyc), yrt)} -- {c(X(cyc), yrb)};')
    for dx in (0.07, BRK - 0.07):
        emit(f'\\draw[brk] {c(XB0 + dx, yrb)} -- {c(XB0 + dx, yrt)};')
    # the warp resumes: the end of the AMO for the warp
    xr = X(t['resume'])
    emit(f'\\draw[endmark] {c(xr, yrb + (RH - SH) / 2 - 0.03)} -- {c(xr, yhead - 0.06)};')
    lab = f'warp resumes {t["resume"] - issue} cycles after the issue'
    if xr > 14.5:
        text(xr - 0.06, yhead, lab, 'notec', 'east')
    else:
        text(xr + 0.06, yhead, lab, 'notec', 'west')
ybot = y
emit(f'\\node[notec, align=center, anchor=north] at {c(XB0 + BRK / 2, ybot - 0.06)} '
     f'{{cycles {CB0} to {CB1}:\\\\line read from DDR4}};')
# key: one line, laid out by LaTeX
emit(f'\\node[cell, anchor=west] at {c(4.75, ybot - 0.28)} {{'
     r'\sw{cread} read request (R)\quad \sw{chit} read that hits in the L1\quad '
     r'\sw{cwrite} write request (W) and response (B)\quad '
     r'\sw{cexe} lane applied\quad '
     r'\sw{cr1}\,\sw{cr2}\,\sw{cr3} round 1, 2, 3};')
text(9.0, ybot - 0.75, r'(c) The example traced on the RTL in the three variants', 'subcap')
body[:0] = grid

TEMPLATE = r"""%% generated by gen_amo_fig.py -- do not edit by hand
\documentclass[10pt]{standalone}
\usepackage{helvet}
\renewcommand{\familydefault}{\sfdefault}
\usepackage{amsmath,amssymb}
\usepackage{tikz}
\usetikzlibrary{arrows.meta,automata}
\definecolor{cstage}{HTML}{FFF8E1}
\definecolor{cctrl}{HTML}{D6E0EC}
\definecolor{cctrlb}{HTML}{3B5675}
\definecolor{cexe}{HTML}{FFE699}
\definecolor{cexeb}{HTML}{7F6000}
\definecolor{cmask}{HTML}{D9EAD3}
\definecolor{cmem}{HTML}{F4CCCC}
\definecolor{cread}{HTML}{DDEBF7}
\definecolor{cwrite}{HTML}{FCE4D6}
\definecolor{chit}{HTML}{C6E0B4}
\definecolor{cr1}{HTML}{DCE6F5}
\definecolor{cr2}{HTML}{A9C0E6}
\definecolor{cr3}{HTML}{7397D4}
\newcommand{\fs}{\fontsize{6.4}{7.4}\selectfont}
\newcommand{\fss}{\fontsize{5.8}{6.6}\selectfont}
\newcommand{\fv}{\fontsize{5.0}{5.6}\selectfont}
\newcommand{\fvs}{\fontsize{4.6}{5.0}\selectfont}
\newcommand{\sw}[1]{\tikz[baseline=-0.55ex]\draw[draw=black, line width=0.4pt, fill=#1] (0,-0.085) rectangle (0.20,0.085);}
\begin{document}
\begin{tikzpicture}[x=1cm, y=1cm,
  base/.style={align=center, font=\fs, inner sep=1pt, line width=0.5pt},
  ctrl/.style={base, draw=cctrlb, fill=cctrl},
  exe/.style={base, draw=cexeb, fill=cexe},  exebox/.style={draw=cexeb, fill=cexe, line width=0.5pt},
  tbl/.style={draw=black!70, line width=0.35pt}, tblthick/.style={draw=black, line width=0.6pt},
  stagebox/.style={draw=black!45, dashed, fill=cstage, rounded corners=3pt, line width=0.5pt},
  stagetitle/.style={font=\fs, inner sep=0.5pt},
  tbltitle/.style={font=\fs, inner sep=0.5pt},
  cell/.style={font=\fss, inner sep=0.5pt},
  cellb/.style={font=\fss\bfseries, inner sep=0.5pt},
  codebox/.style={draw=black!60, fill=black!4, line width=0.4pt},
  code/.style={font=\fs\ttfamily, inner sep=0.5pt},
  fsm/.style={draw=cctrlb, fill=cctrl, rounded corners=5pt, font=\fss\bfseries, minimum width=0.95cm,
              minimum height=0.36cm, inner sep=1pt},
  lbl/.style={font=\fs, inner sep=0.5pt},
  wlabel/.style={font=\fss, inner sep=0.8pt},
  wlabelbg/.style={font=\fss, inner sep=1.2pt, fill=cstage},
  vlabel/.style={font=\fss, rotate=90, inner sep=0.5pt},
  vlabelr/.style={font=\fss, rotate=-90, inner sep=0.5pt},
  line/.style={line width=0.55pt},
  arr/.style={-{Latex[length=1.4mm, width=1.0mm]}, line width=0.55pt},
  wave/.style={draw=black, line width=0.4pt},
  gridline/.style={draw=black!12, line width=0.25pt},
  brk/.style={draw=black!55, line width=0.4pt, densely dashed},
  evmark/.style={draw=black!70, line width=0.4pt, -{Latex[length=1.1mm, width=0.8mm]}},
  endmark/.style={draw=black, line width=0.8pt},
  sig/.style={font=\fss\ttfamily, inner sep=0.5pt},
  cyc/.style={font=\fv, text=black!60, inner sep=0.5pt},
  val/.style={font=\fvs, inner sep=0pt},
  notec/.style={font=\fss\itshape, text=black!75, inner sep=0.5pt},
  subcap/.style={font=\fs, inner sep=1pt}]
%s
\end{tikzpicture}
\end{document}
"""


def main():
    tex = os.path.join(HERE, NAME + '.tex')
    with open(tex, 'w', encoding='utf-8', newline='\n') as f:
        f.write(TEMPLATE % '\n'.join(body))
    subprocess.run(['pdflatex', '-interaction=nonstopmode', NAME + '.tex'], cwd=HERE,
                   check=True, stdout=subprocess.DEVNULL)
    shutil.copyfile(os.path.join(HERE, NAME + '.pdf'), OUT_PDF)
    print('wrote', OUT_PDF)
    for run, short in VAR:
        t = T[short]
        print(f'  {short:4s} issue {t["issue"]} resume {t["resume"]} ({t["resume"] - t["issue"]} cycles) '
              f'{len(t["req"])} requests, {len(t["apply"])} apply cycles, {len(t["ack"])} write responses')
    print('  rounds', ROUNDS, 'returns', ret, 'line', after[-1])


if __name__ == '__main__':
    main()
