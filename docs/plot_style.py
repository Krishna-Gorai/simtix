"""plot_style.py - shared matplotlib style for the paper's figures.

Times at the IEEE caption size, recessive axes and grid, and a one-hue blue
ramp for ordered series (validated as an ordinal ramp: monotone lightness,
visible steps, light end >= 2:1 on white).
"""
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

# Ordinal blue ramp, light -> dark (steps 250, 450, 650 and 250, 600).
RAMP3 = ["#86b6ef", "#2a78d6", "#104281"]
RAMP2 = ["#86b6ef", "#184f95"]
INK = "#222222"       # text and the reference line
MUTED = "#6b6b6b"     # secondary text, tick labels
GRID = "#dcdcdc"


def apply():
    plt.rcParams.update({
        "font.family": "serif",
        "font.serif": ["Times New Roman", "Times", "Nimbus Roman", "DejaVu Serif"],
        "mathtext.fontset": "stix",
        "font.size": 8,
        "axes.labelsize": 8,
        "xtick.labelsize": 7.5,
        "ytick.labelsize": 7.5,
        "legend.fontsize": 7.5,
        "axes.edgecolor": MUTED,
        "axes.linewidth": 0.6,
        "axes.labelcolor": INK,
        "xtick.color": MUTED,
        "ytick.color": MUTED,
        "xtick.labelcolor": INK,
        "ytick.labelcolor": INK,
        "xtick.major.width": 0.6,
        "ytick.major.width": 0.6,
        "xtick.major.size": 2.5,
        "ytick.major.size": 2.5,
        "ytick.minor.size": 0,
        "axes.spines.top": False,
        "axes.spines.right": False,
        "axes.grid": True,
        "axes.grid.axis": "y",
        "grid.color": GRID,
        "grid.linewidth": 0.5,
        "axes.axisbelow": True,
        "legend.frameon": False,
        "pdf.fonttype": 42,
        "ps.fonttype": 42,
        "savefig.bbox": "tight",
        "savefig.pad_inches": 0.02,
    })
