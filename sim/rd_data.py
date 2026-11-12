"""
rd_data.py -- Rodinia's own input files (docs/rodinia_plan.md, "Inputs") as word arrays,
for the simulation cases (sim/gen_rodinia.py) and for the boards' data blob.

    python sim/rd_data.py [--out build_rodinia/rd_data.bin]

The Rodinia 3.1 data archive (rodinia-3.1-data.tar.gz, SHA-256 b90994d5...4fce8cd8 as
in Rodinia's README) is unpacked outside the repository; RODINIA_DATA names its
rodinia-data directory (default C:/work/rodinia_src/data_dl/x/rodinia-data).

The blob is what the board scripts load into DDR at RD_BLOB (0x7000_0000, used by no
host: SIMTiX's arena is at 0x1000_0000, Ara's at 0x4200_0000, Vortex's windows end at
0x6FFF_FFFF). Layout, all little-endian 32-bit words:
    word 0  'RDDB' (0x42444452)      word 1  number of entries E
    E entries of 8 words: name (24 bytes, NUL-padded), byte offset from the blob start,
                          length in words
    the arrays, each at a 64-byte boundary
kernels/rodinia/rd_ref.h (rd_blob_find) reads it.
"""
import argparse
import os
import struct

DATA = os.environ.get('RODINIA_DATA', 'C:/work/rodinia_src/data_dl/x/rodinia-data')
if not os.path.isdir(DATA) and os.path.isdir('/mnt/c/work/rodinia_src/data_dl/x/rodinia-data'):
    DATA = '/mnt/c/work/rodinia_src/data_dl/x/rodinia-data'      # the same tree from WSL
MAGIC = 0x42444452
BLOB_BASE = 0x7000_0000


def bfs_graph(name):
    """graph<N>.txt (Rodinia bfs): N, then N lines 'start edges', the source (bfs.cu
    ignores it and starts at node 0), the edge count, then 'id cost' per edge.
    Returns (rowptr[N+1], col[E]); bfs.cu's edges of node i are col[start_i ...]."""
    tok = open(os.path.join(DATA, 'bfs', name)).read().split()
    n = int(tok[0])
    starts = [int(tok[1 + 2 * i]) for i in range(n)]
    counts = [int(tok[2 + 2 * i]) for i in range(n)]
    p = 1 + 2 * n
    p += 1                                   # source
    e = int(tok[p]); p += 1
    col = [int(tok[p + 2 * i]) for i in range(e)]
    rowptr = [0]
    for i in range(n):
        assert starts[i] == rowptr[-1], f'{name}: node {i} edges are not contiguous'
        rowptr.append(starts[i] + counts[i])
    assert rowptr[-1] == e
    return rowptr, col


def f32_bits(text):
    """A decimal string as the FP32 bits of fscanf("%f"): the correctly rounded value.
    Rounding to double first and then to FP32 differs from rounding once only when the
    double lies exactly half-way between two FP32 values (its 29 dropped mantissa bits
    are 1 followed by zeros); that case is rounded from the exact decimal value."""
    x = float(text)
    d = struct.unpack('<Q', struct.pack('<d', x))[0]
    if (d & ((1 << 29) - 1)) != 1 << 28:
        return struct.unpack('<I', struct.pack('<f', x))[0]
    from fractions import Fraction
    q = Fraction(text)
    lo = struct.unpack('<f', struct.pack('<f', x))[0]          # one of the two neighbours
    b = struct.unpack('<I', struct.pack('<f', lo))[0]
    cands = [b - 1, b, b + 1] if b & 0x7FFF_FFFF else [b, b + 1]
    val = lambda w: Fraction(struct.unpack('<f', struct.pack('<I', w & 0xFFFF_FFFF))[0])
    best = min(cands, key=lambda w: (abs(val(w) - q), w & 1))  # ties to even
    return best & 0xFFFF_FFFF


def hotspot_grid(n):
    """temp_<n> and power_<n> (Rodinia hotspot): n*n values each, row-major, one per line."""
    t = [f32_bits(v) for v in open(os.path.join(DATA, 'hotspot', f'temp_{n}')).read().split()]
    p = [f32_bits(v) for v in open(os.path.join(DATA, 'hotspot', f'power_{n}')).read().split()]
    assert len(t) == n * n and len(p) == n * n, f'hotspot {n}: {len(t)}, {len(p)} values'
    return t, p


def nn_records(files=('cane4_0.db', 'cane4_1.db', 'cane4_2.db', 'cane4_3.db')):
    """Rodinia nn's records (filelist.txt): characters 28-32 and 33-37 of each 48-character
    line are the latitude and longitude, read with atof and stored as float, i.e. rounded
    to double and then to FP32. Returns the (lat, lng) bits, interleaved."""
    out = []
    for f in files:
        for line in open(os.path.join(DATA, 'nn', f)).read().splitlines():
            if len(line) < 38:
                continue
            for txt in (line[28:33], line[33:38]):
                out.append(struct.unpack('<I', struct.pack('<f', float(txt)))[0])
    return out


def hotspot3d_grid(n, nz):
    """temp_<n>x<nz> and power_<n>x<nz> (Rodinia hotspot3D): the file runs row i, column
    j, layer k fastest; 3D.cu stores value (i, j, k) at word i*n + j + k*n*n. Read with
    sscanf("%f"): rounded once."""
    out = []
    for kind in ('temp', 'power'):
        v = open(os.path.join(DATA, 'hotspot3D', f'{kind}_{n}x{nz}')).read().split()
        assert len(v) == n * n * nz, f'hotspot3D {kind} {n}x{nz}: {len(v)} values'
        g = [0] * (n * n * nz)
        for idx, txt in enumerate(v):
            i, rest = divmod(idx, n * nz)
            j, k = divmod(rest, nz)
            g[i * n + j + k * n * n] = f32_bits(txt)
        out.append(g)
    return out[0], out[1]


def gaussian_matrix(n):
    """Rodinia gaussian -s n (create_matrix): coe_i = 10*exp(lamda*i) with float lamda =
    -0.01 and float lamda*i, exp in double (computed here with decimal and rounded to
    double, so that every platform makes the same bits), 10*exp in double, stored as
    float; a[i][j] = coe[n-1-i+j]; b = 1.0. Returned as the augmented n x (n+1) matrix
    (b in column n)."""
    from decimal import Decimal, getcontext
    getcontext().prec = 40
    r32 = lambda x: struct.unpack('<f', struct.pack('<f', x))[0]
    lam = r32(-0.01)
    coe = [0.0] * (2 * n - 1)
    for i in range(n):
        e = float(Decimal(r32(lam * i)).exp())
        ci = r32(10.0 * e)
        coe[n - 1 + i] = coe[n - 1 - i] = ci
    one = struct.unpack('<I', struct.pack('<f', 1.0))[0]
    out = []
    for i in range(n):
        out += [struct.unpack('<I', struct.pack('<f', coe[n - 1 - i + j]))[0] for j in range(n)] + [one]
    return out


def atof(text):
    """C's atof: the longest leading decimal number, 0.0 when there is none. kdd_cup's
    line 485,797 holds the strings tcp, http and SF, which Rodinia reads as 0."""
    import re
    m = re.match(r'\s*[+-]?(\d+\.?\d*([eE][+-]?\d+)?|\.\d+([eE][+-]?\d+)?)', text)
    return float(m.group(0)) if m else 0.0


def kmeans_points(name='kdd_cup', n=None, nf=34):
    """Rodinia kmeans input (kmeans.c): per line an id, then nf features read with atof
    into a float, i.e. rounded to double and then to FP32. Point-major bits."""
    out, cnt = [], 0
    for line in open(os.path.join(DATA, 'kmeans', name)):
        tok = line.split()
        if not tok:
            continue
        out += [struct.unpack('<I', struct.pack('<f', atof(t)))[0] for t in tok[1:1 + nf]]
        cnt += 1
        if n and cnt == n:
            break
    return out


# The board data sets: name -> list of (array name, words)
def board_sets():
    rp, col = bfs_graph('graph65536.txt')
    sets = [('bfs65536_rowptr', rp), ('bfs65536_col', col)]
    for n in (512, 1024):
        t, p = hotspot_grid(n)
        sets += [(f'hotspot{n}_temp', t), (f'hotspot{n}_power', p)]
    sets.append(('nn42764_loc', nn_records()))
    t, p = hotspot3d_grid(512, 8)
    sets += [('hs3d512x8_temp', t), ('hs3d512x8_power', p)]
    sets.append(('gauss1024_a', gaussian_matrix(1024)))
    sets.append(('kdd_cup_feat', kmeans_points('kdd_cup')))
    return sets


def write_blob(arrays, path):
    hdr = 8 + 32 * len(arrays)
    off = -(-hdr // 64) * 64
    entries, body = [], bytearray()
    for name, words in arrays:
        assert len(name) < 24
        pad = (off + len(body)) % 64
        if pad:
            body += bytes(64 - pad)
        entries.append((name, off + len(body), len(words)))
        body += struct.pack(f'<{len(words)}I', *[w & 0xFFFF_FFFF for w in words])
    out = bytearray(struct.pack('<II', MAGIC, len(arrays)))
    for name, o, n in entries:
        out += name.encode().ljust(24, b'\0') + struct.pack('<II', o, n)
    out += bytes(off - len(out))
    out += body
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    open(path, 'wb').write(out)
    for name, o, n in entries:
        print(f'{name:24s} {n:10d} words at +0x{o:08x}')
    print(f'wrote {path}: {len(out)} bytes (DDR 0x{BLOB_BASE:08x}-0x{BLOB_BASE + len(out) - 1:08x})')


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default=os.path.join(os.path.dirname(os.path.abspath(__file__)), '..',
                                                  'build_rodinia', 'rd_data.bin'))
    write_blob(board_sets(), ap.parse_args().out)
