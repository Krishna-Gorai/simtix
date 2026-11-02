#!/usr/bin/env python3
"""plot_lanes.py - application speedup with the lane count.

Reads docs/lanes_apps.csv (sim/lane_sweep.py: cycles per launch at 4, 8 and 16
lanes, 4 warps) and draws each application's speedup at 8 and 16 lanes over the
4-lane accelerator, sorted by the 16-lane speedup, with the linear speedups
(2 and 4) as references.

Produces docs/figs/lanes_speedup.pdf.
Usage:  python docs/plot_lanes.py
"""
import csv
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "figs")
sys.path.insert(0, HERE)

import plot_style  # noqa: E402
from plot_style import plt, RAMP2, INK, MUTED  # noqa: E402

NAMES = {"gemm": "GEMM", "spmv": "SpMV", "stencil": "Stencil", "kmeans": "k-means",
         "bfs": "BFS", "scan": "Scan", "mlp": "MLP"}


def main():
    plot_style.apply()
    tot = {}
    for r in csv.DictReader(open(os.path.join(HERE, "lanes_apps.csv"))):
        k = (r["case"].split("_")[0], int(r["lanes"]))
        tot[k] = tot.get(k, 0) + int(r["cycles"])
    sp = {a: {l: tot[(a, 4)] / tot[(a, l)] for l in (8, 16)} for a in NAMES}
    order = sorted(NAMES, key=lambda a: -sp[a][16])

    fig, ax = plt.subplots(figsize=(3.45, 2.1))
    w = 0.38
    xs = range(len(order))
    for i, (l, lab) in enumerate(((8, "8 lanes"), (16, "16 lanes"))):
        vals = [sp[a][l] for a in order]
        bx = [x + (i - 0.5) * w for x in xs]
        ax.bar(bx, vals, w, color=RAMP2[i], edgecolor="white", linewidth=0.6, label=lab,
               zorder=2)
        if l == 16:
            for x, v in zip(bx, vals):
                ax.text(x, v + 0.06, f"{v:.2f}", ha="center", va="bottom", fontsize=6.3,
                        color=INK)
    for y, t in ((2, "ideal\n2$\\times$"), (4, "ideal\n4$\\times$")):
        ax.axhline(y, color=MUTED, lw=0.7, ls=(0, (3, 2)), zorder=1)
        ax.text(len(order) - 0.33, y, t, ha="left", va="center", fontsize=6.3,
                color=MUTED, linespacing=0.95, clip_on=False)
    ax.set_xticks(list(xs))
    ax.set_xticklabels([NAMES[a] for a in order], rotation=30, ha="right",
                       rotation_mode="anchor")
    ax.tick_params(axis="x", length=0)
    ax.set_xlim(-0.6, len(order) - 0.4)
    ax.set_ylim(0, 4.75)
    ax.set_yticks([0, 1, 2, 3, 4])
    ax.set_ylabel("Speedup over 4 lanes")
    ax.legend(loc="upper center", ncol=2, bbox_to_anchor=(0.5, 1.16), handlelength=1.2)
    fig.tight_layout()
    os.makedirs(OUT, exist_ok=True)
    out = os.path.join(OUT, "lanes_speedup.pdf")
    fig.savefig(out)
    fig.savefig(out.replace(".pdf", ".png"), dpi=200)
    print("wrote", out)


if __name__ == "__main__":
    main()
