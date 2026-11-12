/* dbg_ld.c - Ara unit-stride int8 loads at byte offsets + widening MAC (debug only) */
#include <riscv_vector.h>
#include <stdint.h>
#include "printf.h"

static int8_t src[256] __attribute__((aligned(64)));
static int16_t dst[64];
static int8_t d8[64];

int main(void)
{
    unsigned bad = 0;
    for (unsigned i = 0; i < 256; i++) src[i] = (int8_t)(i * 7 + 3);
    static const unsigned vls[] = { 6, 10, 32 };
    for (unsigned t = 0; t < 3; t++)
        for (unsigned off = 0; off < 9; off++) {
            size_t vl = __riscv_vsetvl_e32m4(vls[t]);
            vint8m1_t v = __riscv_vle8_v_i8m1(src + off, vl);
            __riscv_vse8_v_i8m1(d8, v, vl);
            vint16m2_t s = __riscv_vwmul_vx_i16m2(v, (int8_t)-5, vl);
            __riscv_vse16_v_i16m2(dst, s, vl);
            __asm__ volatile("fence" ::: "memory");
            unsigned e8 = 0, e16 = 0;
            for (unsigned i = 0; i < vl; i++) {
                e8 += d8[i] != src[off + i];
                e16 += dst[i] != (int16_t)(src[off + i] * -5);
            }
            if (e8 || e16) printf("vl %u off %u: load err %u, vwmul err %u\n", (unsigned)vl, off, e8, e16);
            bad += e8 + e16;
        }
    printf("dbg_ld bad %u\n", bad);
    return (int)bad;
}
