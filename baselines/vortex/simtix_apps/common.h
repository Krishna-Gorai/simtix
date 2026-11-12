// SIMTiX application suite on Vortex: the kernel argument shared by host and kernel.
#ifndef _COMMON_H_
#define _COMMON_H_

#include <stdint.h>

// Kernels (main.cpp maps the manifest's KERNEL lines, by file name, to these).
enum {
  APP_GEMM, APP_SPMV, APP_STENCIL, APP_KMEANS, APP_BFS, APP_SCAN, APP_SCAN_ADD, APP_MLP,
  APP_CONV8, APP_EMBAG, APP_HASHJ, APP_MANDEL, APP_SWAT,
  // Rodinia (docs/rodinia_plan.md); kernels/suite2 and kernels/rodinia .S files
  APP_PATHFINDER, APP_BP_FORWARD, APP_BP_ADJUST, APP_HOTSPOT_RD, APP_NN, APP_HOTSPOT3D,
  APP_GAUSS_FAN1, APP_GAUSS_FAN2, APP_KMEANS_RD,
  // RiVEC batch 1 (docs/rivec_plan.md); kernels/rivec .S files
  APP_AXPY_RV, APP_JACOBI_RV, APP_BS_RV, APP_LAVAMD_RV,
  APP_COUNT
};

typedef struct {
  uint32_t app;       // kernel slot
  uint32_t params;    // device address of the launch's parameter block
  uint32_t threads;   // threads in the launch
} kernel_arg_t;

#endif
