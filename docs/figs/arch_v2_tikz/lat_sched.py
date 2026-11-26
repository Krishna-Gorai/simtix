"""lat_sched.py - the issue rules of SIMTiX's warp scheduler, as a cycle model for the
latency-tolerance figure (gen_lat_fig.py). The rules are those of rtl/accel/warp_pool.sv:
  - fetch (F): each cycle the first warp in round-robin order after the one fetched last that
    is running, not in flight and not asleep is fetched; its instruction is in X the next
    cycle. A warp is in flight from its fetch to its X, so it issues at most every other cycle;
  - X: one instruction per cycle. It issues unless a source or destination register is
    pending (register scoreboard); then it is held back, the issue slot of that cycle is lost,
    and its warp sleeps until one of its own pending results is written (any of them), and can
    be fetched again from the next cycle;
  - a result is written `lat` cycles after its instruction issued, and its register is free
    from the next cycle: FPU 7 (FPC_LAT = 6 to the result queue, then the register-file
    write), ALU 0 (written in X); LOAD stands for an L1 hit through the memory engine (a
    schematic value). A load does not stop its warp: only an instruction that reads the loaded
    register waits; an ecall waits for every pending result.
check_lat_sched.py replays the RTL issue trace of kernels/figs/issue_rules.S (four warps) with
these rules and requires the same issue and hold-back cycles.
"""
FPU, LOAD = 7, 9
ALL = 'all'                                     # dependency marker: every earlier result

# per warp: list of (mnemonic, latency, indices of the instructions whose results it reads)
PROG = {
    0: [("fmadd", FPU, []), ("fmadd", FPU, [0]), ("fmadd", FPU, [1])],
    1: [("lw", LOAD, []), ("addi", 0, []), ("fmadd", FPU, [0]), ("fsw", 0, [2])],
    2: [("add", 0, []), ("slli", 0, []), ("add", 0, []), ("sh2add", 0, []), ("add", 0, [])],
    3: [("fmul", FPU, []), ("fadd", FPU, [0]), ("addi", 0, [])],
}


def simulate(prog, ncyc, start):
    """prog: warp -> [(op, lat, deps)]; start: warp -> first cycle it can be fetched.
    Returns issue {cycle: (warp, op)}, state {warp: {cycle: 'I' issue | 'H' held back |
    'S' asleep}}, flight {warp: [(issue cycle, write cycle, op)]}."""
    nw = len(prog)
    pc = {w: 0 for w in range(nw)}
    wake = dict(start)                          # first cycle the warp can be fetched
    written = {w: {} for w in range(nw)}        # instruction index -> cycle its result is written
    issue, state, flight = {}, {w: {} for w in range(nw)}, {w: [] for w in range(nw)}
    rr, in_x = 0, None
    for t in range(min(start.values()), ncyc):
        if in_x is not None:                    # X
            w = in_x
            op, lat, deps = prog[w][pc[w]]
            if deps == ALL:
                deps = list(written[w])
            pending = [written[w][d] for d in deps if written[w].get(d, -1) >= t]
            if not pending:
                issue[t] = (w, op)
                state[w][t] = 'I'
                if lat:
                    written[w][pc[w]] = t + lat
                    flight[w].append((t, t + lat, op))
                pc[w] += 1
                wake[w] = t + 1
            else:
                state[w][t] = 'H'
                own = min(c for c in written[w].values() if c >= t)
                wake[w] = own + 1               # asleep until one of its results is written
                for c in range(t + 1, wake[w]):
                    state[w][c] = 'S'
        in_x = None                             # F
        for k in range(nw):
            w = (rr + k) % nw
            if pc[w] < len(prog[w]) and wake[w] <= t:
                in_x, rr = w, (w + 1) % nw
                break
    return issue, state, flight


def schedule(ncyc=20, nw=4):
    """The figure's four warps, all resident from the start (warp 0 in X in cycle 0)."""
    return simulate({w: PROG[w] for w in range(nw)}, ncyc, {w: -1 for w in range(nw)})


if __name__ == "__main__":
    iss, st, fl = schedule()
    print("issue:", " ".join("%d:W%d.%s" % (t, *iss[t]) for t in sorted(iss)))
    for w in range(4):
        print("W%d" % w, "".join(st[w].get(t, ".") for t in range(20)))
