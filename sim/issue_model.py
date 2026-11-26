"""issue_model.py - cycle model of SIMTiX's issue stage, single and dual issue.

    python sim/issue_model.py <issue_trace.txt> [--dual] [--only N] [--verbose]

Input: the issue trace of a simulation built with SIMTIX_ISSUE_TRACE (warp_pool.sv): every
issued instruction of every warp, when each pending result was written and when a parked
warp resumed. The model replays each warp's instruction stream, in program order, under
the issue rules of warp_pool.sv, with each instruction's latency as measured in the trace
(issue to result write, or issue to resume for a parked warp):

  - fetch picks one runnable warp per cycle, round robin after the last one fetched; the
    instruction issues (X) in the next cycle; a warp is not fetched while its previous
    instruction is in X, nor until stage B after a branch or jump;
  - at X the register scoreboard holds back an instruction that reads or rewrites a pending
    register, a load beyond LD_MAX loads in flight, a store/AMO/barrier/ecall with loads in
    flight, an ecall with results pending, or an op whose unit holds 8 ops: the slot is
    lost and the warp sleeps until one of its results is written (any result, if its unit
    was full);
  - the memory engine takes one memory instruction per cycle; its coalescer sends one line
    request per cycle, so a memory op's result is no earlier than its lines allow;
  - one divide/sqrt instruction is in flight at a time; a barrier releases when every live
    warp of the block has arrived; the spawner places one warp per cycle in a free slot
    (whole blocks into aligned groups).

--dual: two half-schedulers, one over the even slots and one over the odd slots (register
files split by warp parity), each fetching one warp per cycle; in X the two instructions
issue together unless they use the same unit class (ALU incl. branches and pops, FPU, MUL,
DOT, shuffle, memory, divide), and barriers, ecalls and CSR reads pair with nothing; on a
conflict the older-priority side issues and the other retries next cycle.

Validation: in single-issue mode the model must reproduce the RTL's cycles (the E line).
"""
import argparse
import collections
import sys

NW, LD_MAX, RQ, B2B, TAGS = 8, 2, 8, 1, 16
OP_LOAD, OP_LOADFP, OP_STORE, OP_STOREFP = 0x03, 0x07, 0x23, 0x27
OP_OP, OP_OPIMM, OP_LUI, OP_AUIPC = 0x33, 0x13, 0x37, 0x17
OP_JAL, OP_JALR, OP_BRANCH, OP_SYSTEM = 0x6F, 0x67, 0x63, 0x73
OP_AMO, OP_FP, OP_CUSTOM0 = 0x2F, 0x53, 0x0B
OP_FMA = (0x43, 0x47, 0x4B, 0x4F)
F7_DOT, F7_SHFL, F7_BAR = 0x00, None, None          # set from the package below
FP_ADD, FP_SUB, FP_MUL, FP_DIV, FP_SQRT = 0x00, 0x01, 0x02, 0x03, 0x0B
FP_SGNJ, FP_MINMAX, FP_CMP, FP_CVT_W, FP_CVT_S, FP_FMVXW, FP_FMVWX = 0x04, 0x05, 0x14, 0x18, 0x1A, 0x1C, 0x1E
AMO_LR, AMO_SC = 0x02, 0x03
ALU, FPU, MUL, DOT, SHF, MEM, SFU, OTH = range(8)
CNAME = ['alu', 'fpu', 'mul', 'dot', 'shf', 'mem', 'sfu', 'oth']


def read_pkg_consts():
    """F7 codes of the custom-0 instructions and FP funct5 codes, from simtix_pkg.sv."""
    import os
    import re
    global F7_DOT, F7_SHFL, F7_BAR, FP_ADD, FP_SUB, FP_MUL, FP_DIV, FP_SQRT
    global FP_SGNJ, FP_MINMAX, FP_CMP, FP_CVT_W, FP_CVT_S, FP_FMVXW, FP_FMVWX, AMO_LR, AMO_SC
    p = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'rtl', 'accel', 'simtix_pkg.sv')
    s = open(p).read()

    def val(name):
        m = re.search(r"\b%s\s*=\s*(\d+)'b([01_]+)" % name, s)
        return int(m.group(2).replace('_', ''), 2)
    F7_DOT, F7_SHFL, F7_BAR = val('F7_DOT'), val('F7_SHFL'), val('F7_BAR')
    FP_ADD, FP_SUB, FP_MUL, FP_DIV, FP_SQRT = (val(n) for n in ('FP_ADD', 'FP_SUB', 'FP_MUL', 'FP_DIV', 'FP_SQRT'))
    FP_SGNJ, FP_MINMAX, FP_CMP, FP_CVT_W = (val(n) for n in ('FP_SGNJ', 'FP_MINMAX', 'FP_CMP', 'FP_CVT_W'))
    FP_CVT_S, FP_FMVXW, FP_FMVWX = (val(n) for n in ('FP_CVT_S', 'FP_FMVXW', 'FP_FMVWX'))
    AMO_LR, AMO_SC = val('AMO_LR'), val('AMO_SC')


class Ins:
    __slots__ = ('pop', 'cls', 'src', 'dst', 'pend', 'ld', 'st', 'block', 'bar', 'ecall', 'ctl',
                 'g', 't', 'lat', 'unit', 'icomp', 'woff')


def decode(iw, g):
    i = Ins()
    i.pop, i.g = False, g
    op, f3, f5, f7 = iw & 0x7F, (iw >> 12) & 7, iw >> 27, iw >> 25
    rd, rs1, rs2, rs3 = (iw >> 7) & 31, (iw >> 15) & 31, (iw >> 20) & 31, iw >> 27
    fp, fma = op == OP_FP, op in OP_FMA
    fsx = fp and f5 in (FP_CVT_S, FP_FMVWX)
    fid = fp and f5 in (FP_CMP, FP_CVT_W, FP_FMVXW)
    amo = op == OP_AMO and f3 == 2 and f5 not in (AMO_LR, AMO_SC)
    sfu = fp and f5 in (FP_DIV, FP_SQRT)
    csr = op == OP_SYSTEM and f3 != 0
    i.ecall = op == OP_SYSTEM and f3 == 0
    i.bar = op == OP_CUSTOM0 and f7 == F7_BAR
    i.ld = op in (OP_LOAD, OP_LOADFP)
    i.st = op in (OP_STORE, OP_STOREFP) or amo
    i.ctl = op in (OP_BRANCH, OP_JAL, OP_JALR)
    src = []
    if op in (OP_OP, OP_OPIMM, OP_JALR, OP_BRANCH, OP_LOAD, OP_STORE, OP_LOADFP, OP_STOREFP, OP_AMO,
              OP_CUSTOM0) or csr or fsx:
        src.append((0, rs1))
    if op in (OP_OP, OP_BRANCH, OP_STORE, OP_AMO, OP_CUSTOM0):
        src.append((0, rs2))
    if (fp and not fsx) or fma:
        src.append((1, rs1))
    if (fp and f5 in (FP_ADD, FP_SUB, FP_MUL, FP_DIV, FP_SGNJ, FP_MINMAX, FP_CMP)) or fma or op == OP_STOREFP:
        src.append((1, rs2))
    if fma:
        src.append((1, rs3))
    i.src = [s for s in src if not (s[0] == 0 and s[1] == 0)]
    dx = (op in (OP_OP, OP_OPIMM, OP_LUI, OP_AUIPC, OP_JAL, OP_JALR, OP_LOAD, OP_AMO) or
          (op == OP_CUSTOM0 and f7 != F7_BAR) or csr or fid)
    df = op == OP_LOADFP or fma or (fp and not fid)
    i.dst = (1, rd) if df else ((0, rd) if (dx and rd != 0) else None)
    mul = op == OP_OP and f3 == 0 and (f7 & 1)
    if i.ld or i.st:
        i.cls = MEM
    elif sfu:
        i.cls = SFU
    elif fp or fma:
        i.cls = FPU
    elif mul:
        i.cls = MUL
    elif op == OP_CUSTOM0 and f7 == F7_DOT:
        i.cls = DOT
    elif op == OP_CUSTOM0 and f7 == F7_SHFL:
        i.cls = SHF
    elif i.bar or i.ecall or csr:
        i.cls = OTH
    else:
        i.cls = ALU
    # pending through the scoreboard: results of the FPU/MUL/DOT/SHF queues and loads
    i.unit = i.cls if i.cls in (FPU, MUL, DOT, SHF) else None
    i.pend = i.dst is not None and (i.unit is not None or i.ld)
    # parked until the warp resumes: stores, AMOs, divide/sqrt, barriers
    i.block = i.st or sfu or i.bar
    i.lat = 1
    # a single-cycle integer instruction (do_compute): squashed when the integer write port
    # is taken in its X cycle
    i.icomp = i.cls == ALU or csr
    i.woff = []                                          # a load: its write-port cycles - issue
    return i


def pop_ins(t):
    i = Ins()
    i.pop, i.cls, i.src, i.dst, i.pend, i.ld, i.st, i.block = True, ALU, [], None, False, False, False, False
    i.bar, i.ecall, i.ctl, i.g, i.t, i.lat, i.unit = False, False, False, 0, t, 1, None
    i.icomp, i.woff = False, []
    return i


def parse(path):
    """Yield launches: (blk_lg, rtl_cycles, {wb: [Ins, ...]})."""
    cur = None
    for line in open(path):
        f = line.split()
        if not f:
            continue
        k = f[0]
        if k == 'L':
            cur = {'b': int(f[1]), 'w': collections.OrderedDict(), 'pend': collections.defaultdict(collections.deque),
                   'blk': collections.defaultdict(collections.deque)}
        elif cur is None:
            continue
        elif k == 'I':
            t, wb, iw, g = int(f[1]), int(f[2]), int(f[4], 16), int(f[5])
            i = decode(iw, g)
            i.t = t
            cur['w'].setdefault(wb, []).append(i)
            if i.pend:
                cur['pend'][(wb,) + i.dst].append(i)
            if i.block:
                cur['blk'][wb].append(i)
        elif k == 'P':
            t, wb = int(f[1]), int(f[2])
            cur['w'].setdefault(wb, []).append(pop_ins(t))
        elif k == 'R':
            t, wb, fp, rd = int(f[1]), int(f[2]), int(f[3]), int(f[4])
            q = cur['pend'][(wb, fp, rd)]
            if q:
                i = q.popleft()
                i.lat = t - i.t
        elif k == 'W':
            t, wb, fp, rd = int(f[1]), int(f[2]), int(f[3]), int(f[4])
            q = cur['pend'][(wb, fp, rd)]
            if q and q[0].ld:
                q[0].woff.append(t - q[0].t)
        elif k == 'U':
            t, wb = int(f[1]), int(f[2])
            q = cur['blk'][wb]
            if q:
                i = q.popleft()
                i.lat = t - i.t
        elif k == 'E':
            yield cur['b'], int(f[1]), cur['w']
            cur = None


class Warp:
    __slots__ = ('wb', 'prog', 'pc', 'free_at', 'sleep', 'sleep_any', 'park_until', 'pend', 'lds',
                 'at_bar', 'done', 'block')

    def __init__(self, wb, prog, t, block):
        self.wb, self.prog, self.pc, self.free_at = wb, prog, 0, t + 1
        self.sleep, self.sleep_any, self.park_until = False, False, -1
        self.pend, self.lds, self.at_bar, self.done, self.block = {}, [], False, False, block


def simulate(blk_lg, warps, dual, base_lat):
    order = list(warps)                                   # spawn order: ascending base tid
    gsz = 1 << blk_lg
    slots = [None] * NW
    nxt = 0                                               # next warp to spawn
    t = 0
    unit_busy = collections.defaultdict(list)             # unit -> release times
    coal_free = 0
    lines_rel = []                                        # release cycle of each line in flight
    port = collections.defaultdict(set)                   # cycle -> banks whose integer port is taken
    bank = (lambda s: s & 1) if dual else (lambda s: 0)
    squashed = 0
    sfu_free = 0
    fetched = [None, None]                                # per half: (slot) fetched last cycle
    last = [NW - 1, NW - 1]
    issued = 0
    bars = collections.defaultdict(int)
    halves = [list(range(0, NW, 2)), list(range(1, NW, 2))] if dual else [list(range(NW))]
    while True:
        # retire finished warps, release barriers, wake sleepers on results written last cycle
        for s in range(NW):
            w = slots[s]
            if w is None:
                continue
            if w.done and all(r < t for r in w.pend.values()):
                slots[s] = None
                continue
            w.lds = [r for r in w.lds if r >= t]
            if w.sleep:
                written = [r for r in w.pend.values() if r == t - 1]
                if written or (w.sleep_any and any(rel == t - 1 for u in unit_busy for rel in unit_busy[u])):
                    w.sleep = False
                    w.free_at = max(w.free_at, t)
        for u in unit_busy:
            unit_busy[u] = [r for r in unit_busy[u] if r >= t]
        if len(lines_rel) > 64:
            lines_rel[:] = [x for x in lines_rel if x > t]
        port.pop(t - 1, None)
        for blk, n in list(bars.items()):
            live = [w for w in slots if w is not None and w.block == blk and not w.done]
            if live and all(w.at_bar for w in live):
                for w in live:
                    w.at_bar = False
                    w.park_until = t + 1
                del bars[blk]
        # spawn one warp
        if nxt < len(order):
            blk = nxt >> blk_lg
            base = None
            if gsz == 1:
                free = [s for s in range(NW) if slots[s] is None]
                base = free[0] if free else None
            else:
                pos = nxt & (gsz - 1)
                if pos == 0:
                    for g0 in range(0, NW, gsz):
                        if all(slots[s] is None for s in range(g0, g0 + gsz)):
                            base = g0
                            break
                else:
                    base = next((s for s in range(NW) if slots[s] is not None and slots[s].block == blk
                                 and s % gsz == 0), None)
                    if base is not None:
                        base = base + pos if slots[base + pos] is None else None
            if base is not None:
                wb = order[nxt]
                slots[base] = Warp(wb, warps[wb], t, blk)
                nxt += 1
        if nxt >= len(order) and all(w is None for w in slots):
            return t, issued
        # X stage: the instructions fetched last cycle
        cands = []
        for h, s in enumerate(fetched):
            if s is None:
                continue
            w = slots[s]
            if w is None or w.pc >= len(w.prog):
                continue
            i = w.prog[w.pc]
            haz = (any(w.pend.get(r, -1) >= t for r in i.src) or
                   (i.dst is not None and w.pend.get(i.dst, -1) >= t) or
                   (i.ld and len(w.lds) >= LD_MAX) or
                   ((i.st or i.bar or i.ecall) and w.lds) or
                   (i.ecall and any(r >= t for r in w.pend.values())))
            full = i.unit is not None and len(unit_busy[i.unit]) >= RQ
            if haz or full:
                w.sleep, w.sleep_any = True, (full and not haz)
                continue
            if i.cls == SFU and sfu_free > t:
                w.free_at = t + 1
                continue
            if i.icomp and bank(s) in port.get(t, ()):
                w.free_at = t + 1                         # squashed: issues again
                squashed += 1
                continue
            cands.append((h, s, w, i))
        if dual and len(cands) == 2:
            a, b = cands
            if a[3].cls == b[3].cls or OTH in (a[3].cls, b[3].cls):
                keep = a if (t & 1) == 0 else b
                drop = b if keep is a else a
                drop[2].free_at = t + 1
                cands = [keep]
        def send_lines(i):
            """Send a memory op's lines, one per cycle, at most TAGS in flight; return the cycle
            after the last line is sent. A scratchpad op (g < 0) serves one lane per cycle and
            uses no tag."""
            nonlocal coal_free
            s = max(t + 1, coal_free)
            if i.g < 0:
                coal_free = s - i.g
                return coal_free
            for _ in range(max(i.g, 1)):
                act = [x for x in lines_rel if x > s]
                if len(act) >= TAGS:
                    act.sort()
                    s = act[len(act) - TAGS]
                coal_free = s + 1
                s += 1
            return s

        for h, s, w, i in cands:
            w.pc += 1
            if not i.pop:
                issued += 1
            nf = t + 1 + (B2B if i.ctl else 0)
            sent = send_lines(i) if i.cls == MEM else None
            if i.pend:
                r = t + i.lat
                if i.cls == MEM:
                    r = max(r, sent + base_lat)
                    # a line's tag is free when its response is written (the trace's W
                    # cycles); lines without one hold their tag until the op ends
                    if i.g > 0:
                        sh = r - (t + i.lat)
                        rel = [t + off + sh for off in i.woff][:i.g]
                        lines_rel.extend(rel + [r] * (i.g - len(rel)))
                w.pend[i.dst] = r
                if i.unit is not None:
                    unit_busy[i.unit].append(r)
                    if i.dst[0] == 0:                     # integer result: takes the port at r
                        port[r].add(bank(s))
                if i.ld:
                    w.lds.append(r)
                    if i.dst[0] == 0:                     # an integer load takes the integer port
                        shift = r - (t + i.lat)
                        for off in i.woff:
                            port[t + off + shift].add(bank(s))
            if i.block and not i.bar:
                end = t + i.lat
                if i.cls == MEM:
                    end = max(end, sent + base_lat)
                    if i.g > 0:
                        lines_rel.extend([end] * i.g)
                if i.cls == SFU:
                    sfu_free = end
                w.park_until = end
                if i.dst is not None:
                    w.pend[i.dst] = end - 1
            if i.bar:
                w.at_bar = True
                w.park_until = 1 << 60
                bars[w.block] += 1
            if i.ecall:
                w.done = True
            w.free_at = max(w.free_at, nf)
        # fetch: each half picks the next runnable warp after the one it fetched last
        fetched = [None] * len(halves)
        for h, group in enumerate(halves):
            n = len(group)
            k0 = group.index(last[h]) if last[h] in group else n - 1
            for k in range(1, n + 1):
                s = group[(k0 + k) % n]
                w = slots[s]
                if (w is not None and not w.done and not w.sleep and not w.at_bar and w.pc < len(w.prog)
                        and w.free_at <= t and w.park_until <= t):
                    fetched[h] = s
                    last[h] = s
                    w.free_at = t + 2
                    break
        t += 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('trace')
    ap.add_argument('--log', help="the simulation's xsim.log: names the launches (its APPCSV lines, in order)")
    ap.add_argument('--csv', help='write the per-application results here')
    ap.add_argument('--base-lat', type=int, default=4, help='memory pipeline cycles after the last line request')
    a = ap.parse_args()
    read_pkg_consts()
    names = []
    if a.log:
        names = [l.split(',')[1] for l in open(a.log, encoding='utf-8', errors='replace')
                 if l.startswith('APPCSV,')]
    apps = collections.OrderedDict()
    for n, (b, rtl, warps) in enumerate(parse(a.trace)):
        c1, i1 = simulate(b, warps, False, a.base_lat)
        c2, i2 = simulate(b, warps, True, a.base_lat)
        s = apps.setdefault(names[n] if n < len(names) else 'launch%d' % n, collections.Counter())
        s['rtl'] += rtl
        s['c1'] += c1
        s['c2'] += c2
        s['ins'] += i1
        s['n'] += 1
        print('  launch %d (%s): rtl %d, model %d (%+.1f%%), dual %d' % (
            n, names[n] if n < len(names) else '?', rtl, c1, 100 * (c1 - rtl) / rtl, c2), file=sys.stderr)
    print('%-28s %10s %10s %7s %10s %7s %7s %8s' % ('application', 'rtl cyc', 'model 1x', 'err',
                                                    'model 2x', 'IPC 1x', 'IPC 2x', 'speedup'))
    rows, sp = [], []
    for name, s in apps.items():
        # dual-issue IPC on the RTL's scale: the model's speed-up applied to the RTL's cycles
        speed = s['c1'] / s['c2']
        ipc1, ipc2 = s['ins'] / s['rtl'], s['ins'] / (s['rtl'] / speed)
        sp.append(speed)
        print('%-28s %10d %10d %+6.1f%% %10d %7.2f %7.2f %7.2fx' % (
            name, s['rtl'], s['c1'], 100 * (s['c1'] - s['rtl']) / s['rtl'], s['c2'], ipc1, ipc2, speed))
        rows.append({'app': name, 'launches': s['n'], 'rtl_cycles': s['rtl'], 'model_1x': s['c1'],
                     'model_err_pct': '%.2f' % (100 * (s['c1'] - s['rtl']) / s['rtl']),
                     'model_2x': s['c2'], 'issued': s['ins'], 'ipc_1x': '%.3f' % ipc1,
                     'ipc_2x': '%.3f' % ipc2, 'speedup': '%.3f' % speed})
    if sp:
        import math
        print('geometric mean speed-up over %d applications: %.2fx'
              % (len(sp), math.exp(sum(map(math.log, sp)) / len(sp))))
    if a.csv and rows:
        import csv
        with open(a.csv, 'w', newline='') as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0]))
            w.writeheader()
            w.writerows(rows)


if __name__ == '__main__':
    main()
