// s2.cl - SIMTiX's suite 2 (kernels/suite2/*.S: Rodinia, PolyBench, GAP, SHOC, PARSEC) for FGPU
// (docs/fgpu_plan.md, phase 3), OpenCL C for FGPU's compiler (kernels/compile.sh with
// -hard-float). Our own code; FGPUlib.c is FGPU's and is only included at compile time.
//
// As rodinia.cl: one work-item per output (per worker for the radix sort, per digit for its
// scan), the parameter blocks of sw/ps_host/suite2.inc (sim/gen_suite2.py), each kernel takes
// (p, n) and work-items t >= n return. The per-output code follows the .S headers and
// kernels/suite2/s2_ref.h (the A53 reference) operation by operation, with FGPU's limits:
//  - no fused multiply-add: each fma is a multiply then an add (hotspot, atax/bicg, PageRank,
//    backprop, Black-Scholes: checked within a tolerance); jacobi2d has none (exact);
//  - floats compare only with "less than"; no fneg (sign-bit flip); no float -> int conversion
//    (rne by the magic constant 1.5 * 2^23, exact for |x| < 2^22; (float)int likewise);
//  - no atomic or: cc_step stores its flag (every writer stores 1);
//  - the radix sort counts and places in memory as rs_hist.S and rs_scatter.S do (each worker
//    in its own column of hist and off). Its kernels are named sort_*: FGPU's toolchain dropped
//    the symbols of kernels named rs_* from the object file (no entry in the .h).
// Grids: the n x n interior padded as stencil.S's, row stride S, (i, j) at word
// (i+1)*S + 8 + j (S2_LANES = 8).
#include "FGPUlib.c"
#pragma OPENCL FP_CONTRACT OFF
typedef unsigned int u32;
#define GF(a) ((__global float *)(a))
#define GU(a) ((__global u32 *)(a))
#define GI(a) ((__global int *)(a))
#define PF(i) (((__global float *)p)[i])
#define MAGIC 12582912.0f                                  /* 1.5 * 2^23 */
#define MAGIC_BITS 0x4B400000u
typedef union { float f; u32 u; int i; } fbits;
#define BITS_F(x) (((fbits){ .u = (x) }).f)
#define F_BITS(x) (((fbits){ .f = (x) }).u)
#define NEGF(x) BITS_F(F_BITS(x) ^ 0x80000000u)            /* exact negation (FGPU has no fneg) */
inline __attribute__((always_inline)) int rne_i(float x) { float y = x + MAGIC; return (int)(F_BITS(y) - MAGIC_BITS); }
inline __attribute__((always_inline)) float i2f(int i) { return BITS_F(MAGIC_BITS + (u32)i) - MAGIC; }

// pathfinder.S: dst[c] = wall[c] + min(src[c-1], src[c], src[c+1]); rows padded with one
// INT_MAX word per side (element c at word c+1)
__kernel void pathfinder(__global u32 *p, u32 n) {
  u32 c = get_global_id(0);
  if (c >= n) return;
  __global int *src = GI(p[0]), *dst = GI(p[1]), *wall = GI(p[2]);
  int m = src[c] < src[c + 1] ? src[c] : src[c + 1];
  m = m < src[c + 2] ? m : src[c + 2];
  dst[c + 1] = m + wall[c];
}

// hotspot.S (Rodinia, padded grid): a = (tN + tS) - (t + t), b = (tE + tW) - (t + t),
// c = amb - t; s = a*ry1 + p; s = b*rx1 + s; s = c*rz1 + s; out = sdc*s + t
__kernel void hotspot(__global u32 *p, u32 n) {
  u32 t = get_global_id(0);
  if (t >= n) return;
  __global float *in = GF(p[0]), *out = GF(p[1]), *pw = GF(p[2]);
  u32 l2n = p[3], s = p[4];
  float rx1 = PF(5), ry1 = PF(6), rz1 = PF(7), amb = PF(8), sdc = PF(9);
  u32 q = ((t >> l2n) + 1) * s + 8 + (t & ((1u << l2n) - 1));
  float tt = in[q], t2 = tt + tt;
  float a = in[q - s] + in[q + s];
  a = a - t2;
  float b = in[q + 1] + in[q - 1];
  b = b - t2;
  float c = amb - tt;
  float acc = a * ry1;
  acc = acc + pw[q];
  float r = b * rx1;
  acc = r + acc;
  r = c * rz1;
  acc = r + acc;
  r = sdc * acc;
  out[q] = r + tt;
}

// jacobi2d.S (PolyBench): B[i][j] = 0.2f * ((((A[i][j] + A[i][j-1]) + A[i][j+1]) + A[i+1][j]) + A[i-1][j])
__kernel void jacobi2d(__global u32 *p, u32 n) {
  u32 t = get_global_id(0);
  if (t >= n) return;
  __global float *A = GF(p[0]), *B = GF(p[1]);
  u32 l2n = p[2], s = p[3];
  float c02 = PF(4);
  u32 q = ((t >> l2n) + 1) * s + 8 + (t & ((1u << l2n) - 1));
  float x = A[q] + A[q - 1];
  x = x + A[q + 1];
  x = x + A[q + s];
  x = x + A[q - s];
  B[q] = c02 * x;
}

// mv_row.S: y[i] = sum over j of A[i][j] * x[j], j order from +0
__kernel void mv_row(__global u32 *p, u32 n) {
  u32 i = get_global_id(0);
  if (i >= n) return;
  __global float *A = GF(p[0]), *x = GF(p[1]);
  u32 N = p[3];
  __global float *a = A + i * N;
  float acc = 0.0f;
  for (u32 j = 0; j < N; ++j) {
    float q = a[j] * x[j];
    acc = q + acc;
  }
  GF(p[2])[i] = acc;
}

// mv_col.S: y[j] = sum over i of A[i][j] * x[i], i order from +0
__kernel void mv_col(__global u32 *p, u32 n) {
  u32 j = get_global_id(0);
  if (j >= n) return;
  __global float *A = GF(p[0]), *x = GF(p[1]);
  u32 N = p[3];
  float acc = 0.0f;
  for (u32 i = 0; i < N; ++i) {
    float q = A[i * N + j] * x[i];
    acc = q + acc;
  }
  GF(p[2])[j] = acc;
}

// pr_contrib.S (GAP PageRank): c[u] = pr[u] * invdeg[u]
__kernel void pr_contrib(__global u32 *p, u32 n) {
  u32 u = get_global_id(0);
  if (u >= n) return;
  GF(p[2])[u] = GF(p[0])[u] * GF(p[1])[u];
}

// pr_pull.S: acc = c[u] summed over v's neighbours in order from +0; pr'[v] = d * acc + base
__kernel void pr_pull(__global u32 *p, u32 n) {
  u32 v = get_global_id(0);
  if (v >= n) return;
  __global u32 *rowptr = GU(p[0]), *col = GU(p[1]);
  __global float *c = GF(p[2]);
  float d = PF(4), base = PF(5);
  float acc = 0.0f;
  u32 e = rowptr[v + 1];
  for (u32 k = rowptr[v]; k < e; ++k)
    acc = acc + c[col[k]];
  float r = d * acc;
  GF(p[3])[v] = r + base;
}

// cc_step.S (GAP connected components): lab'[v] = min(lab[v], lab[u] over the neighbours),
// unsigned; a vertex whose label changed sets the round's flag
__kernel void cc_step(__global u32 *p, u32 n) {
  u32 v = get_global_id(0);
  if (v >= n) return;
  __global u32 *rowptr = GU(p[0]), *col = GU(p[1]), *lab = GU(p[2]);
  u32 l = lab[v], m = l;
  u32 e = rowptr[v + 1];
  for (u32 k = rowptr[v]; k < e; ++k) {
    u32 x = lab[col[k]];
    if (x < m) m = x;
  }
  GU(p[3])[v] = m;
  if (m != l) GU(p[4])[0] = 1u;
}

// bp_forward.S: ps[t] = sum over i of w[16b+i][j] * in[16b+i], i = 0..15 in order from +0,
// j = t & 15, b = t >> 4, w N x 16 row-major
__kernel void bp_forward(__global u32 *p, u32 n) {
  u32 t = get_global_id(0);
  if (t >= n) return;
  __global float *in = GF(p[0]) + 16 * (t >> 4);
  __global float *w = GF(p[1]) + 256 * (t >> 4) + (t & 15);
  float acc = 0.0f;
  for (u32 i = 0; i < 16; ++i) {
    float pr = w[16 * i] * in[i];
    acc = acc + pr;
  }
  GF(p[2])[t] = acc;
}

// bp_adjust.S: dw = ed[j] * in[i] + m * ow[t]; w[t] = w[t] + dw; ow[t] = dw; i = t >> 4, j = t & 15
__kernel void bp_adjust(__global u32 *p, u32 n) {
  u32 t = get_global_id(0);
  if (t >= n) return;
  __global float *in = GF(p[0]), *w = GF(p[1]), *ow = GF(p[2]), *ed = GF(p[3]);
  float m = PF(4);
  float mo = m * ow[t];
  float pr = ed[t & 15] * in[t >> 4];
  float dw = pr + mo;
  w[t] = w[t] + dw;
  ow[t] = dw;
}

// sort_hist = rs_hist.S (SHOC sort, 4-bit digits): worker w counts the digits of keys[w*C .. w*C+C-1]
// into its column of hist (16 x W, digit-major), zeroed first
__kernel void sort_hist(__global u32 *p, u32 n) {
  u32 w = get_global_id(0);
  if (w >= n) return;
  __global u32 *keys = GU(p[0]) + w * p[2], *hist = GU(p[1]) + w;
  u32 C = p[2], sh = p[3], W = p[4];
  for (u32 d = 0; d < 16; ++d) hist[d * W] = 0u;
  for (u32 i = 0; i < C; ++i) {
    u32 d = (keys[i] >> sh) & 15u;
    hist[d * W] = hist[d * W] + 1u;
  }
}

// sort_scan = rs_scan.S: digit d (16 work-items): off[d][w] = hist[d][0] + ... + hist[d][w-1], tot[d] = all W
__kernel void sort_scan(__global u32 *p, u32 n) {
  u32 d = get_global_id(0);
  if (d >= n) return;
  u32 W = p[3];
  __global u32 *h = GU(p[0]) + d * W, *off = GU(p[1]) + d * W;
  u32 s = 0;
  for (u32 w = 0; w < W; ++w) {
    u32 x = h[w];
    off[w] = s;
    s = s + x;
  }
  GU(p[2])[d] = s;
}

// sort_scatter = rs_scatter.S: worker w adds the digit bases to its column of off, then moves its chunk in
// order: pos = off[d][w]++, kdst[pos] = key, vdst[pos] = val (a stable pass)
__kernel void sort_scatter(__global u32 *p, u32 n) {
  u32 w = get_global_id(0);
  if (w >= n) return;
  u32 C = p[6], sh = p[7], W = p[8];
  __global u32 *ks = GU(p[0]) + w * C, *vs = GU(p[1]) + w * C, *kd = GU(p[2]), *vd = GU(p[3]);
  __global u32 *off = GU(p[4]) + w, *tot = GU(p[5]);
  u32 base = 0;
  for (u32 d = 0; d < 16; ++d) {
    off[d * W] = off[d * W] + base;
    base = base + tot[d];
  }
  for (u32 i = 0; i < C; ++i) {
    u32 key = ks[i], val = vs[i];
    u32 d = (key >> sh) & 15u;
    u32 pos = off[d * W];
    off[d * W] = pos + 1u;
    kd[pos] = key;
    vd[pos] = val;
  }
}

// blackscholes.S (RiVEC / PARSEC, its own exp and log; C = sim/gen_suite2.py BS_C): s2_ref.h
// operation by operation, each fma a multiply then an add
inline __attribute__((always_inline)) float s2_exp(float x, __global float *C) {
  float t = x * C[3];
  int k = rne_i(t);
  float kf = NEGF(i2f(k));
  float f = kf * C[4];
  f = f + x;
  float q = kf * C[5];
  f = q + f;
  float pp = f * C[12];
  pp = pp + C[11];
  q = f * pp; pp = q + C[10];
  q = f * pp; pp = q + C[9];
  q = f * pp; pp = q + C[8];
  q = f * pp; pp = q + C[7];
  q = f * pp; pp = q + C[6];
  return BITS_F(F_BITS(pp) + ((u32)k << 23));
}
inline __attribute__((always_inline)) float s2_log(float x, __global float *C) {
  u32 b = F_BITS(x);
  int e = (int)((b >> 23) & 0xFFu) - 127;
  float m = BITS_F((b & 0x7FFFFFu) | 0x3F800000u);
  if (F_BITS(C[18]) < F_BITS(m)) { m = m * C[0]; e = e + 1; }    // m > sqrt2 (both positive)
  float f = m - C[1];
  float g = f + C[2];
  float s = f / g;
  float z = s * s;
  float R = z * C[17];
  R = R + C[16];
  float q = z * R; R = q + C[15];
  q = z * R; R = q + C[14];
  R = R * z;
  float ss = s + s;
  q = s * R;
  float l = q + ss;
  q = i2f(e) * C[13];
  return q + l;
}
inline __attribute__((always_inline)) float s2_cndf(float x, __global float *C) {
  u32 sign = F_BITS(x) >> 31;
  float xa = BITS_F(F_BITS(x) & 0x7FFFFFFFu);
  float q = xa * xa;
  q = q * C[0];
  float nn = s2_exp(NEGF(q), C);
  nn = nn * C[19];
  float k2 = C[20] * xa;
  k2 = C[1] + k2;
  k2 = C[1] / k2;
  float k22 = k2 * k2, k23 = k22 * k2, k24 = k23 * k2, k25 = k24 * k2;
  float l1 = k2 * C[21];
  float l2 = k22 * C[22];
  q = k23 * C[23]; l2 = l2 + q;
  q = k24 * C[24]; l2 = l2 + q;
  q = k25 * C[25]; l2 = l2 + q;
  l1 = l1 + l2;
  q = l1 * nn;
  float loc = C[1] - q;
  return sign ? C[1] - loc : loc;
}
__kernel void blackscholes(__global u32 *p, u32 n) {
  u32 i = get_global_id(0);
  if (i >= n) return;
  __global float *C = GF(p[7]);
  float S = GF(p[0])[i], K = GF(p[1])[i], r = GF(p[2])[i], v = GF(p[3])[i], T = GF(p[4])[i];
  float sq = sqrtf(T);
  float lt = s2_log(S / K, C);
  float pw = v * v;
  pw = pw * C[0];
  float d1 = r + pw;
  d1 = d1 * T;
  d1 = d1 + lt;
  float den = v * sq;
  d1 = d1 / den;
  float d2 = d1 - den;
  float n1 = s2_cndf(d1, C), n2 = s2_cndf(d2, C);
  float rt = r * T;
  float fv = K * s2_exp(NEGF(rt), C);
  float a = S * n1, b = fv * n2;
  GF(p[5])[i] = a - b;
  float o2 = C[1] - n2, o1 = C[1] - n1;
  a = fv * o2; b = S * o1;
  GF(p[6])[i] = a - b;
}

// The radix sort without in-kernel read-after-write through memory (FGPU, 2026-11-20): on the
// board, sort_hist / sort_scatter (each work-item re-reading, a few instructions later, a word it
// has just stored) gave wrong results at 65,536 keys with 4 wavefronts (and pauses between the
// kernels changed nothing), while kernels whose read-modify-writes are far apart (k-means'
// partial sums) pass. These versions keep the running counts in registers; the outputs are the
// same words. Per pass: sort_hist2, sort_scan, sort_base, sort_scatter2.
// Packed counters: c[k] holds digit 2k in bits 0..15 and digit 2k+1 in bits 16..31 (C <= 65535).
#define PK_SEL(h, k) (0u - (u32)((h) == (k)))
#define PK_GET(d) ((((c0 & PK_SEL((d) >> 1, 0)) | (c1 & PK_SEL((d) >> 1, 1)) | (c2 & PK_SEL((d) >> 1, 2)) |                      (c3 & PK_SEL((d) >> 1, 3)) | (c4 & PK_SEL((d) >> 1, 4)) | (c5 & PK_SEL((d) >> 1, 5)) |                      (c6 & PK_SEL((d) >> 1, 6)) | (c7 & PK_SEL((d) >> 1, 7))) >> (((d) & 1u) << 4)) & 0xFFFFu)
#define PK_INC(d) { u32 inc_ = 1u << (((d) & 1u) << 4), h_ = (d) >> 1;     c0 += inc_ & PK_SEL(h_, 0); c1 += inc_ & PK_SEL(h_, 1); c2 += inc_ & PK_SEL(h_, 2); c3 += inc_ & PK_SEL(h_, 3);     c4 += inc_ & PK_SEL(h_, 4); c5 += inc_ & PK_SEL(h_, 5); c6 += inc_ & PK_SEL(h_, 6); c7 += inc_ & PK_SEL(h_, 7); }

// sort_hist2 = rs_hist.S: worker w counts its chunk's digits in registers, then stores its column
__kernel void sort_hist2(__global u32 *p, u32 n) {
  u32 w = get_global_id(0);
  if (w >= n) return;
  u32 C = p[2], sh = p[3], W = p[4];
  __global u32 *keys = GU(p[0]) + w * C, *hist = GU(p[1]) + w;
  u32 c0 = 0, c1 = 0, c2 = 0, c3 = 0, c4 = 0, c5 = 0, c6 = 0, c7 = 0;
  for (u32 i = 0; i < C; ++i) {
    u32 d = (keys[i] >> sh) & 15u;
    PK_INC(d)
  }
  for (u32 d = 0; d < 16; ++d)
    hist[d * W] = PK_GET(d);
}

// sort_base: work-item j of 16 W adds digit d's base tot[0] + ... + tot[d-1] to off[j]
// (d = j / W), rs_scatter.S's first step, one read-modify-write per work-item.
// The scatter's parameter block: p[4] = &off  p[5] = &tot  p[8] = W; n = 16 W
__kernel void sort_base(__global u32 *p, u32 n) {
  u32 j = get_global_id(0);
  if (j >= n) return;
  u32 W = p[8], d = 0;
  while ((d + 1) * W <= j) d++;
  __global u32 *tot = GU(p[5]);
  u32 base = 0;
  for (u32 e = 0; e < d; ++e) base = base + tot[e];
  __global u32 *off = GU(p[4]);
  off[j] = off[j] + base;
}

// sort_scatter2 = rs_scatter.S's move: pos = off[d][w] (with the base, from sort_base) plus the
// chunk's running count of digit d (registers); kdst[pos] = key, vdst[pos] = val, in order
__kernel void sort_scatter2(__global u32 *p, u32 n) {
  u32 w = get_global_id(0);
  if (w >= n) return;
  u32 C = p[6], sh = p[7], W = p[8];
  __global u32 *ks = GU(p[0]) + w * C, *vs = GU(p[1]) + w * C, *kd = GU(p[2]), *vd = GU(p[3]);
  __global u32 *off = GU(p[4]) + w;
  u32 c0 = 0, c1 = 0, c2 = 0, c3 = 0, c4 = 0, c5 = 0, c6 = 0, c7 = 0;
  for (u32 i = 0; i < C; ++i) {
    u32 key = ks[i], val = vs[i];
    u32 d = (key >> sh) & 15u;
    u32 pos = off[d * W] + PK_GET(d);
    PK_INC(d)
    kd[pos] = key;
    vd[pos] = val;
  }
}
