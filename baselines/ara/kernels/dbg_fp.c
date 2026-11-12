/* dbg_fp.c - Ara FP / compare ops used by spmv and mandel, vs scalar (debug only) */
#include <riscv_vector.h>
#include <stdint.h>
#include "printf.h"

#define N 64
static float a[N], b[N], c[N], r[N];
static uint32_t u[N], ru[N];
static unsigned bad;
static void chk(const char *w, uint32_t got, uint32_t ref, unsigned i)
{
    static const char *last; static unsigned shown;
    if (w != last) { last = w; shown = 0; }
    if (got != ref) { if (shown++ < 3) printf("%s [%u] got %08x ref %08x\n", w, i, got, ref); bad++; }
}
static uint32_t fu(float f) { union { float f; uint32_t u; } v = { .f = f }; return v.u; }

int main(void)
{
    uint32_t s = 99u;
    for (unsigned i = 0; i < N; i++) {
        s = s * 1103515245u + 12345u; a[i] = (float)(int32_t)(s >> 8) * (1.0f / 8388608.0f) - 1.0f;
        s = s * 1103515245u + 12345u; b[i] = (float)(int32_t)(s >> 8) * (1.0f / 8388608.0f) - 1.0f;
        s = s * 1103515245u + 12345u; c[i] = (float)(int32_t)(s >> 8) * (1.0f / 8388608.0f) - 1.0f;
        u[i] = (s >> 20) % 5u;
    }
    static const unsigned vls[] = { 64, 44, 6 };
    for (unsigned t = 0; t < 3; t++) {
        size_t vl = __riscv_vsetvl_e32m1(vls[t]);
        printf("vl %u\n", (unsigned)vl);
        vfloat32m1_t va = __riscv_vle32_v_f32m1(a, vl), vb = __riscv_vle32_v_f32m1(b, vl), vc = __riscv_vle32_v_f32m1(c, vl);
        vuint32m1_t vu = __riscv_vle32_v_u32m1(u, vl);
        /* unmasked vfmacc.vv: c + a*b */
        __riscv_vse32_v_f32m1(r, __riscv_vfmacc_vv_f32m1(vc, va, vb, vl), vl);
        __asm__ volatile("fence" ::: "memory");
        for (unsigned i = 0; i < vl; i++) chk("vfmacc", fu(r[i]), fu(__builtin_fmaf(a[i], b[i], c[i])), i);
        /* compares */
        for (uint32_t j = 0; j < 4; j++) {
            vbool32_t m = __riscv_vmsgtu_vx_u32m1_b32(vu, j, vl);
            __riscv_vse32_v_u32m1(ru, __riscv_vmerge_vxm_u32m1(__riscv_vmv_v_x_u32m1(0, vl), 1, m, vl), vl);
            __asm__ volatile("fence" ::: "memory");
            for (unsigned i = 0; i < vl; i++) chk("vmsgtu", ru[i], u[i] > j, i);
        }
        /* masked vfmacc.vv, mask undisturbed */
        vbool32_t m = __riscv_vmsgtu_vx_u32m1_b32(vu, 1, vl);
        __riscv_vse32_v_f32m1(r, __riscv_vfmacc_vv_f32m1_mu(m, vc, va, vb, vl), vl);
        __asm__ volatile("fence" ::: "memory");
        for (unsigned i = 0; i < vl; i++) chk("vfmacc_mu", fu(r[i]), u[i] > 1 ? fu(__builtin_fmaf(a[i], b[i], c[i])) : fu(c[i]), i);
        /* vfmadd.vf: a * 0.75 + c */
        __riscv_vse32_v_f32m1(r, __riscv_vfmadd_vf_f32m1(va, 0.75f, vc, vl), vl);
        __asm__ volatile("fence" ::: "memory");
        for (unsigned i = 0; i < vl; i++) chk("vfmadd.vf", fu(r[i]), fu(__builtin_fmaf(a[i], 0.75f, c[i])), i);
        /* masked integer add, mask undisturbed */
        __riscv_vse32_v_u32m1(ru, __riscv_vadd_vx_u32m1_mu(m, vu, vu, 1, vl), vl);
        __asm__ volatile("fence" ::: "memory");
        for (unsigned i = 0; i < vl; i++) chk("vadd_mu", ru[i], u[i] > 1 ? u[i] + 1 : u[i], i);
        /* vmfgt.vf */
        vbool32_t g = __riscv_vmfgt_vf_f32m1_b32(va, 0.25f, vl);
        __riscv_vse32_v_u32m1(ru, __riscv_vmerge_vxm_u32m1(__riscv_vmv_v_x_u32m1(0, vl), 1, g, vl), vl);
        __asm__ volatile("fence" ::: "memory");
        for (unsigned i = 0; i < vl; i++) chk("vmfgt", ru[i], a[i] > 0.25f, i);
    }
    printf("dbg_fp bad %u\n", bad);
    return (int)bad;
}
