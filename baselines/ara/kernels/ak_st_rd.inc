/*
 * ak_st_rd.inc - self-tests of the Rodinia kernels (docs/rodinia_plan.md) for the
 * Verilator wrapper model, included by ak_main.c: CVA6 (rd_ref.h) against Ara
 * (ak_vector_rd.inc), word for word.
 */

/* hotspot on an n x n grid (any n >= 2: Ara's vector strips and scalar edge columns) */
static void t_rd_hotspot(uint32_t n, uint32_t steps)
{
    const uint32_t words = n * n;
    float *t0 = alloc(4 * words), *pw = alloc(4 * words);
    for (uint32_t i = 0; i < words; i++) {
        t0[i] = 320.0f + 20.0f * rnd_f32();
        pw[i] = 0.001f * rnd_f32();
    }
    float *g[2][2];
    for (int m = 0; m < 2; m++) { g[m][0] = (float *)dup32(t0, words); g[m][1] = (float *)dup32(t0, words); }
    float k[5];
    rd_hotspot_consts(n, k);
    uint64_t cy[2];
    for (int m = 0; m < 2; m++) {
        uint32_t a[] = { H(g[m][0]), H(g[m][1]), H(pw), n, f2u(k[0]), f2u(k[1]), f2u(k[2]),
                         f2u(k[3]), f2u(k[4]), steps };
        cy[m] = run(AK_RD_HOTSPOT, m, a);
    }
    const int r = (int)(steps & 1);
    report("rd_hotspot", n, cy[0], cy[1], diffw(g[0][r], g[1][r], words));
}

/* nn on n random locations (Rodinia's value ranges: lat 0..90, lng 0..180) */
static void t_rd_nn(uint32_t n)
{
    float *loc = alloc(8 * n);
    for (uint32_t i = 0; i < n; i++) { loc[2 * i] = 90.0f * rnd_f32(); loc[2 * i + 1] = 180.0f * rnd_f32(); }
    float *d[2] = { alloc(4 * n), alloc(4 * n) };
    uint64_t cy[2];
    for (int m = 0; m < 2; m++) {
        uint32_t a[] = { H(loc), H(d[m]), n, f2u(30.0f), f2u(90.0f) };
        cy[m] = run(AK_RD_NN, m, a);
    }
    report("rd_nn", n, cy[0], cy[1], diffw(d[0], d[1], n));
}

/* hotspot3D on an n x n x nz grid */
static void t_rd_hotspot3d(uint32_t n, uint32_t nz, uint32_t iters)
{
    const uint32_t words = n * n * nz;
    float *t0 = alloc(4 * words), *pw = alloc(4 * words);
    for (uint32_t i = 0; i < words; i++) { t0[i] = 320.0f + 20.0f * rnd_f32(); pw[i] = rnd_f32(); }
    float *g[2][2];
    for (int m = 0; m < 2; m++) { g[m][0] = (float *)dup32(t0, words); g[m][1] = (float *)dup32(t0, words); }
    float k[6];
    rd_hotspot3d_consts(n, nz, k);
    uint64_t cy[2];
    for (int m = 0; m < 2; m++) {
        uint32_t a[] = { H(g[m][0]), H(g[m][1]), H(pw), n, nz, f2u(k[0]), f2u(k[1]), f2u(k[2]), f2u(k[3]),
                         f2u(k[4]), f2u(k[5]), iters };
        cy[m] = run(AK_RD_HOTSPOT3D, m, a);
    }
    const int r = (int)(iters & 1);
    report("rd_hotspot3d", n, cy[0], cy[1], diffw(g[0][r], g[1][r], words));
}

/* gaussian on Rodinia's -s n matrix shape (10*exp(-0.01|i-j|), b = 1) */
static void t_rd_gaussian(uint32_t n)
{
    const uint32_t s = n + 1;
    float *a0 = alloc(4 * n * s);
    for (uint32_t i = 0; i < n; i++) {
        for (uint32_t j = 0; j < n; j++) {
            uint32_t d = i > j ? i - j : j - i;
            float c = 10.0f;
            for (uint32_t k = 0; k < d; k++) c *= 0.99005f;      /* ~10*exp(-0.01 d) */
            a0[i * s + j] = c;
        }
        a0[i * s + n] = 1.0f;
    }
    float *A[2], *M[2];
    uint64_t cy[2];
    for (int m = 0; m < 2; m++) {
        A[m] = (float *)dup32(a0, n * s);
        M[m] = alloc(4 * n * n);
        for (uint32_t i = 0; i < n * n; i++) M[m][i] = 0.0f;
        uint32_t a[] = { H(A[m]), H(M[m]), n };
        cy[m] = run(AK_RD_GAUSSIAN, m, a);
    }
    report("rd_gaussian", n, cy[0], cy[1], diffw(A[0], A[1], n * s) + diffw(M[0], M[1], n * n));
}

/* kmeans assignment: n points, k centres (the first k points), nf features */
static void t_rd_kmeans(uint32_t n, uint32_t k, uint32_t nf)
{
    float *pm = alloc(4 * n * nf), *fm = alloc(4 * n * nf), *c = alloc(4 * k * nf);
    for (uint32_t p = 0; p < n; p++)
        for (uint32_t j = 0; j < nf; j++) {
            float v = (rnd() & 3u) ? rnd_f32() : (float)(rnd() % 1000u);       /* kdd_cup mixes counts and rates */
            pm[p * nf + j] = v; fm[j * n + p] = v;
        }
    for (uint32_t i = 0; i < k * nf; i++) c[i] = pm[i];
    int32_t *m[2] = { (int32_t *)alloc(4 * n), (int32_t *)alloc(4 * n) };
    uint64_t cy[2];
    for (int md = 0; md < 2; md++) {
        uint32_t a[] = { H(md ? fm : pm), H(c), H(m[md]), n, k, nf };
        cy[md] = run(AK_RD_KMEANS, md, a);
    }
    report("rd_kmeans", n, cy[0], cy[1], diffw(m[0], m[1], n));
}

#ifdef AK_RD_GAUSS_DBG
/* debug: the first mismatches of gaussian, CVA6 against Ara, with their positions */
static void t_rd_gaussian_dbg(uint32_t n)
{
    const uint32_t s = n + 1;
    float *a0 = alloc(4 * n * s);
    for (uint32_t i = 0; i < n; i++) {
        for (uint32_t j = 0; j < n; j++) {
            uint32_t d = i > j ? i - j : j - i;
            float c = 10.0f;
            for (uint32_t k = 0; k < d; k++) c *= 0.99005f;
            a0[i * s + j] = c;
        }
        a0[i * s + n] = 1.0f;
    }
    float *A[2], *M[2];
    for (int m = 0; m < 2; m++) {
        A[m] = (float *)dup32(a0, n * s);
        M[m] = alloc(4 * n * n);
        for (uint32_t i = 0; i < n * n; i++) M[m][i] = 0.0f;
        uint32_t a[] = { H(A[m]), H(M[m]), n };
        run(AK_RD_GAUSSIAN, m, a);
    }
    unsigned shown = 0, ea = 0, em = 0;
    for (uint32_t i = 0; i < n; i++)
        for (uint32_t j = 0; j < n; j++)
            if (*(uint32_t *)&M[0][i * n + j] != *(uint32_t *)&M[1][i * n + j]) {
                em++;
                if (shown++ < 12) printf("M[%u][%u] cva6 %08x ara %08x\n", i, j, *(uint32_t *)&M[0][i * n + j], *(uint32_t *)&M[1][i * n + j]);
            }
    for (uint32_t i = 0; i < n; i++)
        for (uint32_t j = 0; j < s; j++)
            if (*(uint32_t *)&A[0][i * s + j] != *(uint32_t *)&A[1][i * s + j]) {
                ea++;
                if (shown++ < 24) printf("A[%u][%u] cva6 %08x ara %08x\n", i, j, *(uint32_t *)&A[0][i * s + j], *(uint32_t *)&A[1][i * s + j]);
            }
    printf("gaussian dbg n %u: %u wrong in M, %u wrong in A\n", n, em, ea);
}
#endif
