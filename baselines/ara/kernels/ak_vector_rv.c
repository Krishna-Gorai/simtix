/*
 * ak_vector_rv.c - RiVEC batch 1 for Ara (docs/rivec_plan.md): RiVEC's own vector code in
 * ak_vector_rv.inc, compiled on its own with clang (build.sh), the compiler RiVEC is written
 * for (its README builds with LLVM). GCC 15 spilled a vector register in RiVEC's
 * Black-Scholes (exp, log and two CNDF expanded, every constant broadcast to a register),
 * and Ara reloads whole-register spills wrongly (ak_vector.c item 5); clang allocates it
 * without a spill. The other Ara kernels stay in ak_vector.c with GCC, as validated.
 * ak_vector.c's ak_vector[] table refers to the v_rv_* functions here.
 */
#include <riscv_vector.h>
#include "ak.h"
#include "rv_ref.h"                  /* RV_LAVA_NP */

#define FENCE() __asm__ volatile("fence" ::: "memory")

#include "ak_vector_rv.inc"
