/*
 * rv_qtest.c - checks kernels/rivec/rv_ref.h against RiVEC's own vector code, run under
 * qemu-riscv64 (RVV 1.0) by run_qtest.sh:
 *   1. rv_exp / rv_log against RiVEC's __exp_2xf32 / __log_2xf32 (common/__exp.h,
 *      __log.h), bit for bit, on 2^22 arguments each;
 *   2. rv_blackscholes against RiVEC's BlkSchlsEqEuroNoDiv_vector (verbatim from
 *      _blackscholes/src/blackscholes.cpp) on in_64K.input: as written (with its
 *      mask-agnostic masked subtract) and with that subtract made a vmerge (the Ara
 *      version). QEMU's divide and square root are correctly rounded, as the A53's.
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <riscv_vector.h>
#define USE_RISCV_VECTOR
#include "vector_defines.h"          /* includes RiVEC's __exp.h, __log.h, __cos.h */
#include "../rv_ref.h"

typedef float fptype;
#include "rivec_bs_vector.inc"
#include "rivec_bs_vector_merge.inc"
#include "bs_input.h"

static uint32_t fb(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static float bf(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }
static uint32_t lcg = 12345u;
static uint32_t rnd(void) { lcg = lcg * 1664525u + 1013904223u; return lcg; }

#define CH 256
static float in[CH], out[CH];

static unsigned check_fn(int which)
{
    unsigned bad = 0, shown = 0;
    for (uint32_t blk = 0; blk < (1u << 22) / CH; blk++) {
        for (int i = 0; i < CH; i++) {
            float x;
            if (which == 0) {               /* exp: [-100, 100], and small arguments */
                x = (blk & 1) ? ((float)(int32_t)rnd() / 2147483648.0f) * 100.0f
                              : ((float)(int32_t)rnd() / 2147483648.0f) * 2.0f;
            } else {                        /* log: positive normal bit patterns */
                x = bf((rnd() % 0x7f000000u) + 0x00800000u);
            }
            in[i] = x;
        }
        for (size_t i = 0; i < CH; ) {
            size_t gvl = __riscv_vsetvl_e32m1(CH - i);
            vfloat32m1_t v = __riscv_vle32_v_f32m1(&in[i], gvl);
            v = which == 0 ? __exp_2xf32(v, gvl) : __log_2xf32(v, gvl);
            __riscv_vse32_v_f32m1(&out[i], v, gvl);
            i += gvl;
        }
        for (int i = 0; i < CH; i++) {
            float r = which == 0 ? rv_exp(in[i]) : rv_log(in[i]);
            if (fb(r) != fb(out[i])) {
                if (shown++ < 8) printf("%s(%08x): rivec %08x ref %08x\n", which ? "log" : "exp",
                                        fb(in[i]), fb(out[i]), fb(r));
                bad++;
            }
        }
    }
    printf("%s: %u of %u differ\n", which ? "log" : "exp", bad, 1u << 22);
    return bad;
}

static float S[BS_N], K[BS_N], R[BS_N], V[BS_N], T[BS_N], P0[BS_N], P1[BS_N], P2[BS_N];
static int OT[BS_N];

static unsigned check_bs(void)
{
    for (int i = 0; i < BS_N; i++) {
        S[i] = bf(bs_S[i]); K[i] = bf(bs_K[i]); R[i] = bf(bs_r[i]); V[i] = bf(bs_v[i]);
        T[i] = bf(bs_T[i]); OT[i] = bs_type[i];
    }
    rv_blackscholes(BS_N, S, K, R, V, T, OT, P0);
    for (int i = 0; i < BS_N; ) {
        unsigned long gvl = __riscv_vsetvl_e32m1(BS_N - i);
        BlkSchlsEqEuroNoDiv_vector(&P1[i], gvl, &S[i], &K[i], &R[i], &V[i], &T[i], &OT[i], 0, gvl);
        BlkSchlsEqEuroNoDiv_vector_M(&P2[i], gvl, &S[i], &K[i], &R[i], &V[i], &T[i], &OT[i], 0, gvl);
        i += gvl;
    }
    unsigned b1 = 0, b2 = 0, shown = 0;
    for (int i = 0; i < BS_N; i++) {
        b1 += fb(P1[i]) != fb(P0[i]);
        if (fb(P2[i]) != fb(P0[i])) {
            if (shown++ < 8) printf("bs[%d]: rivec-vmerge %08x ref %08x\n", i, fb(P2[i]), fb(P0[i]));
            b2++;
        }
    }
    printf("blackscholes: RiVEC as written %u of %d differ; with vmerge %u differ\n", b1, BS_N, b2);
    return b2;
}

int main(void)
{
    unsigned e = check_fn(0) + check_fn(1) + check_bs();
    printf("RV_QTEST %s\n", e ? "FAIL" : "PASS");
    return e != 0;
}
