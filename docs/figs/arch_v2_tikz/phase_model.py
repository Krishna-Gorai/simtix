"""phase_model.py - the critical path of one SAXPY warp as phases with latencies, from the RTL
trace, and the latency model T = 3 Lambda + 49 (gen_phase_fig.py, check_phase_model.py).

The warp (kernels/figs/saxpy.S, one warp alone, Lambda = memory latency of the AXI4 model) runs
bgeu, flw a, slli, add, add, flw x, flw y, fmadd, fsw, ecall. Its critical path:
  l1  spawn to the issue of the load of a                         (5)
  l2  load of a: issue to the register write                      (Lambda + 8)
  l3  wake, fetch, issue of the load of y                         (3; a warp has two loads in
                                                                   flight, a and x, so y waits)
  l4  load of y                                                   (Lambda + 8)
  l5  wake, fetch, issue of the FMA                               (3)
  l6  FMA: issue to the register write                            (7)
  l7  fetch and issue of the store                                (2)
  l8  store: issue to the write response                          (Lambda + 8)
  l9  resume, ecall, DONE                                         (5)
so T = 3 (Lambda + 8) + 25 = 3 Lambda + 49. A load's Lambda + 8 is 3 (memory engine) + 2 (L1
lookup, miss) + (Lambda + 1) (AXI4 read address to the first data beat) + 1 (second beat) + 1
(the line to the engine and the register); a store's is 3 + 2 + 2 (address and two data beats)
+ Lambda (to the write response) + 1.
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
PC = {'flw_a': 0x04, 'flw_y': 0x18, 'fmadd': 0x1c, 'fsw': 0x20}


def events(run):
    """(issue trace events, stage trace events) of traces/<run>_*.txt, each {letter: [fields]}"""
    out = []
    for kind in ('issue', 'fig'):
        ev = {}
        for line in open(os.path.join(HERE, 'traces', '%s_%s.txt' % (run, kind))):
            p = line.split()
            if len(p) > 1 and p[1].isdigit():
                ev.setdefault(p[0], []).append(p[1:])
        out.append(ev)
    return out


def phases(run):
    """the cycle boundaries t0..t9 of the critical path and its nine latencies"""
    iv, fv = events(run)
    issue = {int(e[2], 16): int(e[0]) for e in iv['I']}         # pc -> issue cycle (one warp)
    wr = [(int(e[0]), int(e[2]), int(e[3])) for e in iv['W']]   # load register writes
    rr = [(int(e[0]), int(e[2]), int(e[3])) for e in iv['R']]
    t = [0, issue[PC['flw_a']]]
    t.append(next(c for c, fp, rd in wr if fp == 1 and rd == 0))                  # f0 <- a
    t.append(issue[PC['flw_y']])
    t.append(next(c for c, fp, rd in wr if fp == 1 and rd == 2))                  # f2 <- y
    t.append(issue[PC['fmadd']])
    t.append(next(c for c, fp, rd in rr if fp == 1 and rd == 2 and c > t[5]))    # FMA result
    t.append(issue[PC['fsw']])
    qst = next(int(e[0]) for e in fv['Q'] if e[3] == '1')                        # the store's request
    t.append(next(int(e[0]) for e in fv['A'] if int(e[0]) > qst))                # its response
    t.append(int(iv['E'][0][0]))
    lat = [b - a for a, b in zip(t, t[1:])]
    return t, lat


def load_steps(run):
    """the sub-steps of the load of a: issue, L1 request, AXI4 read address, first and last
    data beat, response to the engine"""
    iv, fv = events(run)
    t_iss = int(next(e[0] for e in iv['I'] if int(e[2], 16) == PC['flw_a']))
    q = int(fv['Q'][0][0])
    ar = int(fv['AR'][0][0])
    r = [int(e[0]) for e in fv['R'] if e[1] == fv['AR'][0][1]][:2]
    a = int(fv['A'][0][0])
    return [t_iss, q, ar, r[0], r[1], a]


def model(lam):
    return 3 * lam + 49
