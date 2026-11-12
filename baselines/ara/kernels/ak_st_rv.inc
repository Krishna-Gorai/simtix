/*
 * ak_st_rv.inc - self-tests of RiVEC batch 1 (docs/rivec_plan.md) for the Verilator wrapper
 * model and QEMU, included by ak_main.c: CVA6 (kernels/rivec/rv_ref.h) against Ara
 * (RiVEC's own vector code, ak_vector_rv.inc). Word for word where RiVEC's vector code
 * computes per element (CVA6 and Ara share the divide and square-root unit, so they agree
 * there too); within a relative tolerance where it keeps partial sums per element and
 * reduces them (spmv, lavaMD), with the largest relative difference printed in parts per
 * billion (RVREL lines).
 */

static float rv_fabsf(float x) { return x < 0.0f ? -x : x; }

/* Elements whose |a - b| exceeds tol * scale[i] (scale: the sum of the magnitudes of the
   terms of element i); prints the largest |a - b| / scale in parts per billion. */
static uint32_t rv_diff_rel(const char *app, const float *a, const float *b, const float *scale,
                            uint32_t n, float tol)
{
    uint32_t e = 0;
    float worst = 0.0f;
    for (uint32_t i = 0; i < n; i++) {
        float d = rv_fabsf(a[i] - b[i]), s = scale[i] > 0.0f ? scale[i] : 1.0f;
        float q = d / s;
        if (!(q <= worst)) worst = q;
        if (!(q <= tol) && e++ < 4) printf("  [%u] %08x %08x\n", i, f2u(a[i]), f2u(b[i]));
    }
    printf("RVREL %s %u\n", app, worst < 4.0f ? (unsigned)(worst * 1e9f) : 0xFFFFFFFFu);
    return e;
}

static void t_rv_axpy(uint32_t n)
{
    float *dx = alloc(4 * n), *dy0 = alloc(4 * n);
    for (uint32_t i = 0; i < n; i++) { dx[i] = 4.0f * rnd_f32(); dy0[i] = 4.0f * rnd_f32(); }
    const float aa = 1.53f;
    float *dy[2]; uint64_t cy[2];
    for (int m = 0; m < 2; m++) {
        dy[m] = (float *)dup32(dy0, n);
        uint32_t a[] = { H(dx), H(dy[m]), f2u(aa), n };
        cy[m] = run(AK_RV_AXPY, m, a);
    }
    report("rv_axpy", n, cy[0], cy[1], diffw(dy[0], dy[1], n));
}

/* integer-valued data 0..3, as RiVEC's matmul inputs: exact in any order */
static void t_rv_matmul(uint32_t m, uint32_t n, uint32_t p)
{
    float *A = alloc(4 * m * p), *B = alloc(4 * p * n), *C[2];
    for (uint32_t i = 0; i < m * p; i++) A[i] = (float)(rnd() & 3);
    for (uint32_t i = 0; i < p * n; i++) B[i] = (float)(rnd() & 3);
    uint64_t cy[2];
    for (int k = 0; k < 2; k++) {
        C[k] = alloc(4 * m * n);
        uint32_t a[] = { H(A), H(B), H(C[k]), m, n, p };
        cy[k] = run(AK_RV_MATMUL, k, a);
    }
    report("rv_matmul", m, cy[0], cy[1], diffw(C[0], C[1], m * n));
}

/* random CSR (rows of 0 .. maxnnz entries, some above Ara's 64 elements per register) */
static void t_rv_spmv(uint32_t nrows, uint32_t maxnnz)
{
    uint32_t *ia = alloc_u32(nrows + 1);
    ia[0] = 0;
    for (uint32_t r = 0; r < nrows; r++) ia[r + 1] = ia[r] + rnd() % (maxnnz + 1);
    const uint32_t nnz = ia[nrows];
    uint32_t *ja = alloc_u32(nnz);
    float *va = alloc(4 * nnz), *x = alloc(4 * nrows), *sc = alloc(4 * nrows), *y[2];
    for (uint32_t q = 0; q < nnz; q++) { ja[q] = rnd() % nrows; va[q] = rnd_f32(); }
    for (uint32_t r = 0; r < nrows; r++) x[r] = 1.0f;
    for (uint32_t r = 0; r < nrows; r++) {
        sc[r] = 0.0f;
        for (uint32_t q = ia[r]; q < ia[r + 1]; q++) sc[r] += rv_fabsf(va[q] * x[ja[q]]);
    }
    uint64_t cy[2];
    for (int m = 0; m < 2; m++) {
        y[m] = alloc(4 * nrows);
        uint32_t a[] = { H(ia), H(ja), H(va), H(x), H(y[m]), nrows };
        cy[m] = run(AK_RV_SPMV, m, a);
    }
    report("rv_spmv", nrows, cy[0], cy[1], rv_diff_rel("rv_spmv", y[0], y[1], sc, nrows, 1e-5f));
}

/* PolyBench's init_array, RiVEC's vector order per point: exact */
static void t_rv_jacobi(uint32_t n, uint32_t tsteps)
{
    float *A[2], *B[2];
    uint64_t cy[2];
    for (int m = 0; m < 2; m++) {
        A[m] = alloc(4 * n * n); B[m] = alloc(4 * n * n);
        rv_jacobi_init(A[m], B[m], n);
        uint32_t a[] = { H(A[m]), H(B[m]), n, tsteps };
        cy[m] = run(AK_RV_JACOBI, m, a);
    }
    report("rv_jacobi", n, cy[0], cy[1], diffw(A[0], A[1], n * n) + diffw(B[0], B[1], n * n));
}

static void t_rv_pathfinder(uint32_t rows, uint32_t cols, uint32_t runs)
{
    int32_t *wall = (int32_t *)alloc_u32(rows * cols), *tmp = (int32_t *)alloc_u32(cols), *dst[2];
    for (uint32_t i = 0; i < rows * cols; i++) wall[i] = (int32_t)(rnd() % 10);
    uint64_t cy[2];
    for (int m = 0; m < 2; m++) {
        dst[m] = (int32_t *)alloc_u32(cols);
        uint32_t a[] = { H(wall), H(dst[m]), H(tmp), rows, cols, runs };
        cy[m] = run(AK_RV_PATHFINDER, m, a);
    }
    report("rv_pathfinder", cols, cy[0], cy[1], diffw(dst[0], dst[1], cols));
}

/* options in RiVEC's ranges (in_*.input: S 10-120, K 10-120, r 0.02-0.1, v 0.05-0.65,
   T 0.05-1), half puts */
static void t_rv_bs(uint32_t n)
{
    float *S = alloc(4 * n), *K = alloc(4 * n), *R = alloc(4 * n), *V = alloc(4 * n), *T = alloc(4 * n), *p[2];
    int32_t *ot = (int32_t *)alloc_u32(n);
    for (uint32_t i = 0; i < n; i++) {
        S[i] = 65.0f + 55.0f * rnd_f32(); K[i] = 65.0f + 55.0f * rnd_f32();
        R[i] = 0.06f + 0.04f * rnd_f32(); V[i] = 0.35f + 0.3f * rnd_f32();
        T[i] = 0.525f + 0.475f * rnd_f32(); ot[i] = (int32_t)(rnd() & 1);
    }
    uint64_t cy[2];
    for (int m = 0; m < 2; m++) {
        p[m] = alloc(4 * n);
        uint32_t a[] = { H(S), H(K), H(R), H(V), H(T), H(ot), H(p[m]), n, 1 };
        cy[m] = run(AK_RV_BS, m, a);
    }
    report("rv_bs", n, cy[0], cy[1], diffw(p[0], p[1], n));
}

/* b1d^3 boxes of 96 particles in RiVEC's ranges ((rand()%10 + 1) / 10); the first nhome
   home boxes are computed (with all their neighbours) */
static void t_rv_lavamd(uint32_t b1d, uint32_t nhome)
{
    const uint32_t nb = b1d * b1d * b1d, np = nb * RV_LAVA_NP;
    uint32_t *nn = alloc_u32(nb), *nei = alloc_u32(26 * nb + 1);
    rv_lava_boxes(b1d, nn, nei);
    float *rv = alloc(16 * np), *qv = alloc(4 * np), *fv[2], *sc = alloc(16 * np);
    for (uint32_t i = 0; i < 4 * np; i++) rv[i] = (float)((rnd() % 10) + 1) / 10.0f;
    for (uint32_t i = 0; i < np; i++) qv[i] = (float)((rnd() % 10) + 1) / 10.0f;
    uint64_t cy[2];
    for (int m = 0; m < 2; m++) {
        fv[m] = alloc(16 * np);
        for (uint32_t i = 0; i < 4 * np; i++) fv[m][i] = 0.0f;
        uint32_t a[] = { H(rv), H(qv), H(fv[m]), H(nn), H(nei), f2u(0.5f), nhome };
        cy[m] = run(AK_RV_LAVAMD, m, a);
    }
    /* scale: |fv| of the force component plus one, the sums being of positive charges
       times terms of either sign at most a few units each */
    for (uint32_t i = 0; i < 4 * np; i++) sc[i] = rv_fabsf(fv[0][i]) + 1.0f;
    report("rv_lavamd", nhome, cy[0], cy[1], rv_diff_rel("rv_lavamd", fv[0], fv[1], sc, 4 * np, 1e-5f));
}
