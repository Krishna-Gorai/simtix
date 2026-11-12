"""
gen_rivec.py -- inputs and bit-exact expected outputs of RiVEC batch 1 (docs/rivec_plan.md)
for tests/tb_apps.sv (and the Vortex testbench).

    python sim/gen_rivec.py [--size small|board] [--out DIR] [--only APP ...]

The machinery is gen_apps.py's (Image, Case, the exactly rounded FP32 operations, the
manifest). The expected values come from an exact model in this file (Fractions, every
operation rounded once to FP32), written from the definitions in docs/rivec_plan.md and
independent of kernels/rivec/rv_ref.h; where RiVEC ships the result with its input
(matmul's C, pathfinder's last row) that is checked as well.

The instruction RAM holds kernels/apps' gemm, gemm_rb, spmv and spmv_z, suite 2's
pathfinder and the kernels of kernels/rivec, as the board host loads them.

Board size: RiVEC's "large" inputs; jacobi-2d with 2 of its 2,000 time steps and lavaMD
with the threads of its first 2 home boxes (of 1,000), as the Rodinia cases shorten their
iterations: the data, the layout and the kernels are those of the board run.
Default output directory: build_rivec/.
"""
import argparse
import os
import random
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_apps as ga                                    # noqa: E402
import gen_suite2 as s2                                  # noqa: E402
import rd_data                                           # noqa: E402
import rv_data                                           # noqa: E402

KDIR_APPS = os.path.join(ga.ROOT, 'kernels', 'apps')
KDIR_S2 = os.path.join(ga.ROOT, 'kernels', 'suite2')
KDIR_RV = os.path.join(ga.ROOT, 'kernels', 'rivec')
APP_KERNELS = ['gemm', 'gemm_rb', 'spmv', 'spmv_z']
S2_KERNELS = ['pathfinder']
RV_KERNELS = ['axpy_rv', 'jacobi_rv', 'bs_rv', 'lavamd_rv']
INF = 0x7FFF_FFFF

fadd, fmul, fma, fsub, fdiv, fsqrt = ga.fadd, ga.fmul, ga.fma, s2.fsub, s2.fdiv, s2.fsqrt
flt, fneg, fabs_, cvt, i2f = s2.flt, s2.fneg, s2.fabs_, s2.fcvt_w_rne, s2.fcvt_s_w
ZERO, ONE = 0, s2.f32(1.0)


def dlit(text):
    """A C double literal stored in a float: rounded to double, then to FP32."""
    return s2.f32(float(text))


def flit(text):
    """A C float literal (suffix f): rounded once to FP32."""
    return rd_data.f32_bits(text)


# rv_ref.h rv_bs_consts, word by word (f: float literal, d: double literal)
BS_C_SRC = [('f', '0.5'), ('f', '1.0'), ('d', '88.3762626647949'), ('d', '-88.3762626647949'),
            ('d', '1.44269504088896341'), ('d', '0.693359375'), ('d', '-2.12194440e-4'),
            ('d', '1.9875691500E-4'), ('d', '1.3981999507E-3'), ('d', '8.3334519073E-3'),
            ('d', '4.1665795894E-2'), ('d', '1.6666665459E-1'), ('d', '5.0000001201E-1'),
            ('d', '0.707106781186547524'),
            ('d', '7.0376836292E-2'), ('d', '-1.1514610310E-1'), ('d', '1.1676998740E-1'),
            ('d', '-1.2420140846E-1'), ('d', '1.4249322787E-1'), ('d', '-1.6668057665E-1'),
            ('d', '2.0000714765E-1'), ('d', '-2.4999993993E-1'), ('d', '3.3333331174E-1'),
            ('d', '-2.12194440e-4'), ('d', '0.693359375'),
            ('d', '0.39894228040143270286'), ('f', '0.2316419'),
            ('f', '0.319381530'), ('f', '-0.356563782'), ('f', '1.781477937'), ('f', '-1.821255978'),
            ('f', '1.330274429'), ('f', '-0.5')]
BS_C = [flit(t) if k == 'f' else dlit(t) for k, t in BS_C_SRC] + [0x0080_0000]
assert len(BS_C) == 34


def fmin_(a, b):
    return b if flt(b, a) else a


def fmax_(a, b):
    return b if flt(a, b) else a


def rv_exp(x):
    """RiVEC __exp_2xf32, one element (rv_ref.h rv_exp)."""
    C = BS_C
    x = fmin_(x, C[2])
    x = fmax_(x, C[3])
    fx = fma(C[4], x, C[0])
    tmp = i2f(cvt(fx))
    fx = fsub(tmp, ONE if flt(fx, tmp) else ZERO)
    t1, z = fmul(fx, C[5]), fmul(fx, C[6])
    x = fsub(fsub(x, t1), z)
    z = fmul(x, x)
    y = C[7]
    for p in C[8:13]:
        y = fma(y, x, p)
    y = fma(y, z, x)
    y = fadd(y, ONE)
    return fmul(y, ((cvt(fx) + 127) << 23) & 0xFFFF_FFFF)     # (uint32_t)e << 23


def rv_log(x):
    """RiVEC __log_2xf32, one element, x > 0 (rv_ref.h rv_log)."""
    C = BS_C
    x = fmax_(x, C[33])
    imm0 = x >> 23
    x = (x & ~0x7F80_0000 & 0xFFFF_FFFF) | 0x3F00_0000
    e = fadd(i2f(imm0 - 127), ONE)
    m = flt(x, C[13])
    tmp = x if m else ZERO
    x = fsub(x, ONE)
    e = fsub(e, ONE if m else ZERO)
    x = fadd(x, tmp)
    z = fmul(x, x)
    y = fma(C[14], x, C[15])
    for p in C[16:23]:
        y = fma(y, x, p)
    y = fmul(y, z)
    y = fma(e, C[23], y)
    y = fsub(y, fmul(z, C[0]))
    x = fadd(x, y)
    return fadd(x, fmul(e, C[24]))


def rv_cndf(x):
    C = BS_C
    neg = flt(x, ZERO)
    xa = fabs_(x)
    n = fmul(rv_exp(fmul(fmul(xa, xa), C[32])), C[25])
    k2 = fdiv(ONE, fma(C[26], xa, ONE))
    k22 = fmul(k2, k2); k23 = fmul(k22, k2); k24 = fmul(k23, k2); k25 = fmul(k24, k2)
    l1 = fmul(k2, C[27])
    l2 = fmul(k22, C[28])
    l2 = fma(k23, C[29], l2)
    l2 = fma(k24, C[30], l2)
    l2 = fma(k25, C[31], l2)
    loc = fsub(ONE, fmul(fadd(l2, l1), n))
    return fsub(ONE, loc) if neg else loc


def rv_bs(S, K, r, v, T, put):
    """rv_ref.h rv_blackscholes, one option."""
    lt = rv_log(fdiv(S, K))
    sq = fsqrt(T)
    fv = rv_exp(fneg(fmul(r, T)))
    pw = fmul(fmul(v, v), BS_C[0])
    d1 = fma(fadd(r, pw), T, lt)
    den = fmul(v, sq)
    d1 = fdiv(d1, den)
    d2 = fsub(d1, den)
    n1, n2 = rv_cndf(d1), rv_cndf(d2)
    fv = fmul(fv, K)
    if put:
        n1, n2 = fsub(ONE, n1), fsub(ONE, n2)
    return fabs_(fsub(fmul(fv, n2), fmul(S, n1)))


# ── the cases ────────────────────────────────────────────────────────────────────
def axpy(rng, n, rivec_inputs):
    """axpy_rv.S: dy = fma(a, dx, dy). RiVEC's inputs are constant (dx 1.83, dy 2.22,
    a 1.53); the small case also runs random vectors."""
    if rivec_inputs:
        dx, dy, a = [dlit('1.83')] * n, [dlit('2.22')] * n, dlit('1.53')
    else:
        dx, dy, a = [ga.rand_f32(rng, -4, 4) for _ in range(n)], [ga.rand_f32(rng, -4, 4) for _ in range(n)], \
            ga.rand_f32(rng, -2, 2)
    c = ga.Case(f'axpy_{n}{"" if rivec_inputs else "_rand"}')
    px, py = c.img.alloc(n, dx), c.img.alloc(n, dy)
    c.launch('axpy', 'axpy_rv', [px, py, a], n)
    c.expect(py, [fma(a, x, y) for x, y in zip(dx, dy)])
    return c


def matmul(name, kernel, rows=None):
    """gemm.S / gemm_rb.S on RiVEC's data_<n>.in; the expected C is RiVEC's own (integer
    data: exact in any order). rows: only the first rows of C (gemm: the threads of those
    rows), for the Vortex testbench, whose launch limit the whole 512^3 product exceeds."""
    m, k, n, a, b, cref = rv_data.matmul(name)
    c = ga.Case(f'matmul_{kernel}_{m}' + (f'_rows{rows}' if rows else ''))
    pa, pb, pc = c.img.alloc(m * k, a), c.img.alloc(k * n, b), c.img.alloc(m * n)
    if rows:
        assert kernel == 'gemm'
        c.launch('mm', kernel, [pa, pb, pc, k, n.bit_length() - 1], rows * n)
        c.expect(pc, cref[:rows * n])
        return c
    threads = m * n // 16 if kernel == 'gemm_rb' else m * n
    c.launch('mm', kernel, [pa, pb, pc, k, n.bit_length() - 1], threads)
    c.expect(pc, cref)
    return c


def spmv(name, kernel):
    """spmv.S / spmv_z.S on y = A^T x, x = 1 (rv_data.spmv: 0-based CSR of the transpose),
    the row's products in order with fma from +0."""
    nr, ia, ja, va, _ = rv_data.spmv(name)
    c = ga.Case(f'spmv_{kernel}_{name}')
    x = [ONE] * nr
    pia, pja, pva, px, py = (c.img.alloc(nr + 1, ia), c.img.alloc(len(ja), ja), c.img.alloc(len(va), va),
                             c.img.alloc(nr, x), c.img.alloc(nr))
    c.launch('spmv', kernel, [pia, pja, pva, px, py], nr)
    y = []
    for r in range(nr):
        s = ZERO
        for q in range(ia[r], ia[r + 1]):
            s = fma(va[q], x[ja[q]], s)
        y.append(s)
    c.expect(py, y)
    return c


def pathfinder(name, runs=1):
    """suite 2's pathfinder.S on RiVEC's data_<size>.in, one launch per row step, the rows
    padded with INT_MAX; the expected last row is RiVEC's own."""
    rows, cols, wall, ref = rv_data.pathfinder(name)
    c = ga.Case(f'pathfinder_{rows}x{cols}')
    pw = c.img.alloc(rows * cols, wall)
    bufs = [c.img.alloc(cols + 2, [INF] + wall[:cols] + [INF]), c.img.alloc(cols + 2, [INF] + [0] * cols + [INF])]
    for r in range(1, rows):
        c.launch(f'row{r}', 'pathfinder', [bufs[(r - 1) & 1], bufs[r & 1], pw + 4 * r * cols, cols], cols)
    c.expect(bufs[(rows - 1) & 1] + 4, ref)
    return c


def jacobi(n, tsteps):
    """jacobi_rv.S, PolyBench's init_array in FP32, tsteps x (A -> B, B -> A), RiVEC's
    vector order per point."""
    A = [fdiv(fadd(fmul(i2f(i), i2f(j + 2)), s2.f32(2.0)), i2f(n)) for i in range(n) for j in range(n)]
    B = [fdiv(fadd(fmul(i2f(i), i2f(j + 3)), s2.f32(3.0)), i2f(n)) for i in range(n) for j in range(n)]
    c = ga.Case(f'jacobi_{n}x{tsteps}')
    pa, pb = c.img.alloc(n * n, A), c.img.alloc(n * n, B)
    p02 = flit('0.20')
    lg = n.bit_length() - 1

    def sweep(s, d):
        d = list(d)
        for i in range(1, n - 1):
            for j in range(1, n - 1):
                q = i * n + j
                u = fadd(fadd(s[q], s[q - 1]), s[q + 1])
                d[q] = fmul(fadd(u, fadd(s[q + n], s[q - n])), p02)
        return d
    for t in range(tsteps):
        c.launch(f'ab{t}', 'jacobi_rv', [pa, pb, lg, p02], n * n)
        B = sweep(A, B)
        c.launch(f'ba{t}', 'jacobi_rv', [pb, pa, lg, p02], n * n)
        A = sweep(B, A)
    c.expect(pa, A)
    c.expect(pb, B)
    return c


def blackscholes(name, nopt):
    """bs_rv.S on the first nopt options of RiVEC's in_<size>.input."""
    n, (S, K, r, v, T), ot, _ = rv_data.blackscholes(name)
    n = min(n, nopt)
    S, K, r, v, T, ot = S[:n], K[:n], r[:n], v[:n], T[:n], ot[:n]
    c = ga.Case(f'bs_{n}')
    ps = [c.img.alloc(n, col) for col in (S, K, r, v, T)]
    pt, pp, pc = c.img.alloc(n, ot), c.img.alloc(n), c.img.alloc(len(BS_C), BS_C)
    c.launch('bs', 'bs_rv', ps + [pt, pp, pc], n)
    c.expect(pp, [rv_bs(S[i], K[i], r[i], v[i], T[i], ot[i]) for i in range(n)])
    return c


def lavamd(rng, b1d, nhome):
    """lavamd_rv.S: b1d^3 boxes of 96 particles (RiVEC's value ranges, (rand()%10+1)/10
    stored as float), the threads of the first nhome home boxes."""
    NP = 96
    nb = b1d ** 3
    nn, nei = [], []
    for i in range(b1d):
        for j in range(b1d):
            for k in range(b1d):
                lst = [(i + l) * b1d * b1d + (j + m) * b1d + (k + q)
                       for l in (-1, 0, 1) for m in (-1, 0, 1) for q in (-1, 0, 1)
                       if 0 <= i + l < b1d and 0 <= j + m < b1d and 0 <= k + q < b1d and (l, m, q) != (0, 0, 0)]
                nn.append(len(lst))
                nei += lst + [0] * (26 - len(lst))
    nei.append(0)                                  # the spare word
    rnd = lambda: s2.f32((rng.randrange(10) + 1) / 10.0)
    rv = [rnd() for _ in range(4 * nb * NP)]
    qv = [rnd() for _ in range(nb * NP)]
    a2 = s2.f32(0.5)
    c = ga.Case(f'lavamd_{b1d}x{nhome}')
    prv, pqv, pfv = c.img.alloc(len(rv), rv), c.img.alloc(len(qv), qv), c.img.alloc(4 * nb * NP)
    pnn, pnei, pc = c.img.alloc(nb, nn), c.img.alloc(len(nei), nei), c.img.alloc(len(BS_C), BS_C)
    c.launch('lava', 'lavamd_rv', [prv, pqv, pfv, pnn, pnei, a2, pc], nhome * NP)
    fv = []
    TWO = s2.f32(2.0)
    for l in range(nhome):
        boxes = [l] + nei[l * 26:l * 26 + nn[l]]
        for i in range(NP):
            A = rv[4 * (l * NP + i):4 * (l * NP + i) + 4]
            f = [ZERO] * 4
            for pb in boxes:
                for j in range(NP):
                    B = rv[4 * (pb * NP + j):4 * (pb * NP + j) + 4]
                    r2 = fadd(B[0], A[0])
                    dot = fmul(B[1], A[1])
                    dot = fma(A[2], B[2], dot)
                    dot = fma(A[3], B[3], dot)
                    vij = rv_exp(fneg(fmul(fsub(r2, dot), a2)))
                    fs = fmul(TWO, vij)
                    q = qv[pb * NP + j]
                    f[0] = fma(q, vij, f[0])
                    for d in range(3):
                        f[1 + d] = fma(q, fmul(fs, fsub(A[1 + d], B[1 + d])), f[1 + d])
            fv += f
    c.expect(pfv, fv)
    return c


MM, SP = 'gemm_rb', 'spmv_z'          # --base: gemm, spmv (Vortex has no port of the v3 variants)
SIZES = {
    'small': [lambda r: axpy(r, 4096, False), lambda r: matmul('data_64.in', MM),
              lambda r: spmv('football', SP), lambda r: pathfinder('data_tiny.in'),
              lambda r: jacobi(32, 2), lambda r: blackscholes('in_512.input', 512),
              lambda r: lavamd(r, 2, 1)],
    'board': [lambda r: axpy(r, 2048 * 1024, True), lambda r: matmul('data_512.in', MM),
              lambda r: spmv('poisson3Db', SP), lambda r: pathfinder('data_large.in'),
              lambda r: jacobi(256, 2), lambda r: blackscholes('in_64K.input', 65536),
              lambda r: lavamd(r, 10, 2)],
}
APPS = ['axpy', 'matmul', 'spmv', 'pathfinder', 'jacobi', 'blackscholes', 'lavamd']


def place_kernels():
    """kernels/apps, then suite 2's pathfinder, then kernels/rivec (16-word slots)."""
    s = 0
    for kdir, names in ((KDIR_APPS, APP_KERNELS), (KDIR_S2, S2_KERNELS), (KDIR_RV, RV_KERNELS)):
        for k in names:
            n = len(open(os.path.join(kdir, k + '.hex')).read().split())
            ga.SLOTS[k] = s
            s += -(-n // 16)
    assert 16 * s <= ga.IRAM_WORDS, f'kernels need {16 * s} words, the instruction RAM has {ga.IRAM_WORDS}'


def write_manifest(cases, out):
    kdir_of = {k: KDIR_APPS for k in APP_KERNELS}
    kdir_of.update({k: KDIR_S2 for k in S2_KERNELS})
    kdir_of.update({k: KDIR_RV for k in RV_KERNELS})
    saved = ga.SLOTS.copy()
    ga.write_manifest(cases, out, None, kdir_of=kdir_of)
    assert ga.SLOTS == saved


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--size', default='small', choices=SIZES)
    ap.add_argument('--out', default=os.path.join(ga.ROOT, 'build_rivec'))
    ap.add_argument('--words-lg', type=int, default=20)
    ap.add_argument('--only', nargs='*')
    ap.add_argument('--base', action='store_true', help='gemm and spmv instead of gemm_rb and spmv_z')
    ap.add_argument('--mm-rows', type=int, help='matmul: only the first rows of C (Vortex testbench)')
    args = ap.parse_args()
    global MM, SP
    if args.base:
        MM, SP = 'gemm', 'spmv'
    if args.mm_rows:
        SIZES[args.size][1] = lambda r: matmul('data_512.in' if args.size == 'board' else 'data_64.in', MM, args.mm_rows)
    ga.KERNELS, ga.OVERLAY, ga.WORDS = APP_KERNELS + S2_KERNELS + RV_KERNELS, [], 1 << args.words_lg
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    place_kernels()
    cases = [f(random.Random(5001 + i)) for i, f in enumerate(SIZES[args.size])
             if not args.only or APPS[i] in args.only]
    write_manifest(cases, out)


if __name__ == '__main__':
    main()
