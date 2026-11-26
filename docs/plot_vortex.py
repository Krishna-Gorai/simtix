#!/usr/bin/env python3
"""plot_vortex.py - SIMTiX and Vortex out of context: IPC, execution time and energy.

Reads docs/vortex_apps.csv (cycles and warp instructions, sim/vortex_compare.py) and
docs/vortex_syn.csv (Fmax and power, sim/vortex_syn.py) and draws, for each application,
SIMTiX with four warps and Vortex with 4, 8 and 16 warps of eight threads:
  (a) the IPC (warp instructions per cycle), as in Vortex's own IPC plots;
  (b) the execution time at each design's Fmax;
  (c) the energy of one run at 100 MHz (vectorless power x cycles x 10 ns).
Produces docs/figs/vortex_metrics.pdf (and .png).  Usage:  python docs/plot_vortex.py
"""
import csv
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import plot_style  # noqa: E402
from plot_style import plt, RAMP3  # noqa: E402

RUNS = [("simtix", "simtix", "SIMTiX, 4 warps", "#222222"),
        ("w4_bus128_ip", "w4_bus128_ip", "Vortex, 4 warps", RAMP3[0]),
        ("w8_bus128_ip", "w8_bus128_ip", "Vortex, 8 warps", RAMP3[1]),
        ("w16_bus128_ip", "w16_bus128_ip", "Vortex, 16 warps", RAMP3[2])]
NAMES = {"gemm": "GEMM", "spmv": "SpMV", "stencil": "Stencil", "kmeans": "k-means",
         "bfs": "BFS", "scan": "Scan", "mlp": "MLP"}


def main():
    plot_style.apply()
    syn = {r["design"]: r for r in csv.DictReader(open(os.path.join(HERE, "vortex_syn.csv")))}
    apps = [r for r in csv.DictReader(open(os.path.join(HERE, "vortex_apps.csv")))
            if r["launch"] == "total"]
    cases = [NAMES[r["case"].split("_")[0]] for r in apps]
    fig, axes = plt.subplots(1, 3, figsize=(7.16, 2.2))
    w = 0.2
    for i, (design, col, lab, colour) in enumerate(RUNS):
        b = syn[design]
        cyc = [int(r[f"{col}_cycles"]) for r in apps]
        ins = [int(r[f"{col}_insns"]) for r in apps]
        vals = ([n / c for n, c in zip(ins, cyc)],                                 # IPC
                [c / float(b["fmax_mhz"]) for c in cyc],                           # us
                [float(b["power_w"]) * c * float(b["period_ns"]) * 1e-3 for c in cyc])  # uJ
        bx = [x + (i - 1.5) * w for x in range(len(apps))]
        for ax, v in zip(axes, vals):
            ax.bar(bx, v, w * 0.92, color=colour, lw=0, label=lab, zorder=2)
    for k, (ax, ylab) in enumerate(zip(axes, ("IPC", "Execution time (µs)", "Energy (µJ)"))):
        ax.set_ylabel(ylab)
        ax.set_xticks(range(len(apps)))
        ax.set_xticklabels(cases, rotation=40, ha="right", rotation_mode="anchor", fontsize=6.8)
        ax.tick_params(axis="x", length=0)
        ax.set_xlim(-0.55, len(apps) - 0.45)
        ax.set_xlabel("Application", labelpad=2)
        if k:
            ax.set_yscale("log")
            ax.minorticks_off()
            ax.yaxis.set_major_formatter(plt.FuncFormatter(lambda v, _: f"{v:g}" if v < 1000 else f"{v / 1000:g}k"))
        lo, hi = ax.get_ylim()
        ax.set_ylim(0 if k == 0 else lo, hi * (1.25 if k == 0 else 3))   # room for the tag
        plot_style.panel_tag(ax, "abc"[k])
    h, l = axes[0].get_legend_handles_labels()
    fig.legend(h, l, loc="upper center", ncol=4, bbox_to_anchor=(0.5, 1.08), handlelength=1.3,
               columnspacing=1.6)
    fig.tight_layout(w_pad=1.0)
    out = os.path.join(HERE, "figs", "vortex_metrics.pdf")
    fig.savefig(out)
    fig.savefig(out.replace(".pdf", ".png"), dpi=200)
    print("wrote", out)


if __name__ == "__main__":
    main()
