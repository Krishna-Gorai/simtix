#!/usr/bin/env python3
"""plot_rodinia.py - Rodinia on the ZCU102: each machine's time and cycles relative to SIMTiX.

Reads docs/rodinia_results.csv (baselines/ara/compare_rodinia.py) and draws, for each of
the eight benchmarks (hotspot at 1024) and their geometric mean:
  (a) run time of CVA6, Ara, Vortex and the A53 divided by SIMTiX's run time;
  (b) clock cycles of CVA6, Ara and Vortex divided by SIMTiX's cycles.
Above 1 favours SIMTiX. Bars grow from parity (1) on a log axis.

Colours: categorical slots 1-4 of the reference palette (blue, orange, aqua, yellow), one
per machine in both panels. Adjacent pairs checked under protan/deutan/tritan simulation
(OKLab Delta E x 100 >= 9.1, normal vision >= 13.7); each machine also has its own hatch,
so the figure reads in grayscale.

Produces docs/figs/rodinia_ratio.pdf (and .png).
Usage:  python docs/plot_rodinia.py
"""
import csv
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "figs")
sys.path.insert(0, HERE)

import plot_style  # noqa: E402
from plot_style import plt, INK  # noqa: E402

CSV = os.path.join(HERE, "rodinia_results.csv")
BENCH = [("pathfinder", 100000), ("backprop", 524288), ("bfs", 65536), ("hotspot", 1024),
         ("nn", 42764), ("hotspot3d", 512), ("gaussian", 1024), ("kmeans", 494020)]
NAMES = {"hotspot3d": "hotspot3D"}
# machine, colour, hatch
MACH = [("CVA6", "#2a78d6", ""), ("Ara", "#eb6834", "////"),
        ("Vortex", "#1baf7a", "\\\\\\\\"), ("A53", "#eda100", "....")]
CLK = {"simtix": 115.37, "cva6": 78.95, "ara": 78.95, "vortex": 125.0}


def gmean(v):
    return math.exp(sum(math.log(x) for x in v) / len(v))


def main():
    plot_style.apply()
    plt.rcParams.update({"hatch.color": "white", "hatch.linewidth": 0.6})
    rows = {(r["app"], int(r["size"])): r for r in csv.DictReader(open(CSV))}
    sel = [rows[b] for b in BENCH]
    cases = [NAMES.get(a, a) for a, _ in BENCH] + ["Geo. mean"]
    xs = list(range(len(sel))) + [len(sel) + 0.6]            # gap before the mean

    def series(panel, m):
        if panel == 0:
            v = [float(r[f"{m.lower()}_over_simtix"]) for r in sel]
        else:
            v = [int(r[f"{m.lower()}_cycles"]) / int(r["simtix_cycles"]) for r in sel]
        return v + [gmean(v)]

    fig, axes = plt.subplots(1, 2, figsize=(7.16, 2.35), sharey=True,
                             gridspec_kw={"width_ratios": [1.0, 1.0]})
    panels = ((0, "(a) Run time, each machine at its own clock", MACH),
              (1, "(b) Clock cycles", MACH[:3]))
    for ax, (k, sub, machs) in zip(axes, panels):
        w = 0.8 / len(machs)
        for i, (m, col, hat) in enumerate(machs):
            vals = series(k, m)
            bx = [x + (i - (len(machs) - 1) / 2) * w for x in xs]
            ax.bar(bx, [v - 1 for v in vals], w, bottom=1, color=col, hatch=hat,
                   edgecolor="white", linewidth=0.6, label=m, zorder=2)
            # direct labels on the geometric mean only
            g = vals[-1]
            ax.text(bx[-1], g * 1.08 if g >= 1 else g / 1.08, f"{g:.2f}" if g < 10 else f"{g:.1f}",
                    ha="center", va="bottom" if g >= 1 else "top", fontsize=6.3, color=INK,
                    rotation=90)
        ax.axhline(1.0, color=INK, lw=0.8, zorder=3)
        ax.axvline(len(sel) - 0.2, color="#bbbbbb", lw=0.5, ls=":", zorder=1)
        ax.set_yscale("log")
        ticks = [0.1, 0.3, 1, 3, 10, 30]
        ax.set_yticks(ticks)
        ax.set_yticklabels([f"{t:g}" for t in ticks])
        ax.minorticks_off()
        ax.set_ylim(0.05, 120)
        ax.set_xlim(-0.6, xs[-1] + 0.6)
        ax.set_xticks(xs)
        ax.set_xticklabels(cases, rotation=30, ha="right", rotation_mode="anchor")
        ax.tick_params(axis="x", length=0)
        ax.set_xlabel(sub, labelpad=4)
        ax.text(len(sel) - 0.2, 0.93, "SIMTiX = 1", fontsize=6.5, color=INK, ha="center",
                va="top", bbox=dict(facecolor="white", edgecolor="none", pad=0.6), zorder=4)
    axes[0].set_ylabel("Machine / SIMTiX")
    h, l = axes[0].get_legend_handles_labels()
    fig.legend(h, l, loc="upper center", ncol=4, bbox_to_anchor=(0.5, 1.07),
               handlelength=1.6, handleheight=0.9, columnspacing=1.8)
    fig.tight_layout(w_pad=1.2)
    os.makedirs(OUT, exist_ok=True)
    out = os.path.join(OUT, "rodinia_ratio.pdf")
    fig.savefig(out)
    fig.savefig(out.replace(".pdf", ".png"), dpi=200)
    print("wrote", out)


if __name__ == "__main__":
    main()
