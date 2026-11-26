/* dbg_rv.c - RiVEC batch 1 on Ara (debug only): which vector operations of RiVEC's
   blackscholes (exp, log, their pieces) and jacobi-2d (slides) Ara gets wrong, each against
   the scalar result (kernels/rivec/rv_ref.h). Run in the Verilator model (run_ps_sim.sh). */
#include <riscv_vector.h>
#include <stdint.h>
#include "printf.h"
#define USE_RISCV_VECTOR
#define inline static inline
#include "rivec/vector_defines.h"
#undef inline
#include "rv_ref.h"

#define N 128
static float in[N], out[N], ref[N];
static uint32_t lcg = 777u;
static uint32_t rnd(void) { lcg = lcg * 1664525u + 1013904223u; return lcg; }
static uint32_t fb(float f) { union { float f; uint32_t u; } v = { .f = f }; return v.u; }
static float bf(uint32_t u) { union { uint32_t u; float f; } v = { .u = u }; return v.f; }

static unsigned cmp(const char *what, unsigned n)
{
    unsigned e = 0;
    for (unsigned i = 0; i < n; i++)
        if (fb(out[i]) != fb(ref[i]) && e++ < 3)
            printf("  %s[%u] in %08x vec %08x ref %08x\n", what, i, fb(in[i]), fb(out[i]), fb(ref[i]));
    printf("%s: %u of %u differ\n", what, e, n);
    return e;
}

/* run f over in[] in chunks of vl, then compare with ref[] */
#define VTEST(name, VL, BODY)                                                  \
    do {                                                                       \
        for (size_t i0 = 0; i0 < N; ) {                                        \
            size_t gvl = __riscv_vsetvl_e32m1(N - i0 < (VL) ? N - i0 : (VL));  \
            vfloat32m1_t x = __riscv_vle32_v_f32m1(&in[i0], gvl);              \
            BODY;                                                              \
            __riscv_vse32_v_f32m1(&out[i0], x, gvl);                           \
            i0 += gvl;                                                         \
        }                                                                      \
        __asm__ volatile("fence" ::: "memory");                                \
        cmp(name, N);                                                          \
    } while (0)

int main(void)
{
    /* 1. exp and log */
    for (int i = 0; i < N; i++) { in[i] = (float)(int32_t)rnd() / 2147483648.0f * 20.0f; ref[i] = rv_exp(in[i]); }
    VTEST("exp", 64, x = __exp_2xf32(x, gvl));
    for (int i = 0; i < N; i++) { in[i] = bf((rnd() % 0x7f000000u) + 0x00800000u); ref[i] = rv_log(in[i]); }
    VTEST("log", 64, x = __log_2xf32(x, gvl));

    /* 2. the pieces of exp */
    for (int i = 0; i < N; i++) { in[i] = (float)(int32_t)rnd() / 2147483648.0f * 50.0f; }
    for (int i = 0; i < N; i++) ref[i] = (float)rv_cvt_rne(in[i]);
    VTEST("vfcvt.x.f+f.x", 64, x = __riscv_vfcvt_f_x_v_f32m1(__riscv_vfcvt_x_f_v_i32m1(x, gvl), gvl));
    for (int i = 0; i < N; i++) ref[i] = in[i] < 3.0f ? 1.0f : in[i];
    VTEST("vfmerge.vfm (vmflt)", 64,
          x = __riscv_vfmerge_vfm_f32m1(x, 1.0f, __riscv_vmflt_vf_f32m1_b32(x, 3.0f, gvl), gvl));
    for (int i = 0; i < N; i++) ref[i] = in[i] < 3.0f ? 0.0f : 1.0f;
    VTEST("merge(0,1) (vmflt)", 64,
          x = __riscv_vfmerge_vfm_f32m1(__riscv_vfmv_v_f_f32m1(0.0f, gvl), 1.0f,
                                        __riscv_vmflt_vf_f32m1_b32(x, 3.0f, gvl), gvl));
    for (int i = 0; i < N; i++) { int32_t k = rv_cvt_rne(in[i]) & 63; ref[i] = bf((uint32_t)(k + 0x7f) << 23); }
    VTEST("2^k (vadd, vsll)", 64,
          vint32m1_t k = __riscv_vand_vx_i32m1(__riscv_vfcvt_x_f_v_i32m1(x, gvl), 63, gvl);
          k = __riscv_vsll_vx_i32m1(__riscv_vadd_vx_i32m1(k, 0x7f, gvl), 23, gvl);
          x = __riscv_vreinterpret_v_i32m1_f32m1(k));
    for (int i = 0; i < N; i++) ref[i] = in[i] < -2.0f ? in[i] : -2.0f;
    VTEST("vfmin.vf", 64, x = __riscv_vfmin_vf_f32m1(x, -2.0f, gvl));

    /* 3. jacobi's slides: x[i] + x[i-1] (slide1up, izq) and x[i+1] (slide1down, der) */
    static const unsigned vls[] = { 38, 64, 30 };
    for (unsigned t = 0; t < 3; t++) {
        unsigned VL = vls[t];
        for (int i = 0; i < N; i++) in[i] = (float)(i + 1);
        for (int i = 0; i < N; i++) {
            int c = i % VL, base = i - c;
            unsigned vl = (N - base) < VL ? (unsigned)(N - base) : VL;
            float up = c == 0 ? -1.0f : in[i - 1];
            float dn = (unsigned)c == vl - 1 ? -2.0f : in[i + 1];
            ref[i] = (in[i] + up) * 1000.0f + dn;
        }
        char nm[32];
        sprintf(nm, "slides vl %u", VL);
        VTEST(nm, VL,
              vfloat32m1_t u = __riscv_vfslide1up_vf_f32m1(x, -1.0f, gvl);
              vfloat32m1_t d = __riscv_vfslide1down_vf_f32m1(x, -2.0f, gvl);
              x = __riscv_vfmacc_vf_f32m1(d, 1000.0f, __riscv_vfadd_vv_f32m1(x, u, gvl), gvl));
    }
    printf("DBG_RV done\n");
    return 0;
}
