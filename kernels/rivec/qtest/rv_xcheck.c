/*
 * rv_xcheck.c - runs kernels/rivec/rv_ref.h on the inputs that sim/rv_xcheck.py writes and
 * writes its outputs back, so that the Python model of sim/gen_rivec.py (which the SIMTiX
 * and Vortex kernels are checked against) and rv_ref.h (which the A53 and CVA6 run) can be
 * compared bit for bit. Native (WSL gcc -O2 -mfma -ffp-contract=off).
 *   input : words  [exp: n, x..] [log: n, x..] [bs: n, S.. K.. r.. v.. T.. type..]
 *                  [jacobi: n, steps] [lava: b1d, nhome, rv.. qv..]
 *   output: words  exp.. log.. price.. A.. B.. fv(nhome*96*4)..
 */
#include <stdio.h>
#include <stdlib.h>
#include "../rv_ref.h"

static uint32_t *in;
static size_t ip;
static uint32_t rd(void) { return in[ip++]; }
static float *fp(size_t n) { float *p = (float *)&in[ip]; ip += n; return p; }

int main(int argc, char **argv)
{
    FILE *f = fopen(argv[1], "rb"), *o = fopen(argv[2], "wb");
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    in = malloc(sz); if (fread(in, 1, sz, f) != (size_t)sz) return 2;
    uint32_t n = rd(); float *x = fp(n);
    for (uint32_t i = 0; i < n; i++) { float y = rv_exp(x[i]); fwrite(&y, 4, 1, o); }
    n = rd(); x = fp(n);
    for (uint32_t i = 0; i < n; i++) { float y = rv_log(x[i]); fwrite(&y, 4, 1, o); }
    n = rd();
    float *S = fp(n), *K = fp(n), *r = fp(n), *v = fp(n), *T = fp(n);
    int32_t *ot = (int32_t *)fp(n);
    float *p = malloc(4 * n);
    rv_blackscholes(n, S, K, r, v, T, ot, p);
    fwrite(p, 4, n, o);
    uint32_t jn = rd(), js = rd();
    float *A = malloc(4 * jn * jn), *B = malloc(4 * jn * jn);
    rv_jacobi_init(A, B, jn);
    rv_jacobi2d(A, B, jn, js);
    fwrite(A, 4, jn * jn, o); fwrite(B, 4, jn * jn, o);
    uint32_t b1d = rd(), nh = rd(), nb = b1d * b1d * b1d;
    uint32_t *nn = malloc(4 * nb), *nei = malloc(4 * (26 * nb + 1));
    rv_lava_boxes(b1d, nn, nei);
    float *rv = fp(4 * nb * RV_LAVA_NP), *qv = fp(nb * RV_LAVA_NP), *fv = calloc(4 * nb * RV_LAVA_NP, 4);
    rv_lavamd(nh, nn, nei, rv, qv, fv, 0.5f);
    fwrite(fv, 4, 4 * nh * RV_LAVA_NP, o);
    fclose(o);
    return 0;
}
