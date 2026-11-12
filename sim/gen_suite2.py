"""
gen_suite2.py -- inputs and bit-exact expected outputs of suite 2 (docs/suite2_plan.md:
Rodinia, RiVEC, GAP, SHOC and PolyBench kernels) for tests/tb_apps.sv.

    python sim/gen_suite2.py [--size small|board|dram] [--out DIR] [--only APP ...]

The machinery is gen_apps.py's (Image, Case, the exactly rounded FP32 operations,
the manifest); the kernels are kernels/suite2/<name>.hex, packed into the instruction
RAM from slot 0 (gen_apps.place_kernels with suite 2's kernel list). Default output
directory: build_suite2/.
"""
import argparse
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_apps as ga                                    # noqa: E402
import struct
from fractions import Fraction
from gen_apps import Case, fma, fadd, fmul             # noqa: E402

KDIR = os.path.join(ga.ROOT, 'kernels', 'suite2')
KERNELS = ['pathfinder', 'hotspot', 'jacobi2d', 'mv_row', 'mv_col', 'pr_contrib', 'pr_pull', 'cc_step', 'bp_forward', 'bp_adjust',
           'rs_hist', 'rs_scan', 'rs_scatter', 'blackscholes']
INF = 0x7FFF_FFFF


def s32(x):
    x &= 0xFFFF_FFFF
    return x - (1 << 32) if x & 0x8000_0000 else x


# ── Rodinia pathfinder ───────────────────────────────────────────────────────────
def pathfinder(rng, rows, cols):
    """pathfinder.S: dst[c] = wall[r][c] + min(src[c-1], src[c], src[c+1]); the rows
    are padded with one INT_MAX word on each side, so the edges need no test."""
    c = Case(f'pathfinder_{rows}x{cols}')
    wall = [[rng.randrange(10) for _ in range(cols)] for _ in range(rows)]
    pw = c.img.alloc(rows * cols, [v for row in wall for v in row])
    bufs = [c.img.alloc(cols + 2, [INF] + wall[0] + [INF]), c.img.alloc(cols + 2, [INF] + [0] * cols + [INF])]
    cur = wall[0]
    for r in range(1, rows):
        src, dst = bufs[(r - 1) & 1], bufs[r & 1]
        c.launch(f'row{r}', 'pathfinder', [src, dst, pw + 4 * r * cols, cols], cols)
        cur = [wall[r][x] + min(cur[max(x - 1, 0):x + 2]) for x in range(cols)]
    c.expect(bufs[(rows - 1) & 1] + 4, cur)
    return c



def fsub(a, b):
    return ga.fr2f(ga.f2fr(a) - ga.f2fr(b))


def f32(x):
    return struct.unpack('<I', struct.pack('<f', x))[0]


def rand_range(rng, lo, hi):
    return f32(rng.uniform(lo, hi))


# Padded grid layout of stencil.S: row stride s = n + 2*LANES, interior (i, j) at word
# (i + 1)*s + LANES + j; the padding is the fixed (ghost) border.
def padded(n):
    return n + 2 * ga.LANES


# ── Rodinia hotspot ──────────────────────────────────────────────────────────────
def hotspot_consts(n):
    """Rodinia hotspot.c's constants for an n x n grid of its 16 mm chip."""
    t_chip, h, w, amb = 0.0005, 0.016, 0.016, 80.0
    MAX_PD, PRECISION, SPEC_HEAT_SI, K_SI, FACTOR_CHIP = 3.0e6, 0.001, 1.75e6, 100.0, 0.5
    gh, gw = h / n, w / n
    cap = FACTOR_CHIP * SPEC_HEAT_SI * t_chip * gw * gh
    rx = gw / (2.0 * K_SI * t_chip * gh)
    ry = gh / (2.0 * K_SI * t_chip * gw)
    rz = t_chip / (K_SI * gh * gw)
    max_slope = MAX_PD / (FACTOR_CHIP * t_chip * SPEC_HEAT_SI)
    step = PRECISION / max_slope
    return [f32(1.0 / rx), f32(1.0 / ry), f32(1.0 / rz), f32(amb), f32(step / cap)]


def hotspot(rng, n, steps):
    """hotspot.S: a = (tN + tS) - (t + t); b = (tE + tW) - (t + t); c = amb - t;
    s = fma(a, ry1, p); s = fma(b, rx1, s); s = fma(c, rz1, s); out = fma(sdc, s, t)."""
    c = Case(f'hotspot_{n}x{steps}')
    s = padded(n)
    t = [rand_range(rng, 320.0, 340.0) for _ in range((n + 2) * s)]
    p = [rand_range(rng, 0.0, 0.001) for _ in range((n + 2) * s)]
    rx1, ry1, rz1, amb, sdc = hotspot_consts(n)
    pp = c.img.alloc(len(p), p)
    bufs = [c.img.alloc(len(t), t), c.img.alloc(len(t), t)]
    cur = list(t)
    for k in range(steps):
        c.launch(f'step{k}', 'hotspot', [bufs[k % 2], bufs[(k + 1) % 2], pp, n.bit_length() - 1, s,
                                          rx1, ry1, rz1, amb, sdc], n * n)
        nxt = list(cur)
        for i in range(n):
            for j in range(n):
                q = (i + 1) * s + ga.LANES + j
                tt = cur[q]
                t2 = fadd(tt, tt)
                a = fsub(fadd(cur[q - s], cur[q + s]), t2)
                b = fsub(fadd(cur[q + 1], cur[q - 1]), t2)
                cc = fsub(amb, tt)
                acc = fma(a, ry1, p[q])
                acc = fma(b, rx1, acc)
                acc = fma(cc, rz1, acc)
                nxt[q] = fma(sdc, acc, tt)
        cur = nxt
    c.expect(bufs[steps % 2], cur)
    return c


# ── PolyBench jacobi-2d ──────────────────────────────────────────────────────────
def jacobi2d(rng, n, tsteps):
    """jacobi2d.S: B[i][j] = 0.2f * ((((A[i][j] + A[i][j-1]) + A[i][j+1]) + A[i+1][j])
    + A[i-1][j]), then back from B to A: 2*tsteps sweeps."""
    c = Case(f'jacobi2d_{n}x{tsteps}')
    s = padded(n)
    g = [ga.rand_f32(rng) for _ in range((n + 2) * s)]
    c02 = f32(0.2)
    bufs = [c.img.alloc(len(g), g), c.img.alloc(len(g), g)]
    cur = list(g)
    for k in range(2 * tsteps):
        c.launch(f'sweep{k}', 'jacobi2d', [bufs[k % 2], bufs[(k + 1) % 2], n.bit_length() - 1, s, c02], n * n)
        nxt = list(cur)
        for i in range(n):
            for j in range(n):
                q = (i + 1) * s + ga.LANES + j
                sm = fadd(fadd(fadd(fadd(cur[q], cur[q - 1]), cur[q + 1]), cur[q + s]), cur[q - s])
                nxt[q] = fmul(c02, sm)
        cur = nxt
    c.expect(bufs[0], cur)          # an even number of sweeps ends in A
    return c


# ── PolyBench atax / bicg: row and column products (mv_row.S, mv_col.S) ──────────
def mv_row(A, x, n):
    out = []
    for i in range(n):
        acc = 0
        for j in range(n):
            acc = fma(A[i * n + j], x[j], acc)
        out.append(acc)
    return out


def mv_col(A, x, n):
    out = []
    for j in range(n):
        acc = 0
        for i in range(n):
            acc = fma(A[i * n + j], x[i], acc)
        out.append(acc)
    return out


def atax(rng, n):
    """y = A^T (A x): tmp[i] = fma chain over j of A[i][j]*x[j] (mv_row), then
    y[j] = fma chain over i of A[i][j]*tmp[i] (mv_col)."""
    c = Case(f'atax_{n}')
    A = [ga.rand_f32(rng) for _ in range(n * n)]
    x = [ga.rand_f32(rng) for _ in range(n)]
    pa, px, pt, py = c.img.alloc(n * n, A), c.img.alloc(n, x), c.img.alloc(n), c.img.alloc(n)
    c.launch('Ax', 'mv_row', [pa, px, pt, n], n)
    c.launch('ATtmp', 'mv_col', [pa, pt, py, n], n)
    tmp = mv_row(A, x, n)
    c.expect(pt, tmp)
    c.expect(py, mv_col(A, tmp, n))
    return c


def bicg(rng, n):
    """q = A p (mv_row) and s = A^T r (mv_col)."""
    c = Case(f'bicg_{n}')
    A = [ga.rand_f32(rng) for _ in range(n * n)]
    p = [ga.rand_f32(rng) for _ in range(n)]
    r = [ga.rand_f32(rng) for _ in range(n)]
    pa, pp, pr, pq, ps = (c.img.alloc(n * n, A), c.img.alloc(n, p), c.img.alloc(n, r),
                          c.img.alloc(n), c.img.alloc(n))
    c.launch('q', 'mv_row', [pa, pp, pq, n], n)
    c.launch('s', 'mv_col', [pa, pr, ps, n], n)
    c.expect(pq, mv_row(A, p, n))
    c.expect(ps, mv_col(A, r, n))
    return c


# ── GAP: the graph of gen_apps.bfs (random tree + random edges, symmetric CSR) ──
def graph(rng, nv, deg):
    adj = [set() for _ in range(nv)]
    for v in range(1, nv):
        u = rng.randrange(v)
        adj[u].add(v)
        adj[v].add(u)
    for _ in range(nv * (deg - 2) // 2):
        u, v = rng.randrange(nv), rng.randrange(nv)
        if u != v:
            adj[u].add(v)
            adj[v].add(u)
    rowptr, col = [0], []
    for v in range(nv):
        col += sorted(adj[v])
        rowptr.append(len(col))
    return rowptr, col


def pagerank(rng, nv, deg, iters):
    """GAP PageRank, pull form, fixed iterations: c[u] = pr[u] * invdeg[u] (pr_contrib),
    then acc = +0, acc = acc + c[u] over v's neighbours in CSR order, pr'[v] =
    fma(d, acc, base) (pr_pull); d = 0.85f, base = (1 - d) / N, pr = 1/N at the start
    (N a power of two, so base and 1/N are exact), invdeg[u] = 1.0f / deg(u)."""
    assert nv & (nv - 1) == 0
    c = Case(f'pagerank_{nv}x{deg}x{iters}')
    rowptr, col = graph(rng, nv, deg)
    d = f32(0.85)
    base = ga.fr2f((1 - ga.f2fr(d)) * Fraction(1, nv))
    pr = [ga.fr2f(Fraction(1, nv))] * nv
    invdeg = [ga.fr2f(Fraction(1, rowptr[v + 1] - rowptr[v])) for v in range(nv)]
    prp, pcol, pinv = c.img.alloc(nv + 1, rowptr), c.img.alloc(len(col), col), c.img.alloc(nv, invdeg)
    pc = c.img.alloc(nv)
    bufs = [c.img.alloc(nv, pr), c.img.alloc(nv)]
    for k in range(iters):
        src, dst = bufs[k % 2], bufs[(k + 1) % 2]
        c.launch(f'contrib{k}', 'pr_contrib', [src, pinv, pc], nv)
        c.launch(f'pull{k}', 'pr_pull', [prp, pcol, pc, dst, d, base], nv)
        cv = [fmul(pr[u], invdeg[u]) for u in range(nv)]
        nxt = []
        for v in range(nv):
            acc = 0
            for u in col[rowptr[v]:rowptr[v + 1]]:
                acc = fadd(acc, cv[u])
            nxt.append(fma(d, acc, base))
        pr = nxt
    c.expect(bufs[iters % 2], pr)
    return c


def cc(rng, nv, deg):
    """GAP connected components by label propagation (cc_step): lab'[v] = min(lab[v],
    lab[u] over v's neighbours) between two arrays, a flag word per round set when a
    label changed; rounds until one changes nothing. lab = v at the start."""
    c = Case(f'cc_{nv}x{deg}')
    rowptr, col = graph(rng, nv, deg)
    lab = list(range(nv))
    prp, pcol = c.img.alloc(nv + 1, rowptr), c.img.alloc(len(col), col)
    bufs = [c.img.alloc(nv, lab), c.img.alloc(nv)]
    k, flags = 0, []
    while True:
        pflag = c.img.alloc(1)
        c.launch(f'round{k}', 'cc_step', [prp, pcol, bufs[k % 2], bufs[(k + 1) % 2], pflag], nv)
        nxt = [min([lab[v]] + [lab[u] for u in col[rowptr[v]:rowptr[v + 1]]]) for v in range(nv)]
        changed = nxt != lab
        flags.append((pflag, 1 if changed else 0))
        lab, k = nxt, k + 1
        if not changed:
            break
    c.expect(bufs[k % 2], lab)
    for a, v in flags:
        c.expect(a, [v])
    return c


# ── Rodinia backprop: the two GPU kernels of bpnn ────────────────────────────────
BP_H = 16


def backprop(rng, n):
    """bp_forward: ps[b][j] = fma chain over i = 16b..16b+15 of w[i][j] * in[i] from +0
    (thread t: j = t & 15, b = t >> 4); bp_adjust: per (i, j) (t: i = t >> 4,
    j = t & 15) dw = fma(ed[j], in[i], m * ow[i][j]); w[i][j] = w[i][j] + dw;
    ow[i][j] = dw, m = 0.3f. The host's part between them (the block sums, the sigmoid,
    the output layer, ed[j] = eta * delta[j]) is A53 code on every system; here ed is
    an input."""
    assert n % 16 == 0
    c = Case(f'backprop_{n}')
    inp = [f32(1.0)] + [ga.rand_f32(rng, 0.0, 1.0) for _ in range(n - 1)]
    w = [ga.rand_f32(rng, -0.5, 0.5) for _ in range(n * BP_H)]
    ow = [ga.rand_f32(rng, -0.05, 0.05) for _ in range(n * BP_H)]
    ed = [ga.rand_f32(rng, -0.1, 0.1) for _ in range(BP_H)]
    m = f32(0.3)
    pin, pw, pow_, ped, pps = (c.img.alloc(n, inp), c.img.alloc(n * BP_H, w), c.img.alloc(n * BP_H, ow),
                               c.img.alloc(BP_H, ed), c.img.alloc(n))
    c.launch('forward', 'bp_forward', [pin, pw, pps], n)
    c.launch('adjust', 'bp_adjust', [pin, pw, pow_, ped, m], n * BP_H)
    ps = []
    for t in range(n):
        j, b = t & 15, t >> 4
        acc = 0
        for i in range(16 * b, 16 * b + 16):
            acc = fma(w[i * BP_H + j], inp[i], acc)
        ps.append(acc)
    c.expect(pps, ps)
    nw, now = [], []
    for t in range(n * BP_H):
        i, j = t >> 4, t & 15
        dw = fma(ed[j], inp[i], fmul(m, ow[t]))
        nw.append(fadd(w[t], dw))
        now.append(dw)
    c.expect(pw, nw)
    c.expect(pow_, now)
    return c


# ── SHOC sort: stable LSD radix sort of key-value pairs, 4 bits per pass ─────────
def radixsort(rng, n, workers):
    """W workers own contiguous chunks of n/W pairs. Per pass p (digit = key >> 4p & 15):
    rs_hist (W threads): hist[d][w] = count of digit d in chunk w;
    rs_scan (16 threads): thread d: off[d][w] = exclusive prefix of hist[d][.] over w,
    tot[d] = the digit's total; rs_scatter (W threads): base[d] = sum of tot[d'] for
    d' < d, then the worker's pairs in order to base[d] + off[d][w] (+ a running count,
    kept in off). Stable, so the sorted output is unique. 8 passes, ping-pong buffers."""
    assert n % workers == 0
    c = Case(f'sort_{n}x{workers}')
    keys = [rng.getrandbits(32) for _ in range(n)]
    vals = list(range(n))
    W, C = workers, n // workers
    kb = [c.img.alloc(n, keys), c.img.alloc(n)]
    vb = [c.img.alloc(n, vals), c.img.alloc(n)]
    ph, po, pt = c.img.alloc(16 * W), c.img.alloc(16 * W), c.img.alloc(16)
    for p in range(8):
        src, dst = p % 2, (p + 1) % 2
        c.launch(f'hist{p}', 'rs_hist', [kb[src], ph, C, 4 * p, W], W)
        c.launch(f'scan{p}', 'rs_scan', [ph, po, pt, W], 16)
        c.launch(f'scatter{p}', 'rs_scatter', [kb[src], vb[src], kb[dst], vb[dst], po, pt, C, 4 * p, W], W)
    order = sorted(range(n), key=lambda i: keys[i])          # Python's sort is stable
    c.expect(kb[0], [keys[i] for i in order])
    c.expect(vb[0], [vals[i] for i in order])
    return c


# ── RiVEC / PARSEC Black-Scholes ─────────────────────────────────────────────────
def fdiv(a, b):
    return ga.fr2f(ga.f2fr(a) / ga.f2fr(b))


def fsqrt(a):
    """Correctly rounded FP32 square root (a >= 0)."""
    x = ga.f2fr(a)
    if x == 0:
        return 0
    import math
    y = f32(math.sqrt(float(x)))
    best = y
    for cand in (y - 1, y + 1):                   # neighbours in the bit pattern
        lo, hi = sorted((best, cand), key=lambda b: ga.f2fr(b))
        mid = (ga.f2fr(lo) + ga.f2fr(hi)) / 2
        best = lo if x < mid * mid else hi        # the nearer one to sqrt(x)
    return best


def fneg(a):
    return a ^ 0x8000_0000


def fabs_(a):
    return a & 0x7FFF_FFFF


def flt(a, b):
    return ga.f2fr(a) < ga.f2fr(b)


def fcvt_w_rne(a):
    return round(ga.f2fr(a))                       # Fraction: ties to even


def fcvt_s_w(k):
    return ga.fr2f(Fraction(k))


BS_C = [f32(v) for v in (
    0.5, 1.0, 2.0, 1.4426950408889634,                         # 0..3: 0.5 1 2 log2(e)
    0.693145751953125, 1.4286068203094172e-06,                 # 4 5: ln2 hi, lo
    1.0, 1.0, 0.5, 1 / 6, 1 / 24, 1 / 120, 1 / 720,           # 6..12: exp poly E0..E6
    0.6931471805599453,                                         # 13: ln2
    2 / 3, 2 / 5, 2 / 7, 2 / 9,                                 # 14..17: log poly C1..C4
    1.4142135623730951,                                         # 18: sqrt(2)
    0.39894228040143270286,                                     # 19: 1/sqrt(2 pi)
    0.2316419, 0.319381530, -0.356563782, 1.781477937, -1.821255978, 1.330274429)]  # 20..25


def bs_exp(x):
    C = BS_C
    k = fcvt_w_rne(fmul(x, C[3]))
    kf = fneg(fcvt_s_w(k))
    f = fma(kf, C[4], x)
    f = fma(kf, C[5], f)
    p = fma(f, C[12], C[11])
    for e in (C[10], C[9], C[8], C[7], C[6]):
        p = fma(f, p, e)
    return (p + (k << 23)) & 0xFFFF_FFFF


def bs_log(x):
    C = BS_C
    e = ((x >> 23) & 0xFF) - 127
    m = (x & 0x7F_FFFF) | 0x3F80_0000
    if flt(C[18], m):
        m, e = fmul(m, C[0]), e + 1
    f = fsub(m, C[1])
    s = fdiv(f, fadd(f, C[2]))
    z = fmul(s, s)
    R = fma(z, C[17], C[16])
    R = fma(z, R, C[15])
    R = fma(z, R, C[14])
    R = fmul(R, z)
    l = fma(s, R, fadd(s, s))
    return fma(fcvt_s_w(e), C[13], l)


def bs_cndf(x):
    C = BS_C
    sign = x >> 31
    xa = fabs_(x)
    ex = bs_exp(fneg(fmul(fmul(xa, xa), C[0])))
    n = fmul(ex, C[19])
    k2 = fdiv(C[1], fadd(C[1], fmul(C[20], xa)))
    k22 = fmul(k2, k2)
    k23 = fmul(k22, k2)
    k24 = fmul(k23, k2)
    k25 = fmul(k24, k2)
    l1 = fmul(k2, C[21])
    l2 = fmul(k22, C[22])
    l2 = fadd(l2, fmul(k23, C[23]))
    l2 = fadd(l2, fmul(k24, C[24]))
    l2 = fadd(l2, fmul(k25, C[25]))
    l1 = fadd(l1, l2)
    loc = fsub(C[1], fmul(l1, n))
    return fsub(C[1], loc) if sign else loc


def bs_price(S, K, r, v, T):
    C = BS_C
    sq = fsqrt(T)
    lt = bs_log(fdiv(S, K))
    pw = fmul(fmul(v, v), C[0])
    d1 = fadd(fmul(fadd(r, pw), T), lt)
    den = fmul(v, sq)
    d1 = fdiv(d1, den)
    d2 = fsub(d1, den)
    n1, n2 = bs_cndf(d1), bs_cndf(d2)
    fv = fmul(K, bs_exp(fneg(fmul(r, T))))
    call = fsub(fmul(S, n1), fmul(fv, n2))
    put = fsub(fmul(fv, fsub(C[1], n2)), fmul(S, fsub(C[1], n1)))
    return call, put


def blackscholes(rng, n):
    """blackscholes.S: PARSEC's BlkSchlsEqEuroNoDiv with these exp and log (see the
    kernel's header); spot within 20% of the strike, as PARSEC's data, so every exp
    result is a normal number."""
    c = Case(f'blackscholes_{n}')
    S = [rand_range(rng, 10.0, 100.0) for _ in range(n)]
    K = [f32(ga.f2fr(s) * Fraction(rng.uniform(0.8, 1.2))) for s in S]
    r = [rand_range(rng, 0.01, 0.1) for _ in range(n)]
    v = [rand_range(rng, 0.1, 0.6) for _ in range(n)]
    T = [rand_range(rng, 0.25, 1.0) for _ in range(n)]
    arrs = [c.img.alloc(n, a) for a in (S, K, r, v, T)]
    pcall, pput, pc = c.img.alloc(n), c.img.alloc(n), c.img.alloc(len(BS_C), BS_C)
    c.launch('bs', 'blackscholes', arrs + [pcall, pput, pc], n)
    res = [bs_price(*o) for o in zip(S, K, r, v, T)]
    c.expect(pcall, [a for a, _ in res])
    c.expect(pput, [b for _, b in res])
    return c


SIZES = {
    'small': [lambda r: pathfinder(r, 12, 256), lambda r: hotspot(r, 32, 2), lambda r: jacobi2d(r, 32, 2),
              lambda r: atax(r, 64), lambda r: bicg(r, 64), lambda r: pagerank(r, 512, 8, 3),
              lambda r: cc(r, 512, 8), lambda r: backprop(r, 512), lambda r: radixsort(r, 4096, 64),
              lambda r: blackscholes(r, 512)],
    'board': [lambda r: pathfinder(r, 100, 65536), lambda r: hotspot(r, 512, 4), lambda r: jacobi2d(r, 512, 4),
              lambda r: atax(r, 1024), lambda r: bicg(r, 1024), lambda r: pagerank(r, 16384, 8, 10),
              lambda r: cc(r, 16384, 8), lambda r: backprop(r, 65536), lambda r: radixsort(r, 65536, 256),
              lambda r: blackscholes(r, 65536)],
    'dram':  [lambda r: pathfinder(r, 100, 1 << 18), lambda r: hotspot(r, 1024, 4), lambda r: jacobi2d(r, 2048, 4),
              lambda r: atax(r, 4096), lambda r: bicg(r, 4096), lambda r: pagerank(r, 1 << 18, 8, 10),
              lambda r: cc(r, 1 << 18, 8), lambda r: backprop(r, 1 << 19), lambda r: radixsort(r, 1 << 20, 1024),
              lambda r: blackscholes(r, 1 << 20)],
}
APPS = ['pathfinder', 'hotspot', 'jacobi2d', 'atax', 'bicg', 'pagerank', 'cc', 'backprop', 'sort', 'blackscholes']


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--size', default='small', choices=SIZES)
    ap.add_argument('--out', default=os.path.join(ga.ROOT, 'build_suite2'))
    ap.add_argument('--words-lg', type=int, default=20)
    ap.add_argument('--only', nargs='*')
    args = ap.parse_args()
    ga.KERNELS, ga.OVERLAY, ga.WORDS = KERNELS, [], 1 << args.words_lg
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    ga.place_kernels(KDIR)
    cases = [f(random.Random(3001 + i)) for i, f in enumerate(SIZES[args.size])
             if not args.only or APPS[i] in args.only]
    ga.write_manifest(cases, out, KDIR)


if __name__ == '__main__':
    main()
