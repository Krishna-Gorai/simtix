#!/usr/bin/env python3
"""plot_vortex.py - Vortex / SIMTiX run time and energy per application.

Reads docs/vortex_apps.csv (cycles, sim/vortex_compare.py) and docs/vortex_syn.csv
(Fmax and power, sim/vortex_syn.py) and draws, for each application and their
geometric mean, Vortex's run time (cycles / Fmax of each design) and energy
(power x cycles x the constrained period) relative to SIMTiX at 4, 8 and 16
Vortex warps. Above 1 favours SIMTiX.

Produces docs/figs/vortex_ratio.pdf.
Usage:  python docs/plot_vortex.py
"""
import csv
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "figs")
sys.path.insert(0, HERE)

import plot_style  # noqa: E402
from plot_style import plt, RAMP3, INK  # noqa: E402

RUNS = [("w4_bus128_ip", "Vortex, 4 warps"), ("w8_bus128_ip", "Vortex, 8 warps"),
        ("w16_bus128_ip", "Vortex, 16 warps")]
NAMES = {"gemm": "GEMM", "spmv": "SpMV", "stencil": "Stencil", "kmeans": "k-means",
         "bfs": "BFS", "scan": "Scan", "mlp": "MLP"}


def gmean(v):
    return math.exp(sum(math.log(x) for x in v) / len(v))


def main():
    plot_style.apply()
    syn = {r["design"]: r for r in csv.DictReader(open(os.path.join(HERE, "vortex_syn.csv")))}
    apps = [r for r in csv.DictReader(open(os.path.join(HERE, "vortex_apps.csv")))
            if r["launch"] == "total"]
    s = syn["simtix"]

    def cost(b, cyc):
        return cyc / float(b["fmax_mhz"]), float(b["power_w"]) * cyc * float(b["period_ns"])

    cases = [NAMES[r["case"].split("_")[0]] for r in apps] + ["Geo. mean"]
    xs = list(range(len(apps))) + [len(apps) + 0.6]          # gap before the mean
    fig, axes = plt.subplots(1, 2, figsize=(7.16, 2.15), sharey=True)
    w = 0.27
    for ax, k, sub in ((axes[0], 0, "(a) Run time, each design at its $F_{\\max}$"),
                       (axes[1], 1, "(b) Energy at 100 MHz")):
        for i, (run, lab) in enumerate(RUNS):
            vals = [cost(syn[run], int(r[f"{run}_cycles"]))[k] /
                    cost(s, int(r["simtix_cycles"]))[k] for r in apps]
            vals.append(gmean(vals))
            bx = [x + (i - 1) * w for x in xs]
            # bars grow from parity (1): up where SIMTiX is ahead, down where Vortex is
            ax.bar(bx, [v - 1 for v in vals], w, bottom=1, color=RAMP3[i],
                   edgecolor="white", linewidth=0.6, label=lab, zorder=2)
            # direct labels on the geometric mean only
            ax.text(bx[-1], vals[-1] * 1.06, f"{vals[-1]:.2f}", ha="center", va="bottom",
                    fontsize=6.5, color=INK, rotation=90)
        ax.axhline(1.0, color=INK, lw=0.8, zorder=3)
        ax.axvline(len(apps) - 0.2, color="#bbbbbb", lw=0.5, ls=":", zorder=1)
        ax.set_yscale("log")
        ax.set_yticks([0.75, 1, 2, 4, 8])
        ax.set_yticklabels(["0.75", "1", "2", "4", "8"])
        ax.minorticks_off()
        ax.set_ylim(0.72, 11)
        ax.set_xlim(-0.55, xs[-1] + 0.55)
        ax.set_xticks(xs)
        ax.set_xticklabels(cases, rotation=30, ha="right", rotation_mode="anchor")
        ax.tick_params(axis="x", length=0)
        ax.set_xlabel(sub, labelpad=4)
        ax.text(len(apps) - 0.2, 0.95, "SIMTiX = 1", fontsize=6.5, color=INK, ha="center",
                va="top")
    axes[0].set_ylabel("Vortex / SIMTiX")
    h, l = axes[0].get_legend_handles_labels()
    fig.legend(h, l, loc="upper center", ncol=3, bbox_to_anchor=(0.5, 1.07),
               handlelength=1.2, columnspacing=1.6)
    fig.tight_layout(w_pad=1.2)
    os.makedirs(OUT, exist_ok=True)
    out = os.path.join(OUT, "vortex_ratio.pdf")
    fig.savefig(out)
    fig.savefig(out.replace(".pdf", ".png"), dpi=200)
    print("wrote", out)


if __name__ == "__main__":
    main()
