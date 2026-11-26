"""wavetikz.py - timing-diagram (waveform) primitives in TikZ, in the style of a logic analyser
or WaveDrom: a clock, one-bit signals and buses with crossing transitions.

All functions append TikZ commands to a list `o`. Time runs along x: cycle c spans
[x(c), x(c) + cw]; a signal row has its low level at y and its high level at y + h.
"""

SLOPE = 0.045                                   # half-width of a transition (cm)


def f(v):
    return "%.3f" % v


class Axis:
    """Maps cycles to x positions; `gaps` are (after_cycle, width_cm) axis breaks."""

    def __init__(self, x0, c0, c1, cw):
        self.x0, self.c0, self.c1, self.cw = x0, c0, c1, cw

    def x(self, c):
        return self.x0 + (c - self.c0) * self.cw

    @property
    def x_end(self):
        return self.x(self.c1 + 1)


def label(o, ax, y, h, name, font=r"\fss\ttfamily"):
    o.append(r"\node[anchor=east, font=%s, inner sep=0.5pt] at (%s,%s) {%s};"
             % (font, f(ax.x0 - 0.10), f(y + h / 2), name))


def clock(o, ax, y, h, style="wire"):
    """A clock whose rising edge starts every cycle."""
    pts = []
    for c in range(ax.c0, ax.c1 + 1):
        xa, xm = ax.x(c), ax.x(c) + ax.cw / 2
        pts += ["(%s,%s)" % (f(xa), f(y)), "(%s,%s)" % (f(xa), f(y + h)),
                "(%s,%s)" % (f(xm), f(y + h)), "(%s,%s)" % (f(xm), f(y))]
    pts.append("(%s,%s)" % (f(ax.x_end), f(y)))
    o.append(r"\draw[%s] %s;" % (style, " -- ".join(pts)))


def bit(o, ax, y, h, high, style="wire", fill=None):
    """A one-bit signal; `high` is the set of cycles in which it is 1."""
    s = min(SLOPE, ax.cw * 0.2)
    lvl = [1 if c in high else 0 for c in range(ax.c0, ax.c1 + 1)]
    pts = ["(%s,%s)" % (f(ax.x(ax.c0)), f(y + h * lvl[0]))]
    for i in range(1, len(lvl)):
        xb = ax.x(ax.c0 + i)
        if lvl[i] != lvl[i - 1]:
            pts += ["(%s,%s)" % (f(xb - s), f(y + h * lvl[i - 1])),
                    "(%s,%s)" % (f(xb + s), f(y + h * lvl[i]))]
    pts.append("(%s,%s)" % (f(ax.x_end), f(y + h * lvl[-1])))
    if fill:                                     # shade the high level
        for i, v in enumerate(lvl):
            if v:
                xa = ax.x(ax.c0 + i)
                o.append(r"\fill[%s] (%s,%s) rectangle (%s,%s);" % (fill, f(xa), f(y), f(xa + ax.cw), f(y + h)))
    o.append(r"\draw[%s] %s;" % (style, " -- ".join(pts)))


def segments(values, c0):
    """[(value, first cycle, last cycle)] runs of equal values; values[i] is cycle c0 + i."""
    out = []
    for i, v in enumerate(values):
        c = c0 + i
        if out and out[-1][0] == v:
            out[-1] = (v, out[-1][1], c)
        else:
            out.append((v, c, c))
    return out


def bus(o, ax, y, h, values, fills=None, text=None, style="wire", font=r"\fss", min_w=0.30,
        split=None):
    """A bus. values: one entry per cycle (None = no value: a mid-level line). fills(v) gives
    the fill of a value (a TikZ fill/pattern option string), text(v) its label. A new hexagon
    starts where the value changes, or where split(c) is true."""
    s = min(SLOPE, ax.cw * 0.2)
    fills = fills or (lambda v: "fill=white")
    text = text or (lambda v: str(v))
    vals = list(values)
    runs = []
    for i, v in enumerate(vals):
        c = ax.c0 + i
        if runs and runs[-1][0] == v and not (split and split(c)):
            runs[-1] = (v, runs[-1][1], c)
        else:
            runs.append((v, c, c))
    ym = y + h / 2
    for v, a, b in runs:
        xa, xb = ax.x(a), ax.x(b + 1)
        sa = 0 if a == ax.c0 else s                  # no slope at the window's edges
        sb = 0 if b == ax.c1 else s
        if v is None:
            o.append(r"\draw[%s] (%s,%s) -- (%s,%s);" % (style, f(xa + sa), f(ym), f(xb - sb), f(ym)))
            continue
        path = ("(%s,%s) -- (%s,%s) -- (%s,%s) -- (%s,%s) -- (%s,%s) -- (%s,%s) -- cycle"
                % (f(xa + sa), f(y + h), f(xb - sb), f(y + h), f(xb), f(ym),
                   f(xb - sb), f(y), f(xa + sa), f(y), f(xa), f(ym)))
        o.append(r"\draw[%s, %s] %s;" % (style, fills(v), path))
        t = text(v)
        if t and xb - xa >= min_w:
            bg = ", fill=white, inner sep=0.25pt" if "pattern" in fills(v) else ", inner sep=0pt"
            o.append(r"\node[font=%s%s] at (%s,%s) {%s};" % (font, bg, f((xa + xb) / 2), f(ym), t))


def grid(o, ax, y0, y1, every=1, style="gridline"):
    for c in range(ax.c0, ax.c1 + 2, every):
        o.append(r"\draw[%s] (%s,%s) -- (%s,%s);" % (style, f(ax.x(c)), f(y0), f(ax.x(c)), f(y1)))
