"""gen_sync_board.py - the board's synchronisation kernels as tb_apps cases, at a lane count.

    python sim/gen_sync_board.py <lanes>      (4, 8 or 16)

The four kernels the board host runs (sw/ps_host/main.c run_reduce, run_hist, run_hist_shared,
run_contend) at its three sizes (1024, 16384, 262144 threads), with the host's inputs (its
hash()) and its reference results as the gold words. Writes one case per manifest,
    build_b<L>/sync/<kernel>_<N>/apps.manifest
for sim/run_lanes_board.sh (`... <L> sync`). The kernels are kernels/sync (8 lanes) or
kernels/sync/l<L> (python kernels/sync/build.py --lanes L). Launches pass the buffers in
a1/a2/a3 (tb_apps LAUNCH with B and C bases), as the host does.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..'))
DDR_BASE = 0x1000_0000
WORDS_LG = 25                     # the DDR4 model of run_lanes_board.sh
WORDS = 1 << WORDS_LG
KERNELS = ['reduce_shfl', 'histogram', 'hist_shared', 'amo_contend']
SIZES = [1024, 16384, 262144]
M32 = 0xFFFF_FFFF


def h(i):
    """main.c hash(): ((i * 2654435761) >> 12) & 0xFFF, in 32-bit arithmetic."""
    return (((i * 2654435761) & M32) >> 12) & 0xFFF


def s32(v):
    return v - (1 << 32) if v & 0x8000_0000 else v


class Image:
    def __init__(self):
        self.words, self.top = {}, DDR_BASE

    def alloc(self, vals):
        addr = self.top
        self.top += (4 * len(vals) + 63) & ~63           # line-aligned (64 B lines at 16 lanes)
        for i, v in enumerate(vals):
            self.words[addr + 4 * i] = v & M32
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


def case(kernel, n, lanes):
    """(image, launch (a, b, c, block_log2), gold {addr: value})"""
    img, gold = Image(), {}
    lg = {4: 2, 8: 3, 16: 4}[lanes]
    if kernel == 'amo_contend':
        a = [h(i) ^ (0x8000_0000 if i & 1 else 0) for i in range(n)]
        kb = [(h(i + 7) - 0x800) & M32 for i in range(2 * n)]
        cc = [0xDEADBEEF] * (4 * n)
        pa, pb, pc = img.alloc(a), img.alloc(kb), img.alloc(cc)
        k, cref = list(kb), list(cc)
        for t in range(n):
            v, b, base = a[t], a[t] & 3, 16 * (t // 8)
            cref[4 * t] = k[base + b]
            k[base + b] = (k[base + b] + v) & M32
            cref[4 * t + 1] = k[base + 4 + b]
            if s32(v) > s32(k[base + 4 + b]):
                k[base + 4 + b] = v
            cref[4 * t + 2] = k[base + 8 + b]
            k[base + 8 + b] = t
        if lanes >= 8:
            # warps own disjoint 8-thread groups: the serial order is ascending tid, so every
            # returned value and every final word is defined
            for i, v in enumerate(k):
                gold[pb + 4 * i] = v
            for i, v in enumerate(cref):
                gold[pc + 4 * i] = v
        else:
            # at 4 lanes two warps share each 8-thread group's words in an undefined order:
            # the returned values and the amoswap finals depend on it. The amoadd finals (the
            # initial value plus every add) and the amomax finals do not, and a lost atomic
            # update would change them: check those exactly.
            for grp in range(len(k) // 16):
                for off in range(8):
                    gold[pb + 4 * (16 * grp + off)] = k[16 * grp + off]
        return img, (pa, pb, pc, 0), gold
    a = [h(i) for i in range(n)]
    pa = img.alloc(a)
    if kernel == 'reduce_shfl':
        pc = img.alloc([0] * (n // lanes))
        for w in range(n // lanes):
            gold[pc + 4 * w] = sum(a[lanes * w:lanes * (w + 1)]) & M32
        return img, (pa, 0, pc, 0), gold
    pc = img.alloc([0] * 16)
    bins = [0] * 16
    for v in a:
        bins[v & 15] += 1
    for b in range(16):
        gold[pc + 4 * b] = bins[b]
    blk = (5 - lg) if kernel == 'hist_shared' else 0     # 32-thread blocks (hist_shared.S)
    return img, (pa, 0, pc, blk), gold


def main():
    lanes = int(sys.argv[1])
    only = sys.argv[2:]                  # optional kernel names
    kdir = os.path.join(ROOT, 'kernels', 'sync') if lanes == 8 else \
        os.path.join(ROOT, 'kernels', 'sync', f'l{lanes}')
    slot, slots = 0, {}
    for k in KERNELS:
        slots[k] = slot
        slot += -(-len(open(os.path.join(kdir, k + '.hex')).read().split()) // 16)
    assert 16 * slot <= 1024, 'kernels exceed the instruction RAM'
    wsl = lambda p: p.replace('\\', '/').replace('C:/', '/mnt/c/')
    for k in KERNELS:
        if only and k not in only:
            continue
        for n in SIZES:
            out = os.path.join(ROOT, f'build_b{lanes}', 'sync', f'{k}_{n}')
            os.makedirs(out, exist_ok=True)
            img, (pa, pb, pc, blk), gold = case(k, n, lanes)
            assert img.top - DDR_BASE <= 4 * WORDS
            name = f'{k}_{n}'
            img.write(os.path.join(out, name + '.mem'))
            with open(os.path.join(out, name + '.gold'), 'w', newline='\n') as g:
                for a in sorted(gold):
                    g.write('%x %08x\n' % ((a >> 2) & (WORDS - 1), gold[a]))
            with open(os.path.join(out, 'apps.manifest'), 'w', newline='\n') as m:
                m.write(f'KERNEL {slots[k]} {wsl(os.path.join(kdir, k + ".hex"))}\n')
                m.write(f'CASE {name}\nMEM {wsl(os.path.join(out, name + ".mem"))}\n')
                m.write(f'LAUNCH {k} {slots[k]} {pa:08x} {n} {blk} {pb:08x} {pc:08x}\n')
                m.write(f'GOLD {wsl(os.path.join(out, name + ".gold"))}\nEND\n')
            print(f'{lanes} lanes {name:22s} {len(gold)} checked words')


if __name__ == '__main__':
    main()
