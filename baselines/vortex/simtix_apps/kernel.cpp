// SIMTiX application suite on Vortex: the eight kernels of kernels/apps/*.S, one thread
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

// C = A * B, thread t computes C[t]: acc = fmadd(A[row][k], B[k][col], acc).
static void gemm(const u32* p, u32 t) {
  const float* A = at<const float>(p[0]);
  const float* B = at<const float>(p[1]);
  float* C = at<float>(p[2]);
  u32 K = p[3], l2n = p[4], n = 1u << l2n;
  const float* a = A + (t >> l2n) * K;
  const float* b = B + (t & (n - 1));
  float acc = 0.0f;
  for (u32 k = 0; k < K; ++k)
    acc = __builtin_fmaf(a[k], b[k * n], acc);
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
  for (u32 kk = 0; kk < Kp; ++kk) {
    u32 xa = x[kk], wa = w[kk * np];
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
  default: break;
  }
}
