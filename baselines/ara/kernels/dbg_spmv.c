/* dbg_spmv.c - trace v_spmv's strip loop on Ara (debug only). One strip of 64 rows of
 * the self-test matrix; every iteration j stores the mask (as 0/1), len and acc to
 * memory, no calls while vectors are live (no spills); checked after one fence. */
#include <riscv_vector.h>
#include <stdint.h>
#ifdef AK_QEMU
#include <stdio.h>
#else
#include "printf.h"
#endif

#define ROWS 300u
#define MAXNNZ 16u
#define VL 64u
#define JM 17u
static uint32_t rowptr[ROWS + 1], col[ROWS * MAXNNZ];
static float val[ROWS * MAXNNZ], x[ROWS];
static uint32_t rec_m[JM][VL], rec_len[JM][VL];
static float rec_acc[JM][VL], rec_v[JM][VL], rec_xv[JM][VL];
static uint32_t rec_c[JM][VL];
static uint32_t cnt[JM];
static size_t nvl;

static uint32_t rng = 2027u;
static uint32_t rnd(void) { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng; }
static float rnd_f32(void) { return (float)(int32_t)(rnd() >> 8) * (1.0f / 8388608.0f) - 1.0f; }
static uint32_t fu(float f) { union { float f; uint32_t u; } v = { .f = f }; return v.u; }

int main(void)
{
    uint32_t nnz = 0;
    for (uint32_t r = 0; r < ROWS; r++) {
        rowptr[r] = nnz;
        uint32_t k = rnd() % (MAXNNZ + 1);
        for (uint32_t j = 0; j < k; j++) { col[nnz] = rnd() % ROWS; val[nnz] = rnd_f32(); nnz++; }
    }
    rowptr[ROWS] = nnz;
    for (uint32_t i = 0; i < ROWS; i++) x[i] = rnd_f32();

    size_t vl = __riscv_vsetvl_e32m1(VL);
    nvl = vl;
    vuint32m1_t beg = __riscv_vle32_v_u32m1(rowptr, vl);
    vuint32m1_t len = __riscv_vsub_vv_u32m1(__riscv_vle32_v_u32m1(rowptr + 1, vl), beg, vl);
    vuint32m1_t zero = __riscv_vmv_v_x_u32m1(0, vl), one = __riscv_vmv_v_x_u32m1(1, vl);
    vuint32m1_t z1 = __riscv_vmv_v_x_u32m1(0, 1);
    vuint32m1_t off = __riscv_vsll_vx_u32m1(beg, 2, vl);
    vfloat32m1_t acc = __riscv_vfmv_v_f_f32m1(0.0f, vl);
    for (uint32_t j = 0; j < JM; j++) {
        vbool32_t m = __riscv_vmsgtu_vx_u32m1_b32(len, j, vl);
        __riscv_vse32_v_u32m1(rec_m[j], __riscv_vmerge_vxm_u32m1(zero, 1, m, vl), vl);
        __riscv_vse32_v_u32m1(rec_len[j], len, vl);
        cnt[j] = __riscv_vmv_x_s_u32m1_u32(__riscv_vredsum_vs_u32m1_u32m1_m(m, one, z1, vl));
        vfloat32m1_t v = __riscv_vluxei32_v_f32m1_m(m, val, off, vl);
        vuint32m1_t c = __riscv_vluxei32_v_u32m1_mu(m, zero, col, off, vl);
        vfloat32m1_t xv = __riscv_vluxei32_v_f32m1_m(m, x, __riscv_vsll_vx_u32m1(c, 2, vl), vl);
        __riscv_vse32_v_f32m1(rec_v[j], v, vl);
        __riscv_vse32_v_u32m1(rec_c[j], c, vl);
        __riscv_vse32_v_f32m1(rec_xv[j], xv, vl);
        acc = __riscv_vfmacc_vv_f32m1_mu(m, acc, v, xv, vl);
        __riscv_vse32_v_f32m1(rec_acc[j], acc, vl);
        off = __riscv_vadd_vx_u32m1(off, 4, vl);
    }
    __asm__ volatile("fence" ::: "memory");

    unsigned bad = 0;
    for (uint32_t j = 0; j < JM; j++) {
        uint32_t ec = 0;
        for (uint32_t i = 0; i < nvl; i++) {
            const uint32_t l = rowptr[i + 1] - rowptr[i];
            ec += l > j;
            if (rec_len[j][i] != l && bad++ < 6) printf("j %u i %u len got %u ref %u\n", j, i, rec_len[j][i], l);
            if (rec_m[j][i] != (l > j) && bad++ < 12) printf("j %u i %u mask got %u ref %u\n", j, i, rec_m[j][i], l > j);
        }
        if (cnt[j] != ec && bad++ < 18) printf("j %u count got %u ref %u\n", j, cnt[j], ec);
    }
    /* scalar acc trace for the first rows */
    for (uint32_t i = 0; i < 6; i++) {
        float a = 0.0f;
        for (uint32_t j = 0; j < JM; j++) {
            const uint32_t b = rowptr[i], l = rowptr[i + 1] - b;
            if (j < l) a = __builtin_fmaf(val[b + j], x[col[b + j]], a);
            if (j < l && (fu(rec_v[j][i]) != fu(val[b + j]) || rec_c[j][i] != col[b + j] || fu(rec_xv[j][i]) != fu(x[col[b + j]])))
                if (bad++ < 30) printf("row %u j %u: v %08x/%08x c %u/%u xv %08x/%08x\n", i, j, fu(rec_v[j][i]), fu(val[b + j]),
                                       rec_c[j][i], col[b + j], fu(rec_xv[j][i]), fu(x[col[b + j]]));
            if (fu(rec_acc[j][i]) != fu(a)) {
                if (bad++ < 30) printf("row %u (len %u): acc differs from j %u: got %08x ref %08x\n", i, l, j, fu(rec_acc[j][i]), fu(a));
                break;
            }
        }
    }
    printf("dbg_spmv bad %u\n", bad);
    return (int)bad;
}
