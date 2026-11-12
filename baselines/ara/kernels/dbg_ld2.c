/* dbg_ld2.c - bisect the dbg_ld hang: one step per line, progress printed (debug only) */
#include <riscv_vector.h>
#include <stdint.h>
#include "printf.h"

static int8_t src[256] __attribute__((aligned(64)));
static int8_t d8[64] __attribute__((aligned(64)));
static int16_t d16[64] __attribute__((aligned(64)));

int main(void)
{
    for (unsigned i = 0; i < 256; i++) src[i] = (int8_t)(i * 7 + 3);
    static const unsigned vls[] = { 32, 6 };
    for (unsigned t = 0; t < 2; t++)
        for (unsigned off = 0; off < 4; off++) {
            unsigned e = 0;
            size_t vl = __riscv_vsetvl_e8m1(vls[t]);
            printf("vl %u off %u: ", (unsigned)vl, off);
            vint8m1_t v = __riscv_vle8_v_i8m1(src + off, vl);
            __riscv_vse8_v_i8m1(d8, v, vl);
            __asm__ volatile("fence" ::: "memory");
            for (unsigned i = 0; i < vl; i++) e += d8[i] != src[off + i];
            printf("ld/st8 %u ", e);
            vint16m2_t s = __riscv_vwmul_vx_i16m2(__riscv_vle8_v_i8m1(src + off, vl), (int8_t)-5, vl);
            __riscv_vse16_v_i16m2(d16, s, vl);
            __asm__ volatile("fence" ::: "memory");
            e = 0;
            for (unsigned i = 0; i < vl; i++) e += d16[i] != (int16_t)(src[off + i] * -5);
            printf("vwmul %u\n", e);
        }
    printf("dbg_ld2 done\n");
    return 0;
}
