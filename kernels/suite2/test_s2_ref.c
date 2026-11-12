/*
 * test_s2_ref.c - check s2_ref.h against sim/gen_suite2.py's exact gold (native, WSL):
 *   gcc -O2 -ffp-contract=off -o test_s2_ref test_s2_ref.c && ./test_s2_ref <apps.manifest>
 * Each case's DDR image is loaded at its addresses, the parameter blocks of its launches
 * give the arguments of the s2_ function, and every gold word is compared.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "s2_ref.h"

#define DDR_BASE 0x10000000u
#define WORDS (1u << 22)
static uint32_t *mem;
static void *P(uint32_t a) { return mem + ((a - DDR_BASE) >> 2); }
static uint32_t W(uint32_t a) { return mem[(a - DDR_BASE) >> 2]; }

struct launch { char tag[32]; uint32_t prm, thr; };

static int run_case(const char *name, const char *memf, const char *goldf, struct launch *L, int nl)
{
    memset(mem, 0, 4u * WORDS);
    FILE *f = fopen(memf, "r");
    char tok[64]; uint32_t i = 0;
    while (fscanf(f, "%63s", tok) == 1) {
        if (tok[0] == '@') { i = (uint32_t)strtoul(tok + 1, 0, 16); continue; }
        mem[i++] = (uint32_t)strtoul(tok, 0, 16);
    }
    fclose(f);
    const uint32_t *p = P(L[0].prm);
    if (!strncmp(name, "pathfinder", 10))
        s2_pathfinder(P(W(L[0].prm + 8) - 4 * p[3]), P(p[0]), P(p[1]), (uint32_t)nl + 1, p[3]);
    else if (!strncmp(name, "hotspot", 7)) {
        float k[5]; for (int j = 0; j < 5; j++) k[j] = s2_f(p[5 + j]);
        s2_hotspot(P(p[0]), P(p[1]), P(p[2]), 1u << p[3], p[4], k, (uint32_t)nl);
    } else if (!strncmp(name, "jacobi2d", 8))
        s2_jacobi2d(P(p[0]), P(p[1]), 1u << p[2], p[3], s2_f(p[4]), (uint32_t)nl / 2);
    else if (!strncmp(name, "atax", 4)) {
        s2_mv_row(P(p[0]), P(p[1]), P(p[2]), p[3]);
        const uint32_t *q = P(L[1].prm); s2_mv_col(P(q[0]), P(q[1]), P(q[2]), q[3]);
    } else if (!strncmp(name, "bicg", 4)) {
        s2_mv_row(P(p[0]), P(p[1]), P(p[2]), p[3]);
        const uint32_t *q = P(L[1].prm); s2_mv_col(P(q[0]), P(q[1]), P(q[2]), q[3]);
    } else if (!strncmp(name, "pagerank", 8)) {
        const uint32_t *q = P(L[1].prm);            /* pull: rowptr col c pr' d base */
        s2_pagerank(P(q[0]), P(q[1]), P(p[1]), P(p[2]), P(p[0]), P(q[3]), L[0].thr,
                    s2_f(q[4]), s2_f(q[5]), (uint32_t)nl / 2);
    } else if (!strncmp(name, "cc", 2)) {
        uint32_t r = s2_cc(P(p[0]), P(p[1]), P(p[2]), P(p[3]), L[0].thr);
        for (int k = 0; k < nl; k++) *(uint32_t *)P(((const uint32_t *)P(L[k].prm))[4]) = (k + 1 < (int)r);
        if ((int)r != nl) printf("  cc: %u rounds, gold %d\n", r, nl);
    } else if (!strncmp(name, "backprop", 8)) {
        s2_bp_forward(P(p[0]), P(p[1]), P(p[2]), L[0].thr);
        const uint32_t *q = P(L[1].prm);
        s2_bp_adjust(P(q[0]), P(q[1]), P(q[2]), P(q[3]), L[0].thr, s2_f(q[4]));
    } else if (!strncmp(name, "sort", 4)) {
        const uint32_t *q = P(L[2].prm);            /* scatter: ksrc vsrc kdst vdst ... */
        uint32_t n = q[6] * q[8];
        s2_sort(P(q[0]), P(q[1]), P(q[2]), P(q[3]), n);
    } else if (!strncmp(name, "blackscholes", 12))
        s2_blackscholes(P(p[0]), P(p[1]), P(p[2]), P(p[3]), P(p[4]), P(p[5]), P(p[6]), P(p[7]), L[0].thr);
    else { printf("  %s: no reference\n", name); return 1; }

    int errs = 0, chk = 0;
    f = fopen(goldf, "r");
    uint32_t gi, gv;
    while (fscanf(f, "%x %x", &gi, &gv) == 2) {
        chk++;
        if (mem[gi] != gv) { if (errs < 4) printf("  [%x] %08x want %08x\n", gi, mem[gi], gv); errs++; }
    }
    fclose(f);
    printf("%-22s %s (%d words, %d wrong)\n", name, errs ? "FAIL" : "ok", chk, errs);
    return errs;
}

int main(int argc, char **argv)
{
    mem = malloc(4u * WORDS);
    FILE *m = fopen(argv[1], "r");
    char line[512], name[64] = "", memf[256] = "", goldf[256] = "";
    static struct launch L[4096];
    int nl = 0, errs = 0;
    while (fgets(line, sizeof line, m)) {
        char kw[16]; sscanf(line, "%15s", kw);
        if (!strcmp(kw, "CASE")) { sscanf(line, "%*s %63s", name); nl = 0; }
        else if (!strcmp(kw, "MEM")) sscanf(line, "%*s %255s", memf);
        else if (!strcmp(kw, "GOLD")) sscanf(line, "%*s %255s", goldf);
        else if (!strcmp(kw, "LAUNCH")) { unsigned s, b; sscanf(line, "%*s %31s %u %x %u %u", L[nl].tag, &s, &L[nl].prm, &L[nl].thr, &b); nl++; }
        else if (!strcmp(kw, "END")) errs += run_case(name, memf, goldf, L, nl);
    }
    printf(errs ? "TEST_S2_REF: FAIL\n" : "TEST_S2_REF: PASS\n");
    return errs != 0;
}
