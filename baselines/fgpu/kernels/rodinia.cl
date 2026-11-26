// rodinia.cl - the Rodinia kernels of the SIMTiX comparison for FGPU (docs/fgpu_plan.md, phase 1),
// OpenCL C for FGPU's compiler (kernels/compile.sh with -hard-float). Our own code; FGPUlib.c
// (FGPU's work-item and atomic helpers) is FGPU's and is only included at compile time.
//
// One work-item per output, as the SIMTiX threads (kernels/rodinia/*.S, kernels/suite2/*.S) and
// the Vortex ports (baselines/vortex/simtix_apps/kernel.cpp), reading the same parameter blocks
// that sw/ps_host/rodinia.inc and suite2.inc build. Every kernel takes the block's address p and
// the work-item count n; the host rounds the global size up to whole 64-work-item wavefronts,
// and work-items t >= n return at once.
// The operation order of every benchmark definition is kept. FGPU has no fused multiply-add:
// each fma(a, b, c) of a definition is a * b then + c, two roundings (FP_CONTRACT OFF), and the
// host checks those outputs within a stated tolerance (docs/fgpu_plan.md).
#include "FGPUlib.c"
#pragma OPENCL FP_CONTRACT OFF

typedef unsigned int u32;
#define GF(a) ((__global float *)(a))
#define GU(a) ((__global u32 *)(a))
#define GI(a) ((__global int *)(a))
#define PF(i) (((__global float *)p)[i])          /* parameter word i read as a float */
#define UNSEEN 0xffffffffu

// pathfinder.S: dst[c] = wall[c] + min(src[c-1], src[c], src[c+1]); rows padded with one
// INT_MAX word per side (element c at word c+1).
__kernel void pathfinder(__global u32 *p, u32 n) {
  u32 c = get_global_id(0);
  if (c >= n) return;
  __global int *src = GI(p[0]), *dst = GI(p[1]), *wall = GI(p[2]);
  int m = src[c] < src[c + 1] ? src[c] : src[c + 1];
  m = m < src[c + 2] ? m : src[c + 2];
  dst[c + 1] = m + wall[c];
}

// bp_forward.S: ps[t] = sum over i of w[16b+i][j] * in[16b+i], i = 0..15 in order from +0,
// j = t & 15, b = t >> 4, w N x 16 row-major.
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

// bp_adjust.S: dw = ed[j] * in[i] + m * ow[t]; w[t] = w[t] + dw; ow[t] = dw; i = t >> 4, j = t & 15.
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

// hotspot_rd.S: one step on an n x n grid, every cell, clamped neighbours:
// a = (tN + tS) - (t + t); b = (tE + tW) - (t + t); c = amb - t;
// s = a*ry1 + p; s = b*rx1 + s; s = c*rz1 + s; out = sdc*s + t.
__kernel void hotspot_rd(__global u32 *p, u32 n) {
  u32 t = get_global_id(0);
  if (t >= n) return;
  __global float *in = GF(p[0]), *out = GF(p[1]), *pw = GF(p[2]);
  u32 l2n = p[3], n1 = (1u << l2n) - 1;
  float rx1 = PF(4), ry1 = PF(5), rz1 = PF(6), amb = PF(7), sdc = PF(8);
  u32 i = t >> l2n, j = t & n1;
  u32 iN = i ? i - 1 : 0, iS = i < n1 ? i + 1 : n1, jW = j ? j - 1 : 0, jE = j < n1 ? j + 1 : n1;
  float tt = in[t], t2 = tt + tt;
  float a = (in[(iN << l2n) + j] + in[(iS << l2n) + j]) - t2;
  float b = (in[(i << l2n) + jE] + in[(i << l2n) + jW]) - t2;
  float c = amb - tt;
  float s = a * ry1; s = s + pw[t];
  float q = b * rx1; s = q + s;
  q = c * rz1; s = q + s;
  q = sdc * s;
  out[t] = q + tt;
}

// nn.S: dist[t] = sqrt(dx*dx + dy*dy), dx = lat - loc[t].lat, dy = lng - loc[t].lng, every
// operation rounded once (no fma in the definition: FGPU is exact here).
__kernel void nn(__global u32 *p, u32 n) {
  u32 t = get_global_id(0);
  if (t >= n) return;
  __global float *loc = GF(p[0]);
  float dx = PF(2) - loc[2 * t], dy = PF(3) - loc[2 * t + 1];
  float s = dx * dx;
  float s2 = dy * dy;
  s = s + s2;
  GF(p[1])[t] = sqrtf(s);
}

// hotspot3d.S: work-item t owns column (i, j) and walks its nz layers; clamped neighbours;
// s = cc*t, then + ce*tW + ce*tE + cn*tS + cn*tN + ct*tB + ct*tT + sdc*p + ct*amb, in order.
__kernel void hotspot3d(__global u32 *p, u32 n) {
  u32 t = get_global_id(0);
  if (t >= n) return;
  __global float *in = GF(p[0]), *out = GF(p[1]), *pw = GF(p[2]);
  u32 l2 = p[3], nz = p[4], n1 = (1u << l2) - 1, xy = 1u << (2 * l2);
  float cc = PF(5), ce = PF(6), cn = PF(7), ct = PF(8), sdc = PF(9), amb = PF(10);
  u32 i = t & n1, j = t >> l2;
  int oW = i ? -1 : 0, oE = i < n1 ? 1 : 0, oN = j ? -(int)(n1 + 1) : 0, oS = j < n1 ? (int)(n1 + 1) : 0;
  float t1 = in[t], t2 = t1, t3 = in[t + xy];
  u32 c = t;
  for (u32 z = 0; z < nz; ++z) {
    if (z) { t1 = t2; t2 = t3; if (z + 1 < nz) t3 = in[c + xy]; }
    float s = cc * t2, q;
    q = ce * in[c + oW]; s = q + s;
    q = ce * in[c + oE]; s = q + s;
    q = cn * in[c + oS]; s = q + s;
    q = cn * in[c + oN]; s = q + s;
    q = ct * t1; s = q + s;
    q = ct * t3; s = q + s;
    q = sdc * pw[c]; s = q + s;
    q = ct * amb;
    out[c] = q + s;
    c += xy;
  }
}

// gauss_fan1.S: row i = t + 1 + u of the augmented n x (n+1) matrix a: m[i][t] = a[i][t] / a[t][t].
__kernel void gauss_fan1(__global u32 *p, u32 n) {
  u32 u = get_global_id(0);
  if (u >= n) return;
  __global float *a = GF(p[0]), *m = GF(p[1]);
  u32 N = p[2], t = p[3], s = N + 1, i = t + 1 + u;
  m[i * N + t] = a[i * s + t] / a[t * s + t];
}

// gauss_fan2.S: column j = t + u (t .. n, b is column n), rows t+1 .. n-1:
// a[i][j] = (-m[i][t]) * a[t][j] + a[i][j].
__kernel void gauss_fan2(__global u32 *p, u32 n) {
  u32 u = get_global_id(0);
  if (u >= n) return;
  __global float *a = GF(p[0]), *m = GF(p[1]);
  u32 N = p[2], t = p[3], s = N + 1, j = t + u;
  float atj = a[t * s + j];
  for (u32 i = t + 1; i < N; ++i) {
    float q = (-m[i * N + t]) * atj;
    a[i * s + j] = q + a[i * s + j];
  }
}

// kmeans_rd.S: point t on feature-major features f[j*n + t]: ans = d*d + ans over the
// features, the first strictly smaller distance wins.
__kernel void kmeans_rd(__global u32 *p, u32 n) {
  u32 t = get_global_id(0);
  if (t >= n) return;
  __global float *f = GF(p[0]) + t, *c = GF(p[1]);
  u32 np = p[3], k = p[4], nf = p[5], idx = 0;
  float best = 3.40282347e+38f;
  for (u32 i = 0; i < k; ++i) {
    float ans = 0.0f;
    for (u32 j = 0; j < nf; ++j) {
      float d = f[j * np] - c[i * nf + j];
      float q = d * d;
      ans = q + ans;
    }
    if (ans < best) { best = ans; idx = i; }
  }
  GU(p[2])[t] = idx;
}

// bfs (Rodinia, rodinia.inc app_rd_bfs): level-synchronous; vertex v at level L marks its
// unseen neighbours L+1 and sets the level's flag (a plain store of 1: every writer stores 1).
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
