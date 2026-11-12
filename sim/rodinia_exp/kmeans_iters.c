/* Rodinia kmeans iteration count on kdd_cup, k = 5 (docs/rodinia_plan.md, kmeans):
   gcc -O2 -o k kmeans_iters.c -lm && ./k <rodinia-data>/kmeans/kdd_cup */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <float.h>
#include <time.h>
int main(int argc, char **argv) {
    FILE *f = fopen(argv[1], "r"); int K = 5, F = 34, N = 0, cap = 600000;
    float *feat = malloc(sizeof(float) * (size_t)cap * F); char line[2048];
    while (fgets(line, sizeof line, f)) { char *tok = strtok(line, " \t\n"); if (!tok) continue;
        for (int j = 0; j < F; j++) feat[(size_t)N * F + j] = (float)atof(strtok(NULL, " ,\t\n")); N++; }
    float c[5 * 34], nc[5 * 34]; int len[5], *mem = malloc(4 * N);
    for (int i = 0; i < K; i++) for (int j = 0; j < F; j++) c[i * F + j] = feat[(size_t)i * F + j];
    for (int i = 0; i < N; i++) mem[i] = -1;
    int loop = 0, it = 0; float delta; clock_t t0 = clock();
    do { delta = 0; memset(nc, 0, sizeof nc); memset(len, 0, sizeof len);
        for (int p = 0; p < N; p++) { float best = FLT_MAX; int idx = 0;
            for (int i = 0; i < K; i++) { float ans = 0.0f;
                for (int j = 0; j < F; j++) { float d = feat[(size_t)p * F + j] - c[i * F + j]; ans = fmaf(d, d, ans); }
                if (ans < best) { best = ans; idx = i; } }
            if (idx != mem[p]) { delta++; mem[p] = idx; } len[idx]++;
            for (int j = 0; j < F; j++) nc[idx * F + j] += feat[(size_t)p * F + j]; }
        for (int i = 0; i < K; i++) for (int j = 0; j < F; j++) if (len[i] > 0) c[i * F + j] = nc[i * F + j] / len[i];
        it++; printf("iter %d delta %.0f\n", it, delta);
    } while (delta > 0.001f && loop++ < 500);
    printf("N %d iterations %d, %.1f s\n", N, it, (double)(clock() - t0) / CLOCKS_PER_SEC);
    return 0;
}
