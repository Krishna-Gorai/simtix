#!/usr/bin/env python3
"""plot_closure.py - the timing-closure arc figure, from the sign-off reports.

Parses the worst-path "Data Path Delay" (logic/route split) and the worst
"Slack" out of each step's committed post_route_timing.rpt and draws the
placed critical path as a stacked logic+routing bar per closure step, with
the achieved Fmax above each bar and the 10 ns (100 MHz) requirement line.
The routing share stays dominant at every step - the visual form of the
paper's interconnect-bound finding.

Produces docs/figs/fp_closure.png.
Usage:  python docs/plot_closure.py
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
FPGA = os.path.join(os.path.dirname(HERE), "fpga")
OUT  = os.path.join(HERE, "figs")

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
except ImportError:
    sys.exit("matplotlib is required: pip install matplotlib")

# (label, reports dir) in closure order; all are committed sign-off reports.
STEPS = [
    ("1: two-stage\nFMA",        "reports_fp_impl"),
    ("2: + shared\nserial SFU",  "reports_fp_sharedsfu"),
    ("3: three-stage\nFMA",      "reports_fp_3stage"),
    ("SoC: in-context\n+ pins",  "reports_fp_chip"),
]
PERIOD = 10.0   # ns, the 100 MHz constraint in every run

def worst_path(rpt):
    """First (= worst) slack and data-path logic/route split in the report."""
    slack = logic = route = None
    with open(rpt) as f:
        for line in f:
            if slack is None:
                m = re.search(r"Slack\s*\(\w+\)\s*:\s*(-?[\d.]+)ns", line)
                if m: slack = float(m.group(1))
            m = re.search(r"Data Path Delay:\s*[\d.]+ns\s*"
                          r"\(logic\s*([\d.]+)ns.*route\s*([\d.]+)ns", line)
            if m:
                logic, route = float(m.group(1)), float(m.group(2))
                break
    if None in (slack, logic, route):
        sys.exit(f"could not parse worst path from {rpt}")
    return slack, logic, route

def main():
    os.makedirs(OUT, exist_ok=True)
    labels, logics, routes, fmaxs = [], [], [], []
    for label, d in STEPS:
        rpt = os.path.join(FPGA, d, "post_route_timing.rpt")
        slack, logic, route = worst_path(rpt)
        labels.append(label); logics.append(logic); routes.append(route)
        fmaxs.append(1000.0 / (PERIOD - slack))

    x = range(len(labels))
    plt.figure(figsize=(6, 3.4))
    plt.bar(x, logics, 0.58, color="#4C72B0", label="logic")
    plt.bar(x, routes, 0.58, bottom=logics, color="#DD8452", label="routing")
    for i in x:
        total = logics[i] + routes[i]
        plt.text(i, total + 0.25, f"{fmaxs[i]:.1f} MHz", ha="center",
                 fontsize=9, fontweight="bold")
        plt.text(i, logics[i] + routes[i]/2,
                 f"{100*routes[i]/total:.0f}%\nroute", ha="center", va="center",
                 fontsize=8, color="white", fontweight="bold")
    plt.axhline(PERIOD, ls="--", color="#555555", lw=1.2)
    plt.text(len(labels)-0.52, PERIOD + 0.22, "100 MHz requirement",
             ha="right", fontsize=8, color="#555555")
    plt.xticks(list(x), labels, fontsize=8)
    plt.ylabel("placed critical path (ns)")
    plt.ylim(0, 14.4)
    plt.legend(fontsize=8, loc="upper right")
    plt.grid(True, axis="y", alpha=0.3)
    plt.tight_layout()
    plt.savefig(os.path.join(OUT, "fp_closure.png"), dpi=150)
    plt.close()
    print(f"wrote {os.path.join(OUT, 'fp_closure.png')}")

if __name__ == "__main__":
    main()
