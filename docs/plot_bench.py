#!/usr/bin/env python3
"""plot_bench.py - turn docs/bench.csv (from `make bench`) into paper figures.

Produces, in docs/figs/:
    throughput.png    scalar-equivalent IPC vs problem size (latency-hiding ramp)
    laneutil.png      lane utilisation per kernel (SIMT/control-divergence efficiency)
    memtraffic.png    global line transactions vs size (coalescing behaviour)
    locality.png      matmul naive-vs-smem global traffic (scratchpad data reuse)

Usage:  python docs/plot_bench.py            (reads docs/bench.csv)
"""
import csv, os, sys
from collections import defaultdict

HERE    = os.path.dirname(os.path.abspath(__file__))
CSV     = os.path.join(HERE, "bench.csv")
CPU_CSV = os.path.join(HERE, "bench_cpu.csv")
OUT     = os.path.join(HERE, "figs")

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
            for k in ("N","cycles","gmem_txns","scratch_txns","divergences",
                      "issued_insns","active_lanes","lane_util_pm","scalar_ipc_x100"):
                r[k] = int(r[k])
            rows.append(r)
    return rows

def main():
    if not os.path.exists(CSV):
        sys.exit(f"missing {CSV} - run `make bench | grep '^CSV,' > docs/bench.csv` first")
    os.makedirs(OUT, exist_ok=True)
    rows = load(CSV)
    by_kernel = defaultdict(list)
    for r in rows:
        by_kernel[r["kernel"]].append(r)
    for k in by_kernel:
        by_kernel[k].sort(key=lambda r: r["N"])

    streaming = ["vadd", "saxpy", "fir", "relu", "collatz", "reduce"]

    # 1) Throughput: scalar-equivalent IPC vs N (latency-hiding / scaling).
    plt.figure(figsize=(6,4))
    for k in streaming:
        if k not in by_kernel: continue
        xs = [r["N"] for r in by_kernel[k]]
        ys = [r["scalar_ipc_x100"]/100 for r in by_kernel[k]]
        plt.plot(xs, ys, marker="o", label=k)
    plt.axhline(8, ls="--", color="grey", lw=1, label="ideal (8 lanes)")
    plt.xscale("log", base=2); plt.xlabel("problem size N (threads)")
    plt.ylabel("scalar-equivalent IPC  (work/cycle)")
    plt.title("SIMTiX throughput vs problem size")
    plt.legend(fontsize=8); plt.grid(True, alpha=0.3); plt.tight_layout()
    plt.savefig(os.path.join(OUT, "throughput.png"), dpi=150); plt.close()

    # 2) Lane utilisation (control-divergence / SIMT efficiency), largest size each.
    plt.figure(figsize=(6,4))
    labels, utils = [], []
    for k in streaming:
        if k not in by_kernel: continue
        labels.append(k); utils.append(by_kernel[k][-1]["lane_util_pm"]/10)
    bars = plt.bar(labels, utils, color="#4C72B0")
    for b,u in zip(bars,utils):
        plt.text(b.get_x()+b.get_width()/2, u+1, f"{u:.1f}%", ha="center", fontsize=8)
    plt.ylim(0,105); plt.ylabel("lane utilisation (%)")
    plt.title("SIMT lane utilisation (energy a gated design clocks)")
    plt.grid(True, axis="y", alpha=0.3); plt.tight_layout()
    plt.savefig(os.path.join(OUT, "laneutil.png"), dpi=150); plt.close()

    # 3) Global memory traffic vs N (coalescing: saxpy perfect vs fir partial).
    plt.figure(figsize=(6,4))
    for k in ("vadd","saxpy","fir","relu","reduce"):
        if k not in by_kernel: continue
        xs = [r["N"] for r in by_kernel[k]]
        ys = [r["gmem_txns"] for r in by_kernel[k]]
        plt.plot(xs, ys, marker="s", label=k)
    plt.xscale("log", base=2); plt.yscale("log", base=2)
    plt.xlabel("problem size N (threads)"); plt.ylabel("global line transactions")
    plt.title("Global memory traffic (coalescing efficiency)")
    plt.legend(fontsize=8); plt.grid(True, alpha=0.3); plt.tight_layout()
    plt.savefig(os.path.join(OUT, "memtraffic.png"), dpi=150); plt.close()

    # 4) Locality: matmul naive vs smem global traffic (scratchpad reuse).
    if "mm_naive" in by_kernel and "mm_smem" in by_kernel:
        plt.figure(figsize=(4,4))
        n = by_kernel["mm_naive"][0]; s = by_kernel["mm_smem"][0]
        plt.bar(["naive\n(all global)","smem\n(staged)"],
                [n["gmem_txns"], s["gmem_txns"]], color=["#C44E52","#55A868"])
        plt.ylabel("global line transactions")
        plt.title("Scratchpad data reuse (8x8 matmul row)")
        plt.grid(True, axis="y", alpha=0.3); plt.tight_layout()
        plt.savefig(os.path.join(OUT, "locality.png"), dpi=150); plt.close()

    # 5) Measured speedup vs the scalar host CPU (if the CPU baseline exists).
    if os.path.exists(CPU_CSV):
        cpu = {}
        with open(CPU_CSV, newline="") as f:
            for r in csv.DictReader(f):
                cpu[(r["kernel"], int(r["N"]))] = int(r["cpu_cycles"])
        accel = {(r["kernel"], r["N"]): r["cycles"] for r in rows}

        print("\n  measured speedup (scalar host-CPU cycles / SIMTiX accelerator cycles)")
        print("  kernel      N |   cpu   accel  speedup")
        print("  ------------------------------------------")
        order = ["vadd","saxpy","fir","relu","collatz","reduce"]
        plt.figure(figsize=(6,4))
        for k in order:
            xs, ys = [], []
            for n in sorted({n for (kk,n) in cpu if kk==k}):
                if (k,n) not in accel: continue
                c, a = cpu[(k,n)], accel[(k,n)]
                sp = c / a
                print(f"  {k:<9} {n:4d} | {c:6d} {a:6d}  {sp:6.2f}x")
                xs.append(n); ys.append(sp)
            if xs:
                plt.plot(xs, ys, marker="o", label=k)
        plt.axhline(1, ls="--", color="grey", lw=1, label="break-even")
        plt.xscale("log", base=2); plt.xlabel("problem size N (threads)")
        plt.ylabel("speedup over scalar host CPU (x)")
        plt.title("Measured SIMTiX speedup vs 5-stage RV32I host")
        plt.legend(fontsize=8); plt.grid(True, alpha=0.3); plt.tight_layout()
        plt.savefig(os.path.join(OUT, "speedup.png"), dpi=150); plt.close()
        print("  ------------------------------------------")

    figs = "throughput, laneutil, memtraffic, locality"
    if os.path.exists(CPU_CSV): figs += ", speedup"
    print(f"\nwrote figures to {OUT}/  ({figs})")

if __name__ == "__main__":
    main()
