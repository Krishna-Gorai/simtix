// apps.cl - the SIMTiX application suite (suite 1, kernels/apps/*.S) for FGPU (docs/fgpu_plan.md,
// phase 2), OpenCL C for FGPU's compiler (kernels/compile.sh with -hard-float). Our own code;
// FGPUlib.c (FGPU's work-item and atomic helpers) is FGPU's and is only included at compile time.
//
// As rodinia.cl and rivec.cl: one work-item per output, the parameter blocks of
// sw/ps_host/apps.c (sim/gen_apps.py), each kernel takes (p, n) and work-items t >= n return.
// The per-output code follows baselines/vortex/simtix_apps/kernel.cpp (the Vortex ports, which
// match the .gold files bit for bit), with FGPU's limits:
//  - no fused multiply-add: gemm and spmv multiply then add (checked within a tolerance);
//    stencil's c1 * sum (c1 = 0.125), mandel's x * 2 and its pixel coordinates (an integer
//    times 2.5 / w = 5 * 2^-k, w a power of two) are exact products, so there the separate
//    add equals the fma;
//  - no byte or halfword loads ("lb" is a word load with a byte offset): the INT8 kernels load
//    words and unpack with shifts, as SIMTiX's pdot8. Byte stores (sb) compile but, with
//    FGPU's SUB_INTEGER_IMPLEMENT = 0 (its default, our build), store the whole word: the INT8
//    outputs are packed into words by mlpw and conv8w (end of this file); mlp's and conv8's
//    byte-store versions are not used;
//  - floats compare only with "less than" (fslt): every comparison is written a < b;
//  - no float -> int conversion, and int -> float only from unsigned: rne by the magic constant
//    1.5 * 2^23 (exact for 0 <= x <= 127 here), signed int -> float as sign and magnitude;
//  - atomics: FGPU's atomic add serves ONE address per kernel (gmem_atomics.vhd latches the
//    first atomic's address until the kernel ends; an atomic elsewhere is never retired),
//    so k-means' cluster sums are per-worker partial sums plus a reduction (kmeans_part,
//    kmeans_reduce, at the end of this file; the atomic kernel `kmeans` hangs and is not
//    used); no atomic_or (bfs stores its flag);
//  - no barriers, local memory or shuffles in FGPU's compiler: scan sums each 32-element block
//    directly (integer adds: any order gives the same words).
#include "FGPUlib.c"
#pragma OPENCL FP_CONTRACT OFF
typedef unsigned int u32;
#define GF(a) ((__global float *)(a))
#define GU(a) ((__global u32 *)(a))
#define GI(a) ((__global int *)(a))
#define GB(a) ((__global unsigned char *)(a))
#define PF(i) (((__global float *)p)[i])
#define UNSEEN 0xffffffffu
#define MAGIC 12582912.0f                                  /* 1.5 * 2^23 */
#define MAGIC_BITS 0x4B400000u
typedef union { float f; u32 u; int i; } fbits;
#define BITS_F(x) (((fbits){ .u = (x) }).f)
#define F_BITS(x) (((fbits){ .f = (x) }).u)
#define NEGF(x) BITS_F(F_BITS(x) ^ 0x80000000u)            /* exact negation (FGPU has no fneg) */
inline __attribute__((always_inline)) int imax(int a, int b) { return a < b ? b : a; }
// (float)i for any int: the magnitude through FGPU's unsigned conversion, then the sign
// (round to nearest even is symmetric, so this is the correctly rounded (float)i)
inline __attribute__((always_inline)) float i2f_s(int i) {
  u32 m = i < 0 ? 0u - (u32)i : (u32)i;
  float f = (float)m;
  return i < 0 ? NEGF(f) : f;
}
// sum of the four products of the signed bytes of a and b (SIMTiX's pdot8)
inline __attribute__((always_inline)) int dot8(u32 a, u32 b) {
  int s = ((int)(a << 24) >> 24) * ((int)(b << 24) >> 24);
  s = s + ((int)(a << 16) >> 24) * ((int)(b << 16) >> 24);
  s = s + ((int)(a << 8) >> 24) * ((int)(b << 8) >> 24);
  s = s + ((int)a >> 24) * ((int)b >> 24);
  return s;
}
// mlp.S / conv8.S requantization: rne(clamp(float(acc) * scale + zp, 0, 127)) (the fma of the
// definition as a multiply and an add); rne of 0 <= v <= 127 by the magic constant, exact
inline __attribute__((always_inline)) u32 requant8(int acc, float scale, float zp) {
  float f = i2f_s(acc) * scale;
  f = f + zp;
  f = 127.0f < f ? 127.0f : f;
  f = f < 0.0f ? 0.0f : f;
  float y = f + MAGIC;
  return F_BITS(y) - MAGIC_BITS;
}

// gemm.S: C[t] = sum over k of A[row][k] * B[k][col] in k order from +0
__kernel void gemm(__global u32 *p, u32 n) {
  u32 t = get_global_id(0);
  if (t >= n) return;
  __global float *A = GF(p[0]), *B = GF(p[1]), *C = GF(p[2]);
  u32 K = p[3], l2n = p[4], nn = 1u << l2n;
  __global float *a = A + (t >> l2n) * K;
  __global float *b = B + (t & (nn - 1));
  float acc = 0.0f;
  for (u32 k = 0; k < K; ++k) {
    float q = a[k] * b[k * nn];
    acc = acc + q;
  }
  C[t] = acc;
}

// spmv.S: CSR, one work-item per row, index order from +0
__kernel void spmv(__global u32 *p, u32 n) {
  u32 r = get_global_id(0);
  if (r >= n) return;
  __global u32 *rowptr = GU(p[0]), *col = GU(p[1]);
  __global float *val = GF(p[2]), *x = GF(p[3]), *y = GF(p[4]);
  float acc = 0.0f;
  u32 e = rowptr[r + 1];
  for (u32 j = rowptr[r]; j < e; ++j) {
    float q = val[j] * x[col[j]];
    acc = acc + q;
  }
  y[r] = acc;
}

// stencil.S: one 5-point Jacobi sweep, out = c1 * ((up + down) + (left + right)) + c0 * centre;
// rows padded with 8 words each side (sw/ps_host/apps.c LANES)
__kernel void stencil(__global u32 *p, u32 n) {
  u32 t = get_global_id(0);
  if (t >= n) return;
  __global float *in = GF(p[0]), *out = GF(p[1]);
  u32 l2w = p[2], s = p[3];
  float c0 = PF(4), c1 = PF(5);
  u32 q = ((t >> l2w) + 1) * s + 8 + (t & ((1u << l2w) - 1));
  float ud = in[q - s] + in[q + s], lr = in[q - 1] + in[q + 1];
  float sum = ud + lr;
  float centre = c0 * in[q];
  float r = c1 * sum;
  out[q] = r + centre;
}

// kmeans.S as written, with atomic adds at 3 x K addresses: hangs on FGPU (see the header);
// kept so the kernels after it keep their entry words. The host runs kmeans_part + kmeans_reduce.
__kernel void kmeans(__global u32 *p, u32 n) {
  u32 t = get_global_id(0);
  if (t >= n) return;
  __global u32 *px = GU(p[0]), *py = GU(p[1]), *cx = GU(p[2]), *cy = GU(p[3]);
  u32 K = p[4];
  u32 x = px[t], y = py[t];
  u32 best = 0x7fffffffu, bk = 0;
  for (u32 k = 0; k < K; ++k) {
    int dx = (int)(x - cx[k]), dy = (int)(y - cy[k]);
    u32 d = (u32)(dx * dx + dy * dy);
    if (d < best) { best = d; bk = k; }
  }
  GU(p[5])[t] = bk;
  atomic_add(GI(p[6]) + bk, (int)x);
  atomic_add(GI(p[7]) + bk, (int)y);
  atomic_add(GI(p[8]) + bk, 1);
}

// bfs.S: one level; a frontier vertex labels its unseen neighbours L + 1 and sets the flag
// (every writer stores 1: a plain store, FGPU has no atomic or)
__kernel void bfs(__global u32 *p, u32 n) {
  u32 v = get_global_id(0);
  if (v >= n) return;
  __global u32 *rowptr = GU(p[0]), *col = GU(p[1]), *level = GU(p[2]);
  u32 L = p[3];
  if (level[v] != L) return;
  u32 found = 0;
  u32 e = rowptr[v + 1];
  for (u32 j = rowptr[v]; j < e; ++j) {
    u32 w = col[j];
    if (level[w] == UNSEEN) { level[w] = L + 1; found = 1; }
  }
  if (found) GU(p[4])[0] = 1u;
}

// scan.S: inclusive scan of each block of 32 elements (sw/ps_host/apps.c scan_level: 4 * LANES,
// LANES = 8), the block total to bs[t / 32]; summed directly from the block's first element
__kernel void scan(__global u32 *p, u32 n) {
  u32 t = get_global_id(0);
  if (t >= n) return;
  __global u32 *in = GU(p[0]);
  u32 v = 0;
  for (u32 i = t & ~31u; i <= t; ++i)
    v = v + in[i];
  GU(p[1])[t] = v;
  if ((t & 31u) == 31u) GU(p[2])[t >> 5] = v;
}

// scan_add.S: add the scanned totals of the earlier blocks
__kernel void scan_add(__global u32 *p, u32 n) {
  u32 t = get_global_id(0);
  if (t >= n) return;
  u32 b = t >> 5;
  if (b) GU(p[0])[t] = GU(p[0])[t] + GU(p[1])[b - 1];
}

// mlp.S: one INT8 layer, acc = sum of the byte products of x's row and W's column (packed
// words); mode 0 stores the INT32 acc, mode 1 the requantized byte
__kernel void mlp(__global u32 *p, u32 n) {
  u32 t = get_global_id(0);
  if (t >= n) return;
  u32 Kp = p[3], l2 = p[4], np = 1u << l2;
  __global u32 *x = GU(p[0]) + (t >> l2) * Kp;
  __global u32 *w = GU(p[1]) + (t & (np - 1));
  int acc = 0;
  for (u32 k = 0; k < Kp; ++k)
    acc = acc + dot8(x[k], w[k * np]);
  if (p[7] == 0) { GI(p[2])[t] = acc; return; }
  GB(p[2])[t] = (unsigned char)requant8(acc, PF(5), PF(6));
}

// conv8.S: one INT8 3x3 conv layer; work-item t = output channel o of the four pixels
// (y, x..x+3); X(r, c, x) at X + 4*((r*Cw + c)*Wp + x), weights Wt[ky][c][kx][o]; each output
// byte requantized into the padded layout (Cout/4 words per pixel)
__kernel void conv8(__global u32 *p, u32 n) {
  u32 t = get_global_id(0);
  if (t >= n) return;
  __global u32 *X = GU(p[0]), *Wt = GU(p[1]);
  u32 Cw = p[3], l2co = p[4], l2w4 = p[5], Wp = p[8];
  u32 Cout = 1u << l2co, o = t & (Cout - 1), q = t >> l2co;
  u32 x = 4 * (q & ((1u << l2w4) - 1)), y = q >> l2w4;
  int acc0 = 0, acc1 = 0, acc2 = 0, acc3 = 0;
  for (u32 ky = 0; ky < 3; ++ky)
    for (u32 c = 0; c < Cw; ++c) {
      __global u32 *xr = X + ((y + ky) * Cw + c) * Wp + x;
      __global u32 *wr = Wt + ((ky * Cw + c) * 3) * Cout + o;
      u32 w0 = wr[0], w1 = wr[Cout], w2 = wr[2 * Cout];
      u32 a0 = xr[0], a1 = xr[1], a2 = xr[2], a3 = xr[3], a4 = xr[4], a5 = xr[5];
      acc0 = acc0 + (dot8(a0, w0) + dot8(a1, w1) + dot8(a2, w2));
      acc1 = acc1 + (dot8(a1, w0) + dot8(a2, w1) + dot8(a3, w2));
      acc2 = acc2 + (dot8(a2, w0) + dot8(a3, w1) + dot8(a4, w2));
      acc3 = acc3 + (dot8(a3, w0) + dot8(a4, w1) + dot8(a5, w2));
    }
  float scale = PF(6), zp = PF(7);
  __global unsigned char *ob = GB(p[2]) + 4 * (((y + 1) * (Cout >> 2) + (o >> 2)) * Wp + x + 1) + (o & 3);
  ob[0] = (unsigned char)requant8(acc0, scale, zp);
  ob[4] = (unsigned char)requant8(acc1, scale, zp);
  ob[8] = (unsigned char)requant8(acc2, scale, zp);
  ob[12] = (unsigned char)requant8(acc3, scale, zp);
}

// embag.S: out[b][d] = T[idx[b][0]][d] + ... in order k = 0..K-1 from +0
__kernel void embag(__global u32 *p, u32 n) {
  u32 t = get_global_id(0);
  if (t >= n) return;
  __global float *T = GF(p[0]);
  __global u32 *ib = GU(p[1]);
  u32 K = p[3], l2d = p[4], d = t & ((1u << l2d) - 1), b = t >> l2d;
  ib = ib + b * K;
  float acc = 0.0f;
  for (u32 k = 0; k < K; ++k)
    acc = acc + T[(ib[k] << l2d) + d];
  GF(p[2])[t] = acc;
}

// hashj.S: hash-join probe, linear probing in 2^s slots {key, value}, key 0 = empty
__kernel void hashj(__global u32 *p, u32 n) {
  u32 t = get_global_id(0);
  if (t >= n) return;
  __global u32 *slot = GU(p[0]);
  u32 key = GU(p[1])[t], sh = p[3], mask = p[4];
  u32 h = (key * 0x9E3779B1u) >> sh;
  u32 s = slot[2 * h];
  while (s != key && s != 0) {
    h = (h + 1) & mask;
    s = slot[2 * h];
  }
  GU(p[2])[t] = (s == key) ? slot[2 * h + 1] : 0xFFFFFFFFu;
}

// mandel.S: escape count, every operation rounded once
__kernel void mandel(__global u32 *p, u32 n) {
  u32 t = get_global_id(0);
  if (t >= n) return;
  u32 l2w = p[1], M = p[6];
  float x0 = PF(2), y0 = PF(3), dx = PF(4), dy = PF(5);
  float cr = (float)(t & ((1u << l2w) - 1)) * dx;
  cr = cr + x0;
  float ci = (float)(t >> l2w) * dy;
  ci = ci + y0;
  float zr = 0.0f, zi = 0.0f;
  u32 k = 0;
  int esc;
  do {
    float zr2 = zr * zr, zi2 = zi * zi;
    float r2 = zr2 + zi2;
    esc = 4.0f < r2;
    float zz = zr * zi;
    zz = zz * 2.0f;
    zi = zz + ci;
    float dd = zr2 - zi2;
    zr = dd + cr;
    ++k;
  } while (!esc && k < M);
  GU(p[0])[t] = k;
}

// swat.S: Smith-Waterman score, affine gaps (match +2, mismatch -1, open 3, extend 1), one
// pair per work-item, the query in strips of 4 rows against the whole target; the strip's
// last row (H << 16 | F) goes to the boundary word B[j][p] that the next strip reads
#define SW_NEG (-16384)
#define SW_ROW(h, e, qc) { \
    e = imax(e - 1, h - 3); \
    f = imax(f - 1, hup - 3); \
    int hv = diag + ((qc) == tc ? 2 : -1); \
    hv = imax(imax(hv, 0), imax(e, f)); \
    diag = h; h = hv; hup = hv; best = imax(best, hv); }
__kernel void swat(__global u32 *p, u32 n) {
  u32 t = get_global_id(0);
  if (t >= n) return;
  __global u32 *T = GU(p[0]), *Q = GU(p[1]), *B = GU(p[2]);
  u32 Lt = p[4], S = p[5], stride = p[6] >> 2;
  int best = 0;
  for (u32 s = 0; s < S; ++s) {
    u32 qw = Q[s * stride + t];
    u32 q0 = qw & 3, q1 = (qw >> 2) & 3, q2 = (qw >> 4) & 3, q3 = (qw >> 6) & 3;
    int h0 = 0, h1 = 0, h2 = 0, h3 = 0, e0 = SW_NEG, e1 = SW_NEG, e2 = SW_NEG, e3 = SW_NEG;
    int bprev = 0;
    for (u32 j = 0; j < Lt; ++j) {
      u32 tc = T[j * stride + t] & 3;
      int hup = 0, f = SW_NEG;
      if (s) { u32 bw = B[j * stride + t]; hup = (int)bw >> 16; f = (int)(bw << 16) >> 16; }
      int diag = bprev;
      bprev = hup;
      SW_ROW(h0, e0, q0) SW_ROW(h1, e1, q1) SW_ROW(h2, e2, q2) SW_ROW(h3, e3, q3)
      B[j * stride + t] = ((u32)hup << 16) | ((u32)f & 0xFFFFu);
    }
  }
  GU(p[3])[t] = (u32)best;
}

// k-means without multi-address atomics (docs/fgpu_plan.md, option (a)). kmeans_part: worker w
// of W takes points w, w + W, w + 2W, ... (adjacent workers, adjacent points); for each point
// the nearest centroid as kmeans.S (integer squared distance, lowest index on a tie) to as[i],
// and x, y and 1 added to the worker's own partial sums part[(a*K + k)*W + w], a = 0 (x), 1 (y),
// 2 (count), zeroed first. Integer adds: any grouping gives kmeans.S's sums.
//   p[0] = &px  p[1] = &py  p[2] = &cx  p[3] = &cy  p[4] = K  p[5] = &as  p[6] = &part
//   p[7] = number of points  p[8] = W; n = W work-items
__kernel void kmeans_part(__global u32 *p, u32 n) {
  u32 w = get_global_id(0);
  if (w >= n) return;
  __global u32 *px = GU(p[0]), *py = GU(p[1]), *cx = GU(p[2]), *cy = GU(p[3]), *as = GU(p[5]);
  u32 K = p[4], np = p[7], W = p[8];
  __global u32 *part = GU(p[6]) + w;
  for (u32 j = 0; j < 3 * K; ++j) part[j * W] = 0u;
  for (u32 i = w; i < np; i += W) {
    u32 x = px[i], y = py[i];
    u32 best = 0x7fffffffu, bk = 0;
    for (u32 k = 0; k < K; ++k) {
      int dx = (int)(x - cx[k]), dy = (int)(y - cy[k]);
      u32 d = (u32)(dx * dx + dy * dy);
      if (d < best) { best = d; bk = k; }
    }
    as[i] = bk;
    __global u32 *q = part + bk * W;
    q[0] = q[0] + x;
    q[K * W] = q[K * W] + y;
    q[2 * K * W] = q[2 * K * W] + 1u;
  }
}

// kmeans_reduce: work-item j of 3K adds the W partial sums part[j*W .. j*W + W-1] into
// sx[k] (j < K), sy[k] (j < 2K) or cn[k], k = j mod K (kmeans.S's sums, written, not added)
//   p[0] = &part  p[1] = &sx  p[2] = &sy  p[3] = &cn  p[4] = K  p[5] = W; n = 3K work-items
__kernel void kmeans_reduce(__global u32 *p, u32 n) {
  u32 j = get_global_id(0);
  if (j >= n) return;
  u32 K = p[4], W = p[5];
  __global u32 *part = GU(p[0]) + j * W;
  u32 s = 0;
  for (u32 w = 0; w < W; ++w)
    s = s + part[w];
  u32 a = j < K ? 0u : (j < 2 * K ? 1u : 2u);
  GU(p[1 + a])[j - a * K] = s;
}

// The INT8 kernels with word stores (FGPU without SUB_INTEGER_IMPLEMENT stores every sb as a whole
// word). mlpw: work-item u computes outputs 4u .. 4u+3 of mlp.S (same image b, columns n0 .. n0+3,
// npad a multiple of 8): mode 0 stores the four INT32 sums, mode 1 the four requantized bytes as
// one word (byte j = output 4u + j, as the byte array mlp.S writes). n = batch * npad / 4.
__kernel void mlpw(__global u32 *p, u32 n) {
  u32 u = get_global_id(0);
  if (u >= n) return;
  u32 Kp = p[3], l2 = p[4], np = 1u << l2;
  u32 t0 = u << 2;
  __global u32 *x = GU(p[0]) + (t0 >> l2) * Kp;
  __global u32 *w = GU(p[1]) + (t0 & (np - 1));
  int a0 = 0, a1 = 0, a2 = 0, a3 = 0;
  for (u32 k = 0; k < Kp; ++k) {
    u32 xa = x[k];
    __global u32 *wk = w + k * np;
    a0 = a0 + dot8(xa, wk[0]);
    a1 = a1 + dot8(xa, wk[1]);
    a2 = a2 + dot8(xa, wk[2]);
    a3 = a3 + dot8(xa, wk[3]);
  }
  if (p[7] == 0) {
    __global int *o = GI(p[2]) + t0;
    o[0] = a0; o[1] = a1; o[2] = a2; o[3] = a3;
    return;
  }
  float scale = PF(5), zp = PF(6);
  u32 r = requant8(a0, scale, zp) | (requant8(a1, scale, zp) << 8) |
          (requant8(a2, scale, zp) << 16) | (requant8(a3, scale, zp) << 24);
  GU(p[2])[u] = r;
}

// conv8w: conv8.S's layer with work-item = (row y, pixel xp, output-channel group g of 4): the 3x3
// sums of channels 4g .. 4g+3 at pixel xp, requantized and packed into the output word of that
// pixel and group (conv8.S's padded layout, Cout/4 words per pixel). Same parameter block and
// work-item count (H * W * Cout/4) as conv8; the same integer sums, so the same bytes.
__kernel void conv8w(__global u32 *p, u32 n) {
  u32 t = get_global_id(0);
  if (t >= n) return;
  __global u32 *X = GU(p[0]), *Wt = GU(p[1]);
  u32 Cw = p[3], l2co = p[4], l2w = p[5] + 2, Wp = p[8];
  u32 Cout = 1u << l2co, G = Cout >> 2;
  u32 g = t & (G - 1), q = t >> (l2co - 2);
  u32 xp = q & ((1u << l2w) - 1), y = q >> l2w;
  int a0 = 0, a1 = 0, a2 = 0, a3 = 0;
  for (u32 ky = 0; ky < 3; ++ky)
    for (u32 c = 0; c < Cw; ++c) {
      __global u32 *xr = X + ((y + ky) * Cw + c) * Wp + xp;      // X(y+ky, c, xp)
      __global u32 *wr = Wt + ((ky * Cw + c) * 3) * Cout + 4 * g;  // Wt[ky][c][0][4g]
      for (u32 kx = 0; kx < 3; ++kx) {
        u32 a = xr[kx];
        __global u32 *wk = wr + kx * Cout;
        a0 = a0 + dot8(a, wk[0]);
        a1 = a1 + dot8(a, wk[1]);
        a2 = a2 + dot8(a, wk[2]);
        a3 = a3 + dot8(a, wk[3]);
      }
    }
  float scale = PF(6), zp = PF(7);
  u32 r = requant8(a0, scale, zp) | (requant8(a1, scale, zp) << 8) |
          (requant8(a2, scale, zp) << 16) | (requant8(a3, scale, zp) << 24);
  GU(p[2])[((y + 1) * G + g) * Wp + xp + 1] = r;
}
