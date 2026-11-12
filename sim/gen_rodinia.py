"""
gen_rodinia.py -- inputs and bit-exact expected outputs of the Rodinia suite
(docs/rodinia_plan.md) for tests/tb_apps.sv and the Vortex testbench.

    python sim/gen_rodinia.py [--size small|board] [--out DIR] [--only APP ...]

The machinery is gen_apps.py's (Image, Case, the exactly rounded FP32 operations, the
manifest). The instruction RAM holds suite 2's kernels (kernels/suite2) followed by the
Rodinia kernels (kernels/rodinia), as the board host loads them, so the benchmarks that
suite 2 already has (pathfinder, backprop) reuse its kernels and its case builders at
Rodinia's sizes. Default output directory: build_rodinia/.
"""
import argparse
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_apps as ga                                    # noqa: E402
import gen_suite2 as s2                                  # noqa: E402
import rd_data                                           # noqa: E402
import struct

KDIR_S2 = os.path.join(ga.ROOT, 'kernels', 'suite2')
KDIR_RD = os.path.join(ga.ROOT, 'kernels', 'rodinia')
RD_KERNELS = ['bfs', 'hotspot_rd', 'nn', 'hotspot3d', 'gauss_fan1', 'gauss_fan2', 'kmeans_rd']   # kernels/rodinia, after suite 2's
UNSEEN = 0xFFFF_FFFF


# ── bfs: Rodinia's graph file, level-synchronous from node 0 ────────────────────
def bfs(graph):
    """bfs.S (kernels/apps), one launch per level L = 0, 1, ... until no vertex is
    discovered; the output is every node's level (Rodinia's h_cost, -1 unreached)."""
    rowptr, col = rd_data.bfs_graph(graph)
    nv = len(rowptr) - 1
    c = ga.Case(f'bfs_{graph.split(".")[0]}')
    prp, pcol = c.img.alloc(nv + 1, rowptr), c.img.alloc(len(col), col)
    lev = [UNSEEN] * nv
    lev[0] = 0
    plev = c.img.alloc(nv, lev)
    frontier, L, flags = [0], 0, []
    while True:
        pflag = c.img.alloc(1)
        c.launch(f'bfs{L}', 'bfs', [prp, pcol, plev, L, pflag], nv)
        nxt = []
        for v in frontier:
            for u in col[rowptr[v]:rowptr[v + 1]]:
                if lev[u] == UNSEEN:
                    lev[u] = L + 1
                    nxt.append(u)
        flags.append((pflag, 1 if nxt else 0))
        if not nxt:
            break
        frontier, L = nxt, L + 1
    c.expect(plev, lev)
    for a, v in flags:
        c.expect(a, [v])
    return c


# ── hotspot: Rodinia's temp/power files, every cell, clamped neighbours ─────────
def r32(x):
    """x rounded to FP32 (as a Python float): one float operation of the C code."""
    return struct.unpack('<f', struct.pack('<f', x))[0]


def hotspot_consts(n):
    """rd_ref.h rd_hotspot_consts: Rodinia hotspot.cu's constants with its float and
    double steps (one r32 per float result). Bits of rx1 ry1 rz1 amb sdc."""
    t_chip, ch, cw = r32(0.0005), r32(0.016), r32(0.016)
    gh, gw = r32(ch / n), r32(cw / n)
    cap = r32(0.5 * 1.75e6 * t_chip * gw * gh)
    rx = r32(gw / (2.0 * 100 * t_chip * gh))
    ry = r32(gh / (2.0 * 100 * t_chip * gw))
    rz = r32(t_chip / r32(r32(100.0 * gh) * gw))
    max_slope = r32(3.0e6 / (0.5 * t_chip * 1.75e6))
    step = r32(0.001 / max_slope)
    return [s2.f32(v) for v in (r32(1.0 / rx), r32(1.0 / ry), r32(1.0 / rz), 80.0, r32(step / cap))]


def hotspot(n, steps):
    """hotspot_rd.S on Rodinia's temp_<n>/power_<n>, `steps` launches in ping-pong."""
    t, p = rd_data.hotspot_grid(n)
    c = ga.Case(f'hotspot_rd_{n}x{steps}')
    rx1, ry1, rz1, amb, sdc = k = hotspot_consts(n)
    pp = c.img.alloc(n * n, p)
    bufs = [c.img.alloc(n * n, t), c.img.alloc(n * n, t)]
    cur = list(t)
    for st in range(steps):
        c.launch(f'step{st}', 'hotspot_rd', [bufs[st % 2], bufs[(st + 1) % 2], pp, n.bit_length() - 1] + k, n * n)
        nxt = [0] * (n * n)
        for i in range(n):
            iN, iS = max(i - 1, 0), min(i + 1, n - 1)
            for j in range(n):
                jW, jE = max(j - 1, 0), min(j + 1, n - 1)
                q = i * n + j
                tt = cur[q]
                t2 = ga.fadd(tt, tt)
                a = s2.fsub(ga.fadd(cur[iN * n + j], cur[iS * n + j]), t2)
                b = s2.fsub(ga.fadd(cur[i * n + jE], cur[i * n + jW]), t2)
                cc = s2.fsub(amb, tt)
                acc = ga.fma(a, ry1, p[q])
                acc = ga.fma(b, rx1, acc)
                acc = ga.fma(cc, rz1, acc)
                nxt[q] = ga.fma(sdc, acc, tt)
        cur = nxt
    c.expect(bufs[steps % 2], cur)
    return c


# ── nn: Rodinia's hurricane records, distance to the target ────────────────────
def nn(nrec, lat=30.0, lng=90.0):
    """nn.S on the first nrec records of Rodinia's filelist (target -lat 30 -lng 90):
    dist = sqrt(dx*dx + dy*dy), every operation rounded once."""
    loc = rd_data.nn_records()[:2 * nrec]
    c = ga.Case(f'nn_{nrec}')
    la, ln = s2.f32(lat), s2.f32(lng)
    pl, pd = c.img.alloc(2 * nrec, loc), c.img.alloc(nrec)
    c.launch('nn', 'nn', [pl, pd, la, ln], nrec)
    dist = []
    for r in range(nrec):
        dx, dy = s2.fsub(la, loc[2 * r]), s2.fsub(ln, loc[2 * r + 1])
        dist.append(s2.fsqrt(ga.fadd(ga.fmul(dx, dx), ga.fmul(dy, dy))))
    c.expect(pd, dist)
    return c


# ── hotspot3D: Rodinia's temp/power files, a thread per column of layers ───────
def hotspot3d_consts(n, nz):
    """rd_ref.h rd_hotspot3d_consts: bits of cc ce cn ct sdc amb."""
    t_chip, ch, cw = r32(0.0005), r32(0.016), r32(0.016)
    dx, dy, dz = r32(ch / n), r32(cw / n), r32(t_chip / nz)
    cap = r32(0.5 * 1.75e6 * t_chip * dx * dy)
    rx = r32(dy / (2.0 * 100 * t_chip * dx))
    ry = r32(dx / (2.0 * 100 * t_chip * dy))
    rz = r32(dz / r32(r32(100.0 * dx) * dy))
    max_slope = r32(3.0e6 / (0.5 * t_chip * 1.75e6))
    dt = r32(0.001 / max_slope)
    sdc = r32(dt / cap)
    ce, cn, ct = r32(sdc / rx), r32(sdc / ry), r32(sdc / rz)
    cc = r32(1.0 - (2.0 * ce + 2.0 * cn + 3.0 * ct))
    return [s2.f32(v) for v in (cc, ce, cn, ct, sdc, 80.0)]


def hotspot3d(n, nz, iters):
    """hotspot3d.S on Rodinia's temp_<n>x<nz>/power_<n>x<nz>, `iters` launches."""
    t, p = rd_data.hotspot3d_grid(n, nz)
    c = ga.Case(f'hotspot3d_{n}x{nz}x{iters}')
    cc, ce, cn, ct, sdc, amb = k = hotspot3d_consts(n, nz)
    pp = c.img.alloc(len(p), p)
    bufs = [c.img.alloc(len(t), t), c.img.alloc(len(t), t)]
    xy, cur = n * n, list(t)
    for it in range(iters):
        c.launch(f'it{it}', 'hotspot3d', [bufs[it % 2], bufs[(it + 1) % 2], pp, n.bit_length() - 1, nz] + k, xy)
        nxt = [0] * len(cur)
        for z in range(nz):
            zb, zt = max(z - 1, 0), min(z + 1, nz - 1)
            for j in range(n):
                for i in range(n):
                    q = i + j * n + z * xy
                    W, E = (q - 1 if i else q), (q + 1 if i + 1 < n else q)
                    N, S = (q - n if j else q), (q + n if j + 1 < n else q)
                    a = ga.fmul(cc, cur[q])
                    a = ga.fma(ce, cur[W], a)
                    a = ga.fma(ce, cur[E], a)
                    a = ga.fma(cn, cur[S], a)
                    a = ga.fma(cn, cur[N], a)
                    a = ga.fma(ct, cur[i + j * n + zb * xy], a)
                    a = ga.fma(ct, cur[i + j * n + zt * xy], a)
                    a = ga.fma(sdc, p[q], a)
                    nxt[q] = ga.fma(ct, amb, a)
        cur = nxt
    c.expect(bufs[iters % 2], cur)
    return c


# ── gaussian: Rodinia's -s n matrix, Fan1 and Fan2 per elimination step ─────────
def gaussian(n):
    """gauss_fan1.S, gauss_fan2.S: forward elimination without pivoting on the augmented
    n x (n+1) matrix (b in column n); outputs a and the multipliers m."""
    a = rd_data.gaussian_matrix(n)
    c = ga.Case(f'gaussian_{n}')
    s = n + 1
    pa, pm = c.img.alloc(len(a), a), c.img.alloc(n * n)
    m = [0] * (n * n)
    for t in range(n - 1):
        c.launch(f'fan1_{t}', 'gauss_fan1', [pa, pm, n, t], n - 1 - t)
        c.launch(f'fan2_{t}', 'gauss_fan2', [pa, pm, n, t], n + 1 - t)
        piv = a[t * s + t]
        for i in range(t + 1, n):
            m[i * n + t] = s2.fdiv(a[i * s + t], piv)
        for i in range(t + 1, n):
            mi = s2.fneg(m[i * n + t])
            for j in range(t, n + 1):
                a[i * s + j] = ga.fma(mi, a[t * s + j], a[i * s + j])
    c.expect(pa, a)
    c.expect(pm, m)
    return c


# ── kmeans: Rodinia's kdd_cup, the assignment kernel (one iteration) ────────────
def kmeans(n, k=5, nf=34):
    """kmeans_rd.S on the first n points of kdd_cup, centres = the first k points
    (Rodinia's initial choice): one assignment step. The centre update between
    iterations runs on the A53 and is checked on the board."""
    pm = rd_data.kmeans_points('kdd_cup', n, nf)
    fm = [pm[p * nf + j] for j in range(nf) for p in range(n)]          # feature-major
    cen = pm[:k * nf]
    c = ga.Case(f'kmeans_rd_{n}')
    pf, pc, pmem = c.img.alloc(len(fm), fm), c.img.alloc(len(cen), cen), c.img.alloc(n)
    c.launch('kmeans', 'kmeans_rd', [pf, pc, pmem, n, k, nf], n)
    mem = []
    for p in range(n):
        best, idx = None, 0
        for i in range(k):
            ans = 0
            for j in range(nf):
                d = s2.fsub(pm[p * nf + j], cen[i * nf + j])
                ans = ga.fma(d, d, ans)
            if best is None or s2.flt(ans, best):
                best, idx = ans, i
        mem.append(idx)
    c.expect(pmem, mem)
    return c


def place_kernels():
    """Suite 2's kernels from slot 0, then the Rodinia kernels (gen_apps.place_kernels'
    16-word slots); every image is read from its own directory."""
    s = 0
    for kdir, names in ((KDIR_S2, s2.KERNELS), (KDIR_RD, RD_KERNELS)):
        for k in names:
            n = len(open(os.path.join(kdir, k + '.hex')).read().split())
            ga.SLOTS[k] = s
            s += -(-n // 16)
    assert 16 * s <= ga.IRAM_WORDS, f'kernels need {16 * s} words, the instruction RAM has {ga.IRAM_WORDS}'


SIZES = {
    'small': [lambda r: s2.pathfinder(r, 12, 300), lambda r: s2.backprop(r, 512), lambda r: bfs('graph4096.txt'),
              lambda r: hotspot(64, 2), lambda r: nn(2048), lambda r: hotspot3d(64, 8, 2),
              lambda r: gaussian(48), lambda r: kmeans(512)],
    'board': [lambda r: s2.pathfinder(r, 100, 100000), lambda r: s2.backprop(r, 1 << 19),
              lambda r: bfs('graph65536.txt'), lambda r: hotspot(512, 2),
              lambda r: nn(42764), lambda r: hotspot3d(512, 8, 2),
              lambda r: gaussian(256), lambda r: kmeans(65536)],
}
APPS = ['pathfinder', 'backprop', 'bfs', 'hotspot', 'nn', 'hotspot3d', 'gaussian', 'kmeans']


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--size', default='small', choices=SIZES)
    ap.add_argument('--out', default=os.path.join(ga.ROOT, 'build_rodinia'))
    ap.add_argument('--words-lg', type=int, default=20)
    ap.add_argument('--only', nargs='*')
    args = ap.parse_args()
    ga.KERNELS, ga.OVERLAY, ga.WORDS = s2.KERNELS + RD_KERNELS, [], 1 << args.words_lg
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    place_kernels()
    cases = [f(random.Random(4001 + i)) for i, f in enumerate(SIZES[args.size])
             if not args.only or APPS[i] in args.only]
    write_manifest(cases, out)


def write_manifest(cases, out):
    """gen_apps.write_manifest with each kernel's .hex taken from its own directory."""
    kdir_of = {k: KDIR_S2 for k in s2.KERNELS}
    kdir_of.update({k: KDIR_RD for k in RD_KERNELS})
    saved = ga.SLOTS.copy()
    ga.write_manifest(cases, out, None, kdir_of=kdir_of)
    assert ga.SLOTS == saved


if __name__ == '__main__':
    main()
