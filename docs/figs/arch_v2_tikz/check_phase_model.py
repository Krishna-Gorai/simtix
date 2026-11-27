#!/usr/bin/env python3
"""check_phase_model.py - check the latency model of one SAXPY warp against the RTL.

For the one-warp SAXPY traced at memory latencies of 24, 48 and 96 cycles (fig_trace.py runs
saxpy1, saxpy1_l48, saxpy1_l96), takes the nine phases of the critical path from the trace
(phase_model.py) and requires: the load and store phases take Lambda + 8 cycles, the other
phases 5, 3, 3, 7, 2 and 5 cycles, and the launch ends after T = 3 Lambda + 49 cycles.
Exits 1 on any difference.  Usage: python check_phase_model.py
"""
import sys

from phase_model import load_steps, model, phases

RUNS = [('saxpy1', 24), ('saxpy1_l48', 48), ('saxpy1_l96', 96)]


def main():
    ok = True
    for run, lam in RUNS:
        t, lat = phases(run)
        want = [5, lam + 8, 3, lam + 8, 3, 7, 2, lam + 8, 5]
        good = lat == want and t[-1] == model(lam)
        ok &= good
        steps = load_steps(run)
        print("Lambda = %3d: phases %s, T = %d (model %d), load of a %s  %s"
              % (lam, lat, t[-1], model(lam), [b - a for a, b in zip(steps, steps[1:])],
                 "OK" if good else "MISMATCH"))
    print("PASS: T = 3 Lambda + 49 at every latency" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
