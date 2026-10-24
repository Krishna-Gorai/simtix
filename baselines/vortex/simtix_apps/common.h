// SIMTiX application suite on Vortex: the kernel argument shared by host and kernel.
#ifndef _COMMON_H_
#define _COMMON_H_

#include <stdint.h>

// Kernel slots, numbered as in sim/gen_apps.py SLOTS.
enum {
  APP_GEMM, APP_SPMV, APP_STENCIL, APP_KMEANS, APP_BFS, APP_SCAN, APP_SCAN_ADD, APP_MLP,
  APP_COUNT
};

typedef struct {
  uint32_t app;       // kernel slot
  uint32_t params;    // device address of the launch's parameter block
  uint32_t threads;   // threads in the launch
} kernel_arg_t;

#endif
