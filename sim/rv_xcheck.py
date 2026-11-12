"""
rv_xcheck.py -- the Python model of sim/gen_rivec.py against kernels/rivec/rv_ref.h, bit for
bit: the SIMTiX and Vortex kernels are checked against the model, the A53 and CVA6 run
rv_ref.h, so the two must agree.

    python sim/rv_xcheck.py        (Windows; runs kernels/rivec/qtest/rv_xcheck.c in WSL)

Inputs: 20,000 exp and 20,000 log arguments, RiVEC's 65,536 Black-Scholes options,
jacobi-2d 32 x 32 for 3 steps, lavaMD 2 x 2 x 2 boxes (2 home boxes).
"""
import os
import random
import struct
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_apps as ga                                    # noqa: E402
import gen_rivec as g                                    # noqa: E402
import gen_suite2 as s2                                  # noqa: E402
import rv_data                                           # noqa: E402

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
QT = os.path.join(ROOT, 'kernels', 'rivec', 'qtest')


def main():
    rng = random.Random(77)
    ex = [ga.rand_f32(rng, -100, 100) for _ in range(10000)] + [ga.rand_f32(rng, -2, 2) for _ in range(10000)]
    lg = [rng.randrange(0x0080_0000, 0x7F80_0000) for _ in range(20000)]
    nb, (S, K, r, v, T), ot, _ = rv_data.blackscholes('in_64K.input')
    jn, js = 32, 3
    b1d, nh = 2, 2
    nbox = b1d ** 3
    rnd = lambda: s2.f32((rng.randrange(10) + 1) / 10.0)
    rv = [rnd() for _ in range(4 * nbox * 96)]
    qv = [rnd() for _ in range(nbox * 96)]
    words = [len(ex)] + ex + [len(lg)] + lg + [nb] + S + K + r + v + T + ot + [jn, js, b1d, nh] + rv + qv
    fin, fout = os.path.join(QT, 'build', 'xin.bin'), os.path.join(QT, 'build', 'xout.bin')
    os.makedirs(os.path.dirname(fin), exist_ok=True)
    open(fin, 'wb').write(struct.pack(f'<{len(words)}I', *[w & 0xFFFF_FFFF for w in words]))
    wsl = lambda p: '/mnt/' + p[0].lower() + p[2:].replace('\\', '/')
    cmd = (f'cd {wsl(QT)} && gcc -O2 -mfma -ffp-contract=off rv_xcheck.c -lm -o build/rvx && '
           f'./build/rvx {wsl(fin)} {wsl(fout)}')
    subprocess.run(['wsl.exe', '-e', 'bash', '-c', cmd], check=True)
    out = list(struct.unpack(f'<{os.path.getsize(fout) // 4}I', open(fout, 'rb').read()))
    bad = 0

    def cmp(name, model, got):
        nonlocal bad
        d = [i for i, (a, b) in enumerate(zip(model, got)) if a != b]
        print(f'{name:14s} {len(model):7d} values, {len(d)} differ' + (f' (first at {d[0]}: model {model[d[0]]:08x} rv_ref {got[d[0]]:08x})' if d else ''))
        bad += len(d)
    p = 0
    cmp('exp', [g.rv_exp(x) for x in ex], out[p:p + len(ex)]); p += len(ex)
    cmp('log', [g.rv_log(x) for x in lg], out[p:p + len(lg)]); p += len(lg)
    cmp('blackscholes', [g.rv_bs(S[i], K[i], r[i], v[i], T[i], ot[i]) for i in range(nb)], out[p:p + nb]); p += nb
    # jacobi: the model of gen_rivec.jacobi, without the case
    A = [g.fdiv(g.fadd(g.fmul(g.i2f(i), g.i2f(j + 2)), s2.f32(2.0)), g.i2f(jn)) for i in range(jn) for j in range(jn)]
    B = [g.fdiv(g.fadd(g.fmul(g.i2f(i), g.i2f(j + 3)), s2.f32(3.0)), g.i2f(jn)) for i in range(jn) for j in range(jn)]
    p02 = g.flit('0.20')

    def sweep(s, d):
        d = list(d)
        for i in range(1, jn - 1):
            for j in range(1, jn - 1):
                q = i * jn + j
                u = g.fadd(g.fadd(s[q], s[q - 1]), s[q + 1])
                d[q] = g.fmul(g.fadd(u, g.fadd(s[q + jn], s[q - jn])), p02)
        return d
    for _ in range(js):
        B = sweep(A, B)
        A = sweep(B, A)
    cmp('jacobi A,B', A + B, out[p:p + 2 * jn * jn]); p += 2 * jn * jn
    # lavaMD: gen_rivec.lavamd's model on these particles
    fv = lava_model(rv, qv, b1d, nh)
    cmp('lavamd', fv, out[p:p + 4 * nh * 96]); p += 4 * nh * 96
    print('RV_XCHECK', 'PASS' if bad == 0 else 'FAIL')
    return bad != 0


def lava_model(rv, qv, b1d, nhome):
    NP = 96
    nn, nei = [], []
    for i in range(b1d):
        for j in range(b1d):
            for k in range(b1d):
                lst = [(i + l) * b1d * b1d + (j + m) * b1d + (k + q)
                       for l in (-1, 0, 1) for m in (-1, 0, 1) for q in (-1, 0, 1)
                       if 0 <= i + l < b1d and 0 <= j + m < b1d and 0 <= k + q < b1d and (l, m, q) != (0, 0, 0)]
                nn.append(len(lst))
                nei += lst + [0] * (26 - len(lst))
    a2, TWO, fv = s2.f32(0.5), s2.f32(2.0), []
    for l in range(nhome):
        for i in range(NP):
            A = rv[4 * (l * NP + i):4 * (l * NP + i) + 4]
            f = [0] * 4
            for pb in [l] + nei[l * 26:l * 26 + nn[l]]:
                for j in range(NP):
                    B = rv[4 * (pb * NP + j):4 * (pb * NP + j) + 4]
                    dot = g.fma(A[3], B[3], g.fma(A[2], B[2], g.fmul(B[1], A[1])))
                    vij = g.rv_exp(g.fneg(g.fmul(g.fsub(g.fadd(B[0], A[0]), dot), a2)))
                    fs = g.fmul(TWO, vij)
                    q = qv[pb * NP + j]
                    f[0] = g.fma(q, vij, f[0])
                    for d in range(3):
                        f[1 + d] = g.fma(q, g.fmul(fs, g.fsub(A[1 + d], B[1 + d])), f[1 + d])
            fv += f
    return fv


if __name__ == '__main__':
    sys.exit(main())
