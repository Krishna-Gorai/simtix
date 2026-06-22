// fpu_ref.c  -  DPI-C IEEE-754 reference for tb_fpu.sv (FP32 + FP16).
// Verilator promotes SystemVerilog `shortreal` to `real` (double), so it cannot
// produce true FP32 results; these helpers use the host's real `float` hardware
// (round-to-nearest-even) and exchange raw bit patterns with the testbench.
//
// FP16 (half) is referenced WITHOUT relying on the host `_Float16` type (not
// portable to every CI toolchain): half operands are widened to `double` (exact),
// the operation is done in double (exact for the sum/product of half-range values),
// and the result is rounded back to 16 bits with an explicit round-to-nearest-even
// narrower that mirrors the engine's FTZ policy (subnormal -> 0, overflow -> inf).
#include <stdint.h>
#include <string.h>
#include <math.h>

// Verilator compiles user sources with its C++ toolchain, so give these C linkage
// to match the DPI import wrappers (which expect unmangled `extern "C"` symbols).
#ifdef __cplusplus
extern "C" {
#endif

static float    b2f(uint32_t b) { float f;    memcpy(&f, &b, 4); return f; }
static uint32_t f2b(float f)    { uint32_t b; memcpy(&b, &f, 4); return b; }

uint32_t ref_add(uint32_t a, uint32_t b) { return f2b(b2f(a) + b2f(b)); }
uint32_t ref_sub(uint32_t a, uint32_t b) { return f2b(b2f(a) - b2f(b)); }
uint32_t ref_mul(uint32_t a, uint32_t b) { return f2b(b2f(a) * b2f(b)); }

// FP32 fused multiply-add, single rounding (host fmaf). np/nc negate product/addend
// to cover fmadd/fmsub/fnmsub/fnmadd.  flush-to-zero is applied to a result that
// underflows to a subnormal, matching the engine's FTZ policy.
static uint32_t ftz32(uint32_t x) {
    if (((x >> 23) & 0xff) == 0) return x & 0x80000000u;   // subnormal/zero -> signed 0
    return x;
}
uint32_t ref_fmaf(uint32_t a, uint32_t b, uint32_t c, int np, int nc) {
    float fa = b2f(a), fb = b2f(b), fc = b2f(c);
    if (np) fa = -fa;                       // negate one product factor = negate product
    if (nc) fc = -fc;
    float z = fmaf(fa, fb, fc);
    if (z != z) return 0x7fc00000u;         // RISC-V canonical qNaN (host NaN sign varies)
    return ftz32(f2b(z));
}

// int32 -> float (RNE) and uint32 -> float (RNE)
uint32_t ref_cvt_sw (uint32_t x) { return f2b((float)(int32_t)x);  }
uint32_t ref_cvt_swu(uint32_t x) { return f2b((float)(uint32_t)x); }

// float -> int32 (truncate toward zero, C cast semantics)
uint32_t ref_cvt_ws (uint32_t a) { return (uint32_t)(int32_t)b2f(a); }

// ── FP16 helpers ─────────────────────────────────────────────────────────────
// half bits -> double (exact value; FTZ subnormal input -> signed zero)
static double h2d(uint16_t h) {
    uint16_t s = (h >> 15) & 1, e = (h >> 10) & 0x1f, m = h & 0x3ff;
    if (e == 0x1f) return m ? (s ? -NAN : NAN) : (s ? -INFINITY : INFINITY);
    if (e == 0)    return s ? -0.0 : 0.0;                    // zero / subnormal (FTZ)
    double v = ldexp(1.0 + (double)m / 1024.0, (int)e - 15); // exact
    return s ? -v : v;
}

// double -> half bits (RNE; FTZ subnormal result -> 0; overflow -> inf). Inputs are
// always normal doubles or zero/inf/nan in this reference's usage.
static uint16_t d2h(double v) {
    uint64_t db;
    memcpy(&db, &v, 8);
    uint16_t s = (uint16_t)((db >> 63) & 1);
    if (isnan(v)) return 0x7e00;                       // canonical FP16 qNaN
    if (isinf(v)) return (uint16_t)((s << 15) | 0x7c00);
    if (v == 0.0) return (uint16_t)(s << 15);
    int e = (int)((db >> 52) & 0x7ff) - 1023;          // unbiased exponent (normal double)
    uint64_t sig = (1ULL << 52) | (db & 0xfffffffffffffULL); // 1.frac, hidden at bit 52
    if (e > 15)  return (uint16_t)((s << 15) | 0x7c00);     // overflow -> inf
    if (e < -14) return (uint16_t)(s << 15);                // FP16-subnormal -> FTZ 0
    uint16_t top = (uint16_t)((sig >> 42) & 0x7ff);    // 11 bits: hidden + top 10
    int g  = (int)((sig >> 41) & 1);
    int r  = (int)((sig >> 40) & 1);
    int st = (sig & ((1ULL << 40) - 1)) != 0;
    uint16_t rounded = (uint16_t)(top + ((g && (r || st || (top & 1))) ? 1 : 0));
    int e16 = e + 15;
    if (rounded & 0x800) e16++;                        // significand carried out
    if (e16 > 30) return (uint16_t)((s << 15) | 0x7c00);    // rounded up to inf
    return (uint16_t)((s << 15) | ((e16 & 0x1f) << 10) | (rounded & 0x3ff));
}

uint32_t ref_hadd(uint32_t a, uint32_t b) { return d2h(h2d((uint16_t)a) + h2d((uint16_t)b)); }
uint32_t ref_hsub(uint32_t a, uint32_t b) { return d2h(h2d((uint16_t)a) - h2d((uint16_t)b)); }
uint32_t ref_hmul(uint32_t a, uint32_t b) { return d2h(h2d((uint16_t)a) * h2d((uint16_t)b)); }

// FP16 fused multiply-add: compute a*b+c with ONE rounding to double (host fma,
// which is exact for these small operands), then narrow once to FP16. Double
// rounding exact->double(53)->half(11) is innocuous (53 >= 2*11+2), so this equals
// a true half-precision fused FMA, matching the engine's widen-fuse-narrow path.
uint32_t ref_hfma(uint32_t a, uint32_t b, uint32_t c, int np, int nc) {
    double da = h2d((uint16_t)a), db = h2d((uint16_t)b), dc = h2d((uint16_t)c);
    if (np) da = -da;
    if (nc) dc = -dc;
    return d2h(fma(da, db, dc));
}

// half -> FP32 (exact widen; NaN/inf canonicalised to match the engine)
uint32_t ref_cvt_sh(uint32_t h) {
    uint16_t x = (uint16_t)h, e = (x >> 10) & 0x1f, m = x & 0x3ff, s = (x >> 15) & 1;
    if (e == 0x1f) return m ? 0x7fc00000u : (s ? 0xff800000u : 0x7f800000u);
    return f2b((float)h2d(x));
}
// FP32 -> half (narrow, RNE, FTZ)
uint32_t ref_cvt_hs(uint32_t a) { return d2h((double)b2f(a)); }
// half -> int32 (RTZ) and int32 -> half (RNE) via the FP32 references
uint32_t ref_cvt_wh(uint32_t h) { return ref_cvt_ws(ref_cvt_sh(h)); }
uint32_t ref_cvt_hw(uint32_t x) { return ref_cvt_hs(ref_cvt_sw(x)); }

#ifdef __cplusplus
}
#endif
