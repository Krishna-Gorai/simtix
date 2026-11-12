/* dbg_ops.c - op-level check of the INT8 MLP/conv vector path on Ara (debug only).
 * Each step of v_mlp's inner loop and of requant() against a scalar model; prints
 * the first mismatches per step. Built by hand (see the session notes), build/dbg_ops.elf. */
#include <riscv_vector.h>
#include <stdint.h>
#include "printf.h"

#ifndef N
#define N 32
#endif
static int8_t  w0[N], w1[N], w2[N], w3[N];
static int16_t r16[N];
static int32_t r32[N], acc0[N];
static int8_t  r8[N];
static unsigned bad;

static void chk(const char *what, int32_t got, int32_t ref, unsigned i)
{
    static const char *last; static unsigned shown;
    if (what != last) { last = what; shown = 0; }
    if (got != ref) { if (shown++ < 4) printf("%s [%u] got %d ref %d\n", what, i, got, ref); bad++; }
}

int main(void)
{
    uint32_t s = 12345u;
    for (unsigned i = 0; i < N; i++) {
        s = s * 1103515245u + 12345u; w0[i] = (int8_t)((int32_t)((s >> 16) % 128u) - 64);
        s = s * 1103515245u + 12345u; w1[i] = (int8_t)((int32_t)((s >> 16) % 128u) - 64);
        s = s * 1103515245u + 12345u; w2[i] = (int8_t)((int32_t)((s >> 16) % 128u) - 64);
        s = s * 1103515245u + 12345u; w3[i] = (int8_t)((int32_t)((s >> 16) % 128u) - 64);
        acc0[i] = (int32_t)(i * 1000u) - 9000;
    }
    volatile int8_t xs[4] = { 100, 7, 127, 55 };
    const int8_t x0 = xs[0], x1 = xs[1], x2 = xs[2], x3 = xs[3];
    size_t vl = __riscv_vsetvl_e32m4(N);
    printf("vl %u\n", (unsigned)vl);

    /* 1: vwmul.vx */
    vint16m2_t p = __riscv_vwmul_vx_i16m2(__riscv_vle8_v_i8m1(w0, vl), x0, vl);
    __riscv_vse16_v_i16m2(r16, p, vl); __asm__ volatile("fence" ::: "memory");
    for (unsigned i = 0; i < vl; i++) chk("vwmul", r16[i], w0[i] * x0, i);
    /* 2: three vwmacc.vx */
    p = __riscv_vwmacc_vx_i16m2(p, x1, __riscv_vle8_v_i8m1(w1, vl), vl);
    p = __riscv_vwmacc_vx_i16m2(p, x2, __riscv_vle8_v_i8m1(w2, vl), vl);
    p = __riscv_vwmacc_vx_i16m2(p, x3, __riscv_vle8_v_i8m1(w3, vl), vl);
    __riscv_vse16_v_i16m2(r16, p, vl); __asm__ volatile("fence" ::: "memory");
    for (unsigned i = 0; i < vl; i++)
        chk("vwmacc", r16[i], (int16_t)(w0[i] * x0 + w1[i] * x1 + w2[i] * x2 + w3[i] * x3), i);
    /* 3: vwadd.wv */
    vint32m4_t a = __riscv_vle32_v_i32m4(acc0, vl);
    a = __riscv_vwadd_wv_i32m4(a, p, vl);
    __riscv_vse32_v_i32m4(r32, a, vl); __asm__ volatile("fence" ::: "memory");
    for (unsigned i = 0; i < vl; i++) chk("vwadd.wv", r32[i], acc0[i] + r16[i], i);
    /* 4: requant steps */
    const float scale = 1.0f / 1024.0f, zp = 3.0f;
    vfloat32m4_t f = __riscv_vfcvt_f_x_v_f32m4(a, vl);
    float fr[N];
    __riscv_vse32_v_f32m4(fr, f, vl); __asm__ volatile("fence" ::: "memory");
    for (unsigned i = 0; i < vl; i++) { union { float f; int32_t u; } g = { .f = fr[i] }, h = { .f = (float)r32[i] }; chk("vfcvt.f.x", g.u, h.u, i); }
    f = __riscv_vfmadd_vf_f32m4(f, scale, __riscv_vfmv_v_f_f32m4(zp, vl), vl);
    __riscv_vse32_v_f32m4(fr, f, vl); __asm__ volatile("fence" ::: "memory");
    for (unsigned i = 0; i < vl; i++) { union { float f; int32_t u; } g = { .f = fr[i] }, h = { .f = __builtin_fmaf((float)r32[i], scale, zp) }; chk("vfmadd", g.u, h.u, i); }
    f = __riscv_vfmax_vf_f32m4(__riscv_vfmin_vf_f32m4(f, 127.0f, vl), 0.0f, vl);
    vint32m4_t q = __riscv_vfcvt_x_f_v_i32m4(f, vl);
    __riscv_vse32_v_i32m4(r32, q, vl); __asm__ volatile("fence" ::: "memory");
    for (unsigned i = 0; i < vl; i++) {
        float v = fr[i]; v = v > 127.0f ? 127.0f : (v < 0.0f ? 0.0f : v);
        int32_t t = (int32_t)v; float d = v - (float)t; if (d > 0.5f || (d == 0.5f && (t & 1))) t++;
        chk("vfcvt.x.f", r32[i], t, i);
    }
    vint8m1_t b = __riscv_vncvt_x_x_w_i8m1(__riscv_vncvt_x_x_w_i16m2(q, vl), vl);
    __riscv_vse8_v_i8m1(r8, b, vl); __asm__ volatile("fence" ::: "memory");
    for (unsigned i = 0; i < vl; i++) chk("vncvt", r8[i], (int8_t)r32[i], i);
    /* 5: the narrowing steps one at a time, from memory */
    static int16_t h16[N]; static int8_t h8[N];
    q = __riscv_vle32_v_i32m4(r32, vl);
    __riscv_vse16_v_i16m2(h16, __riscv_vncvt_x_x_w_i16m2(q, vl), vl); __asm__ volatile("fence" ::: "memory");
    for (unsigned i = 0; i < vl; i++) chk("n32to16", h16[i], (int16_t)r32[i], i);
    __riscv_vse8_v_i8m1(h8, __riscv_vncvt_x_x_w_i8m1(__riscv_vle16_v_i16m2(h16, vl), vl), vl); __asm__ volatile("fence" ::: "memory");
    for (unsigned i = 0; i < vl; i++) chk("n16to8", h8[i], (int8_t)h16[i], i);
    /* 6: alternative: FP narrowing convert f32 -> i16, then i16 -> i8 */
    f = __riscv_vle32_v_f32m4(fr, vl);
    f = __riscv_vfmax_vf_f32m4(__riscv_vfmin_vf_f32m4(f, 127.0f, vl), 0.0f, vl);
    vint16m2_t q16 = __riscv_vfncvt_x_f_w_i16m2(f, vl);
    __riscv_vse16_v_i16m2(h16, q16, vl); __asm__ volatile("fence" ::: "memory");
    for (unsigned i = 0; i < vl; i++) chk("vfncvt", h16[i], (int16_t)r32[i], i);
    __riscv_vse8_v_i8m1(h8, __riscv_vncvt_x_x_w_i8m1(q16, vl), vl); __asm__ volatile("fence" ::: "memory");
    for (unsigned i = 0; i < vl; i++) chk("vfncvt+n16to8", h8[i], (int8_t)r32[i], i);
    printf("dbg_ops bad %u\n", bad);
    return (int)bad;
}
