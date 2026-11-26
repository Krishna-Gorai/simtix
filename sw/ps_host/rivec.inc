/*
 * rivec.inc - RiVEC batch 1 on the board (docs/rivec_plan.md). Included after rodinia.inc
 * (whose data-blob reader rd_get it uses: sim/rv_data.py writes the same format) at the end of
 *   sw/ps_host/apps.c                  SIMTiX, and Vortex with SIMTIX_VORTEX: report()
 *                                      rows "BOARD,..." / "VXB,..."
 *   baselines/ara/host/apps_ara.c      with S2_ARA: CVA6 (mode 0) and Ara (mode 1)
 * Hosts built with `rivec` (RV_ONLY) run this suite alone. RiVEC's "large" inputs; the
 * board script has loaded build_rivec/rv_data.bin at RD_BLOB. Every output word is
 * compared with the A53 reference (kernels/rivec/rv_ref.h, timed on the A53):
 *   SIMTiX, Vortex, CVA6: exactly, except CVA6 where it divides or takes a square root
 *   Ara (RiVEC's own vector code): exactly where it computes per element; within a
 *   relative tolerance where it keeps partial sums per element (spmv, lavaMD), and for
 *   CVA6/Ara blackscholes (their divider and square root are not correctly rounded).
 * The largest relative difference is printed as RVREL,<app>,<size>,<mode>,<ppb>.
 * SIMTiX runs its gemm_rb and spmv_z; Vortex the base gemm and spmv (same results).
 */

#include "rv_ref.h"

#ifndef S2_ARA
#include "kernels_rv.h"
static void rv_load_all(void)
{
#if defined(SIMTIX_A53_ONLY) || defined(SIMTIX_VORTEX) || defined(SIMTIX_FGPU)
    return;                     /* no SIMTiX instruction RAM */
#endif
    for (unsigned k = 0; k < sizeof rv_kernels / sizeof rv_kernels[0]; k++)
        for (unsigned i = 0; i < rv_kernels[k].n; i++)
            wr(IRAM + rv_kernels[k].pc + 4u * i, rv_kernels[k].w[i]);
}
#endif

static float rv_fabs(float x) { return x < 0.0f ? -x : x; }
/* Words whose |got - ref| exceeds tol * scale[i]; prints RVREL (largest ratio, ppb). */
__attribute__((unused))
static unsigned rv_diff_rel(const char *app, uint32_t size, uint32_t mode, const float *got,
                            const float *ref, const float *scale, size_t n, float tol)
{
    unsigned e = 0;
    float worst = 0.0f;
    for (size_t i = 0; i < n; i++) {
        float s = scale[i] > 0.0f ? scale[i] : 1.0f;
        float q = rv_fabs(got[i] - ref[i]) / s;
        if (!(q <= tol)) e++;
        if (!(q <= worst)) worst = q;
    }
    xil_printf("RVREL,%s,%u,%u,%u\r\n", app, size, mode, worst < 4.0f ? (unsigned)(worst * 1e9f) : 0xFFFFFFFFu);
    return e;
}

/* ── axpy: dy = fma(a, dx, dy), RiVEC's constant inputs ───────────────────────── */
static unsigned app_rv_axpy(uint32_t n)
{
    unsigned errs_ = 0;
    XTime t2, t3;
    const float a = 1.53f;                               /* RiVEC main.c (double -> float) */
    float *dx = (float *)alloc_u32(n), *dy = (float *)alloc_u32(n), *rdy = (float *)alloc_u32(n);
    for (uint32_t i = 0; i < n; i++) { dx[i] = 1.83f; rdy[i] = 2.22f; }
    A53_BEGIN();
    rv_axpy(a, dx, rdy, n);
    A53_END();
#ifdef S2_ARA
    for (uint32_t m = 0; m < 2; m++) {
        for (uint32_t i = 0; i < n; i++) dy[i] = 2.22f;
        uint32_t ar[] = { addr(dx), addr(dy), f2u(a), n };
        unsigned e = ara_run(AK_RV_AXPY, m, ar, 4);
        e += diff((uint32_t *)dy, (uint32_t *)rdy, n);
        report("axpy", n, m, us(t2, t3), e); errs_ += e;
    }
#else
    for (uint32_t i = 0; i < n; i++) dy[i] = 2.22f;
    uint32_t *p = params(3);
    p[0] = addr(dx); p[1] = addr(dy); p[2] = f2u(a);
    S2_ACC_BEGIN();
    launch(PC_RV_AXPY_RV, p, n, 0);
    S2_ACC_END();
    errs_ = FG_FP_DIFF("axpy", n, dy, rdy, 1, n);
    report("axpy", n, us(t0, t1), us(t2, t3), errs_);
#endif
    return errs_;
}

/* ── matmul: RiVEC's data_512.in (integers 0-3: exact in any order) ──────────── */
static unsigned app_rv_matmul(void)
{
    unsigned errs_ = 0;
    XTime t2, t3;
    uint32_t nd = 0, na = 0, nb = 0, nc = 0;
    uint32_t *d = rd_get("rv_mm_dims", &nd);
    float *A = (float *)rd_get("rv_mm_a", &na), *B = (float *)rd_get("rv_mm_b", &nb);
    float *C0 = (float *)rd_get("rv_mm_c", &nc);
    if (!d || !A || !B || !C0) { xil_printf("RIVEC: matmul not run\r\n"); return 1; }
    const uint32_t m = d[0], p = d[1], n = d[2];
    uint32_t l2 = 0;
    while ((1u << l2) < n) l2++;
    float *rc = (float *)alloc_u32(m * n), *c = (float *)alloc_u32(m * n);
    A53_BEGIN();
    rv_matmul(A, B, rc, m, n, p);
    A53_END();
    errs_ += diff((uint32_t *)rc, (uint32_t *)C0, m * n);           /* RiVEC's own C */
#ifdef S2_ARA
    for (uint32_t mo = 0; mo < 2; mo++) {
        for (uint32_t i = 0; i < m * n; i++) ((uint32_t *)c)[i] = 0xA5A5A5A5u;
        uint32_t ar[] = { addr(A), addr(B), addr(c), m, n, p };
        unsigned e = ara_run(AK_RV_MATMUL, mo, ar, 6);
        e += diff((uint32_t *)c, (uint32_t *)rc, m * n);
        report("matmul", n, mo, us(t2, t3), e); errs_ += e;
    }
#else
    for (uint32_t i = 0; i < m * n; i++) ((uint32_t *)c)[i] = 0xA5A5A5A5u;
    uint32_t *pp = params(5);
    pp[0] = addr(A); pp[1] = addr(B); pp[2] = addr(c); pp[3] = p; pp[4] = l2;
    S2_ACC_BEGIN();
#if defined(SIMTIX_VORTEX) || defined(SIMTIX_FGPU)
    launch(PC_RV_GEMM, pp, m * n, 0);                              /* Vortex: the base kernel */
#else
    launch(PC_RV_GEMM_RB, pp, m * n / 16, 0);                      /* a 4 x 4 block per thread */
#endif
    S2_ACC_END();
    errs_ += diff((uint32_t *)c, (uint32_t *)rc, m * n);
    report("matmul", n, us(t0, t1), us(t2, t3), errs_);
#endif
    return errs_;
}

/* ── spmv: poisson3Db, y = A^T x (0-based CSR of the transpose), x = 1 ──────────── */
static unsigned app_rv_spmv(void)
{
    unsigned errs_ = 0;
    XTime t2, t3;
    uint32_t ni = 0, nj = 0, na = 0;
    uint32_t *ia = rd_get("rv_sp_ia", &ni), *ja = rd_get("rv_sp_ja", &nj);
    float *va = (float *)rd_get("rv_sp_a", &na);
    if (!ia || !ja || !va) { xil_printf("RIVEC: spmv not run\r\n"); return 1; }
    const uint32_t nr = ni - 1;
    float *x = (float *)alloc_u32(nr), *ry = (float *)alloc_u32(nr), *y = (float *)alloc_u32(nr);
    for (uint32_t i = 0; i < nr; i++) x[i] = 1.0f;
    A53_BEGIN();
    rv_spmv(nr, ia, ja, va, x, ry);
    A53_END();
#ifdef S2_ARA
    float *sc = (float *)alloc_u32(nr);                  /* the row's sum of |a * x| */
    for (uint32_t r = 0; r < nr; r++) {
        float s = 0.0f;
        for (uint32_t q = ia[r]; q < ia[r + 1]; q++) s += rv_fabs(va[q] * x[ja[q]]);
        sc[r] = s;
    }
    for (uint32_t m = 0; m < 2; m++) {
        for (uint32_t i = 0; i < nr; i++) ((uint32_t *)y)[i] = 0xA5A5A5A5u;
        uint32_t ar[] = { addr(ia), addr(ja), addr(va), addr(x), addr(y), nr };
        unsigned e = ara_run(AK_RV_SPMV, m, ar, 6);
        e += m ? rv_diff_rel("spmv", nr, m, y, ry, sc, nr, 1e-5f)            /* Ara: reduction */
               : diff((uint32_t *)y, (uint32_t *)ry, nr);                     /* CVA6: exact */
        report("spmv", nr, m, us(t2, t3), e); errs_ += e;
    }
#else
    for (uint32_t i = 0; i < nr; i++) ((uint32_t *)y)[i] = 0xA5A5A5A5u;
    uint32_t *p = params(5);
    p[0] = addr(ia); p[1] = addr(ja); p[2] = addr(va); p[3] = addr(x); p[4] = addr(y);
    S2_ACC_BEGIN();
#if defined(SIMTIX_VORTEX) || defined(SIMTIX_FGPU)
    launch(PC_RV_SPMV, p, nr, 0);
#else
    launch(PC_RV_SPMV_Z, p, nr, 0);
#endif
    S2_ACC_END();
    errs_ = FG_FP_DIFF("spmv", nr, y, ry, 1, nr);
    report("spmv", nr, us(t0, t1), us(t2, t3), errs_);
#endif
    return errs_;
}

/* ── jacobi-2d: 256 x 256, 2,000 steps (each A -> B, B -> A) ───────────────────── */
static unsigned app_rv_jacobi(uint32_t n, uint32_t tsteps)
{
    unsigned errs_ = 0;
    XTime t2, t3;
    const size_t w = (size_t)n * n;
    float *rA = (float *)alloc_u32(w), *rB = (float *)alloc_u32(w);
    float *A = (float *)alloc_u32(w), *B = (float *)alloc_u32(w);
    rv_jacobi_init(rA, rB, n);
    A53_BEGIN();
    rv_jacobi2d(rA, rB, n, tsteps);
    A53_END();
#ifdef S2_ARA
    for (uint32_t m = 0; m < 2; m++) {
        rv_jacobi_init(A, B, n);
        uint32_t ar[] = { addr(A), addr(B), n, tsteps };
        unsigned e = ara_run(AK_RV_JACOBI, m, ar, 4);
        e += diff((uint32_t *)A, (uint32_t *)rA, w) + diff((uint32_t *)B, (uint32_t *)rB, w);
        report("jacobi", n, m, us(t2, t3), e); errs_ += e;
    }
#else
    rv_jacobi_init(A, B, n);
    uint32_t l2 = 0;
    while ((1u << l2) < n) l2++;
    uint32_t *p[2];
    for (int b = 0; b < 2; b++) {
        p[b] = params(4);
        p[b][0] = addr(b ? B : A); p[b][1] = addr(b ? A : B); p[b][2] = l2; p[b][3] = f2u(0.20f);
    }
    S2_ACC_BEGIN();
    for (uint32_t t = 0; t < tsteps; t++) {
        launch(PC_RV_JACOBI_RV, p[0], n * n, 0);
        launch(PC_RV_JACOBI_RV, p[1], n * n, 0);
    }
    S2_ACC_END();
    errs_ = diff((uint32_t *)A, (uint32_t *)rA, w) + diff((uint32_t *)B, (uint32_t *)rB, w);
    report("jacobi", n, us(t0, t1), us(t2, t3), errs_);
#endif
    return errs_;
}

/* ── pathfinder: RiVEC's data_large.in, the whole DP repeated RiVEC's 100 times ─── */
static unsigned app_rv_pathfinder(uint32_t runs)
{
    unsigned errs_ = 0;
    XTime t2, t3;
    uint32_t nd = 0, nw = 0, nr = 0;
    uint32_t *d = rd_get("rv_pf_dims", &nd);
    int32_t *wall = (int32_t *)rd_get("rv_pf_wall", &nw), *ref = (int32_t *)rd_get("rv_pf_ref", &nr);
    if (!d || !wall || !ref) { xil_printf("RIVEC: pathfinder not run\r\n"); return 1; }
    const uint32_t rows = d[0], cols = d[1];
    int32_t *rdst = (int32_t *)alloc_u32(cols), *tmp = (int32_t *)alloc_u32(cols);
    A53_BEGIN();
    rv_pathfinder(wall, rows, cols, rdst, tmp, runs);
    A53_END();
    errs_ += diff((uint32_t *)rdst, (uint32_t *)ref, cols);           /* RiVEC's own result */
#ifdef S2_ARA
    int32_t *dst = (int32_t *)alloc_u32(cols);
    for (uint32_t m = 0; m < 2; m++) {
        for (uint32_t i = 0; i < cols; i++) dst[i] = (int32_t)0xA5A5A5A5;
        uint32_t ar[] = { addr(wall), addr(dst), addr(tmp), rows, cols, runs };
        unsigned e = ara_run(AK_RV_PATHFINDER, m, ar, 6);
        e += diff((uint32_t *)dst, (uint32_t *)rdst, cols);
        report("pathfinder", cols, m, us(t2, t3), e); errs_ += e;
    }
#else
    /* suite 2's pathfinder.S: rows padded with INT_MAX, one launch per row step */
    int32_t *buf[2] = { (int32_t *)alloc_u32(cols + 2), (int32_t *)alloc_u32(cols + 2) };
    for (int b = 0; b < 2; b++) { buf[b][0] = 0x7FFFFFFF; buf[b][cols + 1] = 0x7FFFFFFF; }
    uint32_t *p[2];
    for (int b = 0; b < 2; b++) {
        p[b] = params(4);
        p[b][0] = addr(buf[b]); p[b][1] = addr(buf[b ^ 1]); p[b][3] = cols;
    }
    S2_ACC_BEGIN();
    for (uint32_t r = 0; r < runs; r++) {
        for (uint32_t x = 0; x < cols; x++) buf[0][x + 1] = wall[x];
        Xil_DCacheFlushRange((INTPTR)buf[0], 4u * (cols + 2));
        for (uint32_t t = 1; t < rows; t++) {
            uint32_t *pp = p[(t - 1) & 1];
            pp[2] = addr(wall + (size_t)t * cols);
            Xil_DCacheFlushRange((INTPTR)pp, 16);
            launch(PC_RV_PATHFINDER, pp, cols, 0);
        }
    }
    S2_ACC_END();
    errs_ += diff((uint32_t *)(buf[(rows - 1) & 1] + 1), (uint32_t *)rdst, cols);
    report("pathfinder", cols, us(t0, t1), us(t2, t3), errs_);
#endif
    return errs_;
}

/* ── blackscholes: RiVEC's in_64K.input, RiVEC's 100 runs ────────────────────────── */
static unsigned app_rv_bs(uint32_t runs)
{
    unsigned errs_ = 0;
    XTime t2, t3;
    uint32_t n = 0, k;
    float *S = (float *)rd_get("rv_bs_S", &n), *K = (float *)rd_get("rv_bs_K", &k);
    float *R = (float *)rd_get("rv_bs_r", &k), *V = (float *)rd_get("rv_bs_v", &k);
    float *T = (float *)rd_get("rv_bs_T", &k);
    int32_t *ot = (int32_t *)rd_get("rv_bs_type", &k);
    if (!S || !K || !R || !V || !T || !ot) { xil_printf("RIVEC: blackscholes not run\r\n"); return 1; }
    float *rp = (float *)alloc_u32(n), *pr = (float *)alloc_u32(n);
    A53_BEGIN();
    for (uint32_t r = 0; r < runs; r++) rv_blackscholes(n, S, K, R, V, T, ot, rp);
    A53_END();
#ifdef S2_ARA
    /* CVA6 and Ara: three divisions and a square root per option, not correctly rounded:
       relative to the price, with a cent added for the prices near zero */
    float *sc = (float *)alloc_u32(n);
    for (uint32_t i = 0; i < n; i++) sc[i] = rv_fabs(rp[i]) + 0.01f;
    for (uint32_t m = 0; m < 2; m++) {
        for (uint32_t i = 0; i < n; i++) ((uint32_t *)pr)[i] = 0xA5A5A5A5u;
        uint32_t ar[] = { addr(S), addr(K), addr(R), addr(V), addr(T), addr(ot), addr(pr), n, runs };
        unsigned e = ara_run(AK_RV_BS, m, ar, 9);
        e += rv_diff_rel("blackscholes", n, m, pr, rp, sc, n, 1e-4f);
        report("blackscholes", n, m, us(t2, t3), e); errs_ += e;
    }
#else
    float *C = (float *)alloc_u32(RV_BS_NC);
    rv_bs_consts(C);
    for (uint32_t i = 0; i < n; i++) ((uint32_t *)pr)[i] = 0xA5A5A5A5u;
    uint32_t *p = params(8);
    p[0] = addr(S); p[1] = addr(K); p[2] = addr(R); p[3] = addr(V); p[4] = addr(T);
    p[5] = addr(ot); p[6] = addr(pr); p[7] = addr(C);
    S2_ACC_BEGIN();
    for (uint32_t r = 0; r < runs; r++)
        launch(PC_RV_BS_RV, p, n, 0);
    S2_ACC_END();
    errs_ = FG_FP_DIFF("blackscholes", n, pr, rp, 1, n);
    report("blackscholes", n, us(t0, t1), us(t2, t3), errs_);
#endif
    return errs_;
}

/* ── lavaMD: 10 x 10 x 10 boxes of 96 particles, RiVEC's value ranges ─────────────── */
static unsigned app_rv_lavamd(uint32_t b1d)
{
    unsigned errs_ = 0;
    XTime t2, t3;
    const uint32_t nb = b1d * b1d * b1d, np = nb * RV_LAVA_NP;
    uint32_t *nn = alloc_u32(nb), *nei = alloc_u32(26 * nb + 1);
    rv_lava_boxes(b1d, nn, nei);
    nei[26 * nb] = 0;                                   /* the spare word (lavamd_rv.S) */
    float *rv = (float *)alloc_u32(4 * np), *qv = (float *)alloc_u32(np);
    for (uint32_t i = 0; i < 4 * np; i++) rv[i] = (float)((double)(rnd() % 10 + 1) / 10.0);
    for (uint32_t i = 0; i < np; i++) qv[i] = (float)((double)(rnd() % 10 + 1) / 10.0);
    float *rf = (float *)alloc_u32(4 * np), *f = (float *)alloc_u32(4 * np);
    for (uint32_t i = 0; i < 4 * np; i++) rf[i] = 0.0f;
    A53_BEGIN();
    rv_lavamd(nb, nn, nei, rv, qv, rf, 0.5f);
    A53_END();
#ifdef S2_ARA
    float *sc = (float *)alloc_u32(4 * np);
    for (uint32_t i = 0; i < 4 * np; i++) sc[i] = rv_fabs(rf[i]) + 1.0f;
    for (uint32_t m = 0; m < 2; m++) {
        for (uint32_t i = 0; i < 4 * np; i++) f[i] = 0.0f;
        uint32_t ar[] = { addr(rv), addr(qv), addr(f), addr(nn), addr(nei), f2u(0.5f), nb };
        unsigned e = ara_run(AK_RV_LAVAMD, m, ar, 7);
        e += m ? rv_diff_rel("lavamd", nb, m, f, rf, sc, 4 * np, 1e-5f)       /* Ara: reduction */
               : diff((uint32_t *)f, (uint32_t *)rf, 4 * np);                  /* CVA6: exact */
        report("lavamd", nb, m, us(t2, t3), e); errs_ += e;
    }
#else
    float *C = (float *)alloc_u32(RV_BS_NC);
    rv_bs_consts(C);                                    /* the exp constants */
    for (uint32_t i = 0; i < 4 * np; i++) f[i] = 0.0f;
    uint32_t *p = params(7);
    p[0] = addr(rv); p[1] = addr(qv); p[2] = addr(f); p[3] = addr(nn); p[4] = addr(nei);
    p[5] = f2u(0.5f); p[6] = addr(C);
    S2_ACC_BEGIN();
    launch(PC_RV_LAVAMD_RV, p, np, 0);
    S2_ACC_END();
    errs_ = FG_FP_DIFF("lavamd", nb, f, rf, np, 4);
    report("lavamd", nb, us(t0, t1), us(t2, t3), errs_);
#endif
    return errs_;
}

/* ── The suite: RiVEC's "large" inputs (docs/rivec_plan.md) ───────────────────────── */
static unsigned run_rivec(void)
{
    unsigned errs = 0;
    rng = 5001u;                                        /* lavaMD's particles: the same on every system */
    rd_missing = 0;
    xil_printf("RIVEC,suite,start\r\n");
#ifndef S2_ARA
    rv_load_all();
#endif
#ifdef SIMTIX_VORTEX
    vx_rivec = 1;                                       /* vx_app_of: the RiVEC PCs */
#endif
#ifdef SIMTIX_FGPU
    fg_use_suite(FG_RV);                                /* FGPU's RiVEC image, fg_entry_of */
#endif
#ifndef S2_RUN
#define S2_RUN(call) do { arena_reset(); errs += (call); } while (0)
#endif
#if defined(__has_include)
#if __has_include("rv_cfg.h")
#include "rv_cfg.h"                 /* RV_SEL from the Ara host's build script */
#endif
#endif
#ifndef RV_SEL
#define RV_SEL 0x7Fu                /* bit i: the i-th application below */
#endif
#define RV_RUN(i, call) do { if (RV_SEL & (1u << (i))) S2_RUN(call); } while (0)
#ifndef PW_ONLY                     /* PW_ONLY (build option power): the power pass alone */
    RV_RUN(0, app_rv_axpy(2048u * 1024u));             /* run.sh large: 2048 K elements */
    RV_RUN(1, app_rv_matmul());                        /* data_512.in */
    RV_RUN(2, app_rv_spmv());                          /* poisson3Db */
    RV_RUN(3, app_rv_jacobi(256, 2000));               /* 256 2000 */
    RV_RUN(4, app_rv_pathfinder(100));                 /* data_large.in, NUM_RUNS 100 */
    RV_RUN(5, app_rv_bs(100));                         /* in_64K.input, NUM_RUNS 100 */
    RV_RUN(6, app_rv_lavamd(10));                      /* -boxes1d 10 */
#endif
    /* Power pass (docs/power_plan.md), as rodinia.inc's */
    if (pw_init() > 0) {
        xil_printf("POWER,app,size,phase,rail,mV,mW,samples,reps,ms\r\n");
        pmode = 1;
        rng = 5001u;                                    /* the inputs of the timing pass */
#define RV_PRUN(i, call) do { if (RV_SEL & (1u << (i))) PRUN(call); } while (0)
        RV_PRUN(0, app_rv_axpy(2048u * 1024u));
        RV_PRUN(1, app_rv_matmul());
        RV_PRUN(2, app_rv_spmv());
        RV_PRUN(3, app_rv_jacobi(256, 2000));
        RV_PRUN(4, app_rv_pathfinder(100));
        RV_PRUN(5, app_rv_bs(100));
        RV_PRUN(6, app_rv_lavamd(10));
        pmode = 0;
    }
#ifdef SIMTIX_VORTEX
    vx_rivec = 0;
#endif
    xil_printf("RIVEC,suite,end,%u\r\n", rd_missing);
    return errs + rd_missing;
}
