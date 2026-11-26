/* dbg_rv5.c - after RiVEC spmv (a reduction), which part of RiVEC's jacobi-2d sweep Ara gets wrong (debug only). One sweep
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
#include "ak.h"
#include "rv_ref.h"
void v_rv_spmv(const uint32_t *a);
static uint32_t H(const void *p) { return (uint32_t)((uintptr_t)p - AK_OFS); }

#define NN 40
static float A[NN * NN], B[NN * NN], R[NN * NN], T[64];
static uint32_t ia[151], ja[150 * 140]; static float va[150 * 140], vx[150], vy[150];
static void spmv_first(void)
{
    uint32_t q = 0, l = 99u;
    for (int r = 0; r < 150; r++) { ia[r] = q; uint32_t k = (l = l * 1103515245u + 12345u) % 141; for (uint32_t t = 0; t < k; t++) { ja[q] = (l = l * 1103515245u + 12345u) % 150; va[q] = 0.5f; q++; } vx[r] = 1.0f; }
    ia[150] = q;
    uint32_t a[] = { H(ia), H(ja), H(va), H(vx), H(vy), 150 };
    v_rv_spmv(a);
    __asm__ volatile("fence" ::: "memory");
}
static uint32_t fb(float f) { union { float f; uint32_t u; } v = { .f = f }; return v.u; }

static void sweep(int var)
{
    const int n = NN, size_y = n - 2, size_x = n - 2;
    size_t gvl = __riscv_vsetvl_e32m1(size_y);
    if (var == 5) { vfloat32m1_t z = __riscv_vfmv_v_f_f32m1(0.0f, __riscv_vsetvl_e32m1(64)); z = __riscv_vfslide1down_vf_f32m1(z, 1.0f, 64); __riscv_vse32_v_f32m1(T, z, 1); __asm__ volatile("fence" ::: "memory"); gvl = __riscv_vsetvl_e32m1(size_y); }
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

int main(void)
{
    float tmp[NN * NN];
    rv_jacobi_init(A, tmp, NN);
    for (int i = 0; i < NN * NN; i++) R[i] = tmp[i];
    rv_jacobi_sweep(A, R, NN);
    static const int vars[] = { 0, 3, 5 };
    for (int k = 0; k < 3; k++) {
        int var = vars[k];
        for (int i = 0; i < NN * NN; i++) B[i] = tmp[i];
        spmv_first();
        sweep(var);
        unsigned e = 0, shown = 0;
        for (int i = 0; i < NN * NN; i++)
            if (fb(B[i]) != fb(R[i])) {
                e++;
                if (shown++ < 4) printf("  var %d [%d] (row %d col %d) vec %08x ref %08x\n", var, i, i / NN, i % NN,
                                        fb(B[i]), fb(R[i]));
            }
        printf("variant %d: %u wrong\n", var, e);
    }
    printf("DBG_RV5 done\n");
    return 0;
}
