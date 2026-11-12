/*
 * rv_native_check.c - kernels/rivec/rv_ref.h against the results that RiVEC ships with
 * its inputs, using the board blob (sim/rv_data.py). Native (WSL gcc):
 *   gcc -O2 -mfma -ffp-contract=off rv_native_check.c -o rvn && ./rvn ../../../build_rivec/rv_data.bin
 * matmul: RiVEC's C, exact. pathfinder: RiVEC's result row, exact. spmv: RiVEC's FP64
 * verif[k+1] against y[k] (relative). blackscholes: DerivaGem FP64 values (loose).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "../rv_ref.h"

static uint8_t *blob;
static uint32_t *get(const char *name, uint32_t *nw)
{
    uint32_t *h = (uint32_t *)blob, e = h[1];
    for (uint32_t i = 0; i < e; i++) {
        const uint32_t *en = h + 2 + 8 * i;
        if (!strncmp((const char *)en, name, 24)) { *nw = en[7]; return (uint32_t *)(blob + en[6]); }
    }
    fprintf(stderr, "missing %s\n", name); exit(2);
}

int main(int argc, char **argv)
{
    FILE *f = fopen(argc > 1 ? argv[1] : "rv_data.bin", "rb");
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    blob = malloc(sz); if (fread(blob, 1, sz, f) != (size_t)sz) return 2; fclose(f);
    uint32_t nw, bad = 0;

    /* matmul */
    uint32_t *d = get("rv_mm_dims", &nw), m = d[0], k = d[1], n = d[2];
    float *A = (float *)get("rv_mm_a", &nw), *B = (float *)get("rv_mm_b", &nw), *C = (float *)get("rv_mm_c", &nw);
    float *c = malloc(4 * m * n);
    rv_matmul(A, B, c, m, n, k);
    uint32_t e = 0; for (uint32_t i = 0; i < m * n; i++) e += memcmp(&c[i], &C[i], 4) != 0;
    printf("matmul %ux%ux%u: %u of %u differ from RiVEC's C\n", m, k, n, e, m * n); bad += e;

    /* pathfinder */
    uint32_t *pd = get("rv_pf_dims", &nw), rows = pd[0], cols = pd[1];
    int32_t *wall = (int32_t *)get("rv_pf_wall", &nw), *ref = (int32_t *)get("rv_pf_ref", &nw);
    int32_t *dst = malloc(4 * cols), *tmp = malloc(4 * cols);
    rv_pathfinder(wall, rows, cols, dst, tmp, 1);
    e = 0; for (uint32_t i = 0; i < cols; i++) e += dst[i] != ref[i];
    printf("pathfinder %ux%u: %u of %u differ from RiVEC's result\n", rows, cols, e, cols); bad += e;

    /* spmv: y = A^T * 1 */
    uint32_t nr; uint32_t *ia = get("rv_sp_ia", &nr), *ja = get("rv_sp_ja", &nw);
    nr -= 1;
    float *va = (float *)get("rv_sp_a", &nw), *ver = (float *)get("rv_sp_verif", &nw);
    float *x = malloc(4 * nr), *y = malloc(4 * nr);
    for (uint32_t i = 0; i < nr; i++) x[i] = 1.0f;
    rv_spmv(nr, ia, ja, va, x, y);
    /* RiVEC's verif is wrong where a column has an entry in the last row (its read of
       x[N] past the end): those rows are skipped. Error scale: the row's sum of |a|. */
    double worst = 0; uint32_t wi = 0, skipped = 0;
    for (uint32_t i = 0; i + 2 < nr; i++) {   /* verif[nr - 1], RiVEC's last row, is wrong too */
        double sa = 0; int lastrow = 0;
        for (uint32_t q = ia[i]; q < ia[i + 1]; q++) { sa += fabs((double)va[q]); lastrow |= ja[q] == nr - 1; }
        if (lastrow) { skipped++; continue; }
        double r = fabs((double)y[i] - (double)ver[i + 1]) / sa;
        if (r > worst) { worst = r; wi = i; }
    }
    printf("spmv %u rows: largest |y - verif| / sum|a| %.3g (row %u), %u rows skipped (entry in the last row)\n",
           nr, worst, wi, skipped);
    if (worst > 1e-5) bad++;

    /* blackscholes */
    float *S = (float *)get("rv_bs_S", &nw), *K = (float *)get("rv_bs_K", &nw), *R = (float *)get("rv_bs_r", &nw),
          *V = (float *)get("rv_bs_v", &nw), *T = (float *)get("rv_bs_T", &nw), *dg = (float *)get("rv_bs_dg", &nw);
    int32_t *ot = (int32_t *)get("rv_bs_type", &nw);
    uint32_t nb = nw;
    float *p = malloc(4 * nb);
    rv_blackscholes(nb, S, K, R, V, T, ot, p);
    double wb = 0; for (uint32_t i = 0; i < nb; i++) { double a = fabs(p[i] - dg[i]); if (a > wb) wb = a; }
    printf("blackscholes %u options: largest absolute difference from DerivaGem %.3g\n", nb, wb);

    printf("RV_NATIVE %s\n", bad ? "FAIL" : "PASS");
    return bad != 0;
}
