"""
dp_engine.py -- a small, verified schematic engine that emits TikZ.

Every shape is a polygon in millimetres (origin bottom-left, y up). Wires are
orthogonal polylines grouped into nets. verify() rejects the layout if:
  * a wire passes through the interior of any shape (or grazes an edge),
  * two different nets run collinear / closer than MIN_PAR mm in parallel,
  * a wire of one net ends on (touches) a wire of another net,
  * a label overlaps a shape, another label, or any wire,
  * two shapes overlap.
Perpendicular crossings between different nets are allowed; they are drawn
with a small hop on the horizontal wire so a crossing never reads as a joint.
Junction dots are drawn automatically where a branch leaves its own net.

compact(axis, gap) squeezes every empty corridor (no shape, label or
perpendicular wire inside it) down to `gap` mm -- layout compaction -- so the
figure can be authored with generous coordinates and tightened afterwards.
All geometry is stored as data and only turned into TikZ at emit().
"""
import math
import re

MIN_PAR = 1.6      # min spacing between parallel wires of different nets (mm)
CLEAR = 0.6        # min clearance of a wire from a shape it does not attach to
HOP_R = 0.85       # crossing hop radius (mm)
TOK = re.compile(r'«(\d+)»')


def plain(s):
    s = re.sub(r'\\fontsize\{[^}]*\}\{[^}]*\}\\selectfont', '', s)
    s = re.sub(r'\\(tiny|scriptsize|footnotesize|small|bfseries|itshape|mathrm|textit|textbf|texttt|mathit|overline)\b', '', s)
    s = re.sub(r'\\(times|ne|neq|ge|le|gets|to|sim|cdot|ll|gg|lnot|land|lor|oplus|pm|ell|rightarrow|leftarrow)\b', 'x', s)
    s = re.sub(r'\\[a-zA-Z]+', '', s)
    s = re.sub(r'\[[-0-9.]+pt\]', '', s)
    s = re.sub(r'[{}$^_\\]', '', s)
    return s


def text_wh(text, pt):
    """Rough bbox of a (possibly multi-line) label. Deliberately generous."""
    lines = [l for l in text.split(r'\\')]
    cw = 0.20 * pt      # mm per char (sans)
    lh = 0.42 * pt      # mm per line
    w = max(len(plain(l)) for l in lines) * cw
    return w, len(lines) * lh


# ----------------------------------------------------------------------------- geometry
def pip(pt, poly):
    x, y = pt
    inside = False
    n = len(poly)
    for i in range(n):
        x1, y1 = poly[i]
        x2, y2 = poly[(i + 1) % n]
        if (y1 > y) != (y2 > y):
            xi = x1 + (y - y1) * (x2 - x1) / (y2 - y1)
            if xi > x:
                inside = not inside
    return inside


def dist_seg(p, a, b):
    (px, py), (ax, ay), (bx, by) = p, a, b
    dx, dy = bx - ax, by - ay
    L = dx * dx + dy * dy
    t = 0 if L == 0 else max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / L))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def dist_poly_edge(p, poly):
    return min(dist_seg(p, poly[i], poly[(i + 1) % len(poly)]) for i in range(len(poly)))


def rect_poly(x, y, w, h):
    return [(x, y), (x + w, y), (x + w, y + h), (x, y + h)]


def fmt(v):
    s = f"{v:.2f}".rstrip('0').rstrip('.')
    return '0' if s in ('-0', '') else s


def P(p):
    return f"({fmt(p[0])},{fmt(p[1])})"


def seg_hits_box(a, b, bb):
    x0, y0, x1, y1 = bb
    if abs(a[1] - b[1]) < 1e-6:
        y = a[1]
        return y0 < y < y1 and min(a[0], b[0]) < x1 and max(a[0], b[0]) > x0
    x = a[0]
    return x0 < x < x1 and min(a[1], b[1]) < y1 and max(a[1], b[1]) > y0


# ----------------------------------------------------------------------------- shapes
class Shape:
    def __init__(self, name, kind):
        self.name, self.kind = name, kind
        self.poly = []
        self.extra_polys = []   # decorations that labels must also avoid
        self.pts = []           # every coordinate referenced by the TikZ ops
        self.ops = []           # TikZ strings with «k» placeholders

    def tok(self, p):
        self.pts.append((float(p[0]), float(p[1])))
        return f"«{len(self.pts) - 1}»"

    def set_poly(self, poly):
        self.poly = [(float(a), float(b)) for a, b in poly]
        self._bb()

    def _bb(self):
        xs = [p[0] for p in self.poly]
        ys = [p[1] for p in self.poly]
        self.x0, self.x1, self.y0, self.y1 = min(xs), max(xs), min(ys), max(ys)

    def L(self, y):
        return (self.x0, y)

    def R(self, y):
        return (self.x1, y)

    def T(self, x):
        return (x, self.y1)

    def B(self, x):
        return (x, self.y0)

    def tikz(self):
        return [TOK.sub(lambda m: P(self.pts[int(m.group(1))]), op) for op in self.ops]


FILLS = {'mem': 'memfill', 'alu': 'alufill', 'ctl': 'ctlfill', 'reg': 'regfill',
         'ext': 'extfill', 'mux': 'muxfill', 'gate': 'white'}


def fsz(pt, lead=1.18):
    return rf'\fontsize{{{pt}}}{{{pt * lead:.1f}}}\selectfont'


class Fig:
    def __init__(self):
        self.shapes = {}
        self.nets = {}
        self.labels = []
        self.bands = []      # (x0, y0, x1, y1, title) background panels, drawn first
        self.frames = []     # (x0, y0, x1, y1) white framed panels, drawn after bands
        self.rules = []      # extra free-standing TikZ with «» points: (ops, pts)
        self.warn = []

    def _add(self, s):
        assert s.name not in self.shapes, s.name
        self.shapes[s.name] = s
        return s

    # ---------------------------------------------------------------- primitives
    def box(self, name, x, y, w, h, text, kind='ctl', pt=7, rep=False, bold_first=True, rot=False):
        s = Shape(name, kind)
        s.set_poly(rect_poly(x, y, w, h))
        fill = FILLS[kind]
        if rep:
            for k in (2, 1):
                d = 0.9 * k
                s.ops.append(rf"\draw[blk,fill={fill}] {s.tok((x + d, y + d))} rectangle {s.tok((x + w + d, y + h + d))};")
            s.extra_polys.append(rect_poly(x, y, w + 1.8, h + 1.8))
        s.ops.append(rf"\draw[blk,fill={fill}] {s.tok((x, y))} rectangle {s.tok((x + w, y + h))};")
        if text:
            lines = text.split(r'\\')
            if bold_first:
                lines[0] = r'\textbf{' + lines[0] + '}'
            body = r'\\'.join(lines)
            r = 'rotate=90,' if rot else ''
            s.ops.append(rf"\node[{r}align=center,inner sep=0,font={fsz(pt)}] at {s.tok((x + w / 2, y + h / 2))} {{{body}}};")
            tw, th = text_wh(text, pt)
            if rot:
                tw, th = th, tw
            if tw > w - 0.8 or th > h - 0.6:
                self.warn.append(f"text may overflow box {name}: {tw:.1f}x{th:.1f} in {w}x{h}")
        return self._add(s)

    def reg(self, name, x, y, w, h, text='', pt=6, rot=False):
        """Clocked register: grey fill + clock triangle on the bottom edge."""
        s = Shape(name, 'reg')
        s.set_poly(rect_poly(x, y, w, h))
        s.ops.append(rf"\draw[blk,fill=regfill] {s.tok((x, y))} rectangle {s.tok((x + w, y + h))};")
        cw = min(2.2, w * 0.55)
        s.ops.append(rf"\draw[line width=0.4pt] {s.tok((x + w / 2 - cw / 2, y))} -- {s.tok((x + w / 2, y + cw * 0.8))} -- {s.tok((x + w / 2 + cw / 2, y))};")
        if text:
            r = 'rotate=90,' if rot else ''
            s.ops.append(rf"\node[{r}align=center,inner sep=0,font={fsz(pt, 1.1)}] at {s.tok((x + w / 2, y + h / 2 + 0.6))} {{{text}}};")
        return self._add(s)

    def mux(self, name, x, ys, w=5.0, pad=2.6, sel='bot', ins=None, pt=5):
        """Trapezoid multiplexer pointing right. ys = input y's (top->bottom)."""
        ys = list(ys)
        y1, y0 = max(ys) + pad, min(ys) - pad
        d = min(2.0, (y1 - y0) * 0.2)
        poly = [(x, y0), (x + w, y0 + d), (x + w, y1 - d), (x, y1)]
        s = Shape(name, 'mux')
        s.set_poly(poly)
        s.ops.append(r"\draw[blk,fill=muxfill] " + ' -- '.join(s.tok(p) for p in poly) + " -- cycle;")
        s.inp = [(x, yy) for yy in ys]
        s.out = (x + w, (y0 + y1) / 2)
        s.selpt = (x + w / 2, y0 + d / 2) if sel == 'bot' else (x + w / 2, y1 - d / 2)
        if ins is None:
            ins = [str(i) for i in range(len(ys))]
        for yy, tx in zip(ys, ins):
            if tx:
                s.ops.append(rf"\node[anchor=west,inner sep=0.4pt,font={fsz(pt, 1)}] at {s.tok((x + 0.1, yy))} {{{tx}}};")
        return self._add(s)

    def alu(self, name, x, ya, yb, w, text, pt=7, kind='alu', rep=False, fa=0.84):
        """Classic notched ALU placed by its two input y's. Ports: .a, .b, .out."""
        fb = 1 - fa
        h = (ya - yb) / (fa - fb)
        y = yb - fb * h
        k = h * 0.24
        n = h * 0.09
        ym = y + h / 2
        poly = [(x, y), (x + w, y + k), (x + w, y + h - k), (x, y + h),
                (x, ym + n), (x + n * 1.1, ym), (x, ym - n)]
        s = Shape(name, kind)
        s.set_poly(poly)
        fill = FILLS[kind]
        if rep:
            for kk in (2, 1):
                dd = 0.9 * kk
                s.ops.append(rf"\draw[blk,fill={fill}] " + ' -- '.join(s.tok((px + dd, py + dd)) for px, py in poly) + " -- cycle;")
            s.extra_polys.append([(px + 1.8, py + 1.8) for px, py in poly])
        s.ops.append(rf"\draw[blk,fill={fill}] " + ' -- '.join(s.tok(p) for p in poly) + " -- cycle;")
        s.ops.append(rf"\node[align=center,inner sep=0,font={fsz(pt)}] at {s.tok((x + w * 0.56, ym))} {{{text}}};")
        s.a, s.b, s.out = (x, y + h * fa), (x, y + h * fb), (x + w, ym)
        return self._add(s)

    def circ(self, name, cx, cy, r, text, pt=6.5, kind='alu'):
        s = Shape(name, kind)
        s.set_poly([(cx + r * math.cos(k * math.pi / 8), cy + r * math.sin(k * math.pi / 8)) for k in range(16)])
        s.ops.append(rf"\draw[blk,fill={FILLS[kind]}] {s.tok((cx, cy))} circle ({fmt(r)});")
        s.ops.append(rf"\node[inner sep=0,font={fsz(pt, 1)}] at {s.tok((cx, cy))} {{{text}}};")
        s.Lp, s.Rp, s.Tp, s.Bp = (cx - r, cy), (cx + r, cy), (cx, cy + r), (cx, cy - r)
        return self._add(s)

    def gate(self, name, typ, x, ys, w=6.0, pad=1.6, neg_in=(), lbl=None, pt=5):
        """Logic gate pointing right. typ in {'and','or','not'}. ys = input y's."""
        ys = list(ys)
        y1, y0 = max(ys) + pad, min(ys) - pad
        h = y1 - y0
        yc = (y0 + y1) / 2
        bub = 0.7
        s = Shape(name, 'gate')
        T = s.tok
        if typ == 'and':
            xa = x + w - h / 2
            pts = [(x, y0), (xa, y0)]
            for i in range(1, 16):
                a = -math.pi / 2 + math.pi * i / 16
                pts.append((xa + (h / 2) * math.cos(a), yc + (h / 2) * math.sin(a)))
            pts += [(xa, y1), (x, y1)]
            path = rf"{T((x, y0))} -- {T((xa, y0))} arc (-90:90:{fmt(h / 2)}) -- {T((x, y1))} -- cycle"
        elif typ == 'or':
            bk = h * 0.2
            pts = [(x, y0)]
            pts += [(x + w * 0.45 + w * 0.55 * math.sin(math.pi / 2 * i / 8),
                     y0 + (h / 2) * (1 - math.cos(math.pi / 2 * i / 8))) for i in range(9)]
            pts += [(x + w * 0.45 + w * 0.55 * math.sin(math.pi / 2 * (8 - i) / 8),
                     y1 - (h / 2) * (1 - math.cos(math.pi / 2 * (8 - i) / 8))) for i in range(9)]
            pts += [(x, y1), (x + bk, yc)]
            path = (rf"{T((x, y1))} .. controls {T((x + w * 0.75, y1))} and {T((x + w * 0.95, yc + h * 0.15))} .. {T((x + w, yc))}"
                    rf" .. controls {T((x + w * 0.95, yc - h * 0.15))} and {T((x + w * 0.75, y0))} .. {T((x, y0))}"
                    rf" .. controls {T((x + bk * 1.3, yc - h * 0.2))} and {T((x + bk * 1.3, yc + h * 0.2))} .. {T((x, y1))} -- cycle")
        elif typ == 'not':
            tw = w - 2 * bub
            pts = [(x, y0), (x + tw, yc), (x, y1)]
            path = rf"{T((x, y0))} -- {T((x + tw, yc))} -- {T((x, y1))} -- cycle"
        else:
            raise ValueError(typ)
        s.set_poly(pts)
        s.ops.append(rf"\draw[blk,fill=white] {path};")
        if typ == 'not':
            s.ops.append(rf"\draw[blk,fill=white] {T((x + w - bub, yc))} circle ({fmt(bub)});")
        s.inp = []
        for i, yy in enumerate(ys):
            if i in neg_in:
                s.ops.append(rf"\draw[blk,fill=white] {T((x - bub, yy))} circle ({fmt(bub)});")
                s.inp.append((x - 2 * bub, yy))
            elif typ == 'or':
                s.inp.append((x + h * 0.2 * 0.75, yy))
            else:
                s.inp.append((x, yy))
        s.out = (x + w, yc)
        if lbl:
            s.ops.append(rf"\node[inner sep=0,font={fsz(pt, 1)}] at {T((x + w * 0.42, yc))} {{{lbl}}};")
        return self._add(s)

    def bar(self, name, x, y, w, h, text='', pt=6.5, lbl_below=False):
        """Tall pipeline register."""
        s = Shape(name, 'reg')
        s.set_poly(rect_poly(x, y, w, h))
        s.ops.append(rf"\draw[blk,fill=regfill] {s.tok((x, y))} rectangle {s.tok((x + w, y + h))};")
        s.ops.append(rf"\draw[line width=0.4pt] {s.tok((x + 0.3, y))} -- {s.tok((x + w / 2, y + 1.8))} -- {s.tok((x + w - 0.3, y))};")
        if text:
            if lbl_below:
                s.ops.append(rf"\node[font={fsz(pt, 1)}\bfseries,anchor=north] at {s.tok((x + w / 2, y - 0.6))} {{{text}}};")
                s.extra_polys.append(rect_poly(x + w / 2 - 3, y - 3.6, 6, 3.0))
            else:
                s.ops.append(rf"\node[font={fsz(pt, 1)}\bfseries,anchor=south] at {s.tok((x + w / 2, y + h + 0.6))} {{{text}}};")
                s.extra_polys.append(rect_poly(x + w / 2 - 3, y + h + 0.6, 6, 3.0))
        return self._add(s)

    # ---------------------------------------------------------------- wires, labels
    def wire(self, net, pts, style='sig', arrow=True):
        """Add one orthogonal polyline to net `net`. style: sig|bus|ctl."""
        q = [tuple(map(float, pts[0]))]
        for p in pts[1:]:
            p = tuple(map(float, p))
            if abs(p[0] - q[-1][0]) > 1e-6 or abs(p[1] - q[-1][1]) > 1e-6:
                q.append(p)
        # snap sub-0.05 mm jitter produced by float port positions
        for k in range(1, len(q)):
            a, b = q[k - 1], q[k]
            if abs(a[0] - b[0]) < 0.05 and a[0] != b[0]:
                if k == len(q) - 1:
                    q[k - 1] = (b[0], a[1])
                else:
                    q[k] = (a[0], b[1])
            elif abs(a[1] - b[1]) < 0.05 and a[1] != b[1]:
                if k == len(q) - 1:
                    q[k - 1] = (a[0], b[1])
                else:
                    q[k] = (b[0], a[1])
        for a, b in zip(q, q[1:]):
            if abs(a[0] - b[0]) > 1e-6 and abs(a[1] - b[1]) > 1e-6:
                raise ValueError(f"net {net}: non-orthogonal segment {a}->{b}")
        n = self.nets.setdefault(net, {'lines': [], 'style': style})
        n['lines'].append({'pts': q, 'arrow': arrow})
        return q

    def label(self, text, x, y, anchor='south', pt=6, color=None, italic=False, bold=False):
        self.labels.append(dict(text=text, x=float(x), y=float(y), anchor=anchor, pt=pt,
                                color=color, italic=italic, bold=bold))

    def stub(self, net, p, direction, length, text, pt=5, style='ctl', arrow=True):
        """A labelled control stub arriving at point p from `direction`
        ('down' = from below, 'up' = from above, 'left', 'right')."""
        x, y = p
        dx, dy = {'down': (0, -1), 'up': (0, 1), 'left': (-1, 0), 'right': (1, 0)}[direction]
        far = (x + dx * length, y + dy * length)
        self.wire(net, [far, p], style=style, arrow=arrow)
        anchor = {'down': 'north', 'up': 'south', 'left': 'east', 'right': 'west'}[direction]
        self.label(text, far[0] + dx * 0.3, far[1] + dy * 0.3, anchor=anchor, pt=pt)

    # ---------------------------------------------------------------- analysis
    def segments(self):
        out = []
        for name, n in self.nets.items():
            for li, line in enumerate(n['lines']):
                pts = line['pts']
                for i, (a, b) in enumerate(zip(pts, pts[1:])):
                    out.append((name, li, i, a, b))
        return out

    def label_bbox(self, L):
        w, h = text_wh(L['text'], L['pt'])
        w += 0.5
        h += 0.3
        x, y, a = L['x'], L['y'], L['anchor']
        cx, cy = x, y
        if 'south' in a:
            cy = y + h / 2
        if 'north' in a:
            cy = y - h / 2
        if a.endswith('west'):
            cx = x + w / 2
        if a.endswith('east'):
            cx = x - w / 2
        return (cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2)

    def verify(self):
        errs = []
        segs = self.segments()
        shapes = list(self.shapes.values())

        for i, s in enumerate(shapes):
            for t in shapes[i + 1:]:
                if s.x0 < t.x1 - 0.05 and t.x0 < s.x1 - 0.05 and s.y0 < t.y1 - 0.05 and t.y0 < s.y1 - 0.05:
                    errs.append(f"SHAPE OVERLAP {s.name} / {t.name}")

        for (net, li, i, a, b) in segs:
            L = math.hypot(b[0] - a[0], b[1] - a[1])
            nsteps = max(2, int(L / 0.2))
            for s in shapes:
                if max(a[0], b[0]) < s.x0 - 1.5 or min(a[0], b[0]) > s.x1 + 1.5 or \
                   max(a[1], b[1]) < s.y0 - 1.5 or min(a[1], b[1]) > s.y1 + 1.5:
                    continue
                bad = None
                for k in range(nsteps + 1):
                    tt = k / nsteps
                    p = (a[0] + (b[0] - a[0]) * tt, a[1] + (b[1] - a[1]) * tt)
                    de = min(tt, 1 - tt) * L
                    inside = pip(p, s.poly)
                    d = dist_poly_edge(p, s.poly)
                    if inside and d > 0.15:
                        bad = 'through'
                        break
                    if de > 1.0 and d < CLEAR and not inside and bad is None:
                        bad = 'grazes'
                if bad:
                    errs.append(f"WIRE {bad.upper()} SHAPE: net {net} {a}->{b} / {s.name}")

        for x1 in range(len(segs)):
            n1, _, _, a1, b1 = segs[x1]
            h1 = abs(a1[1] - b1[1]) < 1e-6
            for x2 in range(x1 + 1, len(segs)):
                n2, _, _, a2, b2 = segs[x2]
                if n1 == n2:
                    continue
                h2 = abs(a2[1] - b2[1]) < 1e-6
                if h1 and h2:
                    lo = max(min(a1[0], b1[0]), min(a2[0], b2[0]))
                    hi = min(max(a1[0], b1[0]), max(a2[0], b2[0]))
                    if hi - lo > 0.05 and abs(a1[1] - a2[1]) < MIN_PAR:
                        errs.append(f"PARALLEL H {n1} / {n2} at y={a1[1]:.1f}/{a2[1]:.1f} x[{lo:.1f},{hi:.1f}]")
                elif (not h1) and (not h2):
                    lo = max(min(a1[1], b1[1]), min(a2[1], b2[1]))
                    hi = min(max(a1[1], b1[1]), max(a2[1], b2[1]))
                    if hi - lo > 0.05 and abs(a1[0] - a2[0]) < MIN_PAR:
                        errs.append(f"PARALLEL V {n1} / {n2} at x={a1[0]:.1f}/{a2[0]:.1f} y[{lo:.1f},{hi:.1f}]")
                for p in (a1, b1):
                    if dist_seg(p, a2, b2) < 0.6:
                        errs.append(f"TOUCH {n1} end {p} on {n2}")
                for p in (a2, b2):
                    if dist_seg(p, a1, b1) < 0.6:
                        errs.append(f"TOUCH {n2} end {p} on {n1}")

        boxes = [self.label_bbox(L) for L in self.labels]
        for L, bb in zip(self.labels, boxes):
            for s in shapes:
                for pol in [s.poly] + s.extra_polys:
                    xs = [p[0] for p in pol]
                    ys = [p[1] for p in pol]
                    if bb[0] < max(xs) and min(xs) < bb[2] and bb[1] < max(ys) and min(ys) < bb[3]:
                        hit = any(pip((bb[0] + (bb[2] - bb[0]) * u / 8, bb[1] + (bb[3] - bb[1]) * v / 4), pol)
                                  for u in range(9) for v in range(5))
                        if hit:
                            errs.append(f"LABEL '{L['text']}' overlaps shape {s.name}")
                            break
            for (net, li, i, a, b) in segs:
                if seg_hits_box(a, b, bb):
                    errs.append(f"LABEL '{L['text']}' overlaps wire {net}")
        for i in range(len(boxes)):
            for j in range(i + 1, len(boxes)):
                a, b = boxes[i], boxes[j]
                if a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]:
                    errs.append(f"LABEL overlap '{self.labels[i]['text']}' / '{self.labels[j]['text']}'")
        # hops need room: a crossing must not sit within a hop of a bend/junction/end
        for (x, y, nh, nv) in self.crossings():
            for (n, li, i, a, b) in segs:
                if n == nh and abs(a[1] - b[1]) < 1e-6 and abs(a[1] - y) < 1e-6 and min(a[0], b[0]) <= x <= max(a[0], b[0]):
                    if min(abs(x - a[0]), abs(x - b[0])) < HOP_R + 0.4:
                        errs.append(f"HOP too close to a corner: {nh} x {nv} at ({x:.1f},{y:.1f})")
        return errs

    def crossings(self):
        segs = self.segments()
        H = [(n, a, b) for (n, _, _, a, b) in segs if abs(a[1] - b[1]) < 1e-6]
        V = [(n, a, b) for (n, _, _, a, b) in segs if abs(a[0] - b[0]) < 1e-6]
        out = []
        for (nh, a, b) in H:
            y = a[1]
            xl, xr = sorted((a[0], b[0]))
            for (nv, c, d) in V:
                if nv == nh:
                    continue
                x = c[0]
                yl, yh = sorted((c[1], d[1]))
                if xl + 0.3 < x < xr - 0.3 and yl + 0.3 < y < yh - 0.3:
                    out.append((x, y, nh, nv))
        return out

    # ---------------------------------------------------------------- compaction
    def _map_all(self, fx, fy):
        for s in self.shapes.values():
            s.pts = [(fx(x), fy(y)) for x, y in s.pts]
            s.poly = [(fx(x), fy(y)) for x, y in s.poly]
            s.extra_polys = [[(fx(x), fy(y)) for x, y in pol] for pol in s.extra_polys]
            s._bb()
        for n in self.nets.values():
            for line in n['lines']:
                line['pts'] = [(fx(x), fy(y)) for x, y in line['pts']]
        for L in self.labels:
            L['x'], L['y'] = fx(L['x']), fy(L['y'])
        self.bands = [(fx(a), fy(b), fx(c), fy(d), tt) for a, b, c, d, tt in self.bands]

    def shift(self, v_from, dv, axis='x'):
        """Move every coordinate >= v_from by dv along axis (a cut at v_from).
        The caller guarantees the band [v_from + dv, v_from) is empty."""
        m = lambda v: v + dv if v >= v_from - 1e-9 else v
        ident = lambda v: v
        if axis == 'x':
            self._map_all(m, ident)
        else:
            self._map_all(ident, m)

    def compact(self, axis, gap, keep=()):
        """Shrink every empty corridor along `axis` ('x' or 'y') to `gap` mm.
        keep = list of (lo, hi) coordinate ranges whose gaps are left alone."""
        iv = []
        for s in self.shapes.values():
            for pol in [s.poly] + s.extra_polys:
                vals = [p[0] if axis == 'x' else p[1] for p in pol]
                iv.append((min(vals), max(vals)))
        for L in self.labels:
            bb = self.label_bbox(L)
            iv.append((bb[0], bb[2]) if axis == 'x' else (bb[1], bb[3]))
        for (n, li, i, a, b) in self.segments():
            perp = abs(a[0] - b[0]) < 1e-6 if axis == 'x' else abs(a[1] - b[1]) < 1e-6
            if perp:
                v = a[0] if axis == 'x' else a[1]
                iv.append((v - 0.01, v + 0.01))
        iv.sort()
        merged = []
        for lo, hi in iv:
            if merged and lo <= merged[-1][1] + 1e-6:
                merged[-1][1] = max(merged[-1][1], hi)
            else:
                merged.append([lo, hi])
        cuts = []   # (position, amount removed)
        for (a, b), (c, d) in zip(merged, merged[1:]):
            g = c - b
            if g > gap and not any(lo <= b and c <= hi for lo, hi in keep):
                cuts.append((b + gap, g - gap))

        def m(v):
            return v - sum(amt for pos, amt in cuts if v >= pos + 1e-9)
        ident = lambda v: v
        if axis == 'x':
            self._map_all(m, ident)
        else:
            self._map_all(ident, m)
        return sum(a for _, a in cuts)

    def extent(self):
        xs, ys = [], []
        for s in self.shapes.values():
            for pol in [s.poly] + s.extra_polys:
                xs += [p[0] for p in pol]
                ys += [p[1] for p in pol]
        for L in self.labels:
            bb = self.label_bbox(L)
            xs += [bb[0], bb[2]]
            ys += [bb[1], bb[3]]
        for (n, li, i, a, b) in self.segments():
            xs += [a[0], b[0]]
            ys += [a[1], b[1]]
        return min(xs), min(ys), max(xs), max(ys)

    # ---------------------------------------------------------------- emit
    def junctions(self, net):
        lines = self.nets[net]['lines']
        dots = []
        for i, line in enumerate(lines):
            for p in (line['pts'][0],):
                for j, other in enumerate(lines):
                    if j == i:
                        continue
                    q = other['pts']
                    if any(dist_seg(p, u, v) < 0.05 for u, v in zip(q, q[1:])):
                        if math.hypot(p[0] - q[-1][0], p[1] - q[-1][1]) > 0.05:
                            dots.append(p)
                        break
        out = []
        for d in dots:
            if all(math.hypot(d[0] - e[0], d[1] - e[1]) > 0.05 for e in out):
                out.append(d)
        return out

    def emit(self, path, extra_top=None):
        cross = self.crossings()
        hops = {}
        for (x, y, nh, nv) in cross:
            hops.setdefault((nh, round(y, 3)), []).append(x)
        o = [r"\documentclass[border=1.5mm]{standalone}",
             r"\usepackage[T1]{fontenc}", r"\usepackage{helvet}",
             r"\renewcommand{\familydefault}{\sfdefault}",
             r"\usepackage{amsmath,amssymb}", r"\usepackage{sansmath}",
             r"\usepackage{tikz}", r"\usetikzlibrary{arrows.meta}",
             r"\definecolor{memfill}{HTML}{DCE8F4}", r"\definecolor{alufill}{HTML}{FBE3CD}",
             r"\definecolor{ctlfill}{HTML}{E4EFD6}", r"\definecolor{regfill}{HTML}{CFCFCF}",
             r"\definecolor{extfill}{HTML}{ECE6F4}", r"\definecolor{muxfill}{HTML}{F3F3F3}",
             r"\definecolor{ctlwire}{HTML}{4A4A4A}", r"\definecolor{bandfill}{HTML}{F7F7F7}",
             r"\definecolor{bandline}{HTML}{B0B0B0}",
             r"\begin{document}\sansmath",
             r"\begin{tikzpicture}[x=1mm,y=1mm,line cap=butt,line join=miter,",
             r"  blk/.style={line width=0.55pt,draw=black},",
             r"  sig/.style={line width=0.5pt,draw=black},",
             r"  bus/.style={line width=1.15pt,draw=black},",
             r"  wide/.style={line width=2.2pt,draw=black!80},",
             r"  ctl/.style={line width=0.45pt,draw=ctlwire,dash pattern=on 1.6pt off 1.0pt},",
             r"  arr/.style={-{Stealth[length=1.8mm,width=1.45mm]}},",
             r"  arrb/.style={-{Stealth[length=2.3mm,width=2.0mm]}},",
             r"]"]
        for (x0, y0, x1, y1, tt) in self.bands:
            o.append(rf"\fill[bandfill] {P((x0, y0))} rectangle {P((x1, y1))};")
            o.append(rf"\draw[bandline,line width=0.4pt,dash pattern=on 2pt off 1.5pt] {P((x0, y0))} rectangle {P((x1, y1))};")
            if tt:
                o.append(rf"\node[anchor=north west,inner sep=1.2pt,font={fsz(6.5, 1)}\bfseries,text=black!70] at {P((x0 + 0.6, y1 - 0.5))} {{{tt}}};")
        for (x0, y0, x1, y1) in self.frames:
            o.append(rf"\draw[line width=0.5pt,draw=black!60,fill=white] {P((x0, y0))} rectangle {P((x1, y1))};")
        for s in self.shapes.values():
            o += s.tikz()
        for name, n in self.nets.items():
            st = n['style']
            for line in n['lines']:
                pts = line['pts']
                parts = [P(pts[0])]
                for a, b in zip(pts, pts[1:]):
                    if abs(a[1] - b[1]) < 1e-6 and (name, round(a[1], 3)) in hops:
                        xs = sorted(x for x in hops[(name, round(a[1], 3))]
                                    if min(a[0], b[0]) + 0.3 < x < max(a[0], b[0]) - 0.3)
                        if b[0] < a[0]:
                            xs = xs[::-1]
                        for x in xs:
                            if b[0] > a[0]:
                                parts.append(f"-- {P((x - HOP_R, a[1]))} arc (180:0:{fmt(HOP_R)})")
                            else:
                                parts.append(f"-- {P((x + HOP_R, a[1]))} arc (0:180:{fmt(HOP_R)})")
                    parts.append(f"-- {P(b)}")
                opt = st
                if line['arrow']:
                    opt += ',arrb' if st in ('bus', 'wide') else ',arr'
                o.append(rf"\draw[{opt}] " + ' '.join(parts) + ";")
            for d in self.junctions(name):
                r = 0.8 if st == 'bus' else 0.55
                col = 'ctlwire' if st == 'ctl' else 'black'
                o.append(rf"\fill[{col}] {P(d)} circle ({fmt(r)});")
        for L in self.labels:
            fs = fsz(L['pt'], 1.15)
            if L['italic']:
                fs += r'\itshape'
            if L['bold']:
                fs += r'\bfseries'
            col = f",text={L['color']}" if L['color'] else ''
            o.append(rf"\node[anchor={L['anchor']},inner sep=0.4pt,align=center,font={fs}{col}] at {P((L['x'], L['y']))} {{{L['text']}}};")
        if extra_top:
            o += extra_top
        o += [r"\end{tikzpicture}", r"\end{document}"]
        with open(path, 'w', encoding='utf-8') as fh:
            fh.write('\n'.join(o) + '\n')
        return cross
