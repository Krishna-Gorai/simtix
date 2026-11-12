"""
rv_data.py -- RiVEC's own input files (docs/rivec_plan.md) as word arrays, for the
simulation cases (sim/gen_rivec.py) and for the boards' data blob.

    python sim/rv_data.py [--out build_rivec/rv_data.bin]

RIVEC names the RiVEC checkout (default C:/work/rivec_src/riscv-vectorized-benchmark-suite,
master 32a14ddf). The blob has sim/rd_data.py's layout ('RDDB' header, named arrays at
64-byte boundaries) and is loaded at the same DDR address, 0x7000_0000, by the board
scripts' `rivec` argument; sw/ps_host/rivec.inc finds the arrays by name.

axpy, jacobi-2d and lavaMD generate their inputs on the hosts; they are not in the blob.
"""
import argparse
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rd_data  # noqa: E402  (write_blob, f32_bits)

RIVEC = os.environ.get('RIVEC', 'C:/work/rivec_src/riscv-vectorized-benchmark-suite')
if not os.path.isdir(RIVEC) and os.path.isdir('/mnt/c/work/rivec_src/riscv-vectorized-benchmark-suite'):
    RIVEC = '/mnt/c/work/rivec_src/riscv-vectorized-benchmark-suite'


def fbits(x):
    """A Python float (an FP64 value) as FP32 bits: (float) of a double."""
    return struct.unpack('<I', struct.pack('<f', x))[0]


def matmul(name='data_512.in'):
    """_matmul/input/data_<n>.in: 'm k n', then A (m x k), B (k x n) and RiVEC's C (m x n),
    integers. Returns (m, k, n, A, B, C) as FP32 bits."""
    t = open(os.path.join(RIVEC, '_matmul', 'input', name)).read().split()
    m, k, n = int(t[0]), int(t[1]), int(t[2])
    v = [fbits(float(x)) for x in t[3:]]
    a, b, c = v[:m * k], v[m * k:m * k + k * n], v[m * k + k * n:m * k + k * n + m * n]
    assert len(c) == m * n
    return m, k, n, a, b, c


def spmv(name='poisson3Db'):
    """_spmv/input/<name>.mtx (Matrix Market coordinate, sorted by column) as the 0-based
    CSR of the transpose (row r = the file's column r+1; docs/rivec_plan.md, spmv): values
    read as RiVEC does (%lf) and stored as FP32. Also RiVEC's .verif (FP64 -> FP32 bits).
    Returns (nrows, ia, ja, a, verif)."""
    f = open(os.path.join(RIVEC, '_spmv', 'input', name + '.mtx'))
    for line in f:
        if line[0] != '%':
            m, n, nz = map(int, line.split())
            break
    ia, ja, a = [0] * (n + 1), [], []
    last = 0
    for line in f:
        r, c, v = line.split()
        r, c = int(r) - 1, int(c) - 1
        assert c >= last, f'{name}: entries not sorted by column'
        last = c
        ja.append(r)
        a.append(fbits(float(v)))
        ia[c + 1] += 1
    assert len(a) == nz
    for i in range(n):
        ia[i + 1] += ia[i]
    ver = [fbits(float(x)) for x in open(os.path.join(RIVEC, '_spmv', 'input', name + '.verif'))
           .read().replace(',', ' ').split()]
    return n, ia, ja, a, ver


def pathfinder(name='data_large.in'):
    """_pathfinder/input/<name>: 'rows cols', the wall (rows x cols) and RiVEC's result
    row (cols). Returns (rows, cols, wall, ref)."""
    t = open(os.path.join(RIVEC, '_pathfinder', 'input', name)).read().split()
    rows, cols = int(t[0]), int(t[1])
    v = [int(x) & 0xFFFFFFFF for x in t[2:]]
    assert len(v) == rows * cols + cols
    return rows, cols, v[:rows * cols], v[rows * cols:]


def blackscholes(name='in_64K.input'):
    """_blackscholes/input/<name>: n, then per option 'S K r divq v T type divs DGrefval'
    read with fscanf("%f") (rounded once to FP32). Returns (n, [S, K, r, v, T], type, dg)."""
    lines = open(os.path.join(RIVEC, '_blackscholes', 'input', name)).read().split('\n')
    n = int(lines[0])
    cols, ot, dg = [[] for _ in range(5)], [], []
    for line in lines[1:1 + n]:
        t = line.split()
        for c, i in zip(cols, (0, 1, 2, 4, 5)):
            c.append(rd_data.f32_bits(t[i]))
        ot.append(1 if t[6] == 'P' else 0)
        dg.append(rd_data.f32_bits(t[8]))
    return n, cols, ot, dg


def board_sets():
    m, k, n, a, b, c = matmul()
    sets = [('rv_mm_dims', [m, k, n]), ('rv_mm_a', a), ('rv_mm_b', b), ('rv_mm_c', c)]
    nr, ia, ja, va, ver = spmv()
    sets += [('rv_sp_ia', ia), ('rv_sp_ja', ja), ('rv_sp_a', va), ('rv_sp_verif', ver)]
    rows, cols, wall, ref = pathfinder()
    sets += [('rv_pf_dims', [rows, cols]), ('rv_pf_wall', wall), ('rv_pf_ref', ref)]
    nb, bc, ot, dg = blackscholes()
    sets += [('rv_bs_' + nm, col) for nm, col in zip(('S', 'K', 'r', 'v', 'T'), bc)]
    sets += [('rv_bs_type', ot), ('rv_bs_dg', dg)]
    return sets


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default=os.path.join(os.path.dirname(os.path.abspath(__file__)), '..',
                                                  'build_rivec', 'rv_data.bin'))
    rd_data.write_blob(board_sets(), ap.parse_args().out)
