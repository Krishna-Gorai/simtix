/* ak_st_s2.inc - self-tests of suite 2 (included by ak_main.c under AK_SELFTEST): small
 * inputs in the layouts of sim/gen_suite2.py; the scalar (CVA6) and vector (Ara) runs
 * work on separate copies and every output word is compared. */

static uint32_t *dup32(const void *src, uint32_t nw)
{
    uint32_t *d = alloc_u32(nw);
    for (uint32_t i = 0; i < nw; i++) d[i] = ((const uint32_t *)src)[i];
    return d;
}

static void t_pathfinder(uint32_t rows, uint32_t cols)
{
    int32_t *wall = (int32_t *)alloc_u32(rows * cols);
    for (uint32_t i = 0; i < rows * cols; i++) wall[i] = (int32_t)(rnd() % 10u);
    int32_t *b[2][2];
    for (int m = 0; m < 2; m++)
        for (int k = 0; k < 2; k++) {
            b[m][k] = (int32_t *)alloc_u32(cols + 2);
            b[m][k][0] = b[m][k][cols + 1] = S2_INF;
            for (uint32_t c = 0; c < cols; c++) b[m][k][c + 1] = k ? 0 : wall[c];
        }
    uint64_t cy[2];
    for (int m = 0; m < 2; m++) {
        uint32_t a[] = { H(wall), H(b[m][0]), H(b[m][1]), rows, cols };
        cy[m] = run(AK_PATHFINDER, m, a);
    }
    report("pathfinder", cols, cy[0], cy[1], diffw(b[0][(rows - 1) & 1], b[1][(rows - 1) & 1], cols + 2));
}

static void t_grid(int hot, uint32_t n, uint32_t steps)
{
    uint32_t s = n + 16, words = (n + 2) * s;
    float *t0 = alloc(4 * words), *pw = alloc(4 * words);
    for (uint32_t i = 0; i < words; i++) {
        t0[i] = hot ? 320.0f + 20.0f * rnd_f32() : rnd_f32();
        pw[i] = 0.001f * rnd_f32();
    }
    float *g[2][2];
    for (int m = 0; m < 2; m++) { g[m][0] = (float *)dup32(t0, words); g[m][1] = (float *)dup32(t0, words); }
    float k[5];
    s2_hotspot_consts(n, k);
    uint64_t cy[2];
    for (int m = 0; m < 2; m++) {
        if (hot) {
            uint32_t a[] = { H(g[m][0]), H(g[m][1]), H(pw), n, s, f2u(k[0]), f2u(k[1]), f2u(k[2]),
                             f2u(k[3]), f2u(k[4]), steps };
            cy[m] = run(AK_HOTSPOT, m, a);
        } else {
            uint32_t a[] = { H(g[m][0]), H(g[m][1]), n, s, f2u(0.2f), steps };
            cy[m] = run(AK_JACOBI2D, m, a);
        }
    }
    int r = hot ? (int)(steps & 1) : 0;
    report(hot ? "hotspot" : "jacobi2d", n, cy[0], cy[1], diffw(g[0][r], g[1][r], words));
}

static void t_mv(int bicg, uint32_t n)
{
    float *A = alloc(4 * n * n), *x = alloc(4 * n), *x2 = alloc(4 * n);
    for (uint32_t i = 0; i < n * n; i++) A[i] = rnd_f32();
    for (uint32_t i = 0; i < n; i++) { x[i] = rnd_f32(); x2[i] = rnd_f32(); }
    float *o[2][2];
    uint64_t cy[2];
    for (int m = 0; m < 2; m++) {
        o[m][0] = alloc(4 * n); o[m][1] = alloc(4 * n);
        if (bicg) {
            uint32_t a[] = { H(A), H(x), H(x2), H(o[m][0]), H(o[m][1]), n };
            cy[m] = run(AK_BICG, m, a);
        } else {
            uint32_t a[] = { H(A), H(x), H(o[m][0]), H(o[m][1]), n };
            cy[m] = run(AK_ATAX, m, a);
        }
    }
    report(bicg ? "bicg" : "atax", n, cy[0], cy[1], diffw(o[0][0], o[1][0], n) + diffw(o[0][1], o[1][1], n));
}

static void t_graph(int pr, uint32_t nv, uint32_t deg)
{
    uint32_t *rowptr = alloc_u32(nv + 1), *col = alloc_u32(nv * deg);
    uint32_t e = 0;
    for (uint32_t v = 0; v < nv; v++) {
        rowptr[v] = e;
        uint32_t d = 1 + rnd() % deg;
        for (uint32_t j = 0; j < d; j++) col[e++] = (j == 0 && v) ? v - 1 : rnd() % nv;
    }
    rowptr[nv] = e;
    uint64_t cy[2];
    if (pr) {
        float *inv = alloc(4 * nv), *p0 = alloc(4 * nv);
        for (uint32_t v = 0; v < nv; v++) { inv[v] = 1.0f / (float)(rowptr[v + 1] - rowptr[v]); p0[v] = 1.0f / 512.0f; }
        float *q[2][2], *c[2];
        for (int m = 0; m < 2; m++) {
            q[m][0] = (float *)dup32(p0, nv); q[m][1] = alloc(4 * nv); c[m] = alloc(4 * nv);
            uint32_t a[] = { H(rowptr), H(col), H(inv), H(c[m]), H(q[m][0]), H(q[m][1]), nv,
                             f2u(0.85f), f2u(0.15f / 512.0f), 3 };
            cy[m] = run(AK_PAGERANK, m, a);
        }
        report("pagerank", nv, cy[0], cy[1], diffw(q[0][1], q[1][1], nv));
    } else {
        uint32_t *l[2][2], *rounds = alloc_u32(2);
        for (int m = 0; m < 2; m++) {
            l[m][0] = alloc_u32(nv); l[m][1] = alloc_u32(nv);
            for (uint32_t v = 0; v < nv; v++) l[m][0][v] = v;
            uint32_t a[] = { H(rowptr), H(col), H(l[m][0]), H(l[m][1]), nv, H(rounds + m) };
            cy[m] = run(AK_CC, m, a);
        }
        report("cc", nv, cy[0], cy[1], diffw(l[0][rounds[0] & 1], l[1][rounds[1] & 1], nv) + (rounds[0] != rounds[1]));
    }
}

static void t_backprop(uint32_t n)
{
    float *in = alloc(4 * n), *w0 = alloc(4 * 16 * n), *ow0 = alloc(4 * 16 * n), *ed = alloc(4 * 16);
    for (uint32_t i = 0; i < n; i++) in[i] = rnd_f32();
    for (uint32_t i = 0; i < 16 * n; i++) { w0[i] = 0.5f * rnd_f32(); ow0[i] = 0.05f * rnd_f32(); }
    for (uint32_t i = 0; i < 16; i++) ed[i] = 0.1f * rnd_f32();
    float *w[2], *ow[2], *ps[2];
    uint64_t cy[2];
    for (int m = 0; m < 2; m++) {
        w[m] = (float *)dup32(w0, 16 * n); ow[m] = (float *)dup32(ow0, 16 * n); ps[m] = alloc(4 * n);
        uint32_t a[] = { H(in), H(w[m]), H(ow[m]), H(ed), H(ps[m]), n, f2u(0.3f) };
        cy[m] = run(AK_BACKPROP, m, a);
    }
    report("backprop", n, cy[0], cy[1], diffw(ps[0], ps[1], n) + diffw(w[0], w[1], 16 * n) + diffw(ow[0], ow[1], 16 * n));
}

static void t_sort(uint32_t n, uint32_t W)
{
    uint32_t *k0 = alloc_u32(n);
    for (uint32_t i = 0; i < n; i++) k0[i] = rnd();
    uint32_t *k[2][2], *v[2][2], *scr = alloc_u32(33 * W);
    uint64_t cy[2];
    for (int m = 0; m < 2; m++) {
        k[m][0] = dup32(k0, n); k[m][1] = alloc_u32(n); v[m][0] = alloc_u32(n); v[m][1] = alloc_u32(n);
        for (uint32_t i = 0; i < n; i++) v[m][0][i] = i;
        uint32_t a[] = { H(k[m][0]), H(v[m][0]), H(k[m][1]), H(v[m][1]), n, H(scr), W };
        cy[m] = run(AK_SORT, m, a);
    }
    report("sort", n, cy[0], cy[1], diffw(k[0][0], k[1][0], n) + diffw(v[0][0], v[1][0], n));
}

static void t_blackscholes(uint32_t n)
{
    float *in[5];
    for (int j = 0; j < 5; j++) in[j] = alloc(4 * n);
    for (uint32_t i = 0; i < n; i++) {
        in[0][i] = 55.0f + 45.0f * rnd_f32();
        in[1][i] = in[0][i] * (1.0f + 0.2f * rnd_f32());
        in[2][i] = 0.055f + 0.045f * rnd_f32();
        in[3][i] = 0.35f + 0.25f * rnd_f32();
        in[4][i] = 0.625f + 0.375f * rnd_f32();
    }
    uint32_t *C = dup32(S2_BS_C, 26);
    float *o[2][2];
    uint64_t cy[2];
    for (int m = 0; m < 2; m++) {
        o[m][0] = alloc(4 * n); o[m][1] = alloc(4 * n);
        uint32_t a[] = { H(in[0]), H(in[1]), H(in[2]), H(in[3]), H(in[4]), H(o[m][0]), H(o[m][1]), H(C), n };
        cy[m] = run(AK_BLACKSCHOLES, m, a);
    }
    report("blackscholes", n, cy[0], cy[1], diffw(o[0][0], o[1][0], n) + diffw(o[0][1], o[1][1], n));
}
