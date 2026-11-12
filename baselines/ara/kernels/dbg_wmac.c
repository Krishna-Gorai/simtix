/* dbg_wmac.c - widening int8 multiply(-add) with signed scalars on Ara (debug only).
   Spill-free: all vector work first, results in memory, one fence, then the check. */
#include <riscv_vector.h>
#include <stdint.h>
#ifdef AK_QEMU
#include <stdio.h>
#else
#include "printf.h"
#endif
#define VL 6
static int8_t xin[64];
static volatile int8_t ws[8] = { -5, 7, -64, 63, -1, 1, -128, 127 };
static int16_t rm[8][64], ra[8][64];
int main(void)
{
    for (unsigned i = 0; i < 64; i++) xin[i] = (int8_t)((i * 37 + 11) & 0x7F);
    int8_t w[8];
    for (unsigned t = 0; t < 8; t++) w[t] = ws[t];
    size_t vl = __riscv_vsetvl_e32m4(VL);
    vint8m1_t v = __riscv_vle8_v_i8m1(xin, vl);
    for (unsigned t = 0; t < 8; t++) {
        vint16m2_t p = __riscv_vwmul_vx_i16m2(v, w[t], vl);
        __riscv_vse16_v_i16m2(rm[t], p, vl);
        vint16m2_t q = __riscv_vwmacc_vx_i16m2(__riscv_vmv_v_x_i16m2(100, vl), w[t], v, vl);
        __riscv_vse16_v_i16m2(ra[t], q, vl);
    }
    __asm__ volatile("fence" ::: "memory");
    unsigned bad = 0;
    for (unsigned t = 0; t < 8; t++)
        for (unsigned i = 0; i < vl; i++) {
            int16_t em = (int16_t)(xin[i] * w[t]), ea = (int16_t)(100 + xin[i] * w[t]);
            if (rm[t][i] != em && bad++ < 8) printf("vwmul w %d x %d: got %d ref %d\n", w[t], xin[i], rm[t][i], em);
            if (ra[t][i] != ea && bad++ < 16) printf("vwmacc w %d x %d: got %d ref %d\n", w[t], xin[i], ra[t][i], ea);
        }
    printf("dbg_wmac bad %u\n", bad);
    return (int)bad;
}
