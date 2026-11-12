/* dbg_divsqrt.c - are CVA6's fdiv.s / fsqrt.s and Ara's vfdiv / vfsqrt correctly rounded (RNE)?
   Each result q is compared with its two neighbours by the exact FMA remainder
   a - x*b (division) or a - x*x (square root): the correctly rounded result has the
   smallest |remainder| (ties to an even significand). */
#include <stdint.h>
#include <riscv_vector.h>
#include "printf.h"
#define N 4096
static uint32_t rng = 12345u;
static uint32_t rnd(void) { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng; }
static float u2f(uint32_t u) { union { uint32_t u; float f; } v = { .u = u }; return v.f; }
static uint32_t f2u(float f) { union { uint32_t u; float f; } v = { .f = f }; return v.u; }
static float rnd_pos(void) { return u2f(0x3F000000u + (rnd() % 0x03800000u)); }   /* [0.5, 64) */
static float fab(float x) { return x < 0 ? -x : x; }
static int best_div(float a, float b, float q)
{
    float c[3] = { u2f(f2u(q) - 1), q, u2f(f2u(q) + 1) };
    int k = 1;
    for (int i = 0; i < 3; i += 2) {
        float ri = fab(__builtin_fmaf(-c[i], b, a)), rk = fab(__builtin_fmaf(-c[k], b, a));
        if (ri < rk || (ri == rk && !(f2u(c[i]) & 1))) k = i;
    }
    return k == 1;
}
static int best_sqrt(float a, float q)
{
    float c[3] = { u2f(f2u(q) - 1), q, u2f(f2u(q) + 1) };
    int k = 1;
    for (int i = 0; i < 3; i += 2) {
        float ri = fab(__builtin_fmaf(-c[i], c[i], a)), rk = fab(__builtin_fmaf(-c[k], c[k], a));
        if (ri < rk) k = i;
    }
    return k == 1;
}
static float A[N], B[N], QV[N], SV[N];
int main(void)
{
    for (int i = 0; i < N; i++) { A[i] = rnd_pos(); B[i] = rnd_pos(); }
    unsigned bd = 0, bs = 0, vd = 0, vs = 0, sd = 0, ss = 0;
    for (size_t i = 0; i < N; ) {
        size_t vl = __riscv_vsetvl_e32m1(N - i);
        vfloat32m1_t a = __riscv_vle32_v_f32m1(A + i, vl), b = __riscv_vle32_v_f32m1(B + i, vl);
        __riscv_vse32_v_f32m1(QV + i, __riscv_vfdiv_vv_f32m1(a, b, vl), vl);
        __riscv_vse32_v_f32m1(SV + i, __riscv_vfsqrt_v_f32m1(a, vl), vl);
        i += vl;
    }
    __asm__ volatile("fence" ::: "memory");
    for (int i = 0; i < N; i++) {
        float q, s;
        __asm__ volatile("fdiv.s %0, %1, %2" : "=f"(q) : "f"(A[i]), "f"(B[i]));
        __asm__ volatile("fsqrt.s %0, %1" : "=f"(s) : "f"(A[i]));
        bd += !best_div(A[i], B[i], q);
        bs += !best_sqrt(A[i], s);
        vd += !best_div(A[i], B[i], QV[i]);
        vs += !best_sqrt(A[i], SV[i]);
        sd += f2u(q) != f2u(QV[i]);
        ss += f2u(s) != f2u(SV[i]);
        if (i < 3 || (!best_div(A[i], B[i], q) && bd <= 3))
            printf("  %08x / %08x = %08x (vector %08x)\n", f2u(A[i]), f2u(B[i]), f2u(q), f2u(QV[i]));
    }
    printf("DIVSQRT N=%d: cva6 fdiv wrong %u, fsqrt wrong %u; ara vfdiv wrong %u, vfsqrt wrong %u; "
           "cva6!=ara div %u sqrt %u\n", N, bd, bs, vd, vs, sd, ss);
    return 0;
}
