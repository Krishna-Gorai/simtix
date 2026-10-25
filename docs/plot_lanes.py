#!/usr/bin/env python3
"""plot_lanes.py - application speedup with the lane count.

Reads docs/lanes_apps.csv (sim/lane_sweep.py: cycles per launch at 4, 8 and 16
lanes, 4 warps) and plots each application's speedup over the 4-lane
accelerator, with the ideal (linear) line.

Produces docs/figs/lanes_speedup.pdf.
Usage:  python docs/plot_lanes.py
"""
import csv, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "figs")

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
except ImportError:
    sys.exit("matplotlib is required: pip install matplotlib")

NAMES = {"gemm": "GEMM", "spmv": "SpMV", "stencil": "Stencil", "kmeans": "k-means",
         "bfs": "BFS", "scan": "Scan", "mlp": "MLP"}
MARKERS = "osD^v<>"


def main():
    tot = {}
    for r in csv.DictReader(open(os.path.join(HERE, "lanes_apps.csv"))):
        k = (r["case"].split("_")[0], int(r["lanes"]))
        tot[k] = tot.get(k, 0) + int(r["cycles"])
    lanes = sorted({l for _, l in tot})
    fig, ax = plt.subplots(figsize=(3.5, 2.5))
    ax.plot(lanes, [l / lanes[0] for l in lanes], "--", color="#777777", lw=1, label="linear")
    for i, app in enumerate(NAMES):
        ax.plot(lanes, [tot[(app, lanes[0])] / tot[(app, l)] for l in lanes],
                marker=MARKERS[i], ms=4, lw=1.1, label=NAMES[app])
    ax.set_xscale("log", base=2)
    ax.set_yscale("log", base=2)
    ax.set_xticks(lanes)
    ax.set_xticklabels([str(l) for l in lanes])
    ax.set_yticks([1, 2, 4])
    ax.set_yticklabels(["1", "2", "4"])
    ax.set_xlabel("lanes (4 warps)", fontsize=8)
    ax.set_ylabel("speedup over 4 lanes", fontsize=8)
    ax.tick_params(labelsize=7.5)
    ax.grid(True, alpha=0.3, which="both")
    ax.legend(fontsize=6.5, ncol=2, loc="upper left", frameon=False)
    fig.tight_layout()
    os.makedirs(OUT, exist_ok=True)
    out = os.path.join(OUT, "lanes_speedup.pdf")
    fig.savefig(out)
    print("wrote", out)


if __name__ == "__main__":
    main()
