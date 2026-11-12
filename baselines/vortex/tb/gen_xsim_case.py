"""
gen_xsim_case.py - input files of tb_vortex_xsim.sv (the board build's exact configuration
in xsim, FPU_TYPE=DSP) from a gen_apps case and the kernel image.

    python gen_xsim_case.py <kernel.vxbin> <apps.manifest> <case> <outdir>

Writes into outdir:
  mem.txt     "<ddr byte address hex> <word hex>": the kernel image at DDR 0x5000_0000
              (Vortex 0x8000_0000) and the case's image at its own addresses (Vortex's
              identity window 0x1000_0000-0x1FFF_FFFF)
  launch.txt  "<app> <param address> <threads> <block> <lmem bytes>" per launch, after a
              first line "<image base> <main pc>"
  gold.txt    "<ddr byte address hex> <word hex>"
"""
import os
import struct
import sys

APPS = ['gemm', 'spmv', 'stencil', 'kmeans', 'bfs', 'scan', 'scan_add', 'mlp',
        'conv8', 'embag', 'hashj', 'mandel', 'swat']
NT = 8

vxbin, manifest, case, out = sys.argv[1:5]
os.makedirs(out, exist_ok=True)
b = open(vxbin, 'rb').read()
min_vma, max_vma = struct.unpack_from('<QQ', b, 0)
footer, main_pc = 0, min_vma
if b[-8:] == b'VXSYMTAB':
    n = struct.unpack_from('<I', b, len(b) - 12)[0]
    ents = [struct.unpack_from('<IHHQ', b, len(b) - 12 - 16 * n + 16 * i) for i in range(n)]
    blob_len = max(o + l for o, l, _, _ in ents)
    footer = 12 + 16 * n + blob_len
    blob = b[len(b) - footer:len(b) - footer + blob_len]
    for o, l, _, pc in ents:
        if blob[o:o + l] == b'main':
            main_pc = pc
img = b[16:len(b) - footer]
img += b'\0' * (max_vma - min_vma - len(img))
img += b'\0' * (-len(img) % 4)

slot_app, cur, cases = {}, None, {}
for line in open(manifest):
    t = line.split()
    if not t:
        continue
    if t[0] == 'KERNEL':
        name = os.path.splitext(os.path.basename(t[2]))[0]
        slot_app[int(t[1])] = APPS.index(name) if name in APPS else -1
    elif t[0] == 'CASE':
        cur = cases[t[1]] = {'launches': []}
    elif t[0] in ('MEM', 'GOLD'):
        cur[t[0]] = t[1]
    elif t[0] == 'LAUNCH':
        cur['launches'].append((slot_app[int(t[2])], int(t[3], 16), int(t[4]), int(t[5])))
c = cases[case]

with open(os.path.join(out, 'mem.txt'), 'w') as f:
    for i in range(0, len(img), 4):
        f.write('%08x %08x\n' % (0x50000000 + i, int.from_bytes(img[i:i + 4], 'little')))
    addr = 0x10000000
    for tok in open(c['MEM']).read().split():
        if tok[0] == '@':
            addr = 0x10000000 + 4 * int(tok[1:], 16)
            continue
        f.write('%08x %s\n' % (addr, tok))
        addr += 4
with open(os.path.join(out, 'launch.txt'), 'w') as f:
    f.write('%08x %08x\n' % (min_vma, main_pc))
    for app, prm, thr, blk in c['launches']:
        block = (NT << blk) if APPS[app] == 'scan' else 32
        while thr % block:
            block >>= 1
        lmem = (block // NT) * 4 if APPS[app] == 'scan' else 0
        f.write('%d %08x %d %d %d\n' % (app, prm, thr, block, lmem))
with open(os.path.join(out, 'gold.txt'), 'w') as f:
    for line in open(c['GOLD']):
        i, v = line.split()
        f.write('%08x %s\n' % (0x10000000 + 4 * int(i, 16), v))
print('%s: %d launches, image %d bytes, main 0x%08x' % (case, len(c['launches']), len(img), main_pc))
