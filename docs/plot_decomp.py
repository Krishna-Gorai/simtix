#!/usr/bin/env python3
"""plot_decomp.py - efficiency factor of CVA6, Ara, Vortex and FGPU against SIMTiX.

Reads docs/model_decomp.csv (docs/model_decomp.py) and draws, for every benchmark of the
lane study (Fig. 7: the 17 applications, eight Rodinia and seven RiVEC benchmarks, in the
same order and groups), the efficiency factor eta_S / eta_X of each machine on a log axis
(above 1: SIMTiX sustains a larger fraction of its peak). Ara has no point on MLP and
Smith-Waterman (wrong results).
Produces docs/figs/decomp.pdf (and .png).  Usage:  python docs/plot_decomp.py
"""
import csv
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import plot_style  # noqa: E402
from plot_style import plt, INK, MUTED  # noqa: E402
from plot_lanes_suites import ORDER, NAME  # noqa: E402

CSV = os.path.join(HERE, "model_decomp.csv")
OUT = os.path.join(HERE, "figs", "decomp.pdf")
MACH = [("cva6", "CVA6", "#2a78d6", "o"), ("ara", "Ara", "#eb6834", "s"),
        ("vortex", "Vortex", "#1baf7a", "^"), ("fgpu", "FGPU", "#8e44ad", "D")]
SUITES = [("Apps", "apps", "Applications"), ("Rodinia", "rodinia", "Rodinia"),
          ("RiVEC", "rivec", "RiVEC")]


def main():
    plot_style.apply()
    eff = {(r["suite"], r["key"], r["machine"]): float(r["efficiency_factor"])
           for r in csv.DictReader(open(CSV))}
    fig, ax = plt.subplots(figsize=(7.16, 2.3))
    x, xs, labels, bounds = 0.0, [], [], []
    for suite, okey, title in SUITES:
        start = x
        for k in ORDER[okey]:
            for mi, (m, mname, col, mk) in enumerate(MACH):
                v = eff.get((suite, k, m))
                if v is None:
                    continue
                dx = (mi - (len(MACH) - 1) / 2) * 0.17      # dodge, so that equal values stay apart
                ax.plot(x + dx, v, linestyle="none", marker=mk, markersize=4.0,
                        markerfacecolor=col, markeredgecolor="white", markeredgewidth=0.4,
                        zorder=3, label=mname if not xs and suite == "Apps" else None)
            xs.append(x)
            labels.append(NAME.get(k, k))
            x += 1
        bounds.append((start, x - 1, title))
        x += 0.8
    ax.axhline(1, color=INK, lw=0.7, zorder=2)
    ax.set_yscale("log")
    ticks = [0.125, 0.25, 0.5, 1, 2, 4, 8, 16, 32]
    ax.set_yticks(ticks)
    ax.set_yticklabels([f"{t:g}" for t in ticks])
    ax.minorticks_off()
    yl = (0.09, 45)
    ax.set_ylim(*yl)
    for a, b, name in bounds:
        ax.text((a + b) / 2, 1.015, name, ha="center", va="bottom", fontsize=7.5, color=INK,
                transform=ax.get_xaxis_transform())
        if b < xs[-1]:
            ax.axvline(b + 0.9, color="#d6d6d6", lw=0.6, zorder=0)
    ax.set_xlim(-0.6, xs[-1] + 0.6)
    ax.set_xticks(xs)
    ax.set_xticklabels(labels, rotation=55, ha="right", rotation_mode="anchor", fontsize=6.5)
    ax.tick_params(axis="x", length=0, pad=2)
    ax.grid(axis="x", color="#efefef", lw=0.4)
    ax.set_ylabel(r"Efficiency factor $\eta_S/\eta_X$")
    ax.set_xlabel("Benchmark", labelpad=2)
    one = math.log(1 / yl[0]) / math.log(yl[1] / yl[0])          # axes fraction of y = 1
    ax.text(1.008, one + 0.03, "SIMTiX more\nefficient ↑", transform=ax.transAxes,
            fontsize=6.2, color=MUTED, ha="left", va="bottom")
    ax.text(1.008, one - 0.03, "machine more\nefficient ↓", transform=ax.transAxes,
            fontsize=6.2, color=MUTED, ha="left", va="top")
    ax.legend(loc="lower left", bbox_to_anchor=(0.0, 1.07), ncol=4, handletextpad=0.2,
              columnspacing=1.2, borderaxespad=0.1)
    fig.savefig(OUT)
    fig.savefig(OUT.replace(".pdf", ".png"), dpi=200)
    plt.close(fig)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
