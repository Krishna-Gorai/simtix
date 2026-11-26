#!/usr/bin/env python3
"""gen_fgpu_cases.py - SIMTiX's simulation cases (sim/gen_*.py manifests) as FGPU testbench input
(tb_fgpu_apps.sv), docs/fgpu_plan.md phase 1.

    python baselines/fgpu/tb/gen_fgpu_cases.py <apps.manifest> <fgpu kernel .h> <out.txt> [case ...]

The FGPU kernels read the same parameter blocks as the SIMTiX kernels, so a case keeps its memory
image (.mem), launches and expected words (.gold); only the kernel slot of each LAUNCH becomes the
FGPU kernel's entry word (the <NAME>_POS of the compiler's .h). Writes lines
    CASE <name> <tol>        tol 0: every word exact; 1: FP outputs within 1e-3 of the case's
                             largest |gold| (definitions with fused multiply-adds, which FGPU
                             computes as a multiply and an add)
    MEM <file>
    LAUNCH <entry> <param address hex> <work-items>
    GOLD <file>
    END
"""
import re
import sys

SLOT_KERNEL = {   # kernel image stem of the SIMTiX manifest -> (FGPU kernel, work-item factor)
    'pathfinder': ('pathfinder', 1), 'bp_forward': ('bp_forward', 1), 'bp_adjust': ('bp_adjust', 1),
    'hotspot_rd': ('hotspot_rd', 1), 'nn': ('nn', 1), 'hotspot3d': ('hotspot3d', 1),
    'gauss_fan1': ('gauss_fan1', 1), 'gauss_fan2': ('gauss_fan2', 1), 'kmeans_rd': ('kmeans_rd', 1),
    'bfs': ('bfs', 1),
    # RiVEC: SIMTiX's GEMM-RB (a 4 x 4 block per thread) and SpMV-Z read the parameter blocks of
    # the base kernels, which FGPU runs as Vortex does (one output per work-item)
    'gemm': ('gemm', 1), 'gemm_rb': ('gemm', 16), 'spmv': ('spmv', 1), 'spmv_z': ('spmv', 1),
    'axpy_rv': ('axpy_rv', 1), 'jacobi_rv': ('jacobi_rv', 1), 'bs_rv': ('bs_rv', 1),
    'lavamd_rv': ('lavamd_rv', 1),
    # suite 1 (sim/gen_apps.py, kernels/apps; phase 2): gemm, spmv and bfs above; the overlay
    # kernels (conv8 ... swat) share one slot, each case's own KERNEL line names it
    'stencil': ('stencil', 1), 'kmeans': ('kmeans', 1), 'scan': ('scan', 1),
    'scan_add': ('scan_add', 1), 'mlp': ('mlpw', 0.25), 'conv8': ('conv8w', 1), 'embag': ('embag', 1),
    # mlpw / conv8w: the word-store versions (FGPU stores every sb as a whole word); mlpw does
    # four outputs per work-item
    'hashj': ('hashj', 1), 'mandel': ('mandel', 1), 'swat': ('swat', 1),
    # suite 2 (sim/gen_suite2.py, kernels/suite2; phase 3): pathfinder and backprop above
    'hotspot': ('hotspot', 1), 'jacobi2d': ('jacobi2d', 1), 'mv_row': ('mv_row', 1),
    'mv_col': ('mv_col', 1), 'pr_contrib': ('pr_contrib', 1), 'pr_pull': ('pr_pull', 1),
    'cc_step': ('cc_step', 1), 'rs_hist': ('sort_hist2', 1), 'rs_scan': ('sort_scan', 1),
    'rs_scatter': ('sort_scatter2', 1),   # + sort_base before it (no in-kernel read-after-write)
    'blackscholes': ('blackscholes', 1),   # s2.cl: sort_*
}
FMA_CASES = ('hotspot', 'backprop', 'gaussian',      # Rodinia: hotspot_rd, hotspot3d, ...
             'axpy', 'spmv', 'bs_', 'lavamd',       # RiVEC (matmul: integer data, exact)
             'gemm_',                               # suite 1 (spmv above; stencil and mandel's
                                                    # products are exact, the rest integer)
             'atax', 'bicg', 'pagerank', 'blackscholes')   # suite 2 (hotspot, backprop above;
                                                    # jacobi2d has no fma; cc, sort integer)

KM_W = 512        # kmeans_part's workers (sw/ps_host/apps.c FG_KM_W): W = min(KM_W, points)
WORDS = 1 << 20   # tb_fgpu_apps.sv's memory, word index = (byte address >> 2) mod WORDS


def read_mem(path):
    mem, a = {}, 0
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        if line[0] == '@':
            a = int(line[1:], 16)
            continue
        mem[a % WORDS] = int(line, 16)
        a += 1
    return mem


def kmeans_two_kernels(mem_path, pa):
    """Suite 1's kmeans (one launch, atomic cluster sums) as FGPU runs it (option (a),
    docs/fgpu_plan.md): kmeans_part over W workers, then kmeans_reduce over 3K work-items.
    Writes <case>.fgpu.mem = the case's memory + the two parameter blocks + the partial sums;
    returns its path and the two launches (entry, parameter address, work-items)."""
    mem = read_mem(mem_path)
    base = (int(pa, 16) >> 2) % WORDS
    px, py, cx, cy, K, asg, sx, sy, cn = (mem.get(base + i, 0) for i in range(9))
    npts = KM_NPTS                                           # the launch's work-items: the points
    W = min(KM_W, npts)
    top = (max(mem) + 16) & ~15
    hi = int(pa, 16) & ~((WORDS << 2) - 1)                   # the case's address window
    addr = lambda w: hi + 4 * w
    pf, pr, part = top, top + 16, top + 32
    blocks = {pf: [px, py, cx, cy, K, asg, addr(part), npts, W],
              pr: [addr(part), sx, sy, cn, K, W]}
    out = mem_path[:-len('.mem')] + '.fgpu.mem'
    with open(out, 'w', newline='\n') as f:
        f.write(open(mem_path).read().rstrip('\n') + '\n')
        for w0, words in blocks.items():
            f.write(f'@{w0:x}\n' + ''.join(f'{v:08x}\n' for v in words))
        f.write(f'@{part:x}\n' + '00000000\n' * (3 * K * W))
    return out, [(pos['kmeans_part'], f'{addr(pf):08x}', W), (pos['kmeans_reduce'], f'{addr(pr):08x}', 3 * K)]


manifest, hfile, out = sys.argv[1:4]
only = sys.argv[4:]
pos = {m.group(1).lower(): int(m.group(2))
       for m in re.finditer(r'#define\s+(\w+)_POS\s+(\d+)', open(hfile).read())}
slot_entry, lines, keep = {}, [], True
for line in open(manifest):
    f = line.split()
    if not f:
        continue
    if f[0] == 'KERNEL':
        stem = f[2].replace('\\', '/').rsplit('/', 1)[1].rsplit('.', 1)[0]
        if stem in SLOT_KERNEL:
            k, mul = SLOT_KERNEL[stem]
            slot_entry[int(f[1])] = (pos[k], mul)
    elif f[0] == 'CASE':
        keep = not only or any(f[1].startswith(o) for o in only)
        if keep:
            lines.append(f'CASE {f[1]} {int(f[1].startswith(FMA_CASES))}')
    elif not keep:
        continue
    elif f[0] == 'LAUNCH':
        slot, pa, n = int(f[2]), f[3], int(f[4])
        if slot not in slot_entry:
            sys.exit(f'no FGPU kernel for slot {slot} ({line.strip()})')
        entry, mul = slot_entry[slot]
        if entry == pos.get('kmeans') and 'kmeans_part' in pos:
            # suite 1's kmeans: FGPU's atomics serve one address per kernel, so the two kernels
            KM_NPTS = n
            mem_new, launches = kmeans_two_kernels(case_mem, pa)
            lines[mem_line] = f'MEM {mem_new}'
            lines += [f'LAUNCH {e} {a} {m}' for e, a, m in launches]
        elif entry == pos.get('sort_scatter2') and 'sort_base' in pos:
            # FGPU's sort: sort_base (16 W work-items) adds the digit bases first
            W = read_mem(case_mem).get(((int(pa, 16) >> 2) % WORDS) + 8, 0)
            lines.append(f'LAUNCH {pos["sort_base"]} {pa} {16 * W}')
            lines.append(f'LAUNCH {entry} {pa} {int(n * mul)}')
        else:
            lines.append(f'LAUNCH {entry} {pa} {int(n * mul)}')
    elif f[0] in ('MEM', 'GOLD'):
        if f[0] == 'MEM':
            case_mem, mem_line = f[1].replace(chr(92), '/'), len(lines)
        lines.append(f'{f[0]} {f[1].replace(chr(92), "/")}')
    elif f[0] == 'END':
        lines.append('END')
open(out, 'w', newline='\n').write('\n'.join(lines) + '\n')
print(f'{out}: {sum(l.startswith("CASE") for l in lines)} cases, '
      f'{sum(l.startswith("LAUNCH") for l in lines)} launches')
