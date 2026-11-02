/* xil_io.h  -  the two accessors psu_init_gpl.c uses (32-bit, uncached) */
#ifndef XIL_IO_H
#define XIL_IO_H
#include <stdint.h>
static inline uint32_t Xil_In32(unsigned long a) { return *(volatile uint32_t *)a; }
static inline void Xil_Out32(unsigned long a, uint32_t v) { *(volatile uint32_t *)a = v; }
#endif
