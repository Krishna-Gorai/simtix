#!/usr/bin/env python3
"""plot_dse.py - design-space-exploration figures from docs/dse_perf.csv.

The sweep (sim/Makefile `dse` target) writes rows:
    DSE,lanes,warps,kernel,N,cycles,active_lanes,gmem_txns,divergences
Aggregate them into docs/dse_perf.csv (header added) then run this.

Produces, in docs/figs/:
    dse_throughput.png  aggregate throughput (work/cycle) vs NUM_LANES, per NUM_WARPS
    dse_warps.png       effect of NUM_WARPS (latency hiding) at fixed lanes
    dse_kernels.png     per-kernel throughput vs NUM_LANES (NUM_WARPS=4)
and prints the aggregate table to stdout.
"""
import csv, os, sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
CSV  = os.path.join(HERE, "dse_perf.csv")
OUT  = os.path.join(HERE, "figs")

try:
    import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
except ImportError:
    sys.exit("matplotlib required: pip install matplotlib")

def load():
    rows = []
    with open(CSV, newline="") as f:
        for r in csv.DictReader(f):
            for k in ("lanes","warps","N","cycles","active_lanes","gmem_txns","divergences"):
                r[k] = int(r[k])
            r["thr"] = r["active_lanes"]/r["cycles"]      # work-items retired / cycle
            rows.append(r)
    return rows

def main():
    if not os.path.exists(CSV):
        sys.exit(f"missing {CSV} - run the sweep first (see sim/Makefile `dse`)")
    os.makedirs(OUT, exist_ok=True)
    rows = load()
    lanes_set = sorted({r["lanes"] for r in rows})
    warps_set = sorted({r["warps"] for r in rows})
    kernels   = sorted({r["kernel"] for r in rows})

    # Aggregate throughput per (lanes,warps) = geomean of per-kernel throughput.
    def gmean(xs):
        p = 1.0
        for x in xs: p *= x
        return p ** (1.0/len(xs)) if xs else 0.0
    agg = {}
    for L in lanes_set:
        for W in warps_set:
            xs = [r["thr"] for r in rows if r["lanes"]==L and r["warps"]==W]
            if xs: agg[(L,W)] = gmean(xs)

    print("\n  aggregate throughput (geomean work/cycle) by configuration")
    print("  lanes \\ warps | " + " ".join(f"{W:>7d}" for W in warps_set))
    print("  " + "-"*(16+8*len(warps_set)))
    for L in lanes_set:
        cells = " ".join(f"{agg.get((L,W),0):7.2f}" for W in warps_set)
        print(f"  {L:>11d}  | {cells}")

    # 1) Aggregate throughput vs lanes, one line per warp count.
    plt.figure(figsize=(6,4))
    for W in warps_set:
        ys = [agg.get((L,W),0) for L in lanes_set]
        plt.plot(lanes_set, ys, marker="o", label=f"{W} warps")
    plt.xscale("log", base=2); plt.xticks(lanes_set, [str(l) for l in lanes_set])
    plt.xlabel("NUM_LANES"); plt.ylabel("throughput (work-items / cycle, geomean)")
    plt.title("SIMTiX throughput vs lane count")
    plt.legend(fontsize=8); plt.grid(True, alpha=0.3); plt.tight_layout()
    plt.savefig(os.path.join(OUT, "dse_throughput.png"), dpi=150); plt.close()

    # 2) Effect of warp count (latency hiding) at each lane count.
    plt.figure(figsize=(6,4))
    for L in lanes_set:
        ys = [agg.get((L,W),0) for W in warps_set]
        plt.plot(warps_set, ys, marker="s", label=f"{L} lanes")
    plt.xscale("log", base=2); plt.xticks(warps_set, [str(w) for w in warps_set])
    plt.xlabel("NUM_WARPS (resident)"); plt.ylabel("throughput (work-items / cycle, geomean)")
    plt.title("Latency hiding: throughput vs resident warps")
    plt.legend(fontsize=8); plt.grid(True, alpha=0.3); plt.tight_layout()
    plt.savefig(os.path.join(OUT, "dse_warps.png"), dpi=150); plt.close()

    # 3) Per-kernel throughput vs lanes at NUM_WARPS=4 (or the median warp count).
    Wsel = 4 if 4 in warps_set else warps_set[len(warps_set)//2]
    plt.figure(figsize=(6,4))
    for k in kernels:
        ys = []
        for L in lanes_set:
            m = [r["thr"] for r in rows if r["lanes"]==L and r["warps"]==Wsel and r["kernel"]==k]
            ys.append(m[0] if m else 0)
        plt.plot(lanes_set, ys, marker="o", label=k)
    plt.plot(lanes_set, lanes_set, ls=":", color="grey", lw=1, label="ideal (=lanes)")
    plt.xscale("log", base=2); plt.yscale("log", base=2)
    plt.xticks(lanes_set, [str(l) for l in lanes_set])
    plt.xlabel("NUM_LANES"); plt.ylabel("throughput (work-items / cycle)")
    plt.title(f"Per-kernel throughput vs lane count (NUM_WARPS={Wsel})")
    plt.legend(fontsize=8); plt.grid(True, alpha=0.3); plt.tight_layout()
    plt.savefig(os.path.join(OUT, "dse_kernels.png"), dpi=150); plt.close()

    print(f"\nwrote figures to {OUT}/  (dse_throughput, dse_warps, dse_kernels)")

if __name__ == "__main__":
    main()
