// fpu_ref.c  -  DPI-C IEEE-754 single-precision reference for tb_fpu.sv.
// Verilator promotes SystemVerilog `shortreal` to `real` (double), so it cannot
// produce true FP32 results; these helpers use the host's real `float` hardware
// (round-to-nearest-even) and exchange raw 32-bit patterns with the testbench.
#include <stdint.h>
#include <string.h>

// Verilator compiles user sources with its C++ toolchain, so give these C linkage
// to match the DPI import wrappers (which expect unmangled `extern "C"` symbols).
#ifdef __cplusplus
extern "C" {
#endif

static float  b2f(uint32_t b) { float f;    memcpy(&f, &b, 4); return f; }
static uint32_t f2b(float f)  { uint32_t b; memcpy(&b, &f, 4); return b; }

uint32_t ref_add(uint32_t a, uint32_t b) { return f2b(b2f(a) + b2f(b)); }
uint32_t ref_sub(uint32_t a, uint32_t b) { return f2b(b2f(a) - b2f(b)); }
uint32_t ref_mul(uint32_t a, uint32_t b) { return f2b(b2f(a) * b2f(b)); }

// int32 -> float (RNE) and uint32 -> float (RNE)
uint32_t ref_cvt_sw (uint32_t x) { return f2b((float)(int32_t)x);  }
uint32_t ref_cvt_swu(uint32_t x) { return f2b((float)(uint32_t)x); }

// float -> int32 (truncate toward zero, C cast semantics)
uint32_t ref_cvt_ws (uint32_t a) { return (uint32_t)(int32_t)b2f(a); }

#ifdef __cplusplus
}
#endif
