"""
gen_apps.py -- inputs and bit-exact expected outputs for tests/tb_apps.sv.

    python sim/gen_apps.py [--size small|large|board|dram] [--out DIR] [--lanes L --kdir KDIR]
                           [--words-lg N] [--only APP ...]

For every application case it writes, under DIR (default build_apps/):
    <case>.mem    $readmemh image of the DDR4 model (@<word index> lines)
    <case>.gold   expected words, one "<word index> <value>" pair per line
and DIR/apps.manifest, which tb_apps reads:
    KERNEL <slot> <hex>                    kernel image -> instruction RAM slot
    CASE <name> / MEM <file> / GOLD <file> / END
    LAUNCH <tag> <slot> <param address> <threads> <block_log2>
A slot is 16 words: a kernel in slot s starts at PC 64*s. The kernels are packed
in KERNELS order from their image sizes (the instruction RAM holds 1024 words). Each launch passes the address of its
parameter block in a1 (REG_BASE_A) and the thread count in a4 (REG_N).

--lanes L lays the data out for an L-lane accelerator (a line of stencil padding,
scan blocks of 4*L threads); its kernels come from KDIR, as written by
`kernels/apps/build.py --lanes L --out KDIR`. The default, 8 lanes, uses
kernels/apps.

FP32 results are computed exactly (fractions) and rounded to nearest even once
per operation, so fmadd is a true fused multiply-add. Standard library only.
"""
import argparse
import os
import random
import struct
from fractions import Fraction

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
KDIR = os.path.join(ROOT, 'kernels', 'apps')
KERNELS = ['gemm', 'spmv', 'stencil', 'kmeans', 'bfs', 'scan', 'scan_add', 'mlp', 'gemm_rb',
           'scan_seg', 'scan_segadd', 'stencil_rb', 'kmeans_u', 'zbtest', 'spmv_z']
SLOTS = {}                          # kernel -> first 16-word slot (place_kernels)
IRAM_WORDS = 1024


def place_kernels(kdir):
    """Pack the kernel images into the instruction RAM in 16-word slots."""
    s = 0
    for k in KERNELS:
        n = len(open(os.path.join(kdir, k + '.hex')).read().split())
        SLOTS[k] = s
        s += -(-n // 16)
    assert 16 * s <= IRAM_WORDS, f'kernels need {16 * s} words, the instruction RAM has {IRAM_WORDS}'
DDR_BASE = 0x1000_0000
WORDS = 1 << 20                     # axi_mem_model words in tb_apps: 2^WORDS_LG (--words-lg)
UNSEEN = 0xFFFF_FFFF
LANES = 8                           # --lanes


# ── FP32 with one correct rounding per operation ─────────────────────────────────
def f2fr(bits):
    s, e, m = bits >> 31, (bits >> 23) & 0xFF, bits & 0x7F_FFFF
    assert e != 0xFF, 'inf/nan not used'
    v = Fraction(m, 1 << 149) if e == 0 else \
        Fraction((1 << 23) | m, 1 << 23) * Fraction(2) ** (e - 127)
    return -v if s else v


def fr2f(x):
    """Round a fraction to the nearest FP32 (ties to even); exact zero -> +0."""
    if x == 0:
        return 0
    s = 1 if x < 0 else 0
    x = abs(x)
    n, d = x.numerator, x.denominator
    e = n.bit_length() - d.bit_length()          # 2^e <= x < 2^(e+2)
    if (n << max(0, -e)) < (d << max(0, e)):
        e -= 1                                    # now 2^e <= x < 2^(e+1)
    e = max(e, -126)
    q = e - 23                                    # value of the mantissa LSB
    num, den = (n, d << q) if q >= 0 else (n << -q, d)
    mi, rem = divmod(num, den)
    if 2 * rem > den or (2 * rem == den and mi & 1):
        mi += 1
    if mi == 1 << 24:                             # rounded up into the next binade
        mi, e = 1 << 23, e + 1
    if mi >= 1 << 23:
        ef = e + 127
        assert ef < 255, 'overflow'
        return (s << 31) | (ef << 23) | (mi - (1 << 23))
    return (s << 31) | mi                         # subnormal


def fadd(a, b):     return fr2f(f2fr(a) + f2fr(b))
def fmul(a, b):     return fr2f(f2fr(a) * f2fr(b))
def fma(a, b, c):   return fr2f(f2fr(a) * f2fr(b) + f2fr(c))


def rand_f32(rng, lo=-1.0, hi=1.0):
    return struct.unpack('<I', struct.pack('<f', rng.uniform(lo, hi)))[0]


# ── DDR4 image ───────────────────────────────────────────────────────────────────
class Image:
    def __init__(self):
        self.words = {}
        self.top = DDR_BASE

    def alloc(self, nwords, init=None):
        """Line-aligned buffer of nwords; init is a list (or None for zeros)."""
        addr = self.top
        self.top += (4 * nwords + 31) & ~31
        vals = init if init is not None else [0] * nwords
        assert len(vals) == nwords
        for i, v in enumerate(vals):
            self.words[addr + 4 * i] = v & 0xFFFF_FFFF
        return addr

    def write(self, path):
        with open(path, 'w', newline='\n') as f:
            prev = None
            for a in sorted(self.words):
                i = (a >> 2) & (WORDS - 1)
                if prev is None or i != prev + 1:
                    f.write('@%x\n' % i)
                f.write('%08x\n' % self.words[a])
                prev = i


class Case:
    def __init__(self, name):
        self.name, self.img, self.launches, self.gold = name, Image(), [], {}

    def launch(self, tag, kernel, params, threads, blk=0):
        p = self.img.alloc(len(params), params)
        self.launches.append((tag, SLOTS[kernel], p, threads, blk))

    def expect(self, addr, vals):
        for i, v in enumerate(vals):
            self.gold[addr + 4 * i] = v & 0xFFFF_FFFF


# ── Applications ─────────────────────────────────────────────────────────────────
def gemm(rng, m, n, k, blocked=False):
    """blocked: gemm_rb.S, a 4x4 block of C per thread (M % 4 == 0, N % 4L == 0)."""
    c = Case(f"{'gemmrb' if blocked else 'gemm'}_{m}x{n}x{k}")
    a = [rand_f32(rng) for _ in range(m * k)]
    b = [rand_f32(rng) for _ in range(k * n)]
    pa, pb, pc = c.img.alloc(m * k, a), c.img.alloc(k * n, b), c.img.alloc(m * n)
    if blocked:
        assert m % 4 == 0 and n % (4 * LANES) == 0
        c.launch('gemm', 'gemm_rb', [pa, pb, pc, k, n.bit_length() - 1], m * n // 16)
    else:
        c.launch('gemm', 'gemm', [pa, pb, pc, k, n.bit_length() - 1], m * n)
    out = []
    for r in range(m):
        for col in range(n):
            acc = 0
            for kk in range(k):
                acc = fma(a[r * k + kk], b[kk * n + col], acc)
            out.append(acc)
    c.expect(pc, out)
    return c


def spmv(rng, rows, cols, maxnnz, zba=False):
    """zba: spmv_z.S (pointer walk, sh2add gather; same results)."""
    c = Case(f"{'spmvz' if zba else 'spmv'}_{rows}x{cols}")
    rowptr, col, val = [0], [], []
    for _ in range(rows):
        nz = rng.randint(0, maxnnz)
        col += sorted(rng.sample(range(cols), nz))
        val += [rand_f32(rng) for _ in range(nz)]
        rowptr.append(len(col))
    x = [rand_f32(rng) for _ in range(cols)]
    nnz = max(len(col), 1)
    prp = c.img.alloc(rows + 1, rowptr)
    pcol = c.img.alloc(nnz, col or [0])
    pval = c.img.alloc(nnz, val or [0])
    px, py = c.img.alloc(cols, x), c.img.alloc(rows)
    c.launch('spmv', 'spmv_z' if zba else 'spmv', [prp, pcol, pval, px, py], rows)
    y = []
    for r in range(rows):
        acc = 0
        for j in range(rowptr[r], rowptr[r + 1]):
            acc = fma(val[j], x[col[j]], acc)
        y.append(acc)
    c.expect(py, y)
    return c


def stencil(rng, h, w, sweeps, rows=0):
    """rows: stencil_rb.S, a strip of `rows` points per thread (rows even, h % rows == 0)."""
    c = Case(f"{'stencilrb' if rows else 'stencil'}_{h}x{w}x{sweeps}")
    s = w + 2 * LANES                             # a line of padding each side
    grid = [rand_f32(rng) for _ in range((h + 2) * s)]
    c0 = struct.unpack('<I', struct.pack('<f', 0.5))[0]
    c1 = struct.unpack('<I', struct.pack('<f', 0.125))[0]
    bufs = [c.img.alloc(len(grid), grid), c.img.alloc(len(grid), grid)]
    cur = list(grid)
    for t in range(sweeps):
        src, dst = bufs[t % 2], bufs[(t + 1) % 2]
        if rows:
            assert rows % 2 == 0 and h % rows == 0
            c.launch(f'stencil{t}', 'stencil_rb', [src, dst, w.bit_length() - 1, s, c0, c1, rows],
                     h // rows * w)
        else:
            c.launch(f'stencil{t}', 'stencil', [src, dst, w.bit_length() - 1, s, c0, c1], h * w)
        nxt = list(cur)
        for i in range(h):
            for j in range(w):
                p = (i + 1) * s + LANES + j
                sm = fadd(fadd(cur[p - s], cur[p + s]), fadd(cur[p - 1], cur[p + 1]))
                nxt[p] = fma(c1, sm, fmul(c0, cur[p]))
        cur = nxt
    c.expect(bufs[sweeps % 2], cur)
    return c


def kmeans(rng, npts, k, two=False):
    """two: kmeans_u.S, two points per thread (npts and k even)."""
    c = Case(f"{'kmeansu' if two else 'kmeans'}_{npts}x{k}")
    px = [rng.randrange(1 << 14) for _ in range(npts)]
    py = [rng.randrange(1 << 14) for _ in range(npts)]
    seeds = rng.sample(range(npts), k)
    cx, cy = [px[i] for i in seeds], [py[i] for i in seeds]
    a_px, a_py = c.img.alloc(npts, px), c.img.alloc(npts, py)
    a_cx, a_cy = c.img.alloc(k, cx), c.img.alloc(k, cy)
    a_as, a_sx, a_sy, a_cn = (c.img.alloc(npts), c.img.alloc(k), c.img.alloc(k),
                              c.img.alloc(k))
    if two:
        assert npts % 2 == 0 and k % 2 == 0
    c.launch('kmeans', 'kmeans_u' if two else 'kmeans',
             [a_px, a_py, a_cx, a_cy, k, a_as, a_sx, a_sy, a_cn], npts // 2 if two else npts)
    assign, sx, sy, cn = [], [0] * k, [0] * k, [0] * k
    for x, y in zip(px, py):
        d = [(x - cx[j]) ** 2 + (y - cy[j]) ** 2 for j in range(k)]
        best = d.index(min(d))
        assign.append(best)
        sx[best] += x
        sy[best] += y
        cn[best] += 1
    c.expect(a_as, assign)
    c.expect(a_sx, sx)
    c.expect(a_sy, sy)
    c.expect(a_cn, cn)
    return c


def bfs(rng, nv, deg):
    c = Case(f'bfs_{nv}x{deg}')
    adj = [set() for _ in range(nv)]
    for v in range(1, nv):                        # a random tree keeps it connected
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
    level = [UNSEEN] * nv
    level[0] = 0
    prp, pcol = c.img.alloc(nv + 1, rowptr), c.img.alloc(len(col), col)
    plev = c.img.alloc(nv, level)
    flags = []
    lev, frontier, L = list(level), [0], 0
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


def scan(rng, n):
    c = Case(f'scan_{n}')
    b = 4 * LANES                                 # threads per block (4 warps)
    assert n % b == 0
    vals = [rng.randrange(1 << 16) for _ in range(n)]
    lvl = [0]

    def level(src, m):
        # scan of m (a multiple of b) words at src; returns the address of the result
        out = c.img.alloc(m)
        nb = m // b
        bs = c.img.alloc(-(-nb // b) * b)             # block totals, zero padded
        c.launch(f'scan{lvl[0]}', 'scan', [src, out, bs], m, blk=2)
        lvl[0] += 1
        if nb > 1:
            bsc = level(bs, -(-nb // b) * b)
            c.launch(f'add{lvl[0]}', 'scan_add', [out, bsc], m)
            lvl[0] += 1
        return out

    out = level(c.img.alloc(n, vals), n)
    acc, pre = 0, []
    for v in vals:
        acc = (acc + v) & 0xFFFF_FFFF
        pre.append(acc)
    c.expect(out, pre)
    return c


def scanseg(rng, n, rows=64):
    """scan_seg.S + scan_segadd.S: one warp scans a segment of rows*LANES words (v3)."""
    c = Case(f'scanseg_{n}')
    vals = [rng.randrange(1 << 16) for _ in range(n)]
    lvl = [0]

    def level(src, m):
        # scan of m (a multiple of LANES) words at src; returns the address of the result
        r = min(rows, m // LANES)
        while m % (r * LANES):
            r //= 2
        nseg = m // (r * LANES)
        out = c.img.alloc(m)
        tot = c.img.alloc(-(-nseg // LANES) * LANES)      # segment totals, zero padded
        c.launch(f'seg{lvl[0]}', 'scan_seg', [src, out, tot, r], LANES * nseg)
        lvl[0] += 1
        if nseg > 1:
            tsc = level(tot, -(-nseg // LANES) * LANES)
            c.launch(f'segadd{lvl[0]}', 'scan_segadd', [out, tsc, r], LANES * nseg)
            lvl[0] += 1
        return out

    out = level(c.img.alloc(n, vals), n)
    acc, pre = 0, []
    for v in vals:
        acc = (acc + v) & 0xFFFF_FFFF
        pre.append(acc)
    c.expect(out, pre)
    return c


def zbtest(rng, n):
    """zbtest.S: Zba shNadd, Zbb min/max(u), Zicond czero on random operands."""
    c = Case(f'zbtest_{n}')
    edge = [0, 1, 0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFF, 0xFFFF_FFFE]
    a = [rng.choice(edge) if rng.random() < 0.2 else rng.getrandbits(32) for _ in range(n)]
    b = [rng.choice(edge) if rng.random() < 0.2 else rng.getrandbits(32) for _ in range(n)]
    pa, pb, pr = c.img.alloc(n, a), c.img.alloc(n, b), c.img.alloc(9 * n)
    c.launch('zbtest', 'zbtest', [pa, pb, pr], n)
    sx = lambda v: v - (1 << 32) if v >> 31 else v
    out = []
    for x, y in zip(a, b):
        m = 0xFFFF_FFFF
        out += [(y + (x << 1)) & m, (y + (x << 2)) & m, (y + (x << 3)) & m,
                x if sx(x) < sx(y) else y, min(x, y), x if sx(x) > sx(y) else y, max(x, y),
                0 if (y & 1) == 0 else x, 0 if (y & 1) else x]
    c.expect(pr, out)
    return c


F127 = 0x42FE_0000                                # 127.0f


def requant(acc, scale, zp):
    """mlp.S mode 1: rne(clamp(fmadd(float(acc), scale, zp), 0, 127))."""
    v = f2fr(fma(fr2f(Fraction(acc)), scale, zp))
    v = min(max(v, Fraction(0)), f2fr(F127))
    return round(v)                               # round half to even


def pack8(vals):
    """INT8 values -> little-endian words (len(vals) a multiple of 4)."""
    return [sum((v & 0xFF) << (8 * i) for i, v in enumerate(vals[j:j + 4]))
            for j in range(0, len(vals), 4)]


def mlp(rng, batch, dims):
    """INT8 MLP, dims = [K0, N1, ..., NL]; ReLU between layers, INT32 logits."""
    c = Case(f'mlp_{"x".join(map(str, dims))}_b{batch}')
    scale = struct.unpack('<I', struct.pack('<f', 2.0 ** -10))[0]
    zp = struct.unpack('<I', struct.pack('<f', 3.0))[0]
    x = [[rng.randrange(128) for _ in range(dims[0])] for _ in range(batch)]
    k = dims[0]
    px = c.img.alloc(batch * k // 4, [w for img in x for w in pack8(img)])
    for li, n in enumerate(dims[1:]):
        npad = max(8, 1 << (n - 1).bit_length())
        last = li == len(dims) - 2
        w = [[rng.randrange(-64, 64) if col < n else 0 for col in range(npad)]
             for _ in range(k)]
        wp = [pack8([w[4 * kk + i][col] for i in range(4)])[0]
              for kk in range(k // 4) for col in range(npad)]
        pw = c.img.alloc(len(wp), wp)
        out_words = batch * npad if last else batch * npad // 4
        po = c.img.alloc(out_words)
        c.launch(f'layer{li}', 'mlp', [px, pw, po, k // 4, npad.bit_length() - 1,
                                       scale, zp, 0 if last else 1], batch * npad)
        acc = [[sum(x[b][kk] * w[kk][col] for kk in range(k)) for col in range(npad)]
               for b in range(batch)]
        if last:
            c.expect(po, [a for row in acc for a in row])
        else:
            x = [[requant(a, scale, zp) for a in row] for row in acc]
            c.expect(po, [wd for img in x for wd in pack8(img)])
        px, k = po, npad
    return c


SIZES = {
    'small': [lambda r: gemm(r, 32, 32, 32), lambda r: spmv(r, 512, 512, 16),
              lambda r: stencil(r, 32, 32, 2), lambda r: kmeans(r, 1024, 8),
              lambda r: bfs(r, 1024, 6), lambda r: scan(r, 2048),
              lambda r: mlp(r, 8, [784, 128, 10]), lambda r: zbtest(r, 256)],
    'large': [lambda r: gemm(r, 64, 64, 64), lambda r: spmv(r, 4096, 4096, 16),
              lambda r: stencil(r, 128, 128, 2), lambda r: kmeans(r, 16384, 16),
              lambda r: bfs(r, 16384, 8), lambda r: scan(r, 65536),
              lambda r: mlp(r, 64, [784, 256, 128, 10])],
    # the two input sets of the board host (sw/ps_host/apps.c run_apps): medium,
    # and DRAM-sized (needs --words-lg 24 here and WORDS_LG = 24 in tb_apps)
    'board': [lambda r: gemm(r, 64, 64, 64), lambda r: spmv(r, 4096, 4096, 16),
              lambda r: stencil(r, 128, 128, 4), lambda r: kmeans(r, 16384, 16),
              lambda r: bfs(r, 16384, 8), lambda r: scan(r, 65536),
              lambda r: mlp(r, 16, [784, 256, 128, 10]),
              lambda r: gemm(r, 64, 64, 64, blocked=True), lambda r: scanseg(r, 65536),
              lambda r: stencil(r, 128, 128, 4, rows=16), lambda r: kmeans(r, 16384, 16, two=True),
              lambda r: spmv(r, 4096, 4096, 16, zba=True)],
    'dram':  [lambda r: gemm(r, 256, 256, 256), lambda r: spmv(r, 65536, 65536, 16),
              lambda r: stencil(r, 512, 512, 4), lambda r: kmeans(r, 262144, 16),
              lambda r: bfs(r, 262144, 8), lambda r: scan(r, 1 << 20),
              lambda r: mlp(r, 256, [784, 256, 128, 10]),
              lambda r: gemm(r, 256, 256, 256, blocked=True), lambda r: scanseg(r, 1 << 20),
              lambda r: stencil(r, 512, 512, 4, rows=16), lambda r: kmeans(r, 262144, 16, two=True),
              lambda r: spmv(r, 65536, 65536, 16, zba=True)],
}
APPS = ['gemm', 'spmv', 'stencil', 'kmeans', 'bfs', 'scan', 'mlp', 'gemmrb',   # order of SIZES
        'scanseg', 'stencilrb', 'kmeansu', 'spmvz']
SEED = {'gemmrb': 0, 'scanseg': 5, 'stencilrb': 2, 'kmeansu': 3, 'spmvz': 1}   # the inputs of gemm / scan, for like-for-like comparisons


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--size', default='small', choices=SIZES)
    ap.add_argument('--out', default=os.path.join(ROOT, 'build_apps'))
    ap.add_argument('--lanes', type=int, default=8, choices=(4, 8, 16))
    ap.add_argument('--kdir', default=KDIR, help='kernel images built for --lanes')
    ap.add_argument('--words-lg', type=int, default=20,
                    help='log2 of the DDR4 model words (tb_apps WORDS_LG)')
    ap.add_argument('--only', nargs='*', help='generate only these applications (e.g. gemm bfs)')
    args = ap.parse_args()
    global LANES, WORDS
    LANES = args.lanes
    WORDS = 1 << args.words_lg
    if LANES != 8 and os.path.abspath(args.kdir) == KDIR:
        ap.error('--lanes other than 8 needs --kdir (kernels/apps/build.py --lanes L --out DIR)')
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    p = lambda f: os.path.join(out, f).replace('\\', '/')
    place_kernels(os.path.abspath(args.kdir))
    rng = random.Random(2027)
    if args.size in ('small', 'large'):          # one stream, as the results were made
        cases = [f(rng) for f in SIZES[args.size]]
    else:                                        # a seed per application: --only safe
        cases = [f(random.Random(2027 + SEED.get(APPS[i], i)))
                 for i, f in enumerate(SIZES[args.size]) if not args.only or APPS[i] in args.only]
    with open(p('apps.manifest'), 'w', newline='\n') as man:
        for name, slot in SLOTS.items():
            man.write(f'KERNEL {slot} {os.path.join(os.path.abspath(args.kdir), name + ".hex")}\n'
                      .replace('\\', '/'))
        for c in cases:
            assert c.img.top - DDR_BASE <= 4 * WORDS, f'{c.name} exceeds the DDR model'
            c.img.write(p(c.name + '.mem'))
            with open(p(c.name + '.gold'), 'w', newline='\n') as g:
                for a in sorted(c.gold):
                    g.write('%x %08x\n' % ((a >> 2) & (WORDS - 1), c.gold[a]))
            man.write(f'CASE {c.name}\nMEM {p(c.name + ".mem")}\n')
            for tag, slot, prm, n, blk in c.launches:
                man.write(f'LAUNCH {tag} {slot} {prm:08x} {n} {blk}\n')
            man.write(f'GOLD {p(c.name + ".gold")}\nEND\n')
            print(f'{c.name:22s} {len(c.launches)} launch(es), '
                  f'{(c.img.top - DDR_BASE) // 1024} KB, {len(c.gold)} checked words')
    print('wrote', p('apps.manifest'))


if __name__ == '__main__':
    main()
