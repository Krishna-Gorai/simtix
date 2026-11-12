// SIMTiX application suite on Vortex: the kernels of kernels/apps/*.S (all but the v3
// variants gemm_rb, scan_seg, stencil_rb, kmeans_u, spmv_z), one thread
// per output as there, reading the same parameter blocks (sim/gen_apps.py). Each
// function follows its .S file's header comment, including the order of the FP
// operations, so the results match the same .gold files bit for bit.
#include <vx_spawn2.h>
#include <vx_intrinsics.h>
#include "common.h"

#ifndef VX_CFG_NUM_THREADS
#define VX_CFG_NUM_THREADS 4
#endif

#define UNSEEN 0xffffffffu

typedef uint32_t u32;

template <typename T> static inline T* at(u32 addr) { return reinterpret_cast<T*>(addr); }

static inline float f32(u32 bits) { float f; __builtin_memcpy(&f, &bits, 4); return f; }
static inline int32_t imax(int32_t a, int32_t b) { return a > b ? a : b; }

// C = A * B, thread t computes C[t]: acc = fmadd(A[row][k], B[k][col], acc).
static void gemm(const u32* p, u32 t) {
  const float* A = at<const float>(p[0]);
  const float* B = at<const float>(p[1]);
  float* C = at<float>(p[2]);
  u32 K = p[3], l2n = p[4], n = 1u << l2n;
  const float* a = A + (t >> l2n) * K;
  const float* b = B + (t & (n - 1));
  float acc = 0.0f;
  for (const float* e = a + K; a != e; ++a, b += n)    // B walks down its column
    acc = __builtin_fmaf(*a, *b, acc);
  C[t] = acc;
}

// CSR y = A x, one thread per row, fmadd in index order from +0.0.
static void spmv(const u32* p, u32 r) {
  const u32* rowptr = at<const u32>(p[0]);
  const u32* col = at<const u32>(p[1]);
  const float* val = at<const float>(p[2]);
  const float* x = at<const float>(p[3]);
  float* y = at<float>(p[4]);
  float acc = 0.0f;
  for (u32 j = rowptr[r], e = rowptr[r + 1]; j < e; ++j)
    acc = __builtin_fmaf(val[j], x[col[j]], acc);
  y[r] = acc;
}

// One 5-point Jacobi sweep: out = fmadd(c1, (up + down) + (left + right), c0 * centre).
static void stencil(const u32* p, u32 t) {
  const float* in = at<const float>(p[0]);
  float* out = at<float>(p[1]);
  u32 l2w = p[2], s = p[3];
  float c0 = f32(p[4]), c1 = f32(p[5]);
  u32 q = ((t >> l2w) + 1) * s + 8 + (t & ((1u << l2w) - 1));
  float sum = (in[q - s] + in[q + s]) + (in[q - 1] + in[q + 1]);
  float centre = c0 * in[q];
  out[q] = __builtin_fmaf(c1, sum, centre);
}

// Nearest centroid (lowest index on a tie), then the cluster sums with AMOs.
static void kmeans(const u32* p, u32 t) {
  const u32* px = at<const u32>(p[0]);
  const u32* py = at<const u32>(p[1]);
  const u32* cx = at<const u32>(p[2]);
  const u32* cy = at<const u32>(p[3]);
  u32 K = p[4];
  u32 x = px[t], y = py[t];
  u32 best = 0x7fffffffu, bk = 0;
  for (u32 k = 0; k < K; ++k) {
    int32_t dx = (int32_t)(x - cx[k]), dy = (int32_t)(y - cy[k]);
    u32 d = (u32)(dx * dx + dy * dy);
    if (d < best) { best = d; bk = k; }
  }
  at<u32>(p[5])[t] = bk;
  __atomic_fetch_add(at<u32>(p[6]) + bk, x, __ATOMIC_RELAXED);
  __atomic_fetch_add(at<u32>(p[7]) + bk, y, __ATOMIC_RELAXED);
  __atomic_fetch_add(at<u32>(p[8]) + bk, 1u, __ATOMIC_RELAXED);
}

// One BFS level: a frontier vertex labels its unseen neighbours L + 1 and sets the flag.
static void bfs(const u32* p, u32 v) {
  const u32* rowptr = at<const u32>(p[0]);
  const u32* col = at<const u32>(p[1]);
  u32* level = at<u32>(p[2]);
  u32 L = p[3];
  if (level[v] != L)
    return;
  u32 found = 0;
  for (u32 j = rowptr[v], e = rowptr[v + 1]; j < e; ++j) {
    u32 u = col[j];
    if (level[u] == UNSEEN) { level[u] = L + 1; found = 1; }
  }
  if (found)
    __atomic_fetch_or(at<u32>(p[4]), 1u, __ATOMIC_RELAXED);
}

// Inclusive scan of each 32-thread block: shfl_up within the warp, warp totals in
// shared memory, a barrier, then each thread adds the totals of the lower warps.
// The lane < k mask is arithmetic, as in scan.S: vx_shfl_up is declared const, so
// under an `if` the compiler may move it into the branch, where the low lanes are
// inactive and a shuffle from an inactive lane returns the reader's own value.
static void scan(const u32* p, u32 t) {
  const u32 NT = VX_CFG_NUM_THREADS;
  u32 v = at<const u32>(p[0])[t];
  u32 lane = threadIdx.x & (NT - 1), w = threadIdx.x / NT;
  for (u32 k = 1; k < NT; k <<= 1) {
    u32 o = (u32)vx_shfl_up(v, k, NT - 1, ~(NT - 1) & 0x3f);
    v += o & (0u - (u32)(lane >= k));
  }
  u32* shared = reinterpret_cast<u32*>(__local_mem());
  if (lane == NT - 1)
    shared[w] = v;
  __syncthreads();
  for (u32 i = 0; i < w; ++i)
    v += shared[i];
  at<u32>(p[1])[t] = v;
  if ((t & 31) == 31)
    at<u32>(p[2])[t >> 5] = v;
}

// Second pass of a multi-block scan: add the scanned totals of the earlier blocks.
static void scan_add(const u32* p, u32 t) {
  u32 b = t >> 5;
  if (b)
    at<u32>(p[0])[t] += at<const u32>(p[1])[b - 1];
}

// One INT8 layer: acc = sum of x_b[k] * W[k][n] over packed bytes; mode 0 stores the
// INT32 acc, mode 1 rne(clamp(fmadd(float(acc), scale, zp), 0, 127)) as a byte.
static void mlp(const u32* p, u32 t) {
  u32 Kp = p[3], l2 = p[4], np = 1u << l2;
  const u32* x = at<const u32>(p[0]) + (t >> l2) * Kp;
  const u32* w = at<const u32>(p[1]) + (t & (np - 1));
  int32_t acc = 0;
  for (const u32* e = x + Kp; x != e; ++x, w += np) {   // W walks down its column
    u32 xa = *x, wa = *w;
    for (u32 i = 0; i < 32; i += 8)
      acc += (int32_t)(int8_t)(xa >> i) * (int32_t)(int8_t)(wa >> i);
  }
  if (p[7] == 0) {
    at<int32_t>(p[2])[t] = acc;
    return;
  }
  float f = __builtin_fmaf((float)acc, f32(p[5]), f32(p[6]));
  f = __builtin_fmaxf(__builtin_fminf(f, 127.0f), 0.0f);
  int32_t r;
  __asm__ volatile ("fcvt.w.s %0, %1, rne" : "=r"(r) : "f"(f));
  at<uint8_t>(p[2])[t] = (uint8_t)r;
}

// Requantization of mlp.S / conv8.S: rne(clamp(fmadd(float(acc), scale, zp), 0, 127)).
static inline uint8_t requant8(int32_t acc, float scale, float zp) {
  float f = __builtin_fmaf((float)acc, scale, zp);
  f = __builtin_fmaxf(__builtin_fminf(f, 127.0f), 0.0f);
  int32_t r;
  __asm__ volatile ("fcvt.w.s %0, %1, rne" : "=r"(r) : "f"(f));
  return (uint8_t)r;
}

// Dot product of the four signed bytes of two words (SIMTiX's pdot8).
static inline int32_t dot8(u32 a, u32 b) {
  int32_t s = 0;
  for (u32 i = 0; i < 32; i += 8)
    s += (int32_t)(int8_t)(a >> i) * (int32_t)(int8_t)(b >> i);
  return s;
}

// One INT8 3x3 conv layer (conv8.S): thread t = output channel o of the four pixels
// (y, x..x+3); X(r, c, x) at X + 4*((r*Cw + c)*Wp + x), weights Wt[ky][c][kx][o];
// each output byte requantized into the padded layout (Cout/4 words per pixel).
static void conv8(const u32* p, u32 t) {
  const u32* X = at<const u32>(p[0]);
  const u32* Wt = at<const u32>(p[1]);
  uint8_t* Out = at<uint8_t>(p[2]);
  u32 Cw = p[3], l2co = p[4], l2w4 = p[5], Wp = p[8];
  u32 Cout = 1u << l2co, o = t & (Cout - 1), q = t >> l2co;
  u32 x = 4 * (q & ((1u << l2w4) - 1)), y = q >> l2w4;
  int32_t acc[4] = {0, 0, 0, 0};
  for (u32 ky = 0; ky < 3; ++ky)
    for (u32 c = 0; c < Cw; ++c) {
      const u32* xr = X + ((y + ky) * Cw + c) * Wp + x;      // X(y+ky, c, x)
      const u32* wr = Wt + ((ky * Cw + c) * 3) * Cout + o;    // Wt[ky][c][0][o]
      u32 w0 = wr[0], w1 = wr[Cout], w2 = wr[2 * Cout];
      u32 a0 = xr[0], a1 = xr[1], a2 = xr[2], a3 = xr[3], a4 = xr[4], a5 = xr[5];
      acc[0] += dot8(a0, w0) + dot8(a1, w1) + dot8(a2, w2);
      acc[1] += dot8(a1, w0) + dot8(a2, w1) + dot8(a3, w2);
      acc[2] += dot8(a2, w0) + dot8(a3, w1) + dot8(a4, w2);
      acc[3] += dot8(a3, w0) + dot8(a4, w1) + dot8(a5, w2);
    }
  float scale = f32(p[6]), zp = f32(p[7]);
  uint8_t* ob = Out + 4 * (((y + 1) * (Cout >> 2) + (o >> 2)) * Wp + x + 1) + (o & 3);
  for (u32 j = 0; j < 4; ++j)
    ob[4 * j] = requant8(acc[j], scale, zp);
}

// Embedding bag (embag.S): out[b][d] = T[idx[b][0]][d] + ... in order k = 0..K-1 from +0.
static void embag(const u32* p, u32 t) {
  const float* T = at<const float>(p[0]);
  const u32* idx = at<const u32>(p[1]);
  float* out = at<float>(p[2]);
  u32 K = p[3], l2d = p[4], d = t & ((1u << l2d) - 1), b = t >> l2d;
  const u32* ib = idx + b * K;
  float acc = 0.0f;
  for (u32 k = 0; k < K; ++k)
    acc = acc + T[(ib[k] << l2d) + d];
  out[t] = acc;
}

// Hash-join probe (hashj.S): linear probing in 2^s slots {key, value}, key 0 = empty.
static void hashj(const u32* p, u32 t) {
  const u32* slot = at<const u32>(p[0]);
  u32 key = at<const u32>(p[1])[t], sh = p[3], mask = p[4];
  u32 h = (key * 0x9E3779B1u) >> sh;
  while (slot[2 * h] != key && slot[2 * h] != 0)
    h = (h + 1) & mask;
  at<u32>(p[2])[t] = (slot[2 * h] == key) ? slot[2 * h + 1] : 0xFFFFFFFFu;
}

// Mandelbrot escape count (mandel.S), every FP operation rounded once.
static void mandel(const u32* p, u32 t) {
  u32 l2w = p[1], M = p[6];
  float x0 = f32(p[2]), y0 = f32(p[3]), dx = f32(p[4]), dy = f32(p[5]);
  float cr = __builtin_fmaf((float)(t & ((1u << l2w) - 1)), dx, x0);
  float ci = __builtin_fmaf((float)(t >> l2w), dy, y0);
  float zr = 0.0f, zi = 0.0f;
  u32 n = 0;
  int esc;
  do {
    float zr2 = zr * zr, zi2 = zi * zi;
    esc = (zr2 + zi2) > 4.0f;
    zi = __builtin_fmaf(zr * zi, 2.0f, ci);
    zr = (zr2 - zi2) + cr;
    ++n;
  } while (!esc && n < M);
  at<u32>(p[0])[t] = n;
}

// Smith-Waterman score (swat.S), affine gaps, one pair per thread. The query in strips
// of 4 rows (H and E of the strip in registers) against the whole target; the strip's
// last row (H << 16 | F) goes to the boundary word B[j][p] that the next strip reads.
static void swat(const u32* p, u32 t) {
  const int32_t NEG = -16384;
  const u32* T = at<const u32>(p[0]);
  const u32* Q = at<const u32>(p[1]);
  u32* B = at<u32>(p[2]);
  u32 Lt = p[4], S = p[5], stride = p[6] >> 2;            // words between [j][p] and [j+1][p]
  int32_t best = 0;
  for (u32 s = 0; s < S; ++s) {
    u32 qw = Q[s * stride + t];
    u32 q0 = qw & 3, q1 = (qw >> 2) & 3, q2 = (qw >> 4) & 3, q3 = (qw >> 6) & 3;
    int32_t h0 = 0, h1 = 0, h2 = 0, h3 = 0, e0 = NEG, e1 = NEG, e2 = NEG, e3 = NEG;
    int32_t bprev = 0;                                     // H[4s-1][j-1]
    for (u32 j = 0; j < Lt; ++j) {
      u32 tc = T[j * stride + t] & 3;
      int32_t hup = 0, f = NEG;
      if (s) { u32 bw = B[j * stride + t]; hup = (int32_t)bw >> 16; f = (int16_t)(bw & 0xFFFF); }
      int32_t diag = bprev;
      bprev = hup;
#define SW_ROW(h, e, qc) { \
        e = imax(e - 1, h - 3); \
        f = imax(f - 1, hup - 3); \
        int32_t hv = diag + ((qc) == tc ? 2 : -1); \
        hv = imax(imax(hv, 0), imax(e, f)); \
        diag = h; h = hv; hup = hv; best = imax(best, hv); }
      SW_ROW(h0, e0, q0) SW_ROW(h1, e1, q1) SW_ROW(h2, e2, q2) SW_ROW(h3, e3, q3)
#undef SW_ROW
      B[j * stride + t] = ((u32)hup << 16) | ((u32)f & 0xFFFFu);
    }
  }
  at<u32>(p[3])[t] = (u32)best;
}

// ── Rodinia (docs/rodinia_plan.md): ports of kernels/suite2 and kernels/rodinia ──

// pathfinder.S: dst[c] = wall[c] + min(src[c-1], src[c], src[c+1]); rows padded with
// one INT_MAX word per side (element c at word c+1).
static void pathfinder(const u32* p, u32 c) {
  const int32_t* src = at<const int32_t>(p[0]);
  int32_t* dst = at<int32_t>(p[1]);
  const int32_t* wall = at<const int32_t>(p[2]);
  int32_t m = src[c] < src[c + 1] ? src[c] : src[c + 1];
  m = m < src[c + 2] ? m : src[c + 2];
  dst[c + 1] = m + wall[c];
}

// bp_forward.S: ps[t] = fma(w[16b+15][j], in[16b+15], ... fma(w[16b][j], in[16b], +0)),
// j = t & 15, b = t >> 4, w is N x 16 row-major.
static void bp_forward(const u32* p, u32 t) {
  const float* in = at<const float>(p[0]) + 16 * (t >> 4);
  const float* w = at<const float>(p[1]) + 256 * (t >> 4) + (t & 15);
  float acc = 0.0f;
  for (u32 i = 0; i < 16; ++i)
    acc = __builtin_fmaf(w[16 * i], in[i], acc);
  at<float>(p[2])[t] = acc;
}

// bp_adjust.S: dw = fma(ed[j], in[i], m * ow[t]); w[t] = w[t] + dw; ow[t] = dw,
// i = t >> 4, j = t & 15.
static void bp_adjust(const u32* p, u32 t) {
  const float* in = at<const float>(p[0]);
  float* w = at<float>(p[1]);
  float* ow = at<float>(p[2]);
  const float* ed = at<const float>(p[3]);
  float m = f32(p[4]);
  float dw = __builtin_fmaf(ed[t & 15], in[t >> 4], m * ow[t]);
  w[t] = w[t] + dw;
  ow[t] = dw;
}

// hotspot_rd.S: one step on an n x n grid, every cell, clamped neighbours:
// a = (tN + tS) - (t + t); b = (tE + tW) - (t + t); c = amb - t;
// s = fma(a, ry1, p); s = fma(b, rx1, s); s = fma(c, rz1, s); out = fma(sdc, s, t).
static void hotspot_rd(const u32* p, u32 t) {
  const float* in = at<const float>(p[0]);
  float* out = at<float>(p[1]);
  const float* pw = at<const float>(p[2]);
  u32 l2n = p[3], n1 = (1u << l2n) - 1;
  float rx1 = f32(p[4]), ry1 = f32(p[5]), rz1 = f32(p[6]), amb = f32(p[7]), sdc = f32(p[8]);
  u32 i = t >> l2n, j = t & n1;
  u32 iN = i ? i - 1 : 0, iS = i < n1 ? i + 1 : n1, jW = j ? j - 1 : 0, jE = j < n1 ? j + 1 : n1;
  float tt = in[t], t2 = tt + tt;
  float a = (in[(iN << l2n) + j] + in[(iS << l2n) + j]) - t2;
  float b = (in[(i << l2n) + jE] + in[(i << l2n) + jW]) - t2;
  float c = amb - tt;
  float s = __builtin_fmaf(a, ry1, pw[t]);
  s = __builtin_fmaf(b, rx1, s);
  s = __builtin_fmaf(c, rz1, s);
  out[t] = __builtin_fmaf(sdc, s, tt);
}

// nn.S: dist[t] = sqrt(dx*dx + dy*dy), dx = lat - loc[t].lat, dy = lng - loc[t].lng,
// every operation rounded once (-ffp-contract=off; sqrtf is fsqrt.s).
static void nn(const u32* p, u32 t) {
  const float* loc = at<const float>(p[0]);
  float dx = f32(p[2]) - loc[2 * t], dy = f32(p[3]) - loc[2 * t + 1];
  float s = dx * dx;
  s = s + dy * dy;
  at<float>(p[1])[t] = __builtin_sqrtf(s);
}

// hotspot3d.S: thread t owns column (i, j) and walks its nz layers; clamped neighbours;
// s = cc*t, then fma(ce,tW) fma(ce,tE) fma(cn,tS) fma(cn,tN) fma(ct,tB) fma(ct,tT)
// fma(sdc,p) fma(ct,amb), in that order.
static void hotspot3d(const u32* p, u32 t) {
  const float* in = at<const float>(p[0]);
  float* out = at<float>(p[1]);
  const float* pw = at<const float>(p[2]);
  u32 l2 = p[3], nz = p[4], n1 = (1u << l2) - 1, xy = 1u << (2 * l2);
  float cc = f32(p[5]), ce = f32(p[6]), cn = f32(p[7]), ct = f32(p[8]), sdc = f32(p[9]), amb = f32(p[10]);
  u32 i = t & n1, j = t >> l2;
  int oW = i ? -1 : 0, oE = i < n1 ? 1 : 0, oN = j ? -(int)(n1 + 1) : 0, oS = j < n1 ? (int)(n1 + 1) : 0;
  float t1 = in[t], t2 = t1, t3 = in[t + xy];
  for (u32 z = 0, c = t; z < nz; ++z, c += xy) {
    if (z) { t1 = t2; t2 = t3; if (z + 1 < nz) t3 = in[c + xy]; }
    float s = cc * t2;
    s = __builtin_fmaf(ce, in[c + oW], s);
    s = __builtin_fmaf(ce, in[c + oE], s);
    s = __builtin_fmaf(cn, in[c + oS], s);
    s = __builtin_fmaf(cn, in[c + oN], s);
    s = __builtin_fmaf(ct, t1, s);
    s = __builtin_fmaf(ct, t3, s);
    s = __builtin_fmaf(sdc, pw[c], s);
    out[c] = __builtin_fmaf(ct, amb, s);
  }
}

// gauss_fan1.S: row i = t + 1 + u of the augmented n x (n+1) matrix a:
// m[i][t] = a[i][t] / a[t][t].
static void gauss_fan1(const u32* p, u32 u) {
  const float* a = at<const float>(p[0]);
  float* m = at<float>(p[1]);
  u32 n = p[2], t = p[3], s = n + 1, i = t + 1 + u;
  m[i * n + t] = a[i * s + t] / a[t * s + t];
}

// gauss_fan2.S: column j = t + u (t .. n, b is column n), rows t+1 .. n-1:
// a[i][j] = fma(-m[i][t], a[t][j], a[i][j]).
static void gauss_fan2(const u32* p, u32 u) {
  float* a = at<float>(p[0]);
  const float* m = at<const float>(p[1]);
  u32 n = p[2], t = p[3], s = n + 1, j = t + u;
  float atj = a[t * s + j];
  for (u32 i = t + 1; i < n; ++i)
    a[i * s + j] = __builtin_fmaf(-m[i * n + t], atj, a[i * s + j]);
}

// kmeans_rd.S: point t on feature-major features f[j*n + t]: ans = fma(d, d, ans) over the
// features, the first strictly smaller distance wins.
static void kmeans_rd(const u32* p, u32 t) {
  const float* f = at<const float>(p[0]) + t;
  const float* c = at<const float>(p[1]);
  u32 n = p[3], k = p[4], nf = p[5], idx = 0;
  float best = f32(0x7f7fffffu);
  for (u32 i = 0; i < k; ++i) {
    float ans = 0.0f;
    for (u32 j = 0; j < nf; ++j) {
      float d = f[j * n] - c[i * nf + j];
      ans = __builtin_fmaf(d, d, ans);
    }
    if (ans < best) { best = ans; idx = i; }
  }
  at<u32>(p[2])[t] = idx;
}

// ── RiVEC batch 1 (docs/rivec_plan.md, kernels/rivec/*.S): the per-element work calls
// kernels/rivec/rv_ref.h (run_apps.sh copies it here), the code the A53 and CVA6 run;
// matmul, spmv and pathfinder use gemm, spmv and pathfinder above.
#include "rv_ref.h"

// axpy_rv.S: dy[t] = fma(a, dx[t], dy[t])
static void axpy_rv(const u32* p, u32 t) {
  float* dy = at<float>(p[1]);
  dy[t] = __builtin_fmaf(f32(p[2]), at<const float>(p[0])[t], dy[t]);
}

// jacobi_rv.S: n x n (n = 2^p[2]), interior points only, RiVEC's vector order:
// B = (((c + left) + right) + (bottom + top)) * 0.2f
static void jacobi_rv(const u32* p, u32 t) {
  const float* A = at<const float>(p[0]);
  float* B = at<float>(p[1]);
  u32 l2n = p[2], n = 1u << l2n, i = t >> l2n, j = t & (n - 1);
  if (i - 1 >= n - 2 || j - 1 >= n - 2) return;              // border (unsigned)
  float u = A[t] + A[t - 1];
  u = u + A[t + 1];
  float v = A[t + n] + A[t - n];
  B[t] = (u + v) * f32(p[3]);
}

// bs_rv.S: one option, rv_ref.h rv_blackscholes (its constants are the table of p[7])
static void bs_rv(const u32* p, u32 t) {
  rv_blackscholes(1, at<const float>(p[0]) + t, at<const float>(p[1]) + t, at<const float>(p[2]) + t,
                  at<const float>(p[3]) + t, at<const float>(p[4]) + t, at<const int32_t>(p[5]) + t,
                  at<float>(p[6]) + t);
}

// lavamd_rv.S: particle t of home box t / 96, the home box and then its neighbours in
// RiVEC's order, 96 particles each, rv_ref.h rv_lavamd's operations for one particle.
static void lavamd_rv(const u32* p, u32 t) {
  const float* rv = at<const float>(p[0]);
  const float* qv = at<const float>(p[1]);
  float* fA = at<float>(p[2]) + 4 * t;
  const u32* nn = at<const u32>(p[3]);
  const u32* nei = at<const u32>(p[4]);
  float a2 = f32(p[5]);
  u32 l = t / RV_LAVA_NP;
  const float Av = rv[4 * t], Ax = rv[4 * t + 1], Ay = rv[4 * t + 2], Az = rv[4 * t + 3];
  float fv = fA[0], fx = fA[1], fy = fA[2], fz = fA[3];
  for (u32 k = 0; k < 1 + nn[l]; k++) {
    u32 pb = k ? nei[l * 26 + k - 1] : l;
    const float* rB = rv + 4 * pb * RV_LAVA_NP;
    const float* qB = qv + pb * RV_LAVA_NP;
    for (u32 j = 0; j < RV_LAVA_NP; j++) {
      float Bv = rB[4 * j], Bx = rB[4 * j + 1], By = rB[4 * j + 2], Bz = rB[4 * j + 3];
      float r2 = Bv + Av;
      float dot = Bx * Ax;
      dot = __builtin_fmaf(Ay, By, dot);
      dot = __builtin_fmaf(Az, Bz, dot);
      r2 = r2 - dot;
      float u2 = r2 * a2;
      float vij = rv_exp(-u2);
      float fs = 2.0f * vij;
      float dx = Ax - Bx, dy = Ay - By, dz = Az - Bz;
      float q = qB[j];
      fv = __builtin_fmaf(q, vij, fv);
      fx = __builtin_fmaf(q, fs * dx, fx);
      fy = __builtin_fmaf(q, fs * dy, fy);
      fz = __builtin_fmaf(q, fs * dz, fz);
    }
  }
  fA[0] = fv; fA[1] = fx; fA[2] = fy; fA[3] = fz;
}

__kernel void kernel_main(kernel_arg_t* __UNIFORM__ arg) {
  u32 t = blockIdx.x * blockDim.x + threadIdx.x;
  const u32* p = at<const u32>(arg->params);
  if (arg->app == APP_SCAN) {        // whole blocks only: every thread reaches the barrier
    scan(p, t);
    return;
  }
  if (t >= arg->threads)
    return;
  switch (arg->app) {
  case APP_GEMM:     gemm(p, t);     break;
  case APP_SPMV:     spmv(p, t);     break;
  case APP_STENCIL:  stencil(p, t);  break;
  case APP_KMEANS:   kmeans(p, t);   break;
  case APP_BFS:      bfs(p, t);      break;
  case APP_SCAN_ADD: scan_add(p, t); break;
  case APP_MLP:      mlp(p, t);      break;
  case APP_CONV8:    conv8(p, t);    break;
  case APP_EMBAG:    embag(p, t);    break;
  case APP_HASHJ:    hashj(p, t);    break;
  case APP_MANDEL:   mandel(p, t);   break;
  case APP_SWAT:     swat(p, t);     break;
  case APP_PATHFINDER: pathfinder(p, t); break;
  case APP_BP_FORWARD: bp_forward(p, t); break;
  case APP_BP_ADJUST:  bp_adjust(p, t);  break;
  case APP_HOTSPOT_RD: hotspot_rd(p, t); break;
  case APP_NN:         nn(p, t);         break;
  case APP_HOTSPOT3D:  hotspot3d(p, t);  break;
  case APP_GAUSS_FAN1: gauss_fan1(p, t); break;
  case APP_GAUSS_FAN2: gauss_fan2(p, t); break;
  case APP_KMEANS_RD:  kmeans_rd(p, t);  break;
  case APP_AXPY_RV:    axpy_rv(p, t);    break;
  case APP_JACOBI_RV:  jacobi_rv(p, t);  break;
  case APP_BS_RV:      bs_rv(p, t);      break;
  case APP_LAVAMD_RV:  lavamd_rv(p, t);  break;
  default: break;
  }
}
