"""prep_supp.py - prepare the inputs of simtix_tvlsi_supp.tex: prefix references to the
paper with P- (resolved by xr from simtix_tvlsi.aux) and split the moved figures; strip
the subsection heading of the memory-system part. Sources: supp_figs.tex (figure blocks
moved out of the paper), supp_evalmem.tex, supp_lanes.tex. Safe to run more than once.
Usage (in docs/paper):  python prep_supp.py"""
import re
D = r"C:\work\SIMTiX-v2\docs\paper" + "\\"
LOCAL = {"fig:rodinia", "fig:rivec", "fig:vortex", "fig:lanes", "sup:lanes", "sup:evalmem",
         "sec:evalmem"}


def prefix(t):
    return re.sub(r"\\ref\{([^}]+)\}", lambda m: m.group(0)
                  if m.group(1) in LOCAL or m.group(1).startswith("P-")
                  else "\\ref{P-%s}" % m.group(1), t)


figs = open(D + "supp_figs.tex", encoding="utf-8").read()
blocks = re.findall(r"\\begin\{figure\*\}.*?\\end\{figure\*\}", figs, re.S)
byl = {re.search(r"\\label\{([^}]+)\}", b).group(1): b for b in blocks}
open(D + "supp_figs_rd.tex", "w", encoding="utf-8").write(
    prefix(byl["fig:rodinia"] + "\n\n" + byl["fig:rivec"]) + "\n")
open(D + "supp_figs_vx.tex", "w", encoding="utf-8").write(prefix(byl["fig:vortex"]) + "\n")
mem = open(D + "supp_evalmem.tex", encoding="utf-8").read()
mem = mem.split("\n", 1)[1]                       # drop the \subsection line
open(D + "supp_evalmem_x.tex", "w", encoding="utf-8").write(prefix(mem))
lanes = open(D + "supp_lanes.tex", encoding="utf-8").read()
open(D + "supp_lanes.tex", "w", encoding="utf-8").write(prefix(lanes))
print("ok", sorted(byl))
