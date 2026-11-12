/* dbg_st8.c - vse8 / vle8 of a few bytes at every offset in a 64-bit word on Ara
   (debug only); neighbours must stay untouched. Spill-free. */
#include <riscv_vector.h>
#include <stdint.h>
#ifdef AK_QEMU
#include <stdio.h>
#else
#include "printf.h"
#endif
static int8_t src[64] __attribute__((aligned(64)));
static int8_t dst[8][64] __attribute__((aligned(64)));
static int8_t lod[8][64] __attribute__((aligned(64)));
static const unsigned VLS[3] = { 6, 3, 13 };
int main(void)
{
    unsigned bad = 0;
    for (unsigned i = 0; i < 64; i++) src[i] = (int8_t)(i + 1);
    for (unsigned r = 0; r < 3; r++) {
        for (unsigned o = 0; o < 8; o++) for (unsigned i = 0; i < 64; i++) { dst[o][i] = 0; lod[o][i] = 0; }
        size_t vl = __riscv_vsetvl_e32m4(VLS[r]);
        vint8m1_t v = __riscv_vle8_v_i8m1(src, vl);
        for (unsigned o = 0; o < 8; o++) {
            __riscv_vse8_v_i8m1(&dst[o][8 + o], v, vl);
            __riscv_vse8_v_i8m1(lod[o], __riscv_vle8_v_i8m1(&src[8 + o], vl), vl);
        }
        __asm__ volatile("fence" ::: "memory");
        for (unsigned o = 0; o < 8; o++)
            for (unsigned i = 0; i < 64; i++) {
                int8_t e = (i >= 8 + o && i < 8 + o + vl) ? src[i - 8 - o] : 0;
                if (dst[o][i] != e && bad++ < 10) printf("vl %u st off %u byte %u: got %d ref %d\n", (unsigned)vl, o, i, dst[o][i], e);
                e = (i < vl) ? src[8 + o + i] : 0;
                if (lod[o][i] != e && bad++ < 20) printf("vl %u ld off %u byte %u: got %d ref %d\n", (unsigned)vl, o, i, lod[o][i], e);
            }
    }
    printf("dbg_st8 bad %u\n", bad);
    return (int)bad;
}
