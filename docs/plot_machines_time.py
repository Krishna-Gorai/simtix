#!/usr/bin/env python3
"""plot_machines_time.py - execution time and cycles of the machines on Rodinia and RiVEC.

Reads docs/rodinia_results.csv and docs/rivec_results.csv (baselines/ara/compare_*.py, board
runs on the ZCU102) and draws, for every benchmark at its largest input (Rodinia's hotspot
at 1024):
  (a) the execution time of SIMTiX, CVA6, Ara, Vortex, FGPU and the Cortex-A53 (log scale);
  (b) the clock cycles of SIMTiX, CVA6, Ara, Vortex and FGPU (FGPU has no cycle counter:
      its cycles are its time times its clock of 187.48 MHz).
Produces docs/figs/rodinia_time.pdf and docs/figs/rivec_time.pdf (and .png).
Usage:  python docs/plot_machines_time.py
"""
import csv
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import plot_style  # noqa: E402
from plot_style import plt  # noqa: E402

FGPU_MHZ = 187.48
SUITES = {
    "rodinia": ("rodinia_results.csv", "Benchmark",
                [("pathfinder", 100000), ("backprop", 524288), ("bfs", 65536), ("hotspot", 1024),
                 ("nn", 42764), ("hotspot3d", 512), ("gaussian", 1024), ("kmeans", 494020)],
                {"hotspot3d": "hotspot3D"}),
    "rivec": ("rivec_results.csv", "Application",
              [("axpy", 2097152), ("matmul", 512), ("spmv", 85623), ("jacobi", 256),
               ("pathfinder", 2048), ("blackscholes", 65536), ("lavamd", 1000)],
              {"jacobi": "jacobi-2d", "lavamd": "lavaMD"}),
}
# machine, column prefix, colour, hatch
MACH = [("SIMTiX", "simtix", "#104281", ""), ("CVA6", "cva6", "#86b6ef", ""),
        ("Ara", "ara", "#eb6834", "////"), ("Vortex", "vortex", "#1baf7a", "\\\\\\\\"),
        ("FGPU", "fgpu", "#8e44ad", "xxxx"), ("A53", "a53_O2", "#eda100", "....")]


def series(r, col, cycles):
    if not cycles:
        return float(r[f"{col}_us"]) / 1000                       # ms
    if col == "fgpu":
        return float(r["fgpu_us"]) * FGPU_MHZ / 1e6               # Mcycles
    return int(r[f"{col}_cycles"]) / 1e6


def figure(suite):
    csvname, xlab, bench, names = SUITES[suite]
    rows = {(r["app"], int(r["size"])): r for r in csv.DictReader(open(os.path.join(HERE, csvname)))}
    sel = [rows[b] for b in bench]
    fig, axes = plt.subplots(1, 2, figsize=(7.16, 2.4))
    for k, ax in enumerate(axes):
        machs = MACH if k == 0 else MACH[:5]
        w = 0.84 / len(machs)
        for i, (m, col, colour, hat) in enumerate(machs):
            v = [series(r, col, k == 1) for r in sel]
            bx = [x + (i - (len(machs) - 1) / 2) * w for x in range(len(sel))]
            ax.bar(bx, v, w, color=colour, hatch=hat, edgecolor="white", linewidth=0.5, label=m,
                   zorder=2)
        ax.set_yscale("log")
        ax.minorticks_off()
        ax.yaxis.set_major_formatter(plt.FuncFormatter(
            lambda v, _: f"{v:g}" if v < 1000 else (f"{v / 1000:g}k" if v < 1e6 else f"{v / 1e6:g}M")))
        ax.set_xticks(range(len(sel)))
        ax.set_xticklabels([names.get(a, a) for a, _ in bench], rotation=30, ha="right",
                           rotation_mode="anchor")
        ax.tick_params(axis="x", length=0)
        ax.set_xlim(-0.55, len(sel) - 0.45)
        ax.set_xlabel(xlab, labelpad=3)
        plot_style.panel_tag(ax, "ab"[k])
    axes[0].set_ylabel("Execution time (ms)")
    axes[1].set_ylabel("Clock cycles (millions)")
    for ax in axes:
        lo, hi = ax.get_ylim()
        ax.set_ylim(lo, hi * 4)                                    # room for the panel tag
    h, l = axes[0].get_legend_handles_labels()
    fig.legend(h, l, loc="upper center", ncol=6, bbox_to_anchor=(0.5, 1.07), handlelength=1.6,
               handleheight=0.9, columnspacing=1.6)
    fig.tight_layout(w_pad=1.5)
    out = os.path.join(HERE, "figs", f"{suite}_time.pdf")
    fig.savefig(out)
    fig.savefig(out.replace(".pdf", ".png"), dpi=200)
    plt.close(fig)
    print("wrote", out)


def main():
    plot_style.apply()
    for s in SUITES:
        figure(s)


if __name__ == "__main__":
    main()
