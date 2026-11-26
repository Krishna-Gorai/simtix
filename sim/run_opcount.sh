#!/bin/bash
# run_opcount.sh - FP32 operation counts (SIMTIX_OPCOUNT) for docs/plot_machines_throughput.py,
# eight-lane board configuration, one simulation at a time. Writes sim_l8_w8_ops.log next to
# each case:
#   build_b8/{rodinia,rivec}/<app>/       the board-size cases (sim/gen_lanes_board.py 8)
#   build_b8/apps/mandel/                 Mandelbrot 256^2 (checks the per-pixel FLOP formula)
#   build_dram8/apps/<kernel>/            GEMM-RB 256^3, SpMV-Z 65,536, Stencil-RB 512^2, embedding
#                                         bag 4,096 (the board's larger inputs; manifests have
#                                         Windows paths, rewritten here to apps_wsl.manifest)
#   wsl -e bash -lc "bash /mnt/c/work/SIMTiX-v2/sim/run_opcount.sh"
cd /mnt/c/work/SIMTiX-v2 || exit 1
OPCOUNT=1 bash sim/run_lanes_board.sh 8 rodinia/backprop rodinia/hotspot rodinia/nn \
  rodinia/hotspot3d rodinia/gaussian rodinia/kmeans rivec/matmul rivec/axpy rivec/spmv \
  rivec/jacobi rivec/blackscholes rivec/lavamd apps/mandel
BIN=$HOME/simtix_l8_w8_ops/tb_apps
fails=0
for k in gemmrb spmvz stencilrb embag; do
  d=build_dram8/apps/$k
  sed 's#C:/#/mnt/c/#g' $d/apps.manifest > $d/apps_wsl.manifest
  t0=$(date +%s)
  out=$("$BIN" +MANIFEST=/mnt/c/work/SIMTiX-v2/$d/apps_wsl.manifest 2>&1)
  echo "$out" > $d/sim_l8_w8_ops.log
  if echo "$out" | grep -aq "\[tb_apps\] PASS"; then st=PASS; else st=FAIL; fails=$((fails + 1)); fi
  echo "$st dram/$k ($(echo "$out" | grep -a "\[tb_apps\] [0-9]* checks" | tail -1), $(( $(date +%s) - t0 )) s)"
done
echo "== dram: $fails failing case(s)"
