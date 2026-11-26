/*
 * bs_sens.c - how far RiVEC's Black-Scholes (rv_ref.h rv_blackscholes) moves when its
 * divisions and square roots are not correctly rounded, as on CVA6 and Ara: each quotient
 * is one ulp off with probability 8.7% and each square root with probability 6.9% (the
 * rates measured on 4,096 random operands, docs/rodinia_plan.md). Over TRIALS random draws
 * on RiVEC's 65,536 options (the board blob), prints the largest |p - p_exact| / (|p| + 0.01),
 * the measure of sw/ps_host/rivec.inc. Native (WSL):
 *   gcc -O2 -mfma -ffp-contract=off bs_sens.c -lm -o bs_sens && ./bs_sens rv_data.bin
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "../rv_ref.h"

static uint64_t s = 88172645463325252ull;
static double urand(void) { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return (s >> 11) * (1.0 / 9007199254740992.0); }
static float ulp_off(float x, double p)
{
    if (urand() >= p) return x;
    uint32_t u; memcpy(&u, &x, 4); u += (urand() < 0.5) ? 1u : (uint32_t)-1; memcpy(&x, &u, 4); return x;
}
#define DIV(a, b) ulp_off((a) / (b), 0.087)
#define SQRT(x) ulp_off(rv_sqrtf(x), 0.069)

/* rv_ref.h's rv_cndf and rv_blackscholes with DIV and SQRT (the same operations otherwise) */
static float cndf_p(float x)
{
    const float inv_sqrt_2xPI = 0.39894228040143270286;
    const int neg = x < 0.0f;
    float xa = x < 0.0f ? -x : x;
    float ev = xa * xa; ev = ev * -0.5f;
    float np = rv_exp(ev) * inv_sqrt_2xPI;
    float k2 = DIV(1.0f, rv_fma(0.2316419f, xa, 1.0f));
    float k2_2 = k2 * k2, k2_3 = k2_2 * k2, k2_4 = k2_3 * k2, k2_5 = k2_4 * k2;
    float l1 = k2 * 0.319381530f, l2 = k2_2 * -0.356563782f;
    l2 = rv_fma(k2_3, 1.781477937f, l2); l2 = rv_fma(k2_4, -1.821255978f, l2); l2 = rv_fma(k2_5, 1.330274429f, l2);
    float loc = 1.0f - (l2 + l1) * np;
    return neg ? 1.0f - loc : loc;
}
static float bs_p(float S, float K, float r, float v, float T, int put)
{
    float lt = rv_log(DIV(S, K)), sq = SQRT(T);
    float fv = rv_exp(-(r * T));
    float pw = (v * v) * 0.5f;
    float d1 = rv_fma(r + pw, T, lt);
    float den = v * sq;
    d1 = DIV(d1, den);
    float d2 = d1 - den;
    float n1 = cndf_p(d1), n2 = cndf_p(d2);
    fv = fv * K;
    if (put) { n1 = 1.0f - n1; n2 = 1.0f - n2; }
    float p = fv * n2 - S * n1;
    return p < 0.0f ? -p : p;
}

static uint8_t *blob;
static uint32_t *get(const char *name, uint32_t *nw)
{
    uint32_t *h = (uint32_t *)blob, e = h[1];
    for (uint32_t i = 0; i < e; i++) {
        const uint32_t *en = h + 2 + 8 * i;
        if (!strncmp((const char *)en, name, 24)) { *nw = en[7]; return (uint32_t *)(blob + en[6]); }
    }
    exit(2);
}

int main(int argc, char **argv)
{
    FILE *f = fopen(argv[1], "rb");
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    blob = malloc(sz); if (fread(blob, 1, sz, f) != (size_t)sz) return 2;
    uint32_t n;
    float *S = (float *)get("rv_bs_S", &n), *K = (float *)get("rv_bs_K", &n), *R = (float *)get("rv_bs_r", &n),
          *V = (float *)get("rv_bs_v", &n), *T = (float *)get("rv_bs_T", &n);
    int32_t *ot = (int32_t *)get("rv_bs_type", &n);
    float *ref = malloc(4 * n);
    rv_blackscholes(n, S, K, R, V, T, ot, ref);
    const int TRIALS = 200;
    double worst = 0; long above1e4 = 0;
    for (int t = 0; t < TRIALS; t++)
        for (uint32_t i = 0; i < n; i++) {
            float p = bs_p(S[i], K[i], R[i], V[i], T[i], ot[i]);
            double q = fabs((double)p - ref[i]) / (fabs((double)ref[i]) + 0.01);
            if (q > worst) worst = q;
            above1e4 += q > 1e-4;
        }
    printf("blackscholes, %u options x %d trials: largest |p - p_exact| / (|p| + 0.01) = %.3g; "
           "beyond 1e-4: %.1f options per run on average\n", n, TRIALS, worst, (double)above1e4 / TRIALS);
    return 0;
}
