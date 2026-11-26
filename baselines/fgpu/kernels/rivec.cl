// rivec.cl - the RiVEC kernels of the SIMTiX comparison for FGPU (docs/fgpu_plan.md, phase 1),
// OpenCL C for FGPU's compiler (kernels/compile.sh with -hard-float). Our own code; FGPUlib.c is
// FGPU's and is only included at compile time.
//
// As rodinia.cl: one work-item per output, the parameter blocks of sw/ps_host/rivec.inc, each
// kernel takes (p, n) and work-items t >= n return. matmul and spmv run the base kernels (one
// output per work-item), as Vortex does (rivec.inc, SIMTIX_VORTEX / SIMTIX_FGPU). The per-element
// code follows kernels/rivec/rv_ref.h (the A53 reference) operation by operation; each fma of it
// is a multiply and an add here (FGPU has none; FP_CONTRACT OFF).
// FGPU has no float -> int conversion and converts only unsigned ints to float, so rv_ref.h's
// rv_cvt_rne(x) (round to nearest even) and (float)int use the exact magic-constant forms with
// M = 1.5 * 2^23: rne(x) = (x + M) - M, its integer = bits(x + M) - bits(M), and
// (float)i = float(bits(M) + i) - M, all exact for |x|, |i| < 2^22 (here |x| < 130).
//
// COMPILE WITH  LLC_EXTRA=-disable-machine-licm ./compile.sh rivec.cl -hard-float
// (compile.sh passes $LLC_EXTRA to llc). FGPU gives each work-item 16 words of stack (lmem.vhd:
// LMEM_ADDR_W 10 = phase 3 + wavefront 3 + sp 4 bits); a larger frame wraps onto itself. With
// LLVM's machine LICM, lavamd_rv hoists rv_exp's constants out of its inner loop and spills to an
// 18-word frame: wrong lavaMD results on the board (2026-11-20). Without it the frame is 6 words
// (lavamd_rv 185 instructions, inner loop 100) and every other kernel's code is unchanged.
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

inline __attribute__((always_inline)) float rne_f(float x) { float y = x + MAGIC; return y - MAGIC; }
inline __attribute__((always_inline)) int rne_i(float x) { float y = x + MAGIC; return (int)(F_BITS(y) - MAGIC_BITS); }
inline __attribute__((always_inline)) float i2f(int i) { return BITS_F(MAGIC_BITS + (u32)i) - MAGIC; }
inline __attribute__((always_inline)) float minf_(float a, float b) { return b < a ? b : a; }
// FGPU compares floats only with "less than" (fslt): every comparison is written as a < b
inline __attribute__((always_inline)) float maxf_(float a, float b) { return a < b ? b : a; }

// rv_ref.h rv_exp (RiVEC common/__exp.h, one element)
inline __attribute__((always_inline)) float rv_exp(float x) {
  const float exp_hi = 88.3762626647949f, exp_low = -88.3762626647949f;
  const float LOG2EF = 1.44269504088896341f, C1 = 0.693359375f, C2 = -2.12194440e-4f;
  const float p0 = 1.9875691500E-4f, p1 = 1.3981999507E-3f, p2 = 8.3334519073E-3f,
              p3 = 4.1665795894E-2f, p4 = 1.6666665459E-1f, p5 = 5.0000001201E-1f;
  x = minf_(x, exp_hi);
  x = maxf_(x, exp_low);
  float fx = LOG2EF * x; fx = fx + 0.5f;
  float tmp = rne_f(fx);
  fx = tmp - (fx < tmp ? 1.0f : 0.0f);
  float t1 = fx * C1, z = fx * C2;
  x = x - t1;
  x = x - z;
  z = x * x;
  float y = p0, q;
  q = y * x; y = q + p1;
  q = y * x; y = q + p2;
  q = y * x; y = q + p3;
  q = y * x; y = q + p4;
  q = y * x; y = q + p5;
  q = y * z; y = q + x;
  y = y + 1.0f;
  int e = rne_i(fx) + 0x7f;
  return y * BITS_F((u32)e << 23);
}

// rv_ref.h rv_log (RiVEC common/__log.h, one element)
inline __attribute__((always_inline)) float rv_log(float x) {
  const float SQRTHF = 0.707106781186547524f;
  const float p0 = 7.0376836292E-2f, p1 = -1.1514610310E-1f, p2 = 1.1676998740E-1f,
              p3 = -1.2420140846E-1f, p4 = 1.4249322787E-1f, p5 = -1.6668057665E-1f,
              p6 = 2.0000714765E-1f, p7 = -2.4999993993E-1f, p8 = 3.3333331174E-1f;
  const float q1 = -2.12194440e-4f, q2 = 0.693359375f;
  int invalid = (F_BITS(x) - 1u) >= 0x7F800000u;     // !(x > 0): +-0, negative or NaN, exactly
  x = maxf_(x, BITS_F(0x00800000u));
  int imm0 = (int)(F_BITS(x) >> 23);
  x = BITS_F((F_BITS(x) & ~0x7f800000u) | F_BITS(0.5f));
  imm0 = imm0 - 127;
  float e = i2f(imm0);
  e = e + 1.0f;
  int m = x < SQRTHF;
  float tmp = m ? x : 0.0f;
  x = x - 1.0f;
  e = e - (m ? 1.0f : 0.0f);
  x = x + tmp;
  float z = x * x, q;
  float y = p0 * x; y = y + p1;
  q = y * x; y = q + p2;
  q = y * x; y = q + p3;
  q = y * x; y = q + p4;
  q = y * x; y = q + p5;
  q = y * x; y = q + p6;
  q = y * x; y = q + p7;
  q = y * x; y = q + p8;
  y = y * z;
  q = e * q1; y = q + y;
  tmp = z * 0.5f;
  y = y - tmp;
  tmp = e * q2;
  x = x + y;
  x = x + tmp;
  return invalid ? BITS_F(0xffffffffu) : x;
}

// rv_ref.h rv_cndf (RiVEC CNDF_SIMD, one element)
inline __attribute__((always_inline)) float rv_cndf(float x) {
  const float inv_sqrt_2xPI = 0.39894228040143270286f;
  int neg = x < 0.0f;
  float xa = x < 0.0f ? NEGF(x) : x;
  float ev = xa * xa;
  ev = ev * -0.5f;
  float np = rv_exp(ev);
  np = np * inv_sqrt_2xPI;
  float k2 = 0.2316419f * xa; k2 = k2 + 1.0f;
  k2 = 1.0f / k2;
  float k2_2 = k2 * k2, k2_3 = k2_2 * k2, k2_4 = k2_3 * k2, k2_5 = k2_4 * k2;
  float l1 = k2 * 0.319381530f;
  float l2 = k2_2 * -0.356563782f, q;
  q = k2_3 * 1.781477937f; l2 = q + l2;
  q = k2_4 * -1.821255978f; l2 = q + l2;
  q = k2_5 * 1.330274429f; l2 = q + l2;
  l1 = l2 + l1;
  float loc = l1 * np;
  loc = 1.0f - loc;
  return neg ? 1.0f - loc : loc;
}

// gemm (kernels/apps gemm.S, the base kernel): C[t] = sum over k of A[row][k] * B[k][col] from +0
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

// spmv (kernels/apps spmv.S, the base kernel): CSR, one work-item per row, index order from +0
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

// pathfinder (suite 2's pathfinder.S, as rodinia.cl)
__kernel void pathfinder(__global u32 *p, u32 n) {
  u32 c = get_global_id(0);
  if (c >= n) return;
  __global int *src = GI(p[0]), *dst = GI(p[1]), *wall = GI(p[2]);
  int m = src[c] < src[c + 1] ? src[c] : src[c + 1];
  m = m < src[c + 2] ? m : src[c + 2];
  dst[c + 1] = m + wall[c];
}

// axpy_rv.S: dy[t] = a * dx[t] + dy[t]
__kernel void axpy_rv(__global u32 *p, u32 n) {
  u32 t = get_global_id(0);
  if (t >= n) return;
  __global float *dx = GF(p[0]), *dy = GF(p[1]);
  float q = PF(2) * dx[t];
  dy[t] = q + dy[t];
}

// jacobi_rv.S: n x n (n = 2^p[2]), interior points, RiVEC's order:
// B = (((c + left) + right) + (bottom + top)) * c02 (no fma: exact on FGPU)
__kernel void jacobi_rv(__global u32 *p, u32 n) {
  u32 t = get_global_id(0);
  if (t >= n) return;
  __global float *A = GF(p[0]), *B = GF(p[1]);
  u32 l2n = p[2], nn = 1u << l2n, i = t >> l2n, j = t & (nn - 1);
  if (i - 1 >= nn - 2 || j - 1 >= nn - 2) return;          // border (unsigned)
  float u = A[t] + A[t - 1];
  u = u + A[t + 1];
  float v = A[t + nn] + A[t - nn];
  float s = u + v;
  B[t] = s * PF(3);
}

// bs_rv.S: one option, rv_ref.h rv_blackscholes (p[0..6] = S K r v T otype price)
__kernel void bs_rv(__global u32 *p, u32 n) {
  u32 i = get_global_id(0);
  if (i >= n) return;
  float S = GF(p[0])[i], K = GF(p[1])[i], r = GF(p[2])[i], v = GF(p[3])[i], T = GF(p[4])[i];
  int ot = GI(p[5])[i];
  float lt = rv_log(S / K);
  float sq = sqrtf(T);
  float rt = r * T;
  float fv = rv_exp(NEGF(rt));
  float pw = v * v;
  pw = pw * 0.5f;
  float d1 = r + pw;
  float q = d1 * T; d1 = q + lt;
  float den = v * sq;
  d1 = d1 / den;
  float d2 = d1 - den;
  float n1 = rv_cndf(d1), n2 = rv_cndf(d2);
  fv = fv * K;
  if (ot != 0) { n1 = 1.0f - n1; n2 = 1.0f - n2; }
  float o1 = S * n1, o2 = fv * n2;
  float pr = o2 - o1;
  GF(p[6])[i] = pr < 0.0f ? NEGF(pr) : pr;
}

// lavamd_rv.S: particle t of home box l = t / 96, the home box and then its neighbours in
// RiVEC's order, 96 particles each, rv_ref.h rv_lavamd's operations for one particle.
// t / 96 = ((t >> 5) * 0xAAAB) >> 17, exact for t >> 5 < 2^16.
#define NP 96u
__kernel void lavamd_rv(__global u32 *p, u32 n) {
  u32 t = get_global_id(0);
  if (t >= n) return;
  __global float *rv = GF(p[0]), *qv = GF(p[1]), *fA = GF(p[2]) + 4 * t;
  __global u32 *nn = GU(p[3]), *nei = GU(p[4]);
  float a2 = PF(5);
  u32 l = ((t >> 5) * 0xAAABu) >> 17;
  float Av = rv[4 * t], Ax = rv[4 * t + 1], Ay = rv[4 * t + 2], Az = rv[4 * t + 3];
  float fv = fA[0], fx = fA[1], fy = fA[2], fz = fA[3];
  u32 nb = 1 + nn[l];
  for (u32 k = 0; k < nb; k++) {
    u32 pb = k ? nei[l * 26 + k - 1] : l;
    __global float *rB = rv + 4 * pb * NP, *qB = qv + pb * NP;
    for (u32 j = 0; j < NP; j++) {
      float Bv = rB[4 * j], Bx = rB[4 * j + 1], By = rB[4 * j + 2], Bz = rB[4 * j + 3];
      float r2 = Bv + Av;
      float dot = Bx * Ax, q;
      q = Ay * By; dot = q + dot;
      q = Az * Bz; dot = q + dot;
      r2 = r2 - dot;
      float u2 = r2 * a2;
      float vij = rv_exp(NEGF(u2));
      float fs = 2.0f * vij;
      float dx = Ax - Bx, dy = Ay - By, dz = Az - Bz;
      float qj = qB[j];
      q = qj * vij; fv = q + fv;
      q = fs * dx; q = qj * q; fx = q + fx;
      q = fs * dy; q = qj * q; fy = q + fy;
      q = fs * dz; q = qj * q; fz = q + fz;
    }
  }
  fA[0] = fv; fA[1] = fx; fA[2] = fy; fA[3] = fz;
}
