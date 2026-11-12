/* dbg_mandel.c - trace v_mandel's iteration loop on Ara for one row (debug only).
 * Same parameters as the self-test t_mandel(20, 40); every iteration stores act (0/1),
 * k and the active count; no calls while vectors are live; checked after a fence. */
#include <riscv_vector.h>
#include <stdint.h>
#ifdef AK_QEMU
#include <stdio.h>
#else
#include "printf.h"
#endif

#define N 20u
#define M 40u
#define IT 48u
static uint32_t rec_act[IT][N], rec_k[IT][N], rec_cnt[IT], n_it;

static uint32_t count_b32(vbool32_t m, size_t vl)
{
    const vuint32m1_t one = __riscv_vmv_v_x_u32m1(1, vl), z = __riscv_vmv_v_x_u32m1(0, 1);
    return __riscv_vmv_x_s_u32m1_u32(__riscv_vredsum_vs_u32m1_u32m1_m(m, one, z, vl));
}

int main(void)
{
    const float x0 = -2.0f, y0 = -1.25f, d = 2.5f / (float)N;
    const uint32_t py = N / 2;
    const float ci = __builtin_fmaf((float)py, d, y0);
    size_t vl = __riscv_vsetvl_e32m1(N);
    vfloat32m1_t civ = __riscv_vfmv_v_f_f32m1(ci, vl);
    vfloat32m1_t pxf = __riscv_vfcvt_f_xu_v_f32m1(__riscv_vid_v_u32m1(vl), vl);
    vfloat32m1_t cr = __riscv_vfmadd_vf_f32m1(pxf, d, __riscv_vfmv_v_f_f32m1(x0, vl), vl);
    vfloat32m1_t zr = __riscv_vfmv_v_f_f32m1(0.0f, vl), zi = zr;
    vuint32m1_t k = __riscv_vmv_v_x_u32m1(0, vl), zero = k;
    vbool32_t act = __riscv_vmset_m_b32(vl);
    uint32_t it = 0, c;
    do {
        vfloat32m1_t zr2 = __riscv_vfmul_vv_f32m1(zr, zr, vl), zi2 = __riscv_vfmul_vv_f32m1(zi, zi, vl);
        vbool32_t esc = __riscv_vmfgt_vf_f32m1_b32(__riscv_vfadd_vv_f32m1(zr2, zi2, vl), 4.0f, vl);
        zi = __riscv_vfmadd_vf_f32m1(__riscv_vfmul_vv_f32m1(zr, zi, vl), 2.0f, civ, vl);
        zr = __riscv_vfadd_vv_f32m1(__riscv_vfsub_vv_f32m1(zr2, zi2, vl), cr, vl);
        k = __riscv_vadd_vx_u32m1_mu(act, k, k, 1, vl);
        act = __riscv_vmand_mm_b32(__riscv_vmandn_mm_b32(act, esc, vl),
                                   __riscv_vmsltu_vx_u32m1_b32(k, M, vl), vl);
        c = count_b32(act, vl);
        if (it < IT) {
            __riscv_vse32_v_u32m1(rec_act[it], __riscv_vmerge_vxm_u32m1(zero, 1, act, vl), vl);
            __riscv_vse32_v_u32m1(rec_k[it], k, vl);
            rec_cnt[it] = c;
        }
        it++;
    } while (c && it < 4 * M);
    n_it = it;
    __asm__ volatile("fence" ::: "memory");

    /* scalar model of the same loop */
    unsigned bad = 0;
    float szr[N], szi[N];
    uint32_t sk[N], sact[N];
    for (uint32_t i = 0; i < N; i++) { szr[i] = szi[i] = 0.0f; sk[i] = 0; sact[i] = 1; }
    for (uint32_t t = 0; t < n_it && t < IT; t++) {
        uint32_t sc = 0;
        for (uint32_t i = 0; i < N; i++) {
            const float cri = __builtin_fmaf((float)i, d, x0);
            const float zr2 = szr[i] * szr[i], zi2 = szi[i] * szi[i];
            const int esc = (zr2 + zi2) > 4.0f;
            szi[i] = __builtin_fmaf(szr[i] * szi[i], 2.0f, ci);
            szr[i] = (zr2 - zi2) + cri;
            if (sact[i]) sk[i]++;
            sact[i] = sact[i] && !esc && sk[i] < M;
            sc += sact[i];
            if ((rec_act[t][i] != sact[i] || rec_k[t][i] != sk[i]) && bad++ < 12)
                printf("it %u px %u: act %u/%u k %u/%u\n", t, i, rec_act[t][i], sact[i], rec_k[t][i], sk[i]);
        }
        if (rec_cnt[t] != sc && bad++ < 20) printf("it %u: count %u/%u\n", t, rec_cnt[t], sc);
    }
    printf("dbg_mandel iterations %u bad %u\n", n_it, bad);
    return (int)bad;
}
