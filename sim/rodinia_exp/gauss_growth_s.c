/* Rodinia gaussian error growth on the -s n matrix (create_matrix) (docs/rodinia_plan.md):
   gcc -O2 -o g gauss_growth_s.c -lm && ./g 1024 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
static unsigned rng = 1;
static float bump(float q) { rng = rng * 1103515245u + 12345u; if ((rng >> 16) % 1000 < 87) { unsigned x; memcpy(&x, &q, 4); x += ((rng >> 8) & 1) ? 1 : -1; memcpy(&q, &x, 4); } return q; }
static void elim(float *a, float *b, float *m, int n, int pert) {
    for (int t = 0; t < n - 1; t++) {
        for (int i = t + 1; i < n; i++) { float q = a[i*n+t] / a[t*n+t]; m[i*n+t] = pert ? bump(q) : q; }
        for (int i = t + 1; i < n; i++) {
            float mi = m[i*n+t];
            for (int j = t; j < n; j++) a[i*n+j] = fmaf(-mi, a[t*n+j], a[i*n+j]);
            b[i] = fmaf(-mi, b[t], b[i]);
        }
    }
}
int main(int argc, char **argv) {
    int n = atoi(argv[1]);
    float *a0 = malloc(4*n*n), *b0 = malloc(4*n), *coe = malloc(4*(2*n-1)), lamda = -0.01f;
    for (int i = 0; i < n; i++) { float c = 10*exp(lamda*i); coe[n-1+i] = c; coe[n-1-i] = c; }   /* create_matrix */
    for (int i = 0; i < n; i++) for (int j = 0; j < n; j++) a0[i*n+j] = coe[n-1-i+j];
    for (int i = 0; i < n; i++) b0[i] = 1.0f;
    float *a[2], *b[2], *m[2];
    for (int k = 0; k < 2; k++) { a[k] = malloc(4*n*n); b[k] = malloc(4*n); m[k] = calloc(n*n, 4);
        memcpy(a[k], a0, 4*n*n); memcpy(b[k], b0, 4*n); elim(a[k], b[k], m[k], n, k); }
    double mx = 0, maxabs = 0, worst = 0; int nonfin = 0;
    for (int i = 0; i < n*n; i++) { if (!isfinite(a[0][i])) nonfin++; if (fabs(a[0][i]) > maxabs) maxabs = fabs(a[0][i]); }
    /* relative difference of the upper triangle, scaled by the row's largest element */
    for (int i = 0; i < n; i++) { double rmax = 0; for (int j = i; j < n; j++) if (fabs(a[0][i*n+j]) > rmax) rmax = fabs(a[0][i*n+j]);
        for (int j = i; j < n; j++) { double d = fabs(a[0][i*n+j] - a[1][i*n+j]) / (rmax ? rmax : 1); if (d > worst) worst = d; } }
    /* back substitution: solution difference */
    double *x[2];
    for (int k = 0; k < 2; k++) { x[k] = malloc(8*n); for (int i = n-1; i >= 0; i--) { double s = b[k][i]; for (int j = i+1; j < n; j++) s -= a[k][i*n+j]*x[k][j]; x[k][i] = s / a[k][i*n+i]; } }
    for (int i = 0; i < n; i++) { double d = fabs(x[0][i]-x[1][i]) / (fabs(x[0][i]) > 1e-30 ? fabs(x[0][i]) : 1); if (d > mx) mx = d; }
    printf("n %d: nonfinite %d, max|a| %.3g, worst row-relative diff of U %.3g, worst relative diff of x %.3g\n", n, nonfin, maxabs, worst, mx);
    return 0;
}
