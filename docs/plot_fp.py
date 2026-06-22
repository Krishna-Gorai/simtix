#!/usr/bin/env python3
"""plot_fp.py - turn the FP CSVs into paper figures.

Produces, in docs/figs/:
    fp_throughput.png   throughput (work/cycle) vs N for FP32 and FP16 kernels;
                        the FP16 curves lie exactly on the FP32 ones (same
                        single-cycle datapath), showing FP16 costs no extra cycles.
    fp_cost.png         cycles at the largest size, FP32 vs FP16, per kernel -
                        identical bars: half precision is free in compute time.
    fpk_cost.png        cycles at N=256 for the realistic FP application kernels -
                        the multi-cycle SFU makes fnorm (div+sqrt) ~6x the
                        streaming fsaxpy.
    fpk_energy.png      lane utilization per FP application kernel; the complement
                        is the lane-datapath dynamic energy a gated design saves
                        (fdot's reduction idles 7/8 lanes -> ~55%).

Usage:  python docs/plot_fp.py    (reads docs/fp_bench.csv and docs/fp_kernels.csv)
"""
import csv, os, sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
CSV  = os.path.join(HERE, "fp_bench.csv")
KCSV = os.path.join(HERE, "fp_kernels.csv")
OUT  = os.path.join(HERE, "figs")

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
except ImportError:
    sys.exit("matplotlib is required: pip install matplotlib")

def load(path):
    rows = []
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            for k in ("N","cycles","gmem","issued","active","util_permil","ipc_x100"):
                r[k] = int(r[k])
            rows.append(r)
    return rows

def main():
    if not os.path.exists(CSV):
        sys.exit(f"missing {CSV} - run `make fp-bench | grep '^FPCSV,' > docs/fp_bench.csv`")
    os.makedirs(OUT, exist_ok=True)
    rows = load(CSV)
    series = defaultdict(list)          # (fmt,kernel) -> rows sorted by N
    for r in rows:
        series[(r["fmt"], r["kernel"])].append(r)
    for key in series:
        series[key].sort(key=lambda r: r["N"])

    # 1) Throughput vs N: FP32 solid, FP16 dashed+open markers (overlap is the point).
    plt.figure(figsize=(6,4))
    style = {("f32","vadd"):("#4C72B0","-","o","FP32 vadd"),
             ("f32","mac") :("#C44E52","-","s","FP32 mac (mul+add)"),
             ("f16","vadd"):("#4C72B0","--","x","FP16 vadd"),
             ("f16","mac") :("#C44E52","--","+","FP16 mac (mul+add)")}
    for key in [("f32","vadd"),("f32","mac"),("f16","vadd"),("f16","mac")]:
        if key not in series: continue
        col, ls, mk, lab = style[key]
        xs = [r["N"] for r in series[key]]
        ys = [r["ipc_x100"]/100 for r in series[key]]
        plt.plot(xs, ys, color=col, ls=ls, marker=mk, ms=7, label=lab)
    plt.axhline(8, ls=":", color="grey", lw=1, label="ideal (8 lanes)")
    plt.xscale("log", base=2); plt.xlabel("problem size N (threads)")
    plt.ylabel("throughput  (work-items / cycle)")
    plt.ylim(0, 8.6)
    plt.title("FP throughput vs problem size (FP16 tracks FP32)")
    plt.legend(fontsize=8); plt.grid(True, alpha=0.3); plt.tight_layout()
    plt.savefig(os.path.join(OUT, "fp_throughput.png"), dpi=150); plt.close()

    # 2) Compute cost: cycles at the largest N, FP32 vs FP16, per kernel.
    kernels = ["vadd", "mac"]
    Nmax = max(r["N"] for r in rows)
    f32 = [next(r["cycles"] for r in series[("f32",k)] if r["N"]==Nmax) for k in kernels]
    f16 = [next(r["cycles"] for r in series[("f16",k)] if r["N"]==Nmax) for k in kernels]
    x = range(len(kernels)); w = 0.36
    plt.figure(figsize=(5.6,4))
    b1 = plt.bar([i-w/2 for i in x], f32, w, label="FP32", color="#4C72B0")
    b2 = plt.bar([i+w/2 for i in x], f16, w, label="FP16", color="#55A868")
    for bars in (b1,b2):
        for b in bars:
            plt.text(b.get_x()+b.get_width()/2, b.get_height()+15,
                     f"{int(b.get_height())}", ha="center", fontsize=8)
    plt.xticks(list(x), [k+f"\n(N={Nmax})" for k in kernels])
    plt.ylabel("cycles (launch to done)")
    plt.title("Compute cost: FP16 = FP32 cycles")
    plt.legend(fontsize=9); plt.grid(True, axis="y", alpha=0.3); plt.tight_layout()
    plt.savefig(os.path.join(OUT, "fp_cost.png"), dpi=150); plt.close()

    figs = "fp_throughput, fp_cost"
    if os.path.exists(KCSV):
        figs += ", " + kernel_figures()
    print(f"wrote figures to {OUT}/  ({figs})")

def kernel_figures():
    """Realistic FP application kernels (docs/fp_kernels.csv): SFU-latency cost and
    lane-utilization / energy-saved."""
    krows = []
    with open(KCSV, newline="") as f:
        for r in csv.DictReader(f):
            for k in ("N","cycles","gmem","scratch","issued","active","util_permil"):
                r[k] = int(r[k])
            krows.append(r)
    order  = ["fsaxpy", "fsaxpy16", "fnorm", "fdot"]
    Nmax   = max(r["N"] for r in krows)
    at_max = {r["kernel"]: r for r in krows if r["N"] == Nmax}

    # 3) Compute cost at N=256: the multi-cycle SFU makes fnorm dominate.
    cyc = [at_max[k]["cycles"] for k in order]
    cols = ["#4C72B0", "#55A868", "#C44E52", "#8172B3"]
    plt.figure(figsize=(6,4))
    bars = plt.bar(order, cyc, color=cols)
    for b in bars:
        plt.text(b.get_x()+b.get_width()/2, b.get_height()+20,
                 f"{int(b.get_height())}", ha="center", fontsize=9)
    base = at_max["fsaxpy"]["cycles"]
    for b, k in zip(bars, order):
        if k != "fsaxpy":
            plt.text(b.get_x()+b.get_width()/2, b.get_height()*0.5,
                     f"{at_max[k]['cycles']/base:.1f}x", ha="center", fontsize=9,
                     color="white", fontweight="bold")
    plt.ylabel(f"cycles (launch to done, N={Nmax})")
    plt.title("FP application-kernel cost: the multi-cycle SFU shows up in fnorm")
    plt.grid(True, axis="y", alpha=0.3); plt.tight_layout()
    plt.savefig(os.path.join(OUT, "fpk_cost.png"), dpi=150); plt.close()

    # 4) Lane utilization (energy a gated design saves = the complement).
    util = [at_max[k]["util_permil"]/10 for k in order]
    plt.figure(figsize=(6,4))
    bars = plt.bar(order, util, color=cols)
    for b, u in zip(bars, util):
        plt.text(b.get_x()+b.get_width()/2, u+1, f"{u:.1f}%", ha="center", fontsize=9)
        if u < 99:
            plt.text(b.get_x()+b.get_width()/2, u-7, f"save\n{100-u:.0f}%",
                     ha="center", fontsize=8, color="white", fontweight="bold")
    plt.ylim(0, 108); plt.ylabel("SIMT lane utilization (%)")
    plt.title("FP lane utilization (complement = lane-datapath energy gated away)")
    plt.grid(True, axis="y", alpha=0.3); plt.tight_layout()
    plt.savefig(os.path.join(OUT, "fpk_energy.png"), dpi=150); plt.close()
    return "fpk_cost, fpk_energy"

if __name__ == "__main__":
    main()
