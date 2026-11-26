"""lat_sched.py - the issue rules of SIMTiX's warp scheduler, as a small cycle model for the
latency-tolerance figure (gen_lat_fig.py). The rules are those of rtl/accel/warp_pool.sv:
  - one warp instruction issues (X) per cycle;
  - the scheduler takes the next runnable warp after the one issued last (round robin);
  - a warp is not fetched while its previous instruction is in X, so it issues at most every
    other cycle (`inflight`);
  - an instruction whose source register is still pending (register scoreboard) does not
    issue; its warp sleeps until that result is written, and is runnable from the next cycle;
  - a load does not stop its warp: only an instruction that reads the loaded register waits.
Latencies: FPU 6 cycles from issue to the result write (FPC_LAT); ALU results are
written in X; LOAD stands for an L1 hit through the memory engine (schematic value).
"""
FPU, LOAD = 6, 9

# per warp: list of (mnemonic, latency, index of the instruction whose result it reads)
PROG = {
    0: [("fmadd", FPU, None), ("fmadd", FPU, 0), ("fmadd", FPU, 1)],
    1: [("lw", LOAD, None), ("addi", 0, None), ("fmadd", FPU, 0), ("fsw", 0, 2)],
    2: [("add", 0, None), ("slli", 0, None), ("add", 0, None), ("sh2add", 0, None), ("add", 0, None)],
    3: [("fmul", FPU, None), ("fadd", FPU, 0), ("addi", 0, None)],
}


def schedule(ncyc=20, nw=4):
    pc = {w: 0 for w in range(nw)}
    done_at = {w: {} for w in range(nw)}       # instruction index -> cycle its result is written
    last_issue = {w: -10 for w in range(nw)}
    issue = {}                                  # cycle -> (warp, mnemonic)
    state = {w: {} for w in range(nw)}          # warp -> cycle -> 'I' issue / 'S' sleep
    flight = {w: [] for w in range(nw)}         # warp -> (issue cycle, result-write cycle, unit)
    last = nw - 1
    for t in range(ncyc):
        def ready(w):
            if pc[w] >= len(PROG[w]) or t - last_issue[w] < 2:
                return False
            _, _, dep = PROG[w][pc[w]]
            return dep is None or (dep in done_at[w] and done_at[w][dep] < t)
        for w in range(nw):                     # sleeping: blocked on a pending source
            if pc[w] < len(PROG[w]) and t - last_issue[w] >= 2 and not ready(w):
                state[w][t] = "S"
        for k in range(1, nw + 1):
            w = (last + k) % nw
            if ready(w):
                op, lat, _ = PROG[w][pc[w]]
                issue[t] = (w, op)
                state[w][t] = "I"
                done_at[w][pc[w]] = t + lat
                if lat:
                    flight[w].append((t, t + lat, "L" if op == "lw" else "F"))
                pc[w] += 1
                last_issue[w] = t
                last = w
                break
    return issue, state, flight


if __name__ == "__main__":
    iss, st, fl = schedule()
    print("issue:", " ".join("%d:W%d.%s" % (t, *iss[t]) for t in sorted(iss)))
    for w in range(4):
        print("W%d" % w, "".join(st[w].get(t, ".") for t in range(20)))
