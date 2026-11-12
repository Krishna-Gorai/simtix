/* dbg_conv.c - trace v_conv's accumulation on Ara (debug only): layer 0 of the
 * self-test shape (n 6, ci 8, two output channels), output row y = 0. After every
 * (ky, kx, c) block both int32 accumulators are stored; no calls while vectors are
 * live; checked against a scalar model after one fence. Data: the self-test's. */
#include <riscv_vector.h>
#include <stdint.h>
#ifdef AK_QEMU
#include <stdio.h>
#else
#include "printf.h"
#endif

#define NN 6u
#define CI 8u
#define CO 12u
#define WP (NN + 2u)
#define ROWS (NN + 2u)
#define STEPS (9u * CI / 4u)
static int8_t xs[ROWS * WP * CI], xv[ROWS * CI * WP], wt[CO * 9u * CI];
static int32_t rec0[STEPS][NN], rec1[STEPS][NN];
static int16_t rs0[STEPS][NN], rs1[STEPS][NN];
static int8_t rv[4][64];
static int16_t rsi[4][64];

static uint32_t rng = 2027u;
static uint32_t rnd(void) { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng; }

int main(void)
{
    for (uint32_t r = 1; r <= NN; r++)
        for (uint32_t x = 1; x <= NN; x++)
            for (uint32_t c = 0; c < CI; c++) {
                int8_t v = (int8_t)(rnd() & 0x7Fu);
                xs[(r * WP + x) * CI + c] = v;
                xv[(r * CI + c) * WP + x] = v;
            }
    for (uint32_t i = 0; i < CO * 9u * CI; i++) wt[i] = (int8_t)((int32_t)(rnd() % 128u) - 64);

    __asm__ volatile("fence" ::: "memory");      /* CVA6 write buffer -> memory */
    const uint32_t y = 0, x0 = 0, o = 0, ci = CI, wp = WP;
    const int8_t *in = xv, *W = wt;
    size_t vl = __riscv_vsetvl_e32m4(NN - x0);
    vint32m4_t a0 = __riscv_vmv_v_x_i32m4(0, vl), a1 = a0;
    uint32_t st = 0;
    for (uint32_t ky = 0; ky < 3; ky++)
        for (uint32_t kx = 0; kx < 3; kx++) {
            const int8_t *w0 = W + ((o * 3u + ky) * 3u + kx) * ci;
            const uint32_t ws = 9u * ci;
            for (uint32_t c = 0; c < ci; c += 4) {
                const int8_t *ip = in + ((y + ky) * ci + c) * wp + x0 + kx;
                vint8m1_t v = __riscv_vle8_v_i8m1(ip, vl);
                vint16m2_t s0 = __riscv_vwmul_vx_i16m2(v, w0[c], vl);
                vint16m2_t s1 = __riscv_vwmul_vx_i16m2(v, w0[ws + c], vl);
                if (st == 6) { __riscv_vse8_v_i8m1(rv[0], v, vl); __riscv_vse16_v_i16m2(rsi[0], s0, vl); }
                for (uint32_t i = 1; i < 4; i++) {
                    v = __riscv_vle8_v_i8m1(ip + i * wp, vl);
                    s0 = __riscv_vwmacc_vx_i16m2(s0, w0[c + i], v, vl);
                    s1 = __riscv_vwmacc_vx_i16m2(s1, w0[ws + c + i], v, vl);
                    if (st == 6) { __riscv_vse8_v_i8m1(rv[i], v, vl); __riscv_vse16_v_i16m2(rsi[i], s0, vl); }
                }
                __riscv_vse16_v_i16m2(rs0[st], s0, vl);
                __riscv_vse16_v_i16m2(rs1[st], s1, vl);
                a0 = __riscv_vwadd_wv_i32m4(a0, s0, vl);
                a1 = __riscv_vwadd_wv_i32m4(a1, s1, vl);
                __riscv_vse32_v_i32m4(rec0[st], a0, vl);
                __riscv_vse32_v_i32m4(rec1[st], a1, vl);
                st++;
            }
        }
    __asm__ volatile("fence" ::: "memory");

    unsigned bad = 0;
    int32_t e0[NN] = { 0 }, e1[NN] = { 0 };
    st = 0;
    for (uint32_t ky = 0; ky < 3; ky++)
        for (uint32_t kx = 0; kx < 3; kx++)
            for (uint32_t c = 0; c < ci; c += 4) {
                for (uint32_t xx = 0; xx < NN; xx++) {
                    int32_t p0 = 0, p1 = 0;
                    for (uint32_t i = 0; i < 4; i++) {
                        const int32_t xvv = xs[((y + ky) * WP + xx + kx) * CI + c + i];
                        p0 += xvv * wt[((o * 3u + ky) * 3u + kx) * CI + c + i];
                        p1 += xvv * wt[(((o + 1) * 3u + ky) * 3u + kx) * CI + c + i];
                    }
                    e0[xx] += p0; e1[xx] += p1;
                    if ((rs0[st][xx] != (int16_t)p0 || rs1[st][xx] != (int16_t)p1) && bad++ < 8)
                        printf("step %u (ky %u kx %u c %u) x %u: s0 %d/%d s1 %d/%d\n", st, ky, kx, c, xx,
                               rs0[st][xx], p0, rs1[st][xx], p1);
                    if ((rec0[st][xx] != e0[xx] || rec1[st][xx] != e1[xx]) && bad++ < 16)
                        printf("step %u (ky %u kx %u c %u) x %u: a0 %d/%d a1 %d/%d\n", st, ky, kx, c, xx,
                               rec0[st][xx], e0[xx], rec1[st][xx], e1[xx]);
                }
                st++;
            }
    for (uint32_t i = 0; i < 4; i++) {       /* step 6 = ky 1, kx 0, c 0, pixel x = 1 */
        int32_t ps = 0;
        for (uint32_t ii = 0; ii <= i; ii++) ps += xs[(1u * WP + 1u) * CI + ii] * wt[(0u * 3u + 1u) * 3u * CI + ii];
        printf("i %u: v[x1] %d ref %d  s0[x1] %d ref %d\n", i, rv[i][1], xs[(1u * WP + 1u) * CI + i], rsi[i][1], ps);
    }
    printf("dbg_conv bad %u\n", bad);
    return (int)bad;
}
