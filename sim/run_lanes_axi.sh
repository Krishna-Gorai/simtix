#!/bin/bash
# run_lanes_axi.sh - AXI byte counts (AXICOUNT=1) for docs/plot_lanes_metrics.py: runs only the cases
# that have no _axi log yet, one lane count at a time (4, 8, 16).  wsl -e bash -lc "bash /mnt/c/work/SIMTiX-v2/sim/run_lanes_axi.sh"
cd /mnt/c/work/SIMTiX-v2
for L in 4 8 16; do
  case $L in 4) ENV="L1KB=32"; LOG=sim_l4_w8_k32_axi.log;; 8) ENV=""; LOG=sim_l8_w8_axi.log;;
             16) ENV="L1KB=128"; LOG=sim_l16_w8_s2_k128_axi.log;; esac
  sel=""
  for man in build_b$L/{sync,apps,suite2,rodinia,rivec}/*/apps.manifest; do
    d=$(dirname "$man"); [ -f "$d/$LOG" ] || sel="$sel ${d#build_b$L/}"
  done
  echo "== L=$L: $(echo $sel | wc -w) cases left"
  [ -n "$sel" ] && env $ENV AXICOUNT=1 bash sim/run_lanes_board.sh $L $sel
done
