#!/usr/bin/env python3
"""plot_vortex.py - Vortex / SIMTiX run time and energy per application.

Reads docs/vortex_apps.csv (cycles, sim/vortex_compare.py) and docs/vortex_syn.csv
(Fmax and power, sim/vortex_syn.py) and draws, for each application, Vortex's run
time (cycles / Fmax of each design) and energy (power x cycles x the constrained
period) relative to SIMTiX at 4, 8 and 16 Vortex warps. Above 1 favours SIMTiX.

Produces docs/figs/vortex_ratio.pdf.
Usage:  python docs/plot_vortex.py
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

RUNS = [("w4_bus128_ip", "4 warps"), ("w8_bus128_ip", "8 warps"), ("w16_bus128_ip", "16 warps")]
NAMES = {"gemm": "GEMM", "spmv": "SpMV", "stencil": "Stencil", "kmeans": "k-means",
         "bfs": "BFS", "scan": "Scan", "mlp": "MLP"}
COLORS = ["#4C72B0", "#DD8452", "#55A868"]


def main():
    syn = {r["design"]: r for r in csv.DictReader(open(os.path.join(HERE, "vortex_syn.csv")))}
    apps = [r for r in csv.DictReader(open(os.path.join(HERE, "vortex_apps.csv")))
            if r["launch"] == "total"]
    s = syn["simtix"]

    def cost(b, cyc):
        return cyc / float(b["fmax_mhz"]), float(b["power_w"]) * cyc * float(b["period_ns"])

    cases = [NAMES[r["case"].split("_")[0]] for r in apps]
    fig, axes = plt.subplots(1, 2, figsize=(7.16, 2.45), sharey=True)
    for ax, k, ylab in ((axes[0], 0, "Vortex / SIMTiX run time"),
                        (axes[1], 1, "Vortex / SIMTiX energy")):
        w = 0.26
        for i, (run, lab) in enumerate(RUNS):
            vals = [cost(syn[run], int(r[f"{run}_cycles"]))[k] /
                    cost(s, int(r["simtix_cycles"]))[k] for r in apps]
            ax.bar([j + (i - 1) * w for j in range(len(apps))], vals, w,
                   color=COLORS[i], label=lab)
        ax.axhline(1.0, color="#333333", lw=0.8)
        ax.set_yscale("log")
        ax.set_yticks([0.5, 1, 2, 4, 8])
        ax.set_yticklabels(["0.5", "1", "2", "4", "8"])
        ax.set_ylim(0.5, 9)
        ax.set_xticks(range(len(apps)))
        ax.set_xticklabels(cases, fontsize=7.5, rotation=30, ha="right", rotation_mode="anchor")
        ax.set_ylabel(ylab, fontsize=8)
        ax.tick_params(axis="y", labelsize=7.5)
        ax.grid(True, axis="y", alpha=0.3, which="both")
    axes[0].legend(fontsize=7, loc="upper left", ncol=3, frameon=False)
    fig.tight_layout(w_pad=1.0)
    os.makedirs(OUT, exist_ok=True)
    out = os.path.join(OUT, "vortex_ratio.pdf")
    fig.savefig(out)
    print("wrote", out)


if __name__ == "__main__":
    main()
