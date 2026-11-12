/*
 * rodinia.inc - the Rodinia suite on the board (docs/rodinia_plan.md). Included after
 * suite2.inc at the end of
 *   sw/ps_host/apps.c                  SIMTiX, and Vortex with SIMTIX_VORTEX: report()
 *                                      rows "BOARD,..." / "VXB,..."
 *   baselines/ara/host/apps_ara.c      with S2_ARA: CVA6 (mode 0) and Ara (mode 1)
 * The benchmarks that suite 2 already has run through its functions (app_s2_pathfinder,
 * app_s2_backprop) at Rodinia's sizes; the others are here. Where Rodinia reads a data
 * file, the board script has loaded the data blob of sim/rd_data.py at RD_BLOB, and the
 * host copies the arrays into its arena (rd_get). The A53 reference is timed on the
 * same arrays, and every output word is compared with it.
 */

#include "rd_ref.h"

/* <pre><n><post>, e.g. hotspot512_temp: the blob names of sim/rd_data.py */
static void rd_name(char *out, const char *pre, uint32_t n, const char *post)
{
    char num[12];
    unsigned k = 0, d = 0;
    do { num[d++] = (char)('0' + n % 10); n /= 10; } while (n);
    while (*pre) out[k++] = *pre++;
    while (d) out[k++] = num[--d];
    while (*post) out[k++] = *post++;
    out[k] = 0;
}

/* ── The data blob (sim/rd_data.py): 'RDDB', E, E x {name[24], byte offset, words} ── */
#define RD_BLOB   0x70000000u
#define RD_MAGIC  0x42444452u
static unsigned rd_missing;

/* A copy of blob array <name> in the arena (n words); 0 and a message if it is absent. */
static uint32_t *rd_get(const char *name, uint32_t *n)
{
    const uint32_t *b = (const uint32_t *)(uintptr_t)RD_BLOB;
    if (b[0] != RD_MAGIC) { xil_printf("RODINIA: no data blob at 0x%08x\r\n", RD_BLOB); rd_missing++; return 0; }
    for (uint32_t e = 0; e < b[1]; e++) {
        const char *nm = (const char *)&b[2 + 8 * e];
        unsigned k = 0;
        while (k < 24 && name[k] && nm[k] == name[k]) k++;
        if (k < 24 && !name[k] && !nm[k]) {
            *n = b[2 + 8 * e + 7];
            uint32_t *d = alloc_u32(*n);
            const uint32_t *src = b + b[2 + 8 * e + 6] / 4u;
            for (uint32_t i = 0; i < *n; i++) d[i] = src[i];
            return d;
        }
    }
    xil_printf("RODINIA: %s is not in the data blob\r\n", name);
    rd_missing++;
    return 0;
}

#ifndef S2_ARA
#include "kernels_rd.h"
static void rd_load_all(void)
{
#if defined(SIMTIX_A53_ONLY) || defined(SIMTIX_VORTEX)
    return;                     /* no SIMTiX instruction RAM (apps.c, before suite2.inc) */
#endif
    for (unsigned k = 0; k < sizeof rd_kernels / sizeof rd_kernels[0]; k++)
        for (unsigned i = 0; i < rd_kernels[k].n; i++)
            wr(IRAM + rd_kernels[k].pc + 4u * i, rd_kernels[k].w[i]);
}
#endif

/* ── bfs: Rodinia's graph file, level-synchronous from node 0 ───────────────── */
#define RD_UNSEEN 0xFFFFFFFFu
static void rd_bfs_ref(const uint32_t *rowptr, const uint32_t *col, uint32_t *lev, uint32_t *queue, uint32_t nv)
{
    for (uint32_t v = 0; v < nv; v++) lev[v] = RD_UNSEEN;
    uint32_t head = 0, tail = 0;
    lev[0] = 0; queue[tail++] = 0;
    while (head < tail) {
        uint32_t v = queue[head++];
        for (uint32_t j = rowptr[v]; j < rowptr[v + 1]; j++) {
            uint32_t u = col[j];
            if (lev[u] == RD_UNSEEN) { lev[u] = lev[v] + 1; queue[tail++] = u; }
        }
    }
}

static unsigned app_rd_bfs(const char *rowptr_name, const char *col_name, uint32_t nv_expect)
{
    unsigned errs_ = 0;
    XTime t2, t3;
    uint32_t nr = 0, ne = 0;
    uint32_t *rowptr = rd_get(rowptr_name, &nr), *col = rd_get(col_name, &ne);
    if (!rowptr || !col || nr != nv_expect + 1) {
        xil_printf("RODINIA: bfs %s not run\r\n", rowptr_name);
        return 1;
    }
    const uint32_t nv = nr - 1;
    uint32_t *lev = alloc_u32(nv), *rlev = alloc_u32(nv), *queue = alloc_u32(nv);
    XTime_GetTime(&t2);
    rd_bfs_ref(rowptr, col, rlev, queue, nv);
    XTime_GetTime(&t3);
#ifdef S2_ARA
    uint32_t *q2 = alloc_u32(nv);
    for (uint32_t m = 0; m < 2; m++) {
        for (uint32_t v = 0; v < nv; v++) lev[v] = 0xA5A5A5A5u;
        uint32_t a[] = { addr(rowptr), addr(col), addr(lev), nv, addr(q2) };
        unsigned e = ara_run(AK_BFS, m, a, 5);
        e += diff(lev, rlev, nv);
        report("bfs", nv, m, us(t2, t3), e); errs_ += e;
    }
#else
    for (uint32_t v = 0; v < nv; v++) lev[v] = RD_UNSEEN;
    lev[0] = 0;
    uint32_t *p[64], *flag[64];
    for (uint32_t L = 0; L < 64; L++) {
        p[L] = params(5);
        flag[L] = alloc_u32(8);
        flag[L][0] = 0;
        p[L][0] = addr(rowptr); p[L][1] = addr(col); p[L][2] = addr(lev);
        p[L][3] = L; p[L][4] = addr(flag[L]);
    }
    S2_ACC_BEGIN();
    for (uint32_t L = 0; L < 64; L++) {
        launch(PC_RD_BFS, p[L], nv, 0);
        Xil_DCacheInvalidateRange((INTPTR)flag[L], 32);
        if (!flag[L][0]) break;
    }
    S2_ACC_END();
    errs_ = diff(lev, rlev, nv);
    report("bfs", nv, us(t0, t1), us(t2, t3), errs_);
#endif
    return errs_;
}

/* ── hotspot: Rodinia's temp/power files, every cell, clamped neighbours ──────── */
static unsigned app_rd_hotspot(uint32_t n, uint32_t steps)
{
    unsigned errs_ = 0;
    XTime t2, t3;
    char tn[24], pn[24];
    uint32_t nt = 0, np = 0, l2 = 0;
    while ((1u << l2) < n) l2++;
    rd_name(tn, "hotspot", n, "_temp");               /* sim/rd_data.py names */
    rd_name(pn, "hotspot", n, "_power");
    float *tin = (float *)rd_get(tn, &nt), *pw = (float *)rd_get(pn, &np);
    if (!tin || !pw || nt != n * n || np != n * n) { xil_printf("RODINIA: hotspot %u not run\r\n", n); return 1; }
    const size_t words = (size_t)n * n;
    float k[5];
    rd_hotspot_consts(n, k);
    float *rg[2] = { (float *)s2_dup(tin, words), (float *)s2_dup(tin, words) };
    float *g[2] = { (float *)alloc_u32(words), (float *)alloc_u32(words) };
    XTime_GetTime(&t2);
    rd_hotspot(rg[0], rg[1], pw, n, k, steps);
    XTime_GetTime(&t3);
    const int r = (int)(steps & 1);
#ifdef S2_ARA
    for (uint32_t m = 0; m < 2; m++) {
        s2_copy(g[0], tin, words); s2_copy(g[1], tin, words);
        uint32_t a[] = { addr(g[0]), addr(g[1]), addr(pw), n, f2u(k[0]), f2u(k[1]), f2u(k[2]),
                         f2u(k[3]), f2u(k[4]), steps };
        unsigned e = ara_run(AK_RD_HOTSPOT, m, a, 10);
        e += diff((uint32_t *)g[r], (uint32_t *)rg[r], words);
        report("hotspot", n, m, us(t2, t3), e); errs_ += e;
    }
#else
    s2_copy(g[0], tin, words); s2_copy(g[1], tin, words);
    uint32_t *p[2];
    for (int b = 0; b < 2; b++) {
        p[b] = params(9);
        p[b][0] = addr(g[b]); p[b][1] = addr(g[b ^ 1]); p[b][2] = addr(pw); p[b][3] = l2;
        for (int j = 0; j < 5; j++) p[b][4 + j] = f2u(k[j]);
    }
    S2_ACC_BEGIN();
    for (uint32_t st = 0; st < steps; st++)
        launch(PC_RD_HOTSPOT_RD, p[st & 1], n * n, 0);
    S2_ACC_END();
    errs_ = diff((uint32_t *)g[r], (uint32_t *)rg[r], words);
    report("hotspot", n, us(t0, t1), us(t2, t3), errs_);
#endif
    return errs_;
}

/* ── CVA6/Ara tolerance (docs/rodinia_plan.md, "Checking the results"): their divide
   and square-root unit is not correctly rounded. Outputs further than tol ulp from the
   A53 reference count as errors; the largest distance is printed as
   RDULP,<app>,<size>,<mode>,<max ulp>. ─────────────────────────────────────────── */
static uint32_t rd_ulp(uint32_t a, uint32_t b)
{
    /* FP32 bits to a monotonic integer line; the distance is the ulp count */
    int64_t x = (a & 0x80000000u) ? -(int64_t)(a & 0x7FFFFFFFu) : (int64_t)a;
    int64_t y = (b & 0x80000000u) ? -(int64_t)(b & 0x7FFFFFFFu) : (int64_t)b;
    int64_t d = x > y ? x - y : y - x;
    return d > 0x7FFFFFFF ? 0x7FFFFFFFu : (uint32_t)d;
}
__attribute__((unused))
static unsigned rd_diff_ulp(const char *app, uint32_t size, uint32_t mode, const uint32_t *got,
                            const uint32_t *ref, size_t n, uint32_t tol)
{
    unsigned e = 0;
    uint32_t mx = 0;
    for (size_t i = 0; i < n; i++) {
        uint32_t u = rd_ulp(got[i], ref[i]);
        if (u > mx) mx = u;
        e += (u > tol);
    }
    xil_printf("RDULP,%s,%u,%u,%u\r\n", app, size, mode, mx);
    return e;
}

/* Row-relative tolerance (iterative benchmarks whose rounding differences grow): a row
   fails when any |got - ref| exceeds tol times the row's largest |ref|. The largest
   ratio is printed in parts per billion as RDREL,<app>,<size>,<mode>,<ppb>. */
static float rd_fabs(float x) { return x < 0.0f ? -x : x; }
__attribute__((unused))
static unsigned rd_diff_rowrel(const char *app, uint32_t size, uint32_t mode, const float *got,
                               const float *ref, uint32_t rows, uint32_t cols, float tol)
{
    unsigned e = 0;
    float worst = 0.0f;
    for (uint32_t i = 0; i < rows; i++) {
        float rmax = 0.0f, dmax = 0.0f;
        for (uint32_t j = 0; j < cols; j++) {
            float r = rd_fabs(ref[i * cols + j]), d = rd_fabs(got[i * cols + j] - ref[i * cols + j]);
            if (r > rmax) rmax = r;
            if (!(d <= dmax)) dmax = d;                    /* NaN counts as the largest */
        }
        float q = rmax > 0.0f ? dmax / rmax : (dmax > 0.0f ? 1.0f : 0.0f);
        if (!(q <= tol)) e++;
        if (!(q <= worst)) worst = q;
    }
    xil_printf("RDREL,%s,%u,%u,%u\r\n", app, size, mode, worst < 4.0f ? (unsigned)(worst * 1e9f) : 0xFFFFFFFFu);
    return e;
}

/* ── gaussian: Rodinia's -s n matrix, Fan1 and Fan2 per elimination step ─────── */
static unsigned app_rd_gaussian(const char *blob_name, uint32_t n)
{
    unsigned errs_ = 0;
    XTime t2, t3;
    uint32_t nw = 0;
    float *a0 = (float *)rd_get(blob_name, &nw);
    const uint32_t s = n + 1;
    if (!a0 || nw != n * s) { xil_printf("RODINIA: gaussian %u not run\r\n", n); return 1; }
    float *ra = (float *)s2_dup(a0, (size_t)n * s), *rm = (float *)alloc_u32((size_t)n * n);
    float *A = (float *)alloc_u32((size_t)n * s), *M = (float *)alloc_u32((size_t)n * n);
    for (size_t i = 0; i < (size_t)n * n; i++) rm[i] = 0.0f;
    XTime_GetTime(&t2);
    rd_gaussian(ra, rm, n);
    XTime_GetTime(&t3);
#ifdef S2_ARA
    for (uint32_t m = 0; m < 2; m++) {
        s2_copy(A, a0, (size_t)n * s);
        for (size_t i = 0; i < (size_t)n * n; i++) M[i] = 0.0f;
        uint32_t a[] = { addr(A), addr(M), n };
        unsigned e = ara_run(AK_RD_GAUSSIAN, m, a, 3);
        /* division not correctly rounded: rows within 1e-3 of the row's largest value */
        e += rd_diff_rowrel("gaussian_a", n, m, A, ra, n, s, 1e-3f);
        e += rd_diff_rowrel("gaussian_m", n, m, M, rm, n, n, 1e-3f);
        report("gaussian", n, m, us(t2, t3), e); errs_ += e;
    }
#else
    s2_copy(A, a0, (size_t)n * s);
    for (size_t i = 0; i < (size_t)n * n; i++) M[i] = 0.0f;
    uint32_t *p = params(4 * (n - 1));
    for (uint32_t t = 0; t + 1 < n; t++) {
        uint32_t *q = p + 4 * t;
        q[0] = addr(A); q[1] = addr(M); q[2] = n; q[3] = t;
    }
    S2_ACC_BEGIN();
    for (uint32_t t = 0; t + 1 < n; t++) {
        launch(PC_RD_GAUSS_FAN1, p + 4 * t, n - 1 - t, 0);
        launch(PC_RD_GAUSS_FAN2, p + 4 * t, n + 1 - t, 0);
    }
    S2_ACC_END();
    errs_ = diff((uint32_t *)A, (uint32_t *)ra, (size_t)n * s) + diff((uint32_t *)M, (uint32_t *)rm, (size_t)n * n);
    report("gaussian", n, us(t0, t1), us(t2, t3), errs_);
#endif
    return errs_;
}

/* ── kmeans: Rodinia's kdd_cup, k = 5, until no point changes (or 500 loops) ──── */
/* Rodinia's loop: the kernel assigns every point; the CPU part (here the A53, for every
   system) counts the changes and recomputes the centres. Only the assignment steps are
   timed. The final memberships, the centres and the number of iterations must all match
   the A53 reference exactly (the kernel has no division or square root, so CVA6 and Ara
   are exact too). The iteration count is printed as RDITER,kmeans,<n>,<mode>,<iters>. */
static unsigned app_rd_kmeans(const char *blob_name, uint32_t k, uint32_t nf)
{
    unsigned errs_ = 0;
    uint32_t nw = 0;
    float *pm = (float *)rd_get(blob_name, &nw);
    if (!pm || nw % nf) { xil_printf("RODINIA: kmeans not run\r\n"); return 1; }
    const uint32_t n = nw / nf;
    float *fm = (float *)alloc_u32((size_t)n * nf);              /* feature-major copy */
    for (uint32_t p = 0; p < n; p++)
        for (uint32_t j = 0; j < nf; j++) fm[(size_t)j * n + p] = pm[(size_t)p * nf + j];
    float *rc = (float *)alloc_u32(k * nf), *cc = (float *)alloc_u32(k * nf), *nc = (float *)alloc_u32(k * nf);
    int32_t *rmem = (int32_t *)alloc_u32(n), *rnew = (int32_t *)alloc_u32(n), *len = (int32_t *)alloc_u32(k);
    int32_t *mem = (int32_t *)alloc_u32(n), *mnew = (int32_t *)alloc_u32(n);
    /* A53 reference: Rodinia's whole loop; centres start at the first k points */
    for (uint32_t i = 0; i < k * nf; i++) rc[i] = pm[i];
    for (uint32_t p = 0; p < n; p++) rmem[p] = -1;
    XTime ta, tb, a53 = 0;
    uint32_t rit = 0, loop = 0, delta;
    do {
        XTime_GetTime(&ta);
        rd_kmeans_assign(pm, rc, rnew, n, k, nf);
        XTime_GetTime(&tb);
        a53 += tb - ta;
        delta = rd_kmeans_update(pm, rnew, rmem, rc, nc, len, n, k, nf);
        rit++;
    } while (delta > 0 && loop++ < 500);
    const double a53_us = us(0, a53);
#ifdef S2_ARA
    for (uint32_t m = 0; m < 2; m++) {
        for (uint32_t i = 0; i < k * nf; i++) cc[i] = pm[i];
        for (uint32_t p = 0; p < n; p++) mem[p] = -1;
        uint64_t cyc = 0, hw = 0;
        uint32_t it = 0;
        unsigned e = 0;
        loop = 0;
        do {
            uint32_t a[] = { addr(m ? fm : pm), addr(cc), addr(mnew), n, k, nf };   /* CVA6: point-major */
            e += ara_run(AK_RD_KMEANS, m, a, 6);
            cyc += run_cyc; hw += run_hw;
            delta = rd_kmeans_update(pm, mnew, mem, cc, nc, len, n, k, nf);
            it++;
        } while (delta > 0 && loop++ < 500 && !e);
        run_cyc = cyc; run_hw = hw;
        e += diff((uint32_t *)mem, (uint32_t *)rmem, n) + diff((uint32_t *)cc, (uint32_t *)rc, k * nf) + (it != rit);
        xil_printf("RDITER,kmeans,%u,%u,%u\r\n", n, m, it);
        report("kmeans", n, m, a53_us, e); errs_ += e;
    }
#else
    for (uint32_t i = 0; i < k * nf; i++) cc[i] = pm[i];
    for (uint32_t p = 0; p < n; p++) mem[p] = -1;
    uint32_t *p = params(6);
    p[0] = addr(fm); p[1] = addr(cc); p[2] = addr(mnew); p[3] = n; p[4] = k; p[5] = nf;
    clean_all();                                               /* features and parameters */
    XTime acc = 0;
    uint32_t it = 0;
    loop = 0;
    do {
        Xil_DCacheFlushRange((INTPTR)cc, 4u * k * nf);         /* the centres of this iteration */
        XTime_GetTime(&ta);
        launch(PC_RD_KMEANS_RD, p, n, 0);
        XTime_GetTime(&tb);
        acc += tb - ta;
        Xil_DCacheInvalidateRange((INTPTR)mnew, 4u * n);
        delta = rd_kmeans_update(pm, mnew, mem, cc, nc, len, n, k, nf);
        it++;
    } while (delta > 0 && loop++ < 500);
    errs_ = diff((uint32_t *)mem, (uint32_t *)rmem, n) + diff((uint32_t *)cc, (uint32_t *)rc, k * nf) + (it != rit);
    xil_printf("RDITER,kmeans,%u,0,%u\r\n", n, it);
    report("kmeans", n, us(0, acc), a53_us, errs_);
#endif
    return errs_;
}

/* ── nn: Rodinia's hurricane records (filelist of 4 files), target 30, 90 ─────── */
static unsigned app_rd_nn(const char *blob_name)
{
    unsigned errs_ = 0;
    XTime t2, t3;
    uint32_t nw = 0;
    float *loc = (float *)rd_get(blob_name, &nw);
    if (!loc) { xil_printf("RODINIA: nn not run\r\n"); return 1; }
    const uint32_t n = nw / 2;
    const float lat = 30.0f, lng = 90.0f;               /* Rodinia's run: -lat 30 -lng 90 */
    float *rd = (float *)alloc_u32(n), *d = (float *)alloc_u32(n);
    XTime_GetTime(&t2);
    rd_nn(loc, rd, n, lat, lng);
    XTime_GetTime(&t3);
#ifdef S2_ARA
    for (uint32_t m = 0; m < 2; m++) {
        for (uint32_t i = 0; i < n; i++) ((uint32_t *)d)[i] = 0xA5A5A5A5u;
        uint32_t a[] = { addr(loc), addr(d), n, f2u(lat), f2u(lng) };
        unsigned e = ara_run(AK_RD_NN, m, a, 5);
        e += rd_diff_ulp("nn", n, m, (uint32_t *)d, (uint32_t *)rd, n, 1);   /* sqrt: 1 ulp */
        report("nn", n, m, us(t2, t3), e); errs_ += e;
    }
#else
    uint32_t *p = params(4);
    p[0] = addr(loc); p[1] = addr(d); p[2] = f2u(lat); p[3] = f2u(lng);
    S2_ACC_BEGIN();
    launch(PC_RD_NN, p, n, 0);
    S2_ACC_END();
    errs_ = diff((uint32_t *)d, (uint32_t *)rd, n);
    report("nn", n, us(t0, t1), us(t2, t3), errs_);
#endif
    return errs_;
}

/* ── hotspot3D: Rodinia's temp/power files, a thread per column of layers ────── */
static unsigned app_rd_hotspot3d(const char *tname, const char *pname, uint32_t n, uint32_t nz, uint32_t iters)
{
    unsigned errs_ = 0;
    XTime t2, t3;
    uint32_t nt = 0, np = 0, l2 = 0;
    while ((1u << l2) < n) l2++;
    float *tin = (float *)rd_get(tname, &nt), *pw = (float *)rd_get(pname, &np);
    const size_t words = (size_t)n * n * nz;
    if (!tin || !pw || nt != words || np != words) { xil_printf("RODINIA: hotspot3D not run\r\n"); return 1; }
    float k[6];
    rd_hotspot3d_consts(n, nz, k);
    float *rg[2] = { (float *)s2_dup(tin, words), (float *)s2_dup(tin, words) };
    float *g[2] = { (float *)alloc_u32(words), (float *)alloc_u32(words) };
    XTime_GetTime(&t2);
    rd_hotspot3d(rg[0], rg[1], pw, n, nz, k, iters);
    XTime_GetTime(&t3);
    const int r = (int)(iters & 1);
#ifdef S2_ARA
    for (uint32_t m = 0; m < 2; m++) {
        s2_copy(g[0], tin, words); s2_copy(g[1], tin, words);
        uint32_t a[] = { addr(g[0]), addr(g[1]), addr(pw), n, nz, f2u(k[0]), f2u(k[1]), f2u(k[2]), f2u(k[3]),
                         f2u(k[4]), f2u(k[5]), iters };
        unsigned e = ara_run(AK_RD_HOTSPOT3D, m, a, 12);
        e += diff((uint32_t *)g[r], (uint32_t *)rg[r], words);
        report("hotspot3d", n, m, us(t2, t3), e); errs_ += e;
    }
#else
    s2_copy(g[0], tin, words); s2_copy(g[1], tin, words);
    uint32_t *p[2];
    for (int b = 0; b < 2; b++) {
        p[b] = params(11);
        p[b][0] = addr(g[b]); p[b][1] = addr(g[b ^ 1]); p[b][2] = addr(pw); p[b][3] = l2; p[b][4] = nz;
        for (int j = 0; j < 6; j++) p[b][5 + j] = f2u(k[j]);
    }
    S2_ACC_BEGIN();
    for (uint32_t it = 0; it < iters; it++)
        launch(PC_RD_HOTSPOT3D, p[it & 1], n * n, 0);
    S2_ACC_END();
    errs_ = diff((uint32_t *)g[r], (uint32_t *)rg[r], words);
    report("hotspot3d", n, us(t0, t1), us(t2, t3), errs_);
#endif
    return errs_;
}

/* ── The suite: Rodinia's default data set per benchmark (docs/rodinia_plan.md) ── */
static unsigned run_rodinia(void)
{
    unsigned errs = 0;
    rng = 4001u;                                      /* the same inputs on every system */
    rd_missing = 0;
    xil_printf("RODINIA,suite,start\r\n");
#ifndef S2_ARA
    s2_load_all();
    rd_load_all();
#endif
#ifdef SIMTIX_VORTEX
    vx_rodinia = 1;                                   /* vx_app_of: suite 2 + Rodinia PCs */
#endif
#ifndef S2_RUN
#define S2_RUN(call) do { arena_reset(); errs += (call); } while (0)
#endif
/* RD_SEL (build define, default all): bit i runs the i-th benchmark below, e.g.
   RD_SEL=0x40 for hotspot3D alone. Only pathfinder and backprop draw from rng, and they
   come first, so a selection does not change any other benchmark's input. */
#if defined(__has_include)
#if __has_include("rd_cfg.h")
#include "rd_cfg.h"                 /* the Ara host's build script writes it */
#endif
#endif
#ifndef RD_SEL
#define RD_SEL 0x1FFu
#endif
#define RD_RUN(i, call) do { if (RD_SEL & (1u << (i))) S2_RUN(call); } while (0)
    RD_RUN(0, app_s2_pathfinder(100, 100000));           /* Rodinia: 100,000 columns, 100 rows */
    RD_RUN(1, app_s2_backprop(1u << 19));                /* Rodinia's 2^21 does not fit the Ara arena */
    RD_RUN(2, app_rd_bfs("bfs65536_rowptr", "bfs65536_col", 65536));   /* graph65536.txt */
    RD_RUN(3, app_rd_hotspot(512, 2));                   /* Rodinia: 512 x 512, 2 iterations */
    RD_RUN(4, app_rd_hotspot(1024, 2));                  /* Rodinia's 1024 data set */
    RD_RUN(5, app_rd_nn("nn42764_loc"));                 /* filelist_4: 42,764 records */
    RD_RUN(6, app_rd_hotspot3d("hs3d512x8_temp", "hs3d512x8_power", 512, 8, 100));   /* 512 8 100 */
    RD_RUN(7, app_rd_gaussian("gauss1024_a", 1024));     /* gaussian -s 1024 */
    RD_RUN(8, app_rd_kmeans("kdd_cup_feat", 5, 34));     /* kmeans -i kdd_cup (k = 5) */
#ifdef SIMTIX_VORTEX
    vx_rodinia = 0;
#endif
    xil_printf("RODINIA,suite,end,%u\r\n", rd_missing);
    return errs + rd_missing;
}
