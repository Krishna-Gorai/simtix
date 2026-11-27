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


def panel_tag(ax, tag, x=0.012, y=0.985):
    """the (a)/(b) tag of a panel, in its top-left corner; the caption names the panel"""
    ax.text(x, y, f"({tag})", transform=ax.transAxes, fontsize=8, color=INK, ha="left",
            va="top", zorder=6, bbox=dict(boxstyle="square,pad=0.1", fc="white", ec="none"))


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


# Benchmark names as the paper's tables print them: the applications by their full names,
# the Rodinia and RiVEC benchmarks by their suites' own (lower-case) names. A kernel key can
# occur in several suites (kmeans, bfs, spmv, pathfinder), so the label depends on the suite.
APP_NAME = {
    'gemm': 'GEMM', 'gemmrb': 'GEMM-RB', 'stencil': 'Stencil', 'stencilrb': 'Stencil-RB',
    'conv8': 'CNN', 'mlp': 'MLP', 'embag': 'Embedding bag', 'kmeans': 'k-means',
    'kmeansu': 'k-means-U', 'mandel': 'Mandelbrot', 'swat': 'Smith-Waterman', 'scan': 'Scan',
    'scanseg': 'Segmented scan', 'spmv': 'SpMV', 'spmvz': 'SpMV-Z', 'bfs': 'BFS',
    'hashj': 'Hash join'}
RODINIA_NAME = {
    'hotspot': 'hotspot', 'hotspot3d': 'hotspot3D', 'backprop': 'backprop', 'kmeans': 'kmeans',
    'nn': 'nn', 'gaussian': 'gaussian', 'pathfinder': 'pathfinder', 'bfs': 'bfs'}
RIVEC_NAME = {
    'matmul': 'matmul', 'axpy': 'axpy', 'jacobi': 'jacobi-2d', 'blackscholes': 'blackscholes',
    'lavamd': 'lavaMD', 'pathfinder': 'pathfinder', 'spmv': 'spmv'}


def bench_label(suite, key, default=None):
    """the name of benchmark `key` of `suite` in the paper's tables"""
    s = str(suite).lower()
    table = RODINIA_NAME if s.startswith('rod') else RIVEC_NAME if s.startswith('riv') else APP_NAME
    return table.get(key, default if default is not None else key)
