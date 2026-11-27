"""launch_trace.py - the SAXPY launch of the paper's Figs. 2 and 3 as per-cycle signals.

Reads traces/saxpy92_{fig,issue}.txt (fig_trace.py: kernels/figs/saxpy.S for N = 92 threads
on the board top, board configuration, 24-cycle AXI4 memory model) and gives, per cycle, the
values the waveforms draw: the spawned warp, the fetched and issuing warp and opcode, each
slot's warp and state, the L1 requests and lookups, the AXI4 channels and the register writes.
"""
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..', '..'))
FIG = os.path.join(HERE, "traces", "saxpy92_fig.txt")
ISS = os.path.join(HERE, "traces", "saxpy92_issue.txt")
SRC = os.path.join(ROOT, "kernels", "figs", "saxpy.S")
N, L, NSLOT = 92, 8, 8
BASES = [(0x10002000, 'a'), (0x10001000, 'y'), (0x10000000, 'x')]   # tb_figtrace.sv layout
WS_RUN, WS_MEM, WS_DONE = 1, 2, 4                                    # warp_pool wstate_e
# the three windows drawn cycle by cycle (gen_wave_col_fig.py) and marked on the overview
# (gen_launch_fig.py): first cycle, last cycle, LaTeX label of the window's figure in the paper
WINDOWS = [(9, 23, "fig:wavea"), (55, 69, "fig:waveb"), (97, 111, "fig:wavec")]


def line_name(addr):
    for base, n in BASES:
        if addr >= base:
            return n if n == 'a' else "%s%d" % (n, (addr - base) // 32)
    return "?"


def program():
    ins = []
    for line in open(SRC):
        s = line.split('#')[0].strip()
        s = re.sub(r'^\d+:\s*', '', s)
        if s and not s.startswith('.') and not s.endswith(':'):
            ins.append(s.split()[0].replace('.s', ''))
    return {4 * i: op for i, op in enumerate(ins)}


class Launch:
    def __init__(self):
        self.op = program()
        self.spawn, self.z = [], {k: [] for k in range(NSLOT)}
        self.fetch, self.x, self.q, self.l = {}, {}, {}, {}
        self.miss, self.hit = set(), set()
        self.ar, self.r, self.aw, self.w, self.b = {}, {}, {}, {}, {}
        for line in open(FIG):
            p = line.split()
            if len(p) < 2 or not p[1].lstrip('-').isdigit():
                continue
            k, c = p[0], int(p[1])
            if k == 'S':
                self.spawn.append((c, int(p[2]), int(p[3]) // L, p[4].count('1')))
            elif k == 'Z':
                self.z[int(p[2])].append((c, int(p[3]), int(p[4])))
            elif k == 'F':
                self.fetch[c] = int(p[2])
            elif k == 'X':
                self.x[c] = (int(p[2]), int(p[3], 16), p[5])
            elif k == 'Q':
                self.q[c] = (int(p[2]), int(p[3], 16), p[4] == '1')
            elif k == 'L':
                self.l[c] = (int(p[2]), int(p[3], 16), p[4] == '1')
            elif k == 'U':
                self.miss.add(c)
            elif k == 'H':
                self.hit.add(c)
            elif k == 'AR':
                self.ar[c] = (int(p[2]), int(p[3], 16))
            elif k == 'R':
                self.r[c] = (int(p[2]), p[3] == '1')
            elif k == 'AW':
                self.aw[c] = (int(p[2]), int(p[3], 16))
            elif k == 'W':
                self.w[c] = p[2] == '1'
            elif k == 'BR':
                self.b[c] = int(p[2])
        wr, fin = [], []
        for line in open(ISS):
            p = line.split()
            if p and p[0] == 'W':
                wr.append((int(p[1]), int(p[2]) // L, int(p[3]), int(p[4])))
            elif p and p[0] == 'R':
                fin.append((int(p[1]), int(p[2]) // L, int(p[3]), int(p[4])))
            elif p and p[0] == 'E':
                self.end = int(p[1])
        loads = {(c, w, fp, rd) for c, w, fp, rd in wr}
        # register-file writes: loads (W) and FPU results (an R not one cycle after a load's W)
        self.rf = {}
        for src, events in (('ld', wr), ('fpu', [e for e in fin if (e[0] - 1,) + e[1:] not in loads])):
            for c, w, fp, rd in events:
                self.rf[c] = ("w%d %s%d" % (w, "f" if fp else "x", rd), src)
        self._channels()

    def _channels(self):
        """Name the AXI4 beats and responses after the line of their address."""
        out, self.r_name = {}, {}
        for c in sorted(set(self.ar) | set(self.r)):
            if c in self.r:                      # a beat of the oldest read with its ID
                i, last = self.r[c]
                self.r_name[c] = out[i][0]
                if last:
                    out[i].pop(0)
            if c in self.ar:
                i, a = self.ar[c]
                out.setdefault(i, []).append(line_name(a))
        aws, bq, self.w_name, self.b_name = [], {}, {}, {}
        for c in sorted(set(self.aw) | set(self.w) | set(self.b)):
            if c in self.b:
                self.b_name[c] = bq[self.b[c]].pop(0)
            if c in self.aw:
                i, a = self.aw[c]
                aws.append(line_name(a))
                bq.setdefault(i, []).append(line_name(a))
            if c in self.w:
                self.w_name[c] = aws[0]
                if self.w[c]:
                    aws.pop(0)

    # ── per-cycle values ────────────────────────────────────────────────────────
    def warp_in(self, slot, c):
        """the warp in a slot during cycle c (spawned in an earlier cycle), or None"""
        w = None
        for s, k, wid, _ in self.spawn:
            if k == slot and s < c:
                w = wid
        return w

    def state(self, slot, c):
        """'run', 'sleep' (asleep on the scoreboard), 'park' (waiting for memory) or None"""
        ws, sl = 0, 0
        for zc, zws, zsl in self.z[slot]:
            if zc <= c:
                ws, sl = zws, zsl
        if ws == WS_RUN:
            return 'sleep' if sl else 'run'
        if ws == WS_MEM:
            return 'park'
        return None

    def fetched(self, c):
        return None if c not in self.fetch else self.warp_in(self.fetch[c], c)

    def issued(self, c):
        """(warp, opcode, issued?) of the instruction in X, or None"""
        if c not in self.x:
            return None
        slot, pc, kind = self.x[c]
        return (self.warp_in(slot, c), self.op[pc], kind == 'issue')

    def l1_req(self, c):
        if c not in self.q:
            return None
        _, a, we = self.q[c]
        return (line_name(a), we)

    def l1_result(self, c):
        """'miss' (sent on to memory), 'join' (merged with a miss in flight) or 'hit'"""
        if c in self.hit:
            return 'hit'
        if c in self.miss:
            return 'miss' if (c in self.l and not self.l[c][2]) else 'join'
        return None
