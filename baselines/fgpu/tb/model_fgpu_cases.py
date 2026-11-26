"""model_fgpu_cases.py - float32 models of the FGPU ports (baselines/fgpu/kernels/*.cl), operation by
operation (multiply then add: no FMA), run on the testbench cases (tb/gen_fgpu_cases.py output)
and checked as tb_fgpu_apps.sv checks: tol 0 every word exact, tol 1 within 1e-3 of the case's
largest |gold|. A logic check of the ports in seconds, not of FGPU's RTL.
    python baselines/fgpu/tb/model_fgpu_cases.py <fgpu_cases.txt> <kernel .h> [case-prefix ...]
                                                 [--fgpu-gold <out cases.txt>]
--fgpu-gold also writes the model's values of the checked words as <case>.fgpu.gold and a cases
file that checks them exactly (tol 0): the RTL must reproduce the model bit for bit, which the
1e-3 tolerance cannot show for hotspot data (a hotspot case passes it with no kernel run).
Kernels modelled: Rodinia's hotspot3d, gauss_fan1/2, kmeans_rd and bfs, RiVEC's gemm and lavamd_rv
(the cases whose xsim runs take hours), and all of suite 1 (apps.cl). docs/fgpu_plan.md.
"""
import re
import sys

import numpy as np

WORDS = 1 << 20
MASK = WORDS - 1
f32 = np.float32


class Mem:
    def __init__(self, path):
        self.u = np.zeros(WORDS, dtype=np.uint32)
        a = 0
        for line in open(path):
            line = line.strip()
            if not line:
                continue
            if line[0] == '@':
                a = int(line[1:], 16)
                continue
            self.u[a & MASK] = int(line, 16)
            a += 1
        self.f = self.u.view(np.float32)

    def w(self, addr):                      # word index of a byte address
        return (int(addr) >> 2) & MASK


def idx(m, base, off):                      # base: byte address; off: word offsets (array)
    return (m.w(base) + np.asarray(off, dtype=np.int64)) & MASK


def k_gemm(m, p, n):
    t = np.arange(n, dtype=np.int64)
    A, B, C, K, l2n = (int(m.u[m.w(p) + i]) for i in range(5))
    nn = 1 << l2n
    arow = (t >> l2n) * K
    bcol = t & (nn - 1)
    acc = np.zeros(n, dtype=f32)
    for k in range(K):
        q = m.f[idx(m, A, arow + k)] * m.f[idx(m, B, bcol + k * nn)]
        acc = q + acc
    m.f[idx(m, C, t)] = acc


def k_hotspot3d(m, p, n):
    t = np.arange(n, dtype=np.int64)
    P = [int(m.u[m.w(p) + i]) for i in range(11)]
    PF = m.u[m.w(p):m.w(p) + 11].view(np.float32)
    inb, outb, pwb, l2, nz = P[0], P[1], P[2], P[3], P[4]
    n1, xy = (1 << l2) - 1, 1 << (2 * l2)
    cc, ce, cn, ct, sdc, amb = (PF[i] for i in range(5, 11))
    i, j = t & n1, t >> l2
    oW = np.where(i != 0, -1, 0)
    oE = np.where(i < n1, 1, 0)
    oN = np.where(j != 0, -(n1 + 1), 0)
    oS = np.where(j < n1, n1 + 1, 0)
    IN = lambda o: m.f[idx(m, inb, o)]
    t1 = IN(t)
    t2 = t1
    t3 = IN(t + xy)
    c = t.copy()
    for z in range(nz):
        if z:
            t1, t2 = t2, t3
            if z + 1 < nz:
                t3 = IN(c + xy)
        s = cc * t2
        q = ce * IN(c + oW); s = q + s
        q = ce * IN(c + oE); s = q + s
        q = cn * IN(c + oS); s = q + s
        q = cn * IN(c + oN); s = q + s
        q = ct * t1; s = q + s
        q = ct * t3; s = q + s
        q = sdc * m.f[idx(m, pwb, c)]; s = q + s
        q = ct * amb
        m.f[idx(m, outb, c)] = q + s
        c = c + xy


def k_gauss_fan1(m, p, n):
    u = np.arange(n, dtype=np.int64)
    a, mm, N, t = (int(m.u[m.w(p) + i]) for i in range(4))
    s = N + 1
    i = t + 1 + u
    m.f[idx(m, mm, i * N + t)] = m.f[idx(m, a, i * s + t)] / m.f[idx(m, a, np.array(t * s + t))]


def k_gauss_fan2(m, p, n):
    u = np.arange(n, dtype=np.int64)
    a, mm, N, t = (int(m.u[m.w(p) + i]) for i in range(4))
    s = N + 1
    j = t + u
    atj = m.f[idx(m, a, t * s + j)]
    for i in range(t + 1, N):
        mi = m.f[idx(m, mm, np.array(i * N + t))]
        q = (-mi) * atj
        ai = idx(m, a, i * s + j)
        m.f[ai] = q + m.f[ai]


def k_kmeans_rd(m, p, n):
    t = np.arange(n, dtype=np.int64)
    fb, cb, ob, npt, k, nf = (int(m.u[m.w(p) + i]) for i in range(6))
    best = np.full(n, f32(3.40282347e38), dtype=f32)
    bi = np.zeros(n, dtype=np.uint32)
    for i in range(k):
        ans = np.zeros(n, dtype=f32)
        for j in range(nf):
            d = m.f[idx(m, fb, j * npt + t)] - m.f[idx(m, cb, np.array(i * nf + j))]
            q = d * d
            ans = q + ans
        lt = ans < best
        best = np.where(lt, ans, best)
        bi = np.where(lt, np.uint32(i), bi)
    m.u[idx(m, ob, t)] = bi


M_ = f32(12582912.0)
MB = np.uint32(0x4B400000)


def rne_f(x):
    y = x + M_
    return y - M_


def rne_i(x):
    y = (x + M_).astype(f32)
    return (y.view(np.uint32).astype(np.int64) - int(MB)).astype(np.int64)


def rv_exp(x):
    x = np.where(f32(88.3762626647949) < x, f32(88.3762626647949), x).astype(f32)
    x = np.where(x < f32(-88.3762626647949), f32(-88.3762626647949), x).astype(f32)
    fx = f32(1.44269504088896341) * x
    fx = fx + f32(0.5)
    tmp = rne_f(fx)
    fx = tmp - np.where(fx < tmp, f32(1), f32(0)).astype(f32)
    t1 = fx * f32(0.693359375)
    z = fx * f32(-2.12194440e-4)
    x = x - t1
    x = x - z
    z = x * x
    y = np.full_like(x, f32(1.9875691500E-4))
    for c in (1.3981999507E-3, 8.3334519073E-3, 4.1665795894E-2, 1.6666665459E-1, 5.0000001201E-1):
        q = y * x
        y = q + f32(c)
    q = y * z
    y = q + x
    y = y + f32(1)
    e = rne_i(fx) + 0x7f
    sc = ((e.astype(np.uint32) << np.uint32(23)) & np.uint32(0xFFFFFFFF)).astype(np.uint32).view(np.float32)
    return (y * sc).astype(f32)


def negf(x):
    return (x.view(np.uint32) ^ np.uint32(0x80000000)).view(np.float32)


def k_lavamd_rv(m, p, n):
    NP = 96
    t = np.arange(n, dtype=np.int64)
    P = [int(m.u[m.w(p) + i]) for i in range(6)]
    rvb, qvb, fAb, nnb, neib = P[:5]
    a2 = m.u[m.w(p) + 5:m.w(p) + 6].view(np.float32)[0]
    l = ((t >> 5) * 0xAAAB) >> 17
    RV = lambda o: m.f[idx(m, rvb, o)]
    Av, Ax, Ay, Az = RV(4 * t), RV(4 * t + 1), RV(4 * t + 2), RV(4 * t + 3)
    fv, fx, fy, fz = (m.f[idx(m, fAb, 4 * t + i)] for i in range(4))
    nb = 1 + m.u[idx(m, nnb, l)].astype(np.int64)
    for k in range(int(nb.max())):
        act = k < nb
        if k:
            pb = m.u[idx(m, neib, l * 26 + k - 1)].astype(np.int64)
        else:
            pb = l.copy()
        for j in range(NP):
            rb = 4 * pb * NP + 4 * j
            Bv, Bx, By, Bz = RV(rb), RV(rb + 1), RV(rb + 2), RV(rb + 3)
            r2 = Bv + Av
            dot = Bx * Ax
            q = Ay * By; dot = q + dot
            q = Az * Bz; dot = q + dot
            r2 = r2 - dot
            u2 = r2 * a2
            vij = rv_exp(negf(u2))
            fs = f32(2) * vij
            dx, dy, dz = Ax - Bx, Ay - By, Az - Bz
            qj = m.f[idx(m, qvb, pb * NP + j)]
            q = qj * vij; nfv = q + fv
            q = fs * dx; q = qj * q; nfx = q + fx
            q = fs * dy; q = qj * q; nfy = q + fy
            q = fs * dz; q = qj * q; nfz = q + fz
            fv = np.where(act, nfv, fv); fx = np.where(act, nfx, fx)
            fy = np.where(act, nfy, fy); fz = np.where(act, nfz, fz)
    for i, v in enumerate((fv, fx, fy, fz)):
        m.f[idx(m, fAb, 4 * t + i)] = v


# ── suite 1 (apps.cl) ────────────────────────────────────────────────────────────
U32 = 0xFFFFFFFF


def P(m, p, k):                             # the parameter block's first k words (ints)
    return [int(m.u[m.w(p) + i]) for i in range(k)]


def PFv(m, p, i):                           # parameter word i as a float32
    return m.u[m.w(p) + i:m.w(p) + i + 1].view(np.float32)[0]


def bidx(base, off):                        # byte index of a byte address + byte offsets
    return (int(base) + np.asarray(off, dtype=np.int64)) & (4 * WORDS - 1)


def k_spmv(m, p, n):
    r = np.arange(n, dtype=np.int64)
    rp, col, val, x, y = P(m, p, 5)
    st = m.u[idx(m, rp, r)].astype(np.int64)
    en = m.u[idx(m, rp, r + 1)].astype(np.int64)
    acc = np.zeros(n, dtype=f32)
    for k in range(int((en - st).max()) if n else 0):
        act = st + k < en
        j = np.where(act, st + k, st)
        q = m.f[idx(m, val, j)] * m.f[idx(m, x, m.u[idx(m, col, j)].astype(np.int64))]
        acc = np.where(act, acc + q, acc)
    m.f[idx(m, y, r)] = acc


def k_stencil(m, p, n):
    t = np.arange(n, dtype=np.int64)
    inb, outb, l2w, s = P(m, p, 4)
    c0, c1 = PFv(m, p, 4), PFv(m, p, 5)
    q = ((t >> l2w) + 1) * s + 8 + (t & ((1 << l2w) - 1))
    IN = lambda o: m.f[idx(m, inb, o)]
    ud = IN(q - s) + IN(q + s)
    lr = IN(q - 1) + IN(q + 1)
    sm = ud + lr
    centre = c0 * IN(q)
    r = c1 * sm
    m.f[idx(m, outb, q)] = r + centre


def k_kmeans(m, p, n):
    t = np.arange(n, dtype=np.int64)
    px, py, cx, cy, K, asg, sx, sy, cn = P(m, p, 9)
    x = m.u[idx(m, px, t)].astype(np.int64)
    y = m.u[idx(m, py, t)].astype(np.int64)
    best = np.full(n, 0x7fffffff, dtype=np.int64)
    bk = np.zeros(n, dtype=np.int64)
    for k in range(K):
        dx = ((x - int(m.u[m.w(cx) + k])) & U32).astype(np.uint32).astype(np.int32).astype(np.int64)
        dy = ((y - int(m.u[m.w(cy) + k])) & U32).astype(np.uint32).astype(np.int32).astype(np.int64)
        d = (dx * dx + dy * dy) & U32
        lt = d < best
        best = np.where(lt, d, best)
        bk = np.where(lt, k, bk)
    m.u[idx(m, asg, t)] = bk.astype(np.uint32)
    for base, v in ((sx, x), (sy, y), (cn, np.ones(n, dtype=np.int64))):
        acc = m.u.astype(np.int64)[idx(m, base, np.arange(K))]
        np.add.at(acc, bk, v)
        m.u[idx(m, base, np.arange(K))] = (acc & U32).astype(np.uint32)


def k_bfs(m, p, n):
    v = np.arange(n, dtype=np.int64)
    rp, col, lev, L, flag = P(m, p, 5)
    front = v[m.u[idx(m, lev, v)] == L]
    found = False
    newly = []
    for u in front:                          # every frontier vertex sees the levels at launch
        s, e = int(m.u[m.w(rp) + u]), int(m.u[m.w(rp) + u + 1])
        for j in range(s, e):
            w = int(m.u[m.w(col) + j])
            if m.u[m.w(lev) + w] == 0xFFFFFFFF:
                newly.append(w)
                found = True
    for w in newly:
        m.u[m.w(lev) + w] = L + 1
    if found:
        m.u[m.w(flag)] = 1


def k_scan(m, p, n):
    t = np.arange(n, dtype=np.int64)
    inb, outb, bsb = P(m, p, 3)
    v = np.zeros(n, dtype=np.int64)
    for i in range(32):
        v = v + np.where(i <= (t & 31), m.u[idx(m, inb, (t & ~31) + i)].astype(np.int64), 0)
    v &= U32
    m.u[idx(m, outb, t)] = v.astype(np.uint32)
    last = (t & 31) == 31
    m.u[idx(m, bsb, t[last] >> 5)] = v[last].astype(np.uint32)


def k_scan_add(m, p, n):
    t = np.arange(n, dtype=np.int64)
    outb, bsc = P(m, p, 2)
    b = t >> 5
    sel = b > 0
    o = idx(m, outb, t[sel])
    m.u[o] = ((m.u[o].astype(np.int64) + m.u[idx(m, bsc, b[sel] - 1)].astype(np.int64)) & U32).astype(np.uint32)


def sb8(x):                                 # the low byte of a word as a signed int
    return ((x & 0xFF) ^ 0x80) - 0x80


def dot8(a, b):
    a = a.astype(np.int64); b = b.astype(np.int64)
    return sum(sb8(a >> i) * sb8(b >> i) for i in (0, 8, 16, 24))


def requant8(acc, scale, zp):               # apps.cl requant8: unfused, clamp, rne
    f = acc.astype(np.float32) * scale       # (float)acc correctly rounded, as i2f_s
    f = (f + zp).astype(f32)
    f = np.where(f32(127) < f, f32(127), f).astype(f32)
    f = np.where(f < f32(0), f32(0), f).astype(f32)
    y = (f + M_).astype(f32)
    return (y.view(np.uint32).astype(np.int64) - int(MB)) & 0xFF


def k_mlp(m, p, n):
    t = np.arange(n, dtype=np.int64)
    xb, wb, ob, Kp, l2, scale_u, zp_u, mode = P(m, p, 8)
    npd = 1 << l2
    acc = np.zeros(n, dtype=np.int64)
    for k in range(Kp):
        acc = acc + dot8(m.u[idx(m, xb, (t >> l2) * Kp + k)], m.u[idx(m, wb, (t & (npd - 1)) + k * npd)])
    acc = ((acc + 2**31) & U32) - 2**31
    if mode == 0:
        m.u[idx(m, ob, t)] = (acc & U32).astype(np.uint32)
    else:
        m.u.view(np.uint8)[bidx(ob, t)] = requant8(acc, PFv(m, p, 5), PFv(m, p, 6)).astype(np.uint8)


def k_conv8(m, p, n):
    t = np.arange(n, dtype=np.int64)
    X, Wt, Ob, Cw, l2co, l2w4, _, _, Wp = P(m, p, 9)
    Cout = 1 << l2co
    o, q = t & (Cout - 1), t >> l2co
    x, y = 4 * (q & ((1 << l2w4) - 1)), q >> l2w4
    acc = [np.zeros(n, dtype=np.int64) for _ in range(4)]
    for ky in range(3):
        for c in range(Cw):
            xr = ((y + ky) * Cw + c) * Wp + x
            wr = ((ky * Cw + c) * 3) * Cout + o
            w0, w1, w2 = (m.u[idx(m, Wt, wr + i * Cout)] for i in range(3))
            a = [m.u[idx(m, X, xr + i)] for i in range(6)]
            for j in range(4):
                acc[j] = acc[j] + dot8(a[j], w0) + dot8(a[j + 1], w1) + dot8(a[j + 2], w2)
    scale, zp = PFv(m, p, 6), PFv(m, p, 7)
    ob = 4 * (((y + 1) * (Cout >> 2) + (o >> 2)) * Wp + x + 1) + (o & 3)
    for j in range(4):
        a32 = ((acc[j] + 2**31) & U32) - 2**31
        m.u.view(np.uint8)[bidx(Ob, ob + 4 * j)] = requant8(a32, scale, zp).astype(np.uint8)


def k_embag(m, p, n):
    t = np.arange(n, dtype=np.int64)
    T, ib, ob, K, l2d = P(m, p, 5)
    d, b = t & ((1 << l2d) - 1), t >> l2d
    acc = np.zeros(n, dtype=f32)
    for k in range(K):
        r = m.u[idx(m, ib, b * K + k)].astype(np.int64)
        acc = acc + m.f[idx(m, T, (r << l2d) + d)]
    m.f[idx(m, ob, t)] = acc


def k_hashj(m, p, n):
    t = np.arange(n, dtype=np.int64)
    sl, kb, ob, sh, mask = P(m, p, 5)
    key = m.u[idx(m, kb, t)].astype(np.int64)
    h = ((key * 0x9E3779B1) & U32) >> sh
    s = m.u[idx(m, sl, 2 * h)].astype(np.int64)
    act = (s != key) & (s != 0)
    while act.any():
        h = np.where(act, (h + 1) & mask, h)
        s = np.where(act, m.u[idx(m, sl, 2 * h)].astype(np.int64), s)
        act = act & (s != key) & (s != 0)
    m.u[idx(m, ob, t)] = np.where(s == key, m.u[idx(m, sl, 2 * h + 1)], np.uint32(0xFFFFFFFF)).astype(np.uint32)


def k_mandel(m, p, n):
    t = np.arange(n, dtype=np.int64)
    ob, l2w = P(m, p, 2)
    M = int(m.u[m.w(p) + 6])
    x0, y0, dx, dy = (PFv(m, p, i) for i in (2, 3, 4, 5))
    cr = (t & ((1 << l2w) - 1)).astype(f32) * dx
    cr = cr + x0
    ci = (t >> l2w).astype(f32) * dy
    ci = ci + y0
    zr = np.zeros(n, dtype=f32); zi = np.zeros(n, dtype=f32)
    k = np.zeros(n, dtype=np.int64)
    act = np.ones(n, dtype=bool)
    while act.any():
        zr2, zi2 = zr * zr, zi * zi
        esc = f32(4) < (zr2 + zi2)
        zz = (zr * zi) * f32(2)
        nzi = zz + ci
        nzr = (zr2 - zi2) + cr
        zi = np.where(act, nzi, zi); zr = np.where(act, nzr, zr)
        k = np.where(act, k + 1, k)
        act = act & ~esc & (k < M)
    m.u[idx(m, ob, t)] = k.astype(np.uint32)


def k_swat(m, p, n):
    t = np.arange(n, dtype=np.int64)
    T, Q, B, ob, Lt, S, strideb = P(m, p, 7)
    stride = strideb >> 2
    NEG = -16384
    best = np.zeros(n, dtype=np.int64)
    for s in range(S):
        qw = m.u[idx(m, Q, s * stride + t)].astype(np.int64)
        qc = [(qw >> (2 * i)) & 3 for i in range(4)]
        h = [np.zeros(n, dtype=np.int64) for _ in range(4)]
        e = [np.full(n, NEG, dtype=np.int64) for _ in range(4)]
        bprev = np.zeros(n, dtype=np.int64)
        for j in range(Lt):
            tc = m.u[idx(m, T, j * stride + t)].astype(np.int64) & 3
            if s:
                bw = m.u[idx(m, B, j * stride + t)].astype(np.int64)
                hup = ((bw + 2**31) & U32) - 2**31 >> 16
                f = ((bw & 0xFFFF) ^ 0x8000) - 0x8000
            else:
                hup = np.zeros(n, dtype=np.int64); f = np.full(n, NEG, dtype=np.int64)
            diag = bprev
            bprev = hup
            for r in range(4):
                e[r] = np.maximum(e[r] - 1, h[r] - 3)
                f = np.maximum(f - 1, hup - 3)
                hv = diag + np.where(qc[r] == tc, 2, -1)
                hv = np.maximum(np.maximum(hv, 0), np.maximum(e[r], f))
                diag = h[r]; h[r] = hv; hup = hv; best = np.maximum(best, hv)
            m.u[idx(m, B, j * stride + t)] = (((hup << 16) | (f & 0xFFFF)) & U32).astype(np.uint32)
    m.u[idx(m, ob, t)] = (best & U32).astype(np.uint32)


# ── suite 2 (s2.cl) ──────────────────────────────────────────────────────────────
def k_pathfinder(m, p, n):
    c = np.arange(n, dtype=np.int64)
    src, dst, wall = P(m, p, 3)
    S = lambda o: m.u[idx(m, src, o)].astype(np.int32).astype(np.int64)
    a, b, d = S(c), S(c + 1), S(c + 2)
    mm = np.where(a < b, a, b)
    mm = np.where(mm < d, mm, d)
    w = m.u[idx(m, wall, c)].astype(np.int32).astype(np.int64)
    m.u[idx(m, dst, c + 1)] = ((mm + w) & U32).astype(np.uint32)


def k_hotspot(m, p, n):
    t = np.arange(n, dtype=np.int64)
    inb, outb, pwb, l2n, s = P(m, p, 5)
    rx1, ry1, rz1, amb, sdc = (PFv(m, p, i) for i in range(5, 10))
    q = ((t >> l2n) + 1) * s + 8 + (t & ((1 << l2n) - 1))
    IN = lambda o: m.f[idx(m, inb, o)]
    tt = IN(q); t2 = tt + tt
    a = (IN(q - s) + IN(q + s)) - t2
    b = (IN(q + 1) + IN(q - 1)) - t2
    c = amb - tt
    acc = a * ry1; acc = acc + m.f[idx(m, pwb, q)]
    r = b * rx1; acc = r + acc
    r = c * rz1; acc = r + acc
    r = sdc * acc
    m.f[idx(m, outb, q)] = r + tt


def k_jacobi2d(m, p, n):
    t = np.arange(n, dtype=np.int64)
    A, B, l2n, s = P(m, p, 4)
    c02 = PFv(m, p, 4)
    q = ((t >> l2n) + 1) * s + 8 + (t & ((1 << l2n) - 1))
    IN = lambda o: m.f[idx(m, A, o)]
    x = IN(q) + IN(q - 1)
    x = x + IN(q + 1)
    x = x + IN(q + s)
    x = x + IN(q - s)
    m.f[idx(m, B, q)] = c02 * x


def k_mv_row(m, p, n):
    i = np.arange(n, dtype=np.int64)
    A, x, y, N = P(m, p, 4)
    acc = np.zeros(n, dtype=f32)
    for j in range(N):
        q = m.f[idx(m, A, i * N + j)] * m.f[idx(m, x, np.array(j))]
        acc = q + acc
    m.f[idx(m, y, i)] = acc


def k_mv_col(m, p, n):
    j = np.arange(n, dtype=np.int64)
    A, x, y, N = P(m, p, 4)
    acc = np.zeros(n, dtype=f32)
    for i in range(N):
        q = m.f[idx(m, A, i * N + j)] * m.f[idx(m, x, np.array(i))]
        acc = q + acc
    m.f[idx(m, y, j)] = acc


def k_pr_contrib(m, p, n):
    u = np.arange(n, dtype=np.int64)
    pr, inv, c = P(m, p, 3)
    m.f[idx(m, c, u)] = m.f[idx(m, pr, u)] * m.f[idx(m, inv, u)]


def k_pr_pull(m, p, n):
    v = np.arange(n, dtype=np.int64)
    rp, col, c, out = P(m, p, 4)
    d, base = PFv(m, p, 4), PFv(m, p, 5)
    st = m.u[idx(m, rp, v)].astype(np.int64)
    en = m.u[idx(m, rp, v + 1)].astype(np.int64)
    acc = np.zeros(n, dtype=f32)
    for k in range(int((en - st).max()) if n else 0):
        act = st + k < en
        e = np.where(act, st + k, st)
        acc = np.where(act, acc + m.f[idx(m, c, m.u[idx(m, col, e)].astype(np.int64))], acc)
    r = d * acc
    m.f[idx(m, out, v)] = r + base


def k_cc_step(m, p, n):
    v = np.arange(n, dtype=np.int64)
    rp, col, lab, lab2, flag = P(m, p, 5)
    l = m.u[idx(m, lab, v)].astype(np.int64)
    mm = l.copy()
    st = m.u[idx(m, rp, v)].astype(np.int64)
    en = m.u[idx(m, rp, v + 1)].astype(np.int64)
    for k in range(int((en - st).max()) if n else 0):
        act = st + k < en
        e = np.where(act, st + k, st)
        x = m.u[idx(m, lab, m.u[idx(m, col, e)].astype(np.int64))].astype(np.int64)
        mm = np.where(act & (x < mm), x, mm)
    m.u[idx(m, lab2, v)] = mm.astype(np.uint32)
    if (mm != l).any():
        m.u[m.w(flag)] = 1


def k_bp_forward(m, p, n):
    t = np.arange(n, dtype=np.int64)
    inb, wb, psb = P(m, p, 3)
    acc = np.zeros(n, dtype=f32)
    for i in range(16):
        pr = m.f[idx(m, wb, 256 * (t >> 4) + (t & 15) + 16 * i)] * m.f[idx(m, inb, 16 * (t >> 4) + i)]
        acc = acc + pr
    m.f[idx(m, psb, t)] = acc


def k_bp_adjust(m, p, n):
    t = np.arange(n, dtype=np.int64)
    inb, wb, owb, edb = P(m, p, 4)
    mm = PFv(m, p, 4)
    mo = mm * m.f[idx(m, owb, t)]
    pr = m.f[idx(m, edb, t & 15)] * m.f[idx(m, inb, t >> 4)]
    dw = pr + mo
    m.f[idx(m, wb, t)] = m.f[idx(m, wb, t)] + dw
    m.f[idx(m, owb, t)] = dw


def k_sort_hist(m, p, n):
    keys, hist, C, sh, W = P(m, p, 5)
    for w in range(n):
        k = m.u[idx(m, keys, w * C + np.arange(C))].astype(np.int64)
        cnt = np.bincount((k >> sh) & 15, minlength=16)
        m.u[idx(m, hist, np.arange(16) * W + w)] = cnt.astype(np.uint32)


def k_sort_scan(m, p, n):
    hist, off, tot, W = P(m, p, 4)
    for d in range(n):
        h = m.u[idx(m, hist, d * W + np.arange(W))].astype(np.int64)
        ex = np.concatenate(([0], np.cumsum(h)[:-1]))
        m.u[idx(m, off, d * W + np.arange(W))] = (ex & U32).astype(np.uint32)
        m.u[m.w(tot) + d] = int(h.sum()) & U32


def k_sort_scatter(m, p, n):
    ks, vs, kd, vd, off, tot, C, sh, W = P(m, p, 9)
    tt = [int(m.u[m.w(tot) + d]) for d in range(16)]
    for w in range(n):
        base = 0
        o = []
        for d in range(16):
            o.append(int(m.u[m.w(off) + d * W + w]) + base)
            base += tt[d]
        for i in range(C):
            key = int(m.u[m.w(ks) + w * C + i]); val = int(m.u[m.w(vs) + w * C + i])
            d = (key >> sh) & 15
            pos = o[d]; o[d] += 1
            m.u[m.w(kd) + pos] = key; m.u[m.w(vd) + pos] = val
        for d in range(16):
            m.u[m.w(off) + d * W + w] = o[d] & U32


def i2f_m(i):                               # s2.cl i2f: (float)i by the magic constant
    return ((np.int64(int(MB)) + i) & U32).astype(np.uint32).view(np.float32) - M_


def s2_exp(x, C):
    t = (x * C[3]).astype(f32)
    k = rne_i(t)
    kf = negf(i2f_m(k).astype(f32))
    f = (kf * C[4]).astype(f32); f = (f + x).astype(f32)
    q = (kf * C[5]).astype(f32); f = (q + f).astype(f32)
    pp = (f * C[12]).astype(f32); pp = (pp + C[11]).astype(f32)
    for c in (10, 9, 8, 7, 6):
        q = (f * pp).astype(f32); pp = (q + C[c]).astype(f32)
    return ((pp.view(np.uint32).astype(np.int64) + ((k << 23) & U32)) & U32).astype(np.uint32).view(np.float32)


def s2_log(x, C):
    b = x.view(np.uint32).astype(np.int64)
    e = ((b >> 23) & 0xFF) - 127
    mm = ((b & 0x7FFFFF) | 0x3F800000).astype(np.uint32).view(np.float32)
    big = int(C[18:19].view(np.uint32)[0]) < mm.view(np.uint32).astype(np.int64)
    mm = np.where(big, (mm * C[0]).astype(f32), mm).astype(f32)
    e = np.where(big, e + 1, e)
    f = (mm - C[1]).astype(f32)
    g = (f + C[2]).astype(f32)
    s = (f / g).astype(f32)
    z = (s * s).astype(f32)
    R = (z * C[17]).astype(f32); R = (R + C[16]).astype(f32)
    q = (z * R).astype(f32); R = (q + C[15]).astype(f32)
    q = (z * R).astype(f32); R = (q + C[14]).astype(f32)
    R = (R * z).astype(f32)
    ss = (s + s).astype(f32)
    q = (s * R).astype(f32)
    l = (q + ss).astype(f32)
    q = (i2f_m(e).astype(f32) * C[13]).astype(f32)
    return (q + l).astype(f32)


def s2_cndf(x, C):
    sign = x.view(np.uint32) >> 31
    xa = (x.view(np.uint32) & np.uint32(0x7FFFFFFF)).view(np.float32)
    q = (xa * xa).astype(f32); q = (q * C[0]).astype(f32)
    nn = s2_exp(negf(q), C); nn = (nn * C[19]).astype(f32)
    k2 = (C[20] * xa).astype(f32); k2 = (C[1] + k2).astype(f32); k2 = (C[1] / k2).astype(f32)
    k22 = (k2 * k2).astype(f32); k23 = (k22 * k2).astype(f32)
    k24 = (k23 * k2).astype(f32); k25 = (k24 * k2).astype(f32)
    l1 = (k2 * C[21]).astype(f32); l2 = (k22 * C[22]).astype(f32)
    for kk, c in ((k23, 23), (k24, 24), (k25, 25)):
        q = (kk * C[c]).astype(f32); l2 = (l2 + q).astype(f32)
    l1 = (l1 + l2).astype(f32)
    q = (l1 * nn).astype(f32)
    loc = (C[1] - q).astype(f32)
    return np.where(sign != 0, (C[1] - loc).astype(f32), loc).astype(f32)


def k_blackscholes(m, p, n):
    i = np.arange(n, dtype=np.int64)
    Sb, Kb, rb, vb, Tb, cb, pb, Cb = P(m, p, 8)
    C = m.f[idx(m, Cb, np.arange(26))].copy()
    S, K, r, v, T = (m.f[idx(m, b, i)] for b in (Sb, Kb, rb, vb, Tb))
    sq = np.sqrt(T).astype(f32)                 # correctly rounded, as FGPU's fsqrt
    lt = s2_log((S / K).astype(f32), C)
    pw = (v * v).astype(f32); pw = (pw * C[0]).astype(f32)
    d1 = (r + pw).astype(f32); d1 = (d1 * T).astype(f32); d1 = (d1 + lt).astype(f32)
    den = (v * sq).astype(f32)
    d1 = (d1 / den).astype(f32)
    d2 = (d1 - den).astype(f32)
    n1, n2 = s2_cndf(d1, C), s2_cndf(d2, C)
    rt = (r * T).astype(f32)
    fv = (K * s2_exp(negf(rt), C)).astype(f32)
    a = (S * n1).astype(f32); b = (fv * n2).astype(f32)
    m.f[idx(m, cb, i)] = a - b
    o2 = (C[1] - n2).astype(f32); o1 = (C[1] - n1).astype(f32)
    a = (fv * o2).astype(f32); b = (S * o1).astype(f32)
    m.f[idx(m, pb, i)] = a - b


def k_kmeans_part(m, p, n):                 # apps.cl kmeans_part (k-means option (a))
    px, py, cx, cy, K, asg, part, npts, W = P(m, p, 9)
    cxs = [int(m.u[m.w(cx) + k]) for k in range(K)]
    cys = [int(m.u[m.w(cy) + k]) for k in range(K)]
    i = np.arange(npts, dtype=np.int64)
    x = m.u[idx(m, px, i)].astype(np.int64)
    y = m.u[idx(m, py, i)].astype(np.int64)
    best = np.full(npts, 0x7fffffff, dtype=np.int64)
    bk = np.zeros(npts, dtype=np.int64)
    s32 = lambda v: ((v & U32) ^ 0x80000000) - 0x80000000
    for k in range(K):
        dx, dy = s32(x - cxs[k]), s32(y - cys[k])
        d = (dx * dx + dy * dy) & U32
        lt = d < best
        best = np.where(lt, d, best)
        bk = np.where(lt, k, bk)
    m.u[idx(m, asg, i)] = bk.astype(np.uint32)
    w = i % W                               # worker of point i (points w, w + W, ...)
    acc = np.zeros(3 * K * W, dtype=np.int64)
    for a, v in enumerate((x, y, np.ones(npts, dtype=np.int64))):
        np.add.at(acc, (a * K + bk) * W + w, v)
    m.u[idx(m, part, np.arange(3 * K * W))] = (acc & U32).astype(np.uint32)


def k_kmeans_reduce(m, p, n):
    part, sx, sy, cn, K, W = P(m, p, 6)
    tot = m.u[idx(m, part, np.arange(3 * K * W))].astype(np.int64).reshape(3 * K, W).sum(axis=1) & U32
    for a, base in enumerate((sx, sy, cn)):
        m.u[idx(m, base, np.arange(K))] = tot[a * K:(a + 1) * K].astype(np.uint32)


def k_mlpw(m, p, n):                        # apps.cl mlpw: 4 outputs per work-item, word stores
    u = np.arange(n, dtype=np.int64)
    xb, wb, ob, Kp, l2, _, _, mode = P(m, p, 8)
    npd = 1 << l2
    t0 = u << 2
    acc = [np.zeros(n, dtype=np.int64) for _ in range(4)]
    for k in range(Kp):
        xa = m.u[idx(m, xb, (t0 >> l2) * Kp + k)]
        for j in range(4):
            acc[j] = acc[j] + dot8(xa, m.u[idx(m, wb, (t0 & (npd - 1)) + k * npd + j)])
    acc = [((a + 2**31) & U32) - 2**31 for a in acc]
    if mode == 0:
        for j in range(4):
            m.u[idx(m, ob, t0 + j)] = (acc[j] & U32).astype(np.uint32)
        return
    sc, zp = PFv(m, p, 5), PFv(m, p, 6)
    r = sum(requant8(acc[j], sc, zp) << (8 * j) for j in range(4))
    m.u[idx(m, ob, u)] = (r & U32).astype(np.uint32)


def k_conv8w(m, p, n):                      # apps.cl conv8w: 4 channels of one pixel per work-item
    t = np.arange(n, dtype=np.int64)
    X, Wt, Ob, Cw, l2co, l2w4, _, _, Wp = P(m, p, 9)
    Cout, l2w = 1 << l2co, l2w4 + 2
    G = Cout >> 2
    g, q = t & (G - 1), t >> (l2co - 2)
    xp, y = q & ((1 << l2w) - 1), q >> l2w
    acc = [np.zeros(n, dtype=np.int64) for _ in range(4)]
    for ky in range(3):
        for c in range(Cw):
            xr = ((y + ky) * Cw + c) * Wp + xp
            wr = ((ky * Cw + c) * 3) * Cout + 4 * g
            for kx in range(3):
                a = m.u[idx(m, X, xr + kx)]
                for j in range(4):
                    acc[j] = acc[j] + dot8(a, m.u[idx(m, Wt, wr + kx * Cout + j)])
    sc, zp = PFv(m, p, 6), PFv(m, p, 7)
    acc = [((a + 2**31) & U32) - 2**31 for a in acc]
    r = sum(requant8(acc[j], sc, zp) << (8 * j) for j in range(4))
    m.u[idx(m, Ob, ((y + 1) * G + g) * Wp + xp + 1)] = (r & U32).astype(np.uint32)


k_sort_hist2 = k_sort_hist                  # the same counts, from registers


def k_sort_base(m, p, n):                   # off[j] += tot[0] + ... + tot[d-1], d = j / W
    off, tot, W = int(m.u[m.w(p) + 4]), int(m.u[m.w(p) + 5]), int(m.u[m.w(p) + 8])
    tt = [int(m.u[m.w(tot) + d]) for d in range(16)]
    for j in range(n):
        d = j // W
        m.u[m.w(off) + j] = (int(m.u[m.w(off) + j]) + sum(tt[:d])) & U32


def k_sort_scatter2(m, p, n):               # pos = off[d][w] + running count; off not written
    ks, vs, kd, vd, off, tot, C, sh, W = P(m, p, 9)
    for w in range(n):
        cnt = [0] * 16
        for i in range(C):
            key = int(m.u[m.w(ks) + w * C + i]); val = int(m.u[m.w(vs) + w * C + i])
            d = (key >> sh) & 15
            pos = int(m.u[m.w(off) + d * W + w]) + cnt[d]
            cnt[d] += 1
            m.u[m.w(kd) + pos] = key; m.u[m.w(vd) + pos] = val


KERNELS = {k[2:]: v for k, v in globals().items() if k.startswith('k_')}


def check(m, gold, tol):
    gi, gv = [], []
    for line in open(gold):
        a, b = line.split()
        gi.append(int(a, 16)); gv.append(int(b, 16))
    gi = np.array(gi); gv = np.array(gv, dtype=np.uint32)
    got = m.u[gi]
    exact = got == gv
    errs, worst = 0, 0.0
    if tol:
        gmax = float(np.max(np.abs(gv.view(np.float32).astype(np.float64))))
        d = np.abs(got.view(np.float32).astype(np.float64) - gv.view(np.float32).astype(np.float64)) / gmax
        bad = ~exact & ~(d <= 1e-3)
        errs = int(np.count_nonzero(bad))
        worst = float(np.nanmax(np.where(exact, 0, d))) if len(d) else 0.0
    else:
        bad = ~exact
        errs = int(np.count_nonzero(bad))
    first = [(int(gi[i]), int(got[i]), int(gv[i])) for i in np.flatnonzero(bad)[:3]]
    return len(gv), int(np.count_nonzero(exact)), errs, worst, first


def main():
    args = sys.argv[1:]
    out = None                              # --fgpu-gold <cases.txt>: the model's words as gold
    if '--fgpu-gold' in args:
        k = args.index('--fgpu-gold')
        out = args[k + 1]
        del args[k:k + 2]
    cases, hfile = args[0], args[1]
    only = args[2:]
    ent = {int(mm.group(2)): mm.group(1).lower()
           for mm in re.finditer(r'#define\s+(\w+)_POS\s+(\d+)', open(hfile).read())}
    name = mem = None
    tol = 0
    lines = []
    for line in open(cases):
        f = line.split()
        if not f:
            continue
        if f[0] == 'CASE':
            name, tol = f[1], int(f[2])
            keep = not only or any(name.startswith(o) for o in only)
            if keep:
                lines.append(f'CASE {name} 0')
        elif not keep:
            continue
        elif f[0] == 'MEM':
            mem = Mem(f[1])
            lines.append(line.strip())
        elif f[0] == 'LAUNCH':
            k = ent[int(f[1])]
            KERNELS[k](mem, int(f[2], 16), int(f[3]))
            lines.append(line.strip())
        elif f[0] == 'GOLD':
            words, exact, errs, worst, first = check(mem, f[1], tol)
            print(f'MODEL {name}: {words} words, {exact} exact, {errs} errors, worst {worst:.3e}'
                  + (f'  first bad (idx, got, gold): {[(i, hex(g), hex(v)) for i, g, v in first]}' if errs else ''))
            if out:                         # the same words, FGPU's values: the RTL must match exactly
                gi = [int(l.split()[0], 16) for l in open(f[1])]
                gpath = f[1].rsplit('.', 1)[0] + '.fgpu.gold'
                with open(gpath, 'w', newline='\n') as g:
                    g.writelines(f'{i:x} {int(mem.u[i]):08x}\n' for i in gi)
                lines.append(f'GOLD {gpath}')
        elif f[0] == 'END':
            lines.append('END')
    if out:
        open(out, 'w', newline='\n').write('\n'.join(lines) + '\n')
        print(f'{out}: FGPU gold, every word exact (tol 0)')


if __name__ == '__main__':
    with np.errstate(over='ignore', invalid='ignore'):
        main()
