/* dbg_rv4.c - the real v_rv_jacobi (ak_vector_rv.o, clang) on Ara against rv_jacobi2d, for
   n = 40, 1 and 2 time steps, and n = 36 (debug only). */
#include <riscv_vector.h>
#include <stdint.h>
#include "printf.h"
#include "ak.h"
#include "rv_ref.h"
void v_rv_jacobi(const uint32_t *a);
static float A[64 * 64], B[64 * 64], RA[64 * 64], RB[64 * 64];
static uint32_t fb(float f) { union { float f; uint32_t u; } v = { .f = f }; return v.u; }
static uint32_t H(const void *p) { return (uint32_t)((uintptr_t)p - AK_OFS); }
static void one(uint32_t n, uint32_t ts)
{
    rv_jacobi_init(A, B, n); rv_jacobi_init(RA, RB, n);
    rv_jacobi2d(RA, RB, n, ts);
    uint32_t a[] = { H(A), H(B), n, ts };
    v_rv_jacobi(a);
    __asm__ volatile("fence" ::: "memory");
    unsigned e = 0, shown = 0;
    for (uint32_t i = 0; i < n * n; i++) {
        if (fb(A[i]) != fb(RA[i]) && shown++ < 3) printf("  A[%u] (row %u col %u) %08x %08x\n", i, i / n, i % n, fb(A[i]), fb(RA[i]));
        if (fb(B[i]) != fb(RB[i]) && shown++ < 3) printf("  B[%u] (row %u col %u) %08x %08x\n", i, i / n, i % n, fb(B[i]), fb(RB[i]));
        e += (fb(A[i]) != fb(RA[i])) + (fb(B[i]) != fb(RB[i]));
    }
    printf("n %u tsteps %u: %u wrong\n", n, ts, e);
}
int main(void)
{
    one(40, 1); one(40, 2); one(36, 2); one(64, 2);
    printf("DBG_RV4 done\n");
    return 0;
}
