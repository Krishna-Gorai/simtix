/* dbg_mandel2.c - where does v_mandel deadlock Ara? (debug only) Current kernel shape,
   self-test parameters, a progress line per phase / iteration. */
#include <riscv_vector.h>
#include <stdint.h>
#include "printf.h"
#define FENCE() __asm__ volatile("fence" ::: "memory")
static uint32_t out[400];
static inline uint32_t sum_u32(vuint32m1_t v, size_t vl)
{
    return __riscv_vmv_x_s_u32m1_u32(__riscv_vredsum_vs_u32m1_u32m1(v, __riscv_vmv_v_x_u32m1(0, 1), vl));
}
int main(void)
{
    const uint32_t n = 20, m = 40;
    const float x0 = -2.0f, y0 = -1.25f, d = 2.5f / 20.0f;
    for (uint32_t py = 0; py < 2; py++) {
        const float ci = __builtin_fmaf((float)py, d, y0);
        for (uint32_t px0 = 0; px0 < n; ) {
            size_t vl = __riscv_vsetvl_e32m1(n - px0);
            printf("py %u px0 %u vl %u\n", py, px0, (unsigned)vl);
            vfloat32m1_t civ = __riscv_vfmv_v_f_f32m1(ci, vl);
            vfloat32m1_t pxf = __riscv_vfcvt_f_xu_v_f32m1(__riscv_vadd_vx_u32m1(__riscv_vid_v_u32m1(vl), px0, vl), vl);
            vfloat32m1_t cr = __riscv_vfmadd_vf_f32m1(pxf, d, __riscv_vfmv_v_f_f32m1(x0, vl), vl);
            FENCE(); printf(" setup ok\n");
            vfloat32m1_t zr = __riscv_vfmv_v_f_f32m1(0.0f, vl), zi = __riscv_vfmv_v_f_f32m1(0.0f, vl);
            vuint32m1_t k = __riscv_vmv_v_x_u32m1(0, vl), zero = __riscv_vmv_v_x_u32m1(0, vl);
            const vuint32m1_t one = __riscv_vmv_v_x_u32m1(1, vl);
            vuint32m1_t act = one;
            uint32_t it = 0, c;
            do {
                vfloat32m1_t zr2 = __riscv_vfmul_vv_f32m1(zr, zr, vl), zi2 = __riscv_vfmul_vv_f32m1(zi, zi, vl);
                vuint32m1_t in = __riscv_vmerge_vxm_u32m1(one, 0,
                                     __riscv_vmfgt_vf_f32m1_b32(__riscv_vfadd_vv_f32m1(zr2, zi2, vl), 4.0f, vl), vl);
                zi = __riscv_vfmadd_vf_f32m1(__riscv_vfmul_vv_f32m1(zr, zi, vl), 2.0f, civ, vl);
                zr = __riscv_vfadd_vv_f32m1(__riscv_vfsub_vv_f32m1(zr2, zi2, vl), cr, vl);
                k = __riscv_vadd_vv_u32m1(k, act, vl);
                vuint32m1_t lt = __riscv_vmerge_vxm_u32m1(zero, 1, __riscv_vmsltu_vx_u32m1_b32(k, m, vl), vl);
                act = __riscv_vand_vv_u32m1(__riscv_vand_vv_u32m1(act, in, vl), lt, vl);
                FENCE();
                c = sum_u32(act, vl);
                if (it < 3 || !c) printf(" it %u live %u\n", it, c);
                it++;
            } while (c);
            __riscv_vse32_v_u32m1(out + py * n + px0, k, vl);
            px0 += vl;
        }
    }
    printf("dbg_mandel2 done\n");
    return 0;
}
