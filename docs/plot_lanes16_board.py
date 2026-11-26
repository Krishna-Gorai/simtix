#!/usr/bin/env python3
"""plot_lanes16_board.py - the 16-lane SIMTiX on the ZCU102 against the 8-lane board design.

Reads docs/lanes16_board_results.csv (sim/compare_board_l16.py, from the board logs) and
docs/lanes16_cycles.csv (sim/compare_lanes_cycles.py, board-size simulations) and draws:
  (a) for every benchmark at its largest board input, the measured execution time of the
      8-lane design at 115.37 MHz and of the 16-lane design at 100 MHz (bars, log scale),
      with the Cortex-A53's time as a marker, grouped by suite;
  (b) the cycles measured on the board against the cycles of the board-size simulation, at
      8 and 16 lanes, for the simulated cases whose board run executes the same iterations.
Produces docs/figs/lanes16_board.pdf (and .png).  Usage:  python docs/plot_lanes16_board.py
"""
import csv
import os
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import plot_style  # noqa: E402
from plot_style import plt, INK, MUTED, RAMP2  # noqa: E402

BOARD = os.path.join(HERE, "lanes16_board_results.csv")
SIM = os.path.join(HERE, "lanes16_cycles.csv")
OUT = os.path.join(HERE, "figs", "lanes16_board.pdf")
SUITES = [("sync", "Sync"), ("apps", "Applications"), ("suite2", "Suite 2"),
          ("rodinia", "Rodinia"), ("rivec", "RiVEC")]
NAME = {
    "reduce_shfl": "reduce", "histogram": "histogram", "hist_shared": "hist. shared",
    "amo_contend": "AMO contend", "gemm": "GEMM", "spmv": "SpMV", "stencil": "stencil",
    "kmeans": "k-means", "bfs": "BFS", "scan": "scan", "mlp": "MLP", "gemmrb": "GEMM-RB",
    "scanseg": "seg. scan", "stencilrb": "stencil-RB", "kmeansu": "k-means-U", "spmvz": "SpMV-Z",
    "conv8": "CNN", "embag": "emb. bag", "hashj": "hash join", "mandel": "Mandelbrot",
    "swat": "Smith-W.", "pathfinder": "pathfinder", "hotspot": "hotspot", "jacobi2d": "Jacobi-2D",
    "atax": "ATAX", "bicg": "BiCG", "pagerank": "PageRank", "cc": "conn. comp.",
    "backprop": "backprop", "sort": "radix sort", "blackscholes": "Black-Scholes", "nn": "NN",
    "hotspot3d": "hotspot3D", "gaussian": "Gaussian", "axpy": "AXPY", "matmul": "matmul",
    "jacobi": "Jacobi-2D", "lavamd": "LavaMD"}
# board runs with more iterations than the board-size simulation of the same kernel
LONGER = {"rodinia/hotspot3d", "rodinia/gaussian", "rodinia/kmeans", "rivec/jacobi",
          "rivec/pathfinder", "rivec/blackscholes", "rivec/lavamd"}
C8, C16 = RAMP2


def main():
    plot_style.apply()
    rows = list(csv.DictReader(open(BOARD)))
    for r in rows:
        r["N"] = int(r["N"])
    fig, (axa, axb) = plt.subplots(1, 2, figsize=(7.16, 2.75),
                                   gridspec_kw={"width_ratios": [1.5, 0.5]})

    # (a) execution time of every benchmark at its largest input
    xs, labels, x, bounds = [], [], 0.0, []
    bw = 0.4
    for s, sname in SUITES:
        best = {}
        for r in rows:
            if r["suite"] == s and (r["kernel"] not in best or r["N"] > best[r["kernel"]]["N"]):
                best[r["kernel"]] = r
        start = x
        for k, r in best.items():
            t8, t16, ta = (float(r[c]) / 1000 for c in ("us_8L_115MHz", "us_16L_100MHz", "a53_us_16Lrun"))
            axa.bar(x - bw / 2, t8, bw * 0.95, color=C8, lw=0, zorder=2)
            axa.bar(x + bw / 2, t16, bw * 0.95, color=C16, lw=0, zorder=2)
            axa.plot(x, ta, marker="_", ms=6.5, mew=1.3, color=INK, zorder=3, linestyle="none")
            xs.append(x)
            labels.append(NAME.get(k, k))
            x += 1
        bounds.append((start, x - 1, sname))
        x += 0.8
    axa.set_yscale("log")
    axa.set_ylim(0.2, 1.2e5)
    ticks = [1, 10, 100, 1000, 10000]
    axa.set_yticks(ticks)
    axa.set_yticklabels(["1", "10", "100", "1k", "10k"])
    axa.minorticks_off()
    axa.set_xticks(xs)
    axa.set_xticklabels(labels, rotation=90, fontsize=6.6)
    axa.tick_params(axis="x", length=0, pad=2)
    axa.set_xlim(-0.8, x - 0.6)
    axa.set_ylabel("Execution time (ms)")
    axa.set_xlabel("Benchmark", labelpad=3)
    for a, b, sname in bounds:
        axa.text((a + b) / 2, 6.5e4, sname, ha="center", va="center", fontsize=7.5, color=INK)
        if b < xs[-1]:
            axa.axvline(b + 0.9, color="#dcdcdc", lw=0.6, zorder=0)
    h1 = axa.bar([0], [0], color=C8, label="8 lanes, 115.37 MHz")
    h2 = axa.bar([0], [0], color=C16, label="16 lanes, 100 MHz")
    h3, = axa.plot([], [], marker="_", ms=6.5, mew=1.3, color=INK, linestyle="none",
                   label="Cortex-A53, 1.2 GHz")
    axa.legend(handles=[h1, h2, h3], loc="lower left", bbox_to_anchor=(0.0, 1.0), ncol=3,
               handlelength=1.3, columnspacing=1.2, borderaxespad=0.1)
    axa.text(-0.02, 1.13, "(a)", transform=axa.transAxes, fontsize=8, color=INK, ha="right")

    # (b) cycles on the board against cycles in the board-size simulation
    sim = {r["case"]: r for r in csv.DictReader(open(SIM))}
    pts = {8: [], 16: []}
    for case, r in sim.items():
        suite, kern = case.split("/")
        if case in LONGER:
            continue
        cand = [b for b in rows if b["suite"] == suite and b["kernel"] == kern]
        if not cand:
            continue
        if suite == "rodinia" and kern == "hotspot":
            cand = [b for b in cand if b["N"] == 512]
        b = min(cand, key=lambda b: b["N"])   # the medium (simulated) input
        pts[8].append((int(r["cycles_l8_w8"]), int(b["cycles_8L"])))
        pts[16].append((int(r["cycles_l16_w8_s2_k128"]), int(b["cycles_16L"])))
    lo, hi = 1e4, 1e8
    axb.plot([lo, hi], [lo, hi], color=MUTED, lw=0.6, zorder=1)
    med = {}
    for L, col, mk in ((8, C8, "o"), (16, C16, "s")):
        axb.plot([p for p, _ in pts[L]], [q for _, q in pts[L]], marker=mk, ms=3.2, mew=0.5,
                 mec="white", color=col, linestyle="none", zorder=2, label=f"{L} lanes")
        med[L] = statistics.median(abs(q / p - 1) for p, q in pts[L])
    axb.set_xscale("log")
    axb.set_yscale("log")
    axb.set_xlim(lo, hi)
    axb.set_ylim(lo, hi)
    dec = [1e4, 1e5, 1e6, 1e7, 1e8]
    axb.set_xticks(dec)
    axb.set_yticks(dec)
    axb.set_xticklabels(["$10^4$", "", "$10^6$", "", "$10^8$"])
    axb.set_yticklabels(["$10^4$", "", "$10^6$", "", "$10^8$"])
    axb.minorticks_off()
    axb.grid(True, axis="both")
    axb.set_xlabel("Cycles, simulation")
    axb.set_ylabel("Cycles, board")
    axb.legend(loc="upper left", fontsize=6.4, handletextpad=0.1, borderaxespad=0.2)
    axb.text(0.97, 0.04, f"{len(pts[8])} cases\nmedian error\n{med[8] * 100:.1f}% and {med[16] * 100:.1f}%",
             transform=axb.transAxes, ha="right", va="bottom", fontsize=6.4, color=MUTED)
    axb.text(-0.22, 1.10, "(b)", transform=axb.transAxes, fontsize=8, color=INK, ha="right")
    print(f"(b): {len(pts[8])} cases; median |board/sim - 1| 8L {med[8]:.3f}, 16L {med[16]:.3f}")

    fig.subplots_adjust(wspace=0.25)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    fig.savefig(OUT)
    fig.savefig(OUT.replace(".pdf", ".png"), dpi=200)
    print("written", OUT)


if __name__ == "__main__":
    main()
