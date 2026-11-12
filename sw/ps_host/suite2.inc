/*
 * suite2.inc - suite 2 on the board (docs/suite2_plan.md: Rodinia pathfinder, hotspot,
 * backprop; RiVEC Black-Scholes; GAP PageRank, connected components; SHOC sort;
 * PolyBench atax, bicg, jacobi-2d). Included at the end of
 *   sw/ps_host/apps.c                  SIMTiX: the launches of kernels/suite2 (as
 *                                      sim/gen_suite2.py), report() rows "BOARD,..."
 *   baselines/ara/host/apps_ara.c      with S2_ARA: CVA6 (mode 0) and Ara (mode 1), one
 *                                      start per application (ak.h AK_PATHFINDER ...)
 * which provide alloc/alloc_u32/addr, rnd/rnd_f32/f2u, clean_all/invalidate_all, us,
 * diff and report, and (SIMTiX) launch/params/wr or (Ara) ara_run. The generator is
 * re-seeded at the start of the suite, so every system gets the same inputs; the A53
 * reference is kernels/suite2/s2_ref.h on its own copies (timed), and every output
 * word is compared with it.
 */
#include "s2_ref.h"

#ifndef S2_ARA
#include "kernels_s2.h"
#ifndef S2_NO_LOAD
static void s2_load_all(void)
{
    for (unsigned k = 0; k < sizeof s2_kernels / sizeof s2_kernels[0]; k++)
        for (unsigned i = 0; i < s2_kernels[k].n; i++)
            wr(IRAM + s2_kernels[k].pc + 4u * i, s2_kernels[k].w[i]);
}
#endif
#define S2_ACC_BEGIN()  XTime t0, t1; clean_all(); XTime_GetTime(&t0)
#define S2_ACC_END()    XTime_GetTime(&t1); invalidate_all()
#endif

static uint32_t *s2_dup(const void *src, size_t nw)
{
    uint32_t *d = alloc_u32(nw);
    for (size_t i = 0; i < nw; i++) d[i] = ((const uint32_t *)src)[i];
    return d;
}
static void s2_copy(void *dst, const void *src, size_t nw)
{
    for (size_t i = 0; i < nw; i++) ((uint32_t *)dst)[i] = ((const uint32_t *)src)[i];
}
static float s2_range(float lo, float hi) { return lo + (hi - lo) * (0.5f * rnd_f32() + 0.5f); }

/* ── Rodinia pathfinder ─────────────────────────────────────────────────────── */
static unsigned app_s2_pathfinder(uint32_t rows, uint32_t cols)
{
    unsigned errs_ = 0;
    XTime t2, t3;
    int32_t *wall = (int32_t *)alloc_u32((size_t)rows * cols);
    for (size_t i = 0; i < (size_t)rows * cols; i++) wall[i] = (int32_t)(rnd() % 10u);
    int32_t *rb[2], *b[2];
    for (int k = 0; k < 2; k++) { rb[k] = (int32_t *)alloc_u32(cols + 2); b[k] = (int32_t *)alloc_u32(cols + 2); }
#define PF_PREP(x) do { for (int k_ = 0; k_ < 2; k_++) { x[k_][0] = x[k_][cols + 1] = S2_INF; \
                          for (uint32_t c_ = 0; c_ < cols; c_++) x[k_][c_ + 1] = k_ ? 0 : wall[c_]; } } while (0)
    PF_PREP(rb);
    XTime_GetTime(&t2);
    s2_pathfinder(wall, rb[0], rb[1], rows, cols);
    XTime_GetTime(&t3);
    const int r = (int)((rows - 1) & 1);
#ifdef S2_ARA
    for (uint32_t m = 0; m < 2; m++) {
        PF_PREP(b);
        uint32_t a[] = { addr(wall), addr(b[0]), addr(b[1]), rows, cols };
        unsigned e = ara_run(AK_PATHFINDER, m, a, 5);
        e += diff((uint32_t *)b[r], (uint32_t *)rb[r], cols + 2);
        report("pathfinder", cols, m, us(t2, t3), e); errs_ += e;
    }
#else
    PF_PREP(b);
    uint32_t *p[2] = { params(4), params(4) };
    S2_ACC_BEGIN();
    for (uint32_t rr = 1; rr < rows; rr++) {
        uint32_t *q = p[rr & 1];
        q[0] = addr(b[(rr - 1) & 1]); q[1] = addr(b[rr & 1]); q[2] = addr(wall + (size_t)rr * cols); q[3] = cols;
        Xil_DCacheFlushRange((INTPTR)q, 16);
        launch(PC_S2_PATHFINDER, q, cols, 0);
    }
    S2_ACC_END();
    errs_ = diff((uint32_t *)b[r], (uint32_t *)rb[r], cols + 2);
    report("pathfinder", cols, us(t0, t1), us(t2, t3), errs_);
#endif
#undef PF_PREP
    return errs_;
}

/* ── Rodinia hotspot and PolyBench jacobi-2d (stencil.S's padded grids) ─────── */
static unsigned app_s2_grid(int hot, uint32_t n, uint32_t steps)
{
    unsigned errs_ = 0;
    XTime t2, t3;
    const uint32_t s = n + 2u * S2_LANES;
    const size_t words = (size_t)(n + 2) * s;
    float *g0 = alloc(4 * words), *pw = hot ? alloc(4 * words) : 0;
    for (size_t i = 0; i < words; i++) g0[i] = hot ? s2_range(320.0f, 340.0f) : rnd_f32();
    if (hot) for (size_t i = 0; i < words; i++) pw[i] = s2_range(0.0f, 0.001f);
    float k[5];
    s2_hotspot_consts(n, k);
    const float c02 = 0.2f;
    float *rg[2] = { (float *)s2_dup(g0, words), (float *)s2_dup(g0, words) };
    float *g[2] = { (float *)alloc_u32(words), (float *)alloc_u32(words) };
    XTime_GetTime(&t2);
    if (hot) s2_hotspot(rg[0], rg[1], pw, n, s, k, steps);
    else     s2_jacobi2d(rg[0], rg[1], n, s, c02, steps);
    XTime_GetTime(&t3);
    const int r = hot ? (int)(steps & 1) : 0;
    const char *name = hot ? "hotspot" : "jacobi2d";
#ifdef S2_ARA
    for (uint32_t m = 0; m < 2; m++) {
        s2_copy(g[0], g0, words); s2_copy(g[1], g0, words);
        unsigned e;
        if (hot) {
            uint32_t a[] = { addr(g[0]), addr(g[1]), addr(pw), n, s, f2u(k[0]), f2u(k[1]), f2u(k[2]),
                             f2u(k[3]), f2u(k[4]), steps };
            e = ara_run(AK_HOTSPOT, m, a, 11);
        } else {
            uint32_t a[] = { addr(g[0]), addr(g[1]), n, s, f2u(c02), steps };
            e = ara_run(AK_JACOBI2D, m, a, 6);
        }
        e += diff((uint32_t *)g[r], (uint32_t *)rg[r], words);
        report(name, n, m, us(t2, t3), e); errs_ += e;
    }
#else
    s2_copy(g[0], g0, words); s2_copy(g[1], g0, words);
    uint32_t *p[2] = { params(10), params(10) };
    for (int k_ = 0; k_ < 2; k_++) {
        uint32_t *q = p[k_];
        q[0] = addr(g[k_]); q[1] = addr(g[k_ ^ 1]);
        if (hot) { q[2] = addr(pw); q[3] = 31u - (uint32_t)__builtin_clz(n); q[4] = s;
                   for (int j = 0; j < 5; j++) q[5 + j] = f2u(k[j]); }
        else     { q[2] = 31u - (uint32_t)__builtin_clz(n); q[3] = s; q[4] = f2u(c02); }
    }
    const uint32_t sweeps = hot ? steps : 2 * steps;
    S2_ACC_BEGIN();
    for (uint32_t st = 0; st < sweeps; st++)
        launch(hot ? PC_S2_HOTSPOT : PC_S2_JACOBI2D, p[st & 1], n * n, 0);
    S2_ACC_END();
    errs_ = diff((uint32_t *)g[r], (uint32_t *)rg[r], words);
    report(name, n, us(t0, t1), us(t2, t3), errs_);
#endif
    return errs_;
}

/* ── PolyBench atax and bicg ────────────────────────────────────────────────── */
static unsigned app_s2_mv(int bicg, uint32_t n)
{
    unsigned errs_ = 0;
    XTime t2, t3;
    float *A = alloc(4u * (size_t)n * n), *x = alloc(4u * n), *x2 = alloc(4u * n);
    for (size_t i = 0; i < (size_t)n * n; i++) A[i] = rnd_f32();
    for (uint32_t i = 0; i < n; i++) x[i] = rnd_f32();
    if (bicg) for (uint32_t i = 0; i < n; i++) x2[i] = rnd_f32();
    float *r0 = alloc(4u * n), *r1 = alloc(4u * n), *o0 = alloc(4u * n), *o1 = alloc(4u * n);
    XTime_GetTime(&t2);
    s2_mv_row(A, x, r0, n);
    s2_mv_col(A, bicg ? x2 : r0, r1, n);
    XTime_GetTime(&t3);
    const char *name = bicg ? "bicg" : "atax";
#ifdef S2_ARA
    for (uint32_t m = 0; m < 2; m++) {
        unsigned e;
        if (bicg) { uint32_t a[] = { addr(A), addr(x), addr(x2), addr(o0), addr(o1), n }; e = ara_run(AK_BICG, m, a, 6); }
        else      { uint32_t a[] = { addr(A), addr(x), addr(o0), addr(o1), n };          e = ara_run(AK_ATAX, m, a, 5); }
        e += diff((uint32_t *)o0, (uint32_t *)r0, n) + diff((uint32_t *)o1, (uint32_t *)r1, n);
        report(name, n, m, us(t2, t3), e); errs_ += e;
    }
#else
    uint32_t *p1 = params(4), *p2 = params(4);
    p1[0] = addr(A); p1[1] = addr(x); p1[2] = addr(o0); p1[3] = n;
    p2[0] = addr(A); p2[1] = addr(bicg ? x2 : o0); p2[2] = addr(o1); p2[3] = n;
    S2_ACC_BEGIN();
    launch(PC_S2_MV_ROW, p1, n, 0);
    launch(PC_S2_MV_COL, p2, n, 0);
    S2_ACC_END();
    errs_ = diff((uint32_t *)o0, (uint32_t *)r0, n) + diff((uint32_t *)o1, (uint32_t *)r1, n);
    report(name, n, us(t0, t1), us(t2, t3), errs_);
#endif
    return errs_;
}

/* ── GAP: the graph of the BFS application (random tree + random edges, CSR) ── */
static uint32_t *s2_rowptr, *s2_col;
static void s2_graph(uint32_t nv, uint32_t deg)
{
    /* adjacency as sorted neighbour lists; built in two passes over an edge list */
    size_t ne = 2u * ((size_t)(nv - 1) + (size_t)nv * (deg - 2) / 2);
    uint32_t *eu = alloc_u32(ne), *ev = alloc_u32(ne), *cnt = alloc_u32(nv + 1);
    size_t m = 0;
    for (uint32_t v = 1; v < nv; v++) { uint32_t u = rnd() % v; eu[m] = u; ev[m++] = v; eu[m] = v; ev[m++] = u; }
    for (size_t i = 0; i < (size_t)nv * (deg - 2) / 2; i++) {
        uint32_t u = rnd() % nv, v = rnd() % nv;
        if (u != v) { eu[m] = u; ev[m++] = v; eu[m] = v; ev[m++] = u; }
    }
    for (uint32_t v = 0; v <= nv; v++) cnt[v] = 0;
    for (size_t i = 0; i < m; i++) cnt[eu[i] + 1]++;
    for (uint32_t v = 0; v < nv; v++) cnt[v + 1] += cnt[v];
    uint32_t *tmp = alloc_u32(m), *fill = s2_dup(cnt, nv + 1);
    for (size_t i = 0; i < m; i++) tmp[fill[eu[i]]++] = ev[i];
    /* sort each list and drop duplicates (the edge set of the generator) */
    s2_rowptr = alloc_u32(nv + 1);
    s2_col = alloc_u32(m);
    size_t e = 0;
    for (uint32_t v = 0; v < nv; v++) {
        uint32_t *l = tmp + cnt[v], len = cnt[v + 1] - cnt[v];
        for (uint32_t i = 1; i < len; i++) {            /* insertion sort: short lists */
            uint32_t x = l[i], j = i;
            while (j > 0 && l[j - 1] > x) { l[j] = l[j - 1]; j--; }
            l[j] = x;
        }
        s2_rowptr[v] = (uint32_t)e;
        for (uint32_t i = 0; i < len; i++)
            if (i == 0 || l[i] != l[i - 1]) s2_col[e++] = l[i];
    }
    s2_rowptr[nv] = (uint32_t)e;
}

static unsigned app_s2_pagerank(uint32_t nv, uint32_t deg, uint32_t iters)
{
    unsigned errs_ = 0;
    XTime t2, t3;
    s2_graph(nv, deg);
    float *inv = alloc(4u * nv), *c = alloc(4u * nv);
    for (uint32_t v = 0; v < nv; v++) inv[v] = 1.0f / (float)(s2_rowptr[v + 1] - s2_rowptr[v]);
    const float d = 0.85f, base = (1.0f - d) * (1.0f / (float)nv), p0 = 1.0f / (float)nv;
    float *rp[2] = { alloc(4u * nv), alloc(4u * nv) }, *pr[2] = { alloc(4u * nv), alloc(4u * nv) };
    for (uint32_t v = 0; v < nv; v++) rp[0][v] = p0;
    XTime_GetTime(&t2);
    s2_pagerank(s2_rowptr, s2_col, inv, c, rp[0], rp[1], nv, d, base, iters);
    XTime_GetTime(&t3);
    const int r = (int)(iters & 1);
#ifdef S2_ARA
    for (uint32_t m = 0; m < 2; m++) {
        for (uint32_t v = 0; v < nv; v++) pr[0][v] = p0;
        uint32_t a[] = { addr(s2_rowptr), addr(s2_col), addr(inv), addr(c), addr(pr[0]), addr(pr[1]), nv,
                         f2u(d), f2u(base), iters };
        unsigned e = ara_run(AK_PAGERANK, m, a, 10);
        e += diff((uint32_t *)pr[r], (uint32_t *)rp[r], nv);
        report("pagerank", nv, m, us(t2, t3), e); errs_ += e;
    }
#else
    for (uint32_t v = 0; v < nv; v++) pr[0][v] = p0;
    uint32_t *pc[2], *pp[2];
    for (int k_ = 0; k_ < 2; k_++) {
        pc[k_] = params(3); pp[k_] = params(6);
        pc[k_][0] = addr(pr[k_]); pc[k_][1] = addr(inv); pc[k_][2] = addr(c);
        pp[k_][0] = addr(s2_rowptr); pp[k_][1] = addr(s2_col); pp[k_][2] = addr(c); pp[k_][3] = addr(pr[k_ ^ 1]);
        pp[k_][4] = f2u(d); pp[k_][5] = f2u(base);
    }
    S2_ACC_BEGIN();
    for (uint32_t k_ = 0; k_ < iters; k_++) {
        launch(PC_S2_PR_CONTRIB, pc[k_ & 1], nv, 0);
        launch(PC_S2_PR_PULL, pp[k_ & 1], nv, 0);
    }
    S2_ACC_END();
    errs_ = diff((uint32_t *)pr[r], (uint32_t *)rp[r], nv);
    report("pagerank", nv, us(t0, t1), us(t2, t3), errs_);
#endif
    return errs_;
}

static unsigned app_s2_cc(uint32_t nv, uint32_t deg)
{
    unsigned errs_ = 0;
    XTime t2, t3;
    s2_graph(nv, deg);
    uint32_t *rl[2] = { alloc_u32(nv), alloc_u32(nv) }, *l[2] = { alloc_u32(nv), alloc_u32(nv) };
    for (uint32_t v = 0; v < nv; v++) rl[0][v] = v;
    XTime_GetTime(&t2);
    uint32_t rounds = s2_cc(s2_rowptr, s2_col, rl[0], rl[1], nv);
    XTime_GetTime(&t3);
    const int r = (int)(rounds & 1);
#ifdef S2_ARA
    uint32_t *rout = alloc_u32(8);
    for (uint32_t m = 0; m < 2; m++) {
        for (uint32_t v = 0; v < nv; v++) l[0][v] = v;
        rout[0] = 0;
        uint32_t a[] = { addr(s2_rowptr), addr(s2_col), addr(l[0]), addr(l[1]), nv, addr(rout) };
        unsigned e = ara_run(AK_CC, m, a, 6);
        e += diff(l[r], rl[r], nv) + (rout[0] != rounds);
        report("cc", nv, m, us(t2, t3), e); errs_ += e;
    }
#else
    for (uint32_t v = 0; v < nv; v++) l[0][v] = v;
    uint32_t *p[2] = { params(5), params(5) }, *flag = alloc_u32(8);
    for (int k_ = 0; k_ < 2; k_++) {
        p[k_][0] = addr(s2_rowptr); p[k_][1] = addr(s2_col); p[k_][2] = addr(l[k_]); p[k_][3] = addr(l[k_ ^ 1]);
        p[k_][4] = addr(flag);
    }
    uint32_t k_ = 0;
    S2_ACC_BEGIN();
    for (;;) {
        flag[0] = 0;
        Xil_DCacheFlushRange((INTPTR)flag, 32);
        launch(PC_S2_CC_STEP, p[k_ & 1], nv, 0);
        k_++;
        Xil_DCacheInvalidateRange((INTPTR)flag, 32);
        if (!flag[0] || k_ > 4u * nv) break;
    }
    S2_ACC_END();
    errs_ = diff(l[r], rl[r], nv) + (k_ != rounds);
    report("cc", nv, us(t0, t1), us(t2, t3), errs_);
#endif
    return errs_;
}

/* ── Rodinia backprop: the two GPU kernels ──────────────────────────────────── */
static unsigned app_s2_backprop(uint32_t n)
{
    unsigned errs_ = 0;
    XTime t2, t3;
    float *in = alloc(4u * n), *w0 = alloc(64u * n), *ow0 = alloc(64u * n), *ed = alloc(64);
    in[0] = 1.0f;
    for (uint32_t i = 1; i < n; i++) in[i] = s2_range(0.0f, 1.0f);
    const uint32_t rng_w = rng;                       /* (Ara) the weights are drawn again per run */
    for (size_t i = 0; i < 16u * (size_t)n; i++) { w0[i] = s2_range(-0.5f, 0.5f); ow0[i] = s2_range(-0.05f, 0.05f); }
    for (int j = 0; j < 16; j++) ed[j] = s2_range(-0.1f, 0.1f);
    const float m_ = 0.3f;
    float *rw = (float *)s2_dup(w0, 16u * (size_t)n), *row = (float *)s2_dup(ow0, 16u * (size_t)n), *rps = alloc(4u * n);
    XTime_GetTime(&t2);
    s2_bp_forward(in, rw, rps, n);
    s2_bp_adjust(in, rw, row, ed, n, m_);
    XTime_GetTime(&t3);
#ifdef S2_ARA
    /* Ara's arena is 192 MB: at n = 2^19 a further copy of both weight arrays (396 bytes per
       input in all) does not fit, so each run works on w0/ow0, redrawn from the same state. */
    float *w = w0, *ow = ow0, *ps = alloc(4u * n);
    const uint32_t rng_end = rng;
    for (uint32_t m = 0; m < 2; m++) {
        rng = rng_w;
        for (size_t i = 0; i < 16u * (size_t)n; i++) { w[i] = s2_range(-0.5f, 0.5f); ow[i] = s2_range(-0.05f, 0.05f); }
        uint32_t a[] = { addr(in), addr(w), addr(ow), addr(ed), addr(ps), n, f2u(m_) };
        unsigned e = ara_run(AK_BACKPROP, m, a, 7);
        e += diff((uint32_t *)ps, (uint32_t *)rps, n) + diff((uint32_t *)w, (uint32_t *)rw, 16u * n) +
             diff((uint32_t *)ow, (uint32_t *)row, 16u * n);
        report("backprop", n, m, us(t2, t3), e); errs_ += e;
    }
    rng = rng_end;
#else
    (void)rng_w;
    float *w = alloc(64u * n), *ow = alloc(64u * n), *ps = alloc(4u * n);
    s2_copy(w, w0, 16u * (size_t)n); s2_copy(ow, ow0, 16u * (size_t)n);
    uint32_t *pf = params(3), *pa = params(5);
    pf[0] = addr(in); pf[1] = addr(w); pf[2] = addr(ps);
    pa[0] = addr(in); pa[1] = addr(w); pa[2] = addr(ow); pa[3] = addr(ed); pa[4] = f2u(m_);
    S2_ACC_BEGIN();
    launch(PC_S2_BP_FORWARD, pf, n, 0);
    launch(PC_S2_BP_ADJUST, pa, 16u * n, 0);
    S2_ACC_END();
    errs_ = diff((uint32_t *)ps, (uint32_t *)rps, n) + diff((uint32_t *)w, (uint32_t *)rw, 16u * n) +
            diff((uint32_t *)ow, (uint32_t *)row, 16u * n);
    report("backprop", n, us(t0, t1), us(t2, t3), errs_);
#endif
    return errs_;
}

/* ── SHOC sort ──────────────────────────────────────────────────────────────── */
static unsigned app_s2_sort(uint32_t n, uint32_t W)
{
    unsigned errs_ = 0;
    XTime t2, t3;
    uint32_t *k0 = alloc_u32(n);
    for (uint32_t i = 0; i < n; i++) k0[i] = rnd();
    uint32_t *rk[2] = { s2_dup(k0, n), alloc_u32(n) }, *rv[2] = { alloc_u32(n), alloc_u32(n) };
    for (uint32_t i = 0; i < n; i++) rv[0][i] = i;
    XTime_GetTime(&t2);
    s2_sort(rk[0], rv[0], rk[1], rv[1], n);
    XTime_GetTime(&t3);
    uint32_t *k[2] = { alloc_u32(n), alloc_u32(n) }, *v[2] = { alloc_u32(n), alloc_u32(n) };
#ifdef S2_ARA
    uint32_t *scr = alloc_u32(33u * W);
    for (uint32_t m = 0; m < 2; m++) {
        s2_copy(k[0], k0, n);
        for (uint32_t i = 0; i < n; i++) v[0][i] = i;
        uint32_t a[] = { addr(k[0]), addr(v[0]), addr(k[1]), addr(v[1]), n, addr(scr), W };
        unsigned e = ara_run(AK_SORT, m, a, 7);
        e += diff(k[0], rk[0], n) + diff(v[0], rv[0], n);
        report("sort", n, m, us(t2, t3), e); errs_ += e;
    }
#else
    s2_copy(k[0], k0, n);
    for (uint32_t i = 0; i < n; i++) v[0][i] = i;
    uint32_t *hist = alloc_u32(16u * W), *off = alloc_u32(16u * W), *tot = alloc_u32(16);
    const uint32_t C = n / W;
    uint32_t *ph[8], *ps_[8], *pz[8];
    for (uint32_t p = 0; p < 8; p++) {
        const int sr = (int)(p & 1);
        ph[p] = params(5); ps_[p] = params(4); pz[p] = params(9);
        ph[p][0] = addr(k[sr]); ph[p][1] = addr(hist); ph[p][2] = C; ph[p][3] = 4 * p; ph[p][4] = W;
        ps_[p][0] = addr(hist); ps_[p][1] = addr(off); ps_[p][2] = addr(tot); ps_[p][3] = W;
        pz[p][0] = addr(k[sr]); pz[p][1] = addr(v[sr]); pz[p][2] = addr(k[sr ^ 1]); pz[p][3] = addr(v[sr ^ 1]);
        pz[p][4] = addr(off); pz[p][5] = addr(tot); pz[p][6] = C; pz[p][7] = 4 * p; pz[p][8] = W;
    }
    S2_ACC_BEGIN();
    for (uint32_t p = 0; p < 8; p++) {
        launch(PC_S2_RS_HIST, ph[p], W, 0);
        launch(PC_S2_RS_SCAN, ps_[p], 16, 0);
        launch(PC_S2_RS_SCATTER, pz[p], W, 0);
    }
    S2_ACC_END();
    errs_ = diff(k[0], rk[0], n) + diff(v[0], rv[0], n);
    report("sort", n, us(t0, t1), us(t2, t3), errs_);
#endif
    return errs_;
}

/* ── RiVEC / PARSEC Black-Scholes ───────────────────────────────────────────── */
static unsigned app_s2_blackscholes(uint32_t n)
{
    unsigned errs_ = 0;
    XTime t2, t3;
    float *in[5];
    for (int j = 0; j < 5; j++) in[j] = alloc(4u * n);
    for (uint32_t i = 0; i < n; i++) {
        in[0][i] = s2_range(10.0f, 100.0f);
        in[1][i] = in[0][i] * s2_range(0.8f, 1.2f);
        in[2][i] = s2_range(0.01f, 0.1f);
        in[3][i] = s2_range(0.1f, 0.6f);
        in[4][i] = s2_range(0.25f, 1.0f);
    }
    float *C = (float *)s2_dup(S2_BS_C, 26);
    float *rc = alloc(4u * n), *rpt = alloc(4u * n), *oc = alloc(4u * n), *op = alloc(4u * n);
    XTime_GetTime(&t2);
    s2_blackscholes(in[0], in[1], in[2], in[3], in[4], rc, rpt, C, n);
    XTime_GetTime(&t3);
#ifdef S2_ARA
    for (uint32_t m = 0; m < 2; m++) {
        uint32_t a[] = { addr(in[0]), addr(in[1]), addr(in[2]), addr(in[3]), addr(in[4]), addr(oc), addr(op),
                         addr(C), n };
        unsigned e = ara_run(AK_BLACKSCHOLES, m, a, 9);
        e += diff((uint32_t *)oc, (uint32_t *)rc, n) + diff((uint32_t *)op, (uint32_t *)rpt, n);
        report("blackscholes", n, m, us(t2, t3), e); errs_ += e;
    }
#else
    uint32_t *p = params(8);
    for (int j = 0; j < 5; j++) p[j] = addr(in[j]);
    p[5] = addr(oc); p[6] = addr(op); p[7] = addr(C);
    S2_ACC_BEGIN();
    launch(PC_S2_BLACKSCHOLES, p, n, 0);
    S2_ACC_END();
    errs_ = diff((uint32_t *)oc, (uint32_t *)rc, n) + diff((uint32_t *)op, (uint32_t *)rpt, n);
    report("blackscholes", n, us(t0, t1), us(t2, t3), errs_);
#endif
    return errs_;
}

/* ── The suite: two sizes per application (sim/gen_suite2.py 'board' and 'dram') ── */
static unsigned run_suite2(void)
{
    unsigned errs = 0;
    rng = 3001u;                                      /* the same inputs on every system */
#ifndef S2_ARA
    s2_load_all();
#endif
#ifndef S2_RUN
#define S2_RUN(call) do { arena_reset(); errs += (call); } while (0)
#endif
    S2_RUN(app_s2_pathfinder(100, 65536));    S2_RUN(app_s2_pathfinder(100, 1u << 18));
    S2_RUN(app_s2_grid(1, 512, 4));           S2_RUN(app_s2_grid(1, 1024, 4));
    S2_RUN(app_s2_grid(0, 512, 4));           S2_RUN(app_s2_grid(0, 2048, 4));
    S2_RUN(app_s2_mv(0, 1024));               S2_RUN(app_s2_mv(0, 4096));
    S2_RUN(app_s2_mv(1, 1024));               S2_RUN(app_s2_mv(1, 4096));
    S2_RUN(app_s2_pagerank(16384, 8, 10));    S2_RUN(app_s2_pagerank(1u << 18, 8, 10));
    S2_RUN(app_s2_cc(16384, 8));              S2_RUN(app_s2_cc(1u << 18, 8));
    S2_RUN(app_s2_backprop(65536));           S2_RUN(app_s2_backprop(1u << 19));
    S2_RUN(app_s2_sort(65536, 256));          S2_RUN(app_s2_sort(1u << 20, 1024));
    S2_RUN(app_s2_blackscholes(65536));       S2_RUN(app_s2_blackscholes(1u << 20));
    return errs;
}
