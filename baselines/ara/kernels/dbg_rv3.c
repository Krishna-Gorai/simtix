/* dbg_rv2.c - which part of RiVEC's jacobi-2d sweep Ara gets wrong (debug only). One sweep
   A -> B on n x n (PolyBench init), against the scalar sweep of rv_ref.h, in variants:
     0  RiVEC's kernel (as ak_vector_rv.inc: slides, row registers rotating)
     1  right neighbour by a unit-stride load from A[i][j+1] instead of vfslide1down
     2  left neighbour by a load from A[i][j-1] instead of vfslide1up
     3  both neighbours by loads (no slides)
     4  as 0, the store into a scratch row first and copied by scalar code
   Run in the Verilator model (run_ps_sim.sh). */
#include <riscv_vector.h>
#include <stdint.h>
#include "printf.h"
#include "rv_ref.h"

#define NN 40
static float A[NN * NN], B[NN * NN], R[NN * NN], T[NN];
static uint32_t fb(float f) { union { float f; uint32_t u; } v = { .f = f }; return v.u; }

static void sweep(int var)
{
    const int n = NN, size_y = n - 2, size_x = n - 2;
    size_t gvl = __riscv_vsetvl_e32m1(size_y);
    vfloat32m1_t c = __riscv_vfmv_v_f_f32m1(0.20f, gvl);
    for (int j = 1; j <= size_x; j += gvl) {
        gvl = __riscv_vsetvl_e32m1(size_y - j + 1);
        for (int i = 1; i <= size_y; i++) {
            vfloat32m1_t top = __riscv_vle32_v_f32m1(&A[(i - 1) * n + j], gvl);
            vfloat32m1_t mid = __riscv_vle32_v_f32m1(&A[i * n + j], gvl);
            vfloat32m1_t bot = __riscv_vle32_v_f32m1(&A[(i + 1) * n + j], gvl);
            vfloat32m1_t l, r;
            if (var == 2 || var == 3) l = __riscv_vle32_v_f32m1(&A[i * n + j - 1], gvl);
            else l = __riscv_vfslide1up_vf_f32m1(mid, A[i * n + j - 1], gvl);
            if (var == 1 || var == 3) r = __riscv_vle32_v_f32m1(&A[i * n + j + 1], gvl);
            else r = __riscv_vfslide1down_vf_f32m1(mid, A[i * n + j + gvl], gvl);
            vfloat32m1_t u = __riscv_vfadd_vv_f32m1(mid, l, gvl);
            u = __riscv_vfadd_vv_f32m1(u, r, gvl);
            vfloat32m1_t v = __riscv_vfadd_vv_f32m1(bot, top, gvl);
            u = __riscv_vfmul_vv_f32m1(__riscv_vfadd_vv_f32m1(u, v, gvl), c, gvl);
            if (var == 4) {
                __riscv_vse32_v_f32m1(T, u, gvl);
                __asm__ volatile("fence" ::: "memory");
                for (size_t k = 0; k < gvl; k++) B[i * n + j + k] = T[k];
            } else {
                __riscv_vse32_v_f32m1(&B[i * n + j], u, gvl);
            }
        }
    }
    __asm__ volatile("fence" ::: "memory");
}

static void sweep2(float *A, float *B)
{
    const int n = NN, size_y = n - 2, size_x = n - 2;
    size_t gvl = __riscv_vsetvl_e32m1(size_y);
    vfloat32m1_t c = __riscv_vfmv_v_f_f32m1(0.20f, gvl);
    for (int j = 1; j <= size_x; j += gvl) {
        gvl = __riscv_vsetvl_e32m1(size_y - j + 1);
        for (int i = 1; i <= size_y; i++) {
            vfloat32m1_t top = __riscv_vle32_v_f32m1(&A[(i - 1) * n + j], gvl);
            vfloat32m1_t mid = __riscv_vle32_v_f32m1(&A[i * n + j], gvl);
            vfloat32m1_t bot = __riscv_vle32_v_f32m1(&A[(i + 1) * n + j], gvl);
            vfloat32m1_t l, r;
            if (0 == 2 || 0 == 3) l = __riscv_vle32_v_f32m1(&A[i * n + j - 1], gvl);
            else l = __riscv_vfslide1up_vf_f32m1(mid, A[i * n + j - 1], gvl);
            if (0 == 1 || 0 == 3) r = __riscv_vle32_v_f32m1(&A[i * n + j + 1], gvl);
            else r = __riscv_vfslide1down_vf_f32m1(mid, A[i * n + j + gvl], gvl);
            vfloat32m1_t u = __riscv_vfadd_vv_f32m1(mid, l, gvl);
            u = __riscv_vfadd_vv_f32m1(u, r, gvl);
            vfloat32m1_t v = __riscv_vfadd_vv_f32m1(bot, top, gvl);
            u = __riscv_vfmul_vv_f32m1(__riscv_vfadd_vv_f32m1(u, v, gvl), c, gvl);
            if (0 == 4) {
                __riscv_vse32_v_f32m1(T, u, gvl);
                __asm__ volatile("fence" ::: "memory");
                for (size_t k = 0; k < gvl; k++) B[i * n + j + k] = T[k];
            } else {
                __riscv_vse32_v_f32m1(&B[i * n + j], u, gvl);
            }
        }
    }
    __asm__ volatile("fence" ::: "memory");
}

int main(void)
{
    static float A0[NN * NN], B0[NN * NN], RA[NN * NN], RB[NN * NN];
    rv_jacobi_init(A0, B0, NN);
    for (int i = 0; i < NN * NN; i++) { A[i] = A0[i]; B[i] = B0[i]; RA[i] = A0[i]; RB[i] = B0[i]; }
    /* 4 sweeps, RiVEC's form (variant 0), alternating A -> B and B -> A as v_rv_jacobi */
    for (int s = 0; s < 4; s++) {
        float *src = (s & 1) ? B : A, *dst = (s & 1) ? A : B;
        float *rs = (s & 1) ? RB : RA, *rd = (s & 1) ? RA : RB;
        sweep2(src, dst);
        rv_jacobi_sweep(rs, rd, NN);
        unsigned e = 0, shown = 0;
        for (int i = 0; i < NN * NN; i++)
            if (fb(dst[i]) != fb(rd[i])) {
                e++;
                if (shown++ < 4) printf("  sweep %d [%d] (row %d col %d) vec %08x ref %08x\n", s, i, i / NN, i % NN,
                                        fb(dst[i]), fb(rd[i]));
            }
        printf("sweep %d: %u wrong\n", s, e);
    }
    printf("DBG_RV3 done\n");
    return 0;
}
