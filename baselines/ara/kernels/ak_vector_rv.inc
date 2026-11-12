/*
 * ak_vector_rv.inc - RiVEC batch 1 for Ara (docs/rivec_plan.md), included by ak_vector.c.
 *
 * The user's decision (2026-11-11): Ara runs RiVEC's OWN vector code, changed only where
 * Ara has a hardware bug, for FP32, or for bare-metal input and output. Each function below
 * is RiVEC's (master 32a14ddf; file and function named in its comment), with its _MM_
 * macros from RiVEC's common/vector_defines.h (copied to rivec/, licences in
 * rivec/LICENSES.txt). Every change is marked "CHANGE:" with its reason:
 *   FP32        double -> float, e64/f64 -> e32/f32 (SIMTiX and Vortex have no FP64)
 *   bare metal  arrays and sizes from the mailbox arguments instead of files and malloc;
 *               2-D row-pointer arrays become one contiguous array
 *   Ara         a restriction of ak_vector.c's header (item number given)
 * The results are checked against kernels/rivec/rv_ref.h (the CVA6 scalar versions):
 * exactly where RiVEC's vector code computes per element, within a tolerance where it
 * keeps partial sums per element and reduces them (spmv, lavaMD).
 */

/* RiVEC's headers define their exp, log and cos as C99 `inline` functions, which emit no
   out-of-line copy under -std=gnu11: made `static inline` for this inclusion only. */
#define USE_RISCV_VECTOR
#define inline static inline
#include "rivec/vector_defines.h"
#undef inline

/* ── axpy: RiVEC _axpy/src/axpy.c axpy_vector ──────────────────────────────────────── */
/* a = dx dy a n */
static void v_rv_axpy(const uint32_t *a)
{
    float *dx = AKP(float, a[0]), *dy = AKP(float, a[1]);   /* CHANGE: bare metal */
    const float aa = ak_f(a[2]);                            /* CHANGE: FP32 (double a) */
    const int n = (int)a[3];
    int i;
    long gvl = _MMR_VSETVL_E32M1(n);                         /* CHANGE: FP32 (E64M1) */
    for (i = 0; i < n;) {
        gvl = _MMR_VSETVL_E32M1(n - i);
        vfloat32m1_t v_dx = _MM_LOAD_f32(&dx[i], gvl);
        vfloat32m1_t v_dy = _MM_LOAD_f32(&dy[i], gvl);
        vfloat32m1_t v_res = _MM_MACC_VF_f32(v_dy, aa, v_dx, gvl);
        _MM_STORE_f32(&dy[i], v_res, gvl);
        i += gvl;
    }
}

/* ── matmul: RiVEC _matmul/src/matmul.c matrixmul_intrinsics ─────────────────────── */
/* a = A B C m n p   (C m x n = A m x p * B p x n) */
static void v_rv_matmul(const uint32_t *a)
{
    float *pa = AKP(float, a[0]), *pb = AKP(float, a[1]), *pc = AKP(float, a[2]);   /* CHANGE: bare metal */
    const size_t m = a[3], n = a[4], p = a[5];
    for (size_t i = 0; i < m; i++) {
        for (size_t j = 0; j < n; j++) {
            size_t gvl = _MMR_VSETVL_E32M1(p);              /* CHANGE: FP32 */
            vfloat32m1_t vprod = _MM_SET_f32(0, gvl);
            vfloat32m1_t vsum  = _MM_SET_f32(0, gvl);
            for (size_t k = 0; k < p; k += gvl) {
                gvl = _MMR_VSETVL_E32M1(p - k);
                vfloat32m1_t va = _MM_LOAD_f32(&pa[i * p + k], gvl);
                vfloat32m1_t vb = _MM_LOAD_STRIDE_f32(&pb[k * n + j], n * sizeof(float), gvl);
                vprod = _MM_MACC_f32(vprod, va, vb, gvl);
            }
            gvl = _MMR_VSETVL_E32M1(p);
            vsum = _MM_REDSUM_f32(vprod, vsum, gvl);
            pc[i * n + j] = _MM_VGETFIRST_f32(vsum);
        }
    }
}

/* ── spmv: RiVEC _spmv/src/spmv.c spmv_intrinsics ────────────────────────────────── */
/* CHANGE: Ara item 4 (an indexed load must not write its own index register): the
   gather is this early-clobber form of RiVEC's _MM_LOAD_INDEX. */
static inline vfloat32m1_t rv_gather_f32(const float *base, vuint32m1_t off, size_t vl)
{
    vfloat32m1_t r;
    __asm__ volatile("vsetvli zero, %[vl], e32, m1, ta, ma\n\t"
                     "vluxei32.v %[r], (%[b]), %[o]"
                     : [r] "=&vr"(r)
                     : [o] "vr"(off), [b] "r"(base), [vl] "r"(vl)
                     : "memory", "vl", "vtype");
    return r;
}
/* a = ia ja val x y nrows (CSR of the transpose, 0-based: docs/rivec_plan.md, spmv) */
static void v_rv_spmv(const uint32_t *a)
{
    const uint32_t *ia = AKP(const uint32_t, a[0]), *ja = AKP(const uint32_t, a[1]);  /* CHANGE: bare metal; */
    const float *va = AKP(const float, a[2]), *x = AKP(const float, a[3]);           /*   32-bit indices (FP32: */
    float *y = AKP(float, a[4]);                                                      /*   e64 indices need LMUL 2) */
    const size_t nrows = a[5];
    vfloat32m1_t vprod, vx, vav, part_res;
    vuint32m1_t v_idx_row;
    for (size_t row = 0; row < nrows; row++) {
        int64_t nnz_row = ia[row + 1] - ia[row];
        int64_t idx = ia[row];
        if (nnz_row == 0) {
            y[row] = 0;
        } else {
            size_t gvl = _MMR_VSETVL_E32M1(nnz_row);
            vprod = _MM_SET_f32(0.0, gvl);
            part_res = _MM_SET_f32(0.0, 1);
            for (size_t colid = 0; colid < (size_t)nnz_row; colid += gvl) {
                gvl = _MMR_VSETVL_E32M1(nnz_row - colid);
                vav = _MM_LOAD_f32(&va[idx + colid], gvl);
                v_idx_row = _MM_LOAD_u32(&ja[idx + colid], gvl);
                v_idx_row = _MM_SLL_VX_u32(v_idx_row, 2, gvl);   /* CHANGE: 4-byte elements (was 3) */
                vx = rv_gather_f32(x, v_idx_row, gvl);            /* CHANGE: Ara item 4 */
                vprod = _MM_MACC_f32(vprod, vav, vx, gvl);
            }
            gvl = _MMR_VSETVL_E32M1(nnz_row);
            part_res = _MM_REDSUM_f32(vprod, part_res, gvl);
            y[row] = _MM_VGETFIRST_f32(part_res);
        }
    }
}

/* ── jacobi-2d: RiVEC _jacobi-2d/src/jacobi-2d.cpp kernel_jacobi_2d_vector ────────── */
/* CHANGE: bare metal: A[i][j] is A[i*n + j] (RiVEC allocates rows separately). */
static void rv_jacobi_vector(int n, float *A, float *B)
{
    vfloat32m1_t xU, xUtmp, xUtmp2, xUleft, xUright, xUtop, xUbottom, xConstant;
    float izq, der;
    int size_y = n - 2;
    int size_x = n - 2;
    unsigned long int gvl = _MMR_VSETVL_E32M1(size_y);
    xConstant = _MM_SET_f32(0.20f, gvl);
    for (int j = 1; j <= size_x; j = j + gvl) {
        gvl = _MMR_VSETVL_E32M1(size_y - j + 1);
        xUtop = _MM_LOAD_f32(&A[0 * n + j], gvl);
        xU = _MM_LOAD_f32(&A[1 * n + j], gvl);
        xUbottom = _MM_LOAD_f32(&A[2 * n + j], gvl);
        for (int i = 1; i <= size_y; i++) {
            if (i != 1) {
                xUtop = xU;
                xU = xUbottom;
                xUbottom = _MM_LOAD_f32(&A[(i + 1) * n + j], gvl);
            }
            izq = A[i * n + j - 1];
            der = A[i * n + j + gvl];
            xUleft = _MM_VSLIDE1UP_f32(xU, izq, gvl);
            xUright = _MM_VSLIDE1DOWN_f32(xU, der, gvl);
            xUtmp = _MM_ADD_f32(xU, xUleft, gvl);
            xUtmp = _MM_ADD_f32(xUtmp, xUright, gvl);
            xUtmp2 = _MM_ADD_f32(xUbottom, xUtop, gvl);
            xUtmp = _MM_ADD_f32(xUtmp, xUtmp2, gvl);
            xUtmp = _MM_MUL_f32(xUtmp, xConstant, gvl);
            _MM_STORE_f32(&B[i * n + j], xUtmp, gvl);
        }
    }
}
/* a = A B n tsteps   (RiVEC kernel_jacobi_2d: tsteps x (A -> B, B -> A)) */
static void v_rv_jacobi(const uint32_t *a)
{
    float *A = AKP(float, a[0]), *B = AKP(float, a[1]);
    const int n = (int)a[2], tsteps = (int)a[3];
    for (int t = 0; t < tsteps; t++) {
        rv_jacobi_vector(n, A, B);
        FENCE();                       /* CHANGE: Ara (header, Ordering): scalar izq/der read the sweep's stores */
        rv_jacobi_vector(n, B, A);
        FENCE();
    }
}

/* ── pathfinder: RiVEC _pathfinder/src/pathfinder.cpp run_vector ──────────────────── */
/* a = wall dst tmp rows cols runs (the result in dst; tmp is the scalar version's) */
static void v_rv_pathfinder(const uint32_t *a)
{
    const int *wall = AKP(const int, a[0]);                 /* CHANGE: bare metal */
    int *dst = AKP(int, a[1]);
    const size_t rows = a[3], cols = a[4], runs = a[5];
    vint32m1_t xSrc_slideup, xSrc_slidedown, xSrc, xNextrow;
    int aux, aux2;
    for (size_t r = 0; r < runs; r++) {                     /* RiVEC: NUM_RUNS */
        for (size_t x = 0; x < cols; x++)
            dst[x] = wall[x];
        unsigned long int gvl = __riscv_vsetvl_e32m1(cols);
        for (size_t t = 0; t < rows - 1; t++) {
            FENCE();                   /* CHANGE: Ara (header, Ordering): aux/aux2 read the last row's stores */
            aux = dst[0];
            for (size_t n = 0; n < cols; n = n + gvl) {
                gvl = __riscv_vsetvl_e32m1(cols - n);
                xNextrow = _MM_LOAD_i32(&dst[n], gvl);
                xSrc = xNextrow;
                aux2 = (n + gvl >= cols) ? dst[n + gvl - 1] : dst[n + gvl];
                xSrc_slideup = _MM_VSLIDE1UP_i32(xSrc, aux, gvl);
                xSrc_slidedown = _MM_VSLIDE1DOWN_i32(xSrc, aux2, gvl);
                xSrc = _MM_MIN_i32(xSrc, xSrc_slideup, gvl);
                xSrc = _MM_MIN_i32(xSrc, xSrc_slidedown, gvl);
                xNextrow = _MM_LOAD_i32(&wall[(t + 1) * cols + n], gvl);
                xNextrow = _MM_ADD_i32(xNextrow, xSrc, gvl);
                aux = dst[n + gvl - 1];
                _MM_STORE_i32(&dst[n], xNextrow, gvl);
            }
        }
        FENCE();
    }
}

/* ── blackscholes: RiVEC _blackscholes/src/blackscholes.cpp CNDF_SIMD and
      BlkSchlsEqEuroNoDiv_vector (fptype is float there already) ──────────────────── */
typedef float fptype;
#define inv_sqrt_2xPI 0.39894228040143270286

static vfloat32m1_t CNDF_SIMD(vfloat32m1_t xInput, unsigned long int gvl)
{
    vfloat32m1_t xNPrimeofX, xK2, xK2_2, xK2_3, xK2_4, xK2_5, xLocal, xLocal_1, xLocal_2, xLocal_3;
    vfloat32m1_t xVLocal_2, expValues;
    vbool32_t xMask;
    vfloat32m1_t xOne = _MM_SET_f32(1.0, gvl);
    (void)xLocal_3;
    xVLocal_2 = _MM_SET_f32(0.0, gvl);
    xMask = _MM_VFLT_f32(xInput, xVLocal_2, gvl);
    xInput = _MM_VFSGNJX_f32(xInput, xInput, gvl);
    expValues = _MM_MUL_f32(xInput, xInput, gvl);
    expValues = _MM_MUL_f32(expValues, _MM_SET_f32(-0.5, gvl), gvl);
    xNPrimeofX = _MM_EXP_f32(expValues, gvl);
    xNPrimeofX = _MM_MUL_f32(xNPrimeofX, _MM_SET_f32(inv_sqrt_2xPI, gvl), gvl);
    xK2 = _MM_MADD_f32(_MM_SET_f32(0.2316419, gvl), xInput, xOne, gvl);
    xK2 = _MM_DIV_f32(xOne, xK2, gvl);
    xK2_2 = _MM_MUL_f32(xK2, xK2, gvl);
    xK2_3 = _MM_MUL_f32(xK2_2, xK2, gvl);
    xK2_4 = _MM_MUL_f32(xK2_3, xK2, gvl);
    xK2_5 = _MM_MUL_f32(xK2_4, xK2, gvl);
    xLocal_1 = _MM_MUL_f32(xK2, _MM_SET_f32(0.319381530, gvl), gvl);
    xLocal_2 = _MM_MUL_f32(xK2_2, _MM_SET_f32(-0.356563782, gvl), gvl);
    xLocal_2 = _MM_MACC_f32(xLocal_2, xK2_3, _MM_SET_f32(1.781477937, gvl), gvl);
    xLocal_2 = _MM_MACC_f32(xLocal_2, xK2_4, _MM_SET_f32(-1.821255978, gvl), gvl);
    xLocal_2 = _MM_MACC_f32(xLocal_2, xK2_5, _MM_SET_f32(1.330274429, gvl), gvl);
    xLocal_1 = _MM_ADD_f32(xLocal_2, xLocal_1, gvl);
    xLocal = _MM_MUL_f32(xLocal_1, xNPrimeofX, gvl);
    xLocal = _MM_SUB_f32(xOne, xLocal, gvl);
    /* CHANGE: Ara item 2, and a RiVEC bug: RiVEC's _MM_SUB_f32_MASK(xMask, xOne, xLocal) is
       the mask-agnostic vfsub_m, which leaves the unselected elements unspecified
       (docs/rivec_plan.md, blackscholes); the vmerge gives the intended value. */
    xLocal = _MM_MERGE_f32(xLocal, _MM_SUB_f32(xOne, xLocal, gvl), xMask, gvl);
    return xLocal;
}

static void BlkSchlsEqEuroNoDiv_vector(fptype *OptionPrice, int numOptions, fptype *sptprice,
                                       fptype *strike, fptype *rate, fptype *volatility,
                                       fptype *time, int *otype, float timet, unsigned long int gvl)
{
    vfloat32m1_t xStockPrice, xStrikePrice, xRiskFreeRate, xVolatility, xTime, xSqrtTime, xLogTerm;
    vfloat32m1_t xD1, xD2, xPowerTerm, xDen, xRatexTime, xFutureValueX;
    vbool32_t xMask;
    vint32m1_t xOtype, xZero;
    vfloat32m1_t xOptionPrice, xOptionPrice1, xOptionPrice2, xfXd1, xfXd2;
    (void)numOptions; (void)timet;
    xStrikePrice = _MM_LOAD_f32(strike, gvl);
    xStockPrice = _MM_LOAD_f32(sptprice, gvl);
    xStrikePrice = _MM_DIV_f32(xStockPrice, xStrikePrice, gvl);
    xLogTerm = _MM_LOG_f32(xStrikePrice, gvl);
    xRiskFreeRate = _MM_LOAD_f32(rate, gvl);
    xVolatility = _MM_LOAD_f32(volatility, gvl);
    xTime = _MM_LOAD_f32(time, gvl);
    xSqrtTime = _MM_SQRT_f32(xTime, gvl);
    xRatexTime = _MM_MUL_f32(xRiskFreeRate, xTime, gvl);
    xRatexTime = _MM_VFSGNJN_f32(xRatexTime, xRatexTime, gvl);
    xFutureValueX = _MM_EXP_f32(xRatexTime, gvl);
    xPowerTerm = _MM_MUL_f32(xVolatility, xVolatility, gvl);
    xPowerTerm = _MM_MUL_f32(xPowerTerm, _MM_SET_f32(0.5, gvl), gvl);
    xD1 = _MM_ADD_f32(xRiskFreeRate, xPowerTerm, gvl);
    xD1 = _MM_MADD_f32(xD1, xTime, xLogTerm, gvl);
    xDen = _MM_MUL_f32(xVolatility, xSqrtTime, gvl);
    xD1 = _MM_DIV_f32(xD1, xDen, gvl);
    xD2 = _MM_SUB_f32(xD1, xDen, gvl);
    xfXd1 = CNDF_SIMD(xD1, gvl);
    xfXd2 = CNDF_SIMD(xD2, gvl);
    xStrikePrice = _MM_LOAD_f32(strike, gvl);
    xFutureValueX = _MM_MUL_f32(xFutureValueX, xStrikePrice, gvl);
    xOtype = _MM_LOAD_i32(otype, gvl);
    xZero = _MM_SET_i32(0, gvl);
    xMask = _MM_VMSEQ_i32(xZero, xOtype, gvl);
    xfXd1 = _MM_MERGE_f32(_MM_SUB_f32(_MM_SET_f32(1.0, gvl), xfXd1, gvl), xfXd1, xMask, gvl);
    xStockPrice = _MM_LOAD_f32(sptprice, gvl);
    xOptionPrice1 = _MM_MUL_f32(xStockPrice, xfXd1, gvl);
    xfXd2 = _MM_MERGE_f32(_MM_SUB_f32(_MM_SET_f32(1.0, gvl), xfXd2, gvl), xfXd2, xMask, gvl);
    xOptionPrice2 = _MM_MUL_f32(xFutureValueX, xfXd2, gvl);
    xOptionPrice = _MM_SUB_f32(xOptionPrice2, xOptionPrice1, gvl);
    xOptionPrice = _MM_VFSGNJX_f32(xOptionPrice, xOptionPrice, gvl);
    _MM_STORE_f32(OptionPrice, xOptionPrice, gvl);
}
/* a = S K r v T type price n runs   (RiVEC bs_thread's vector loop: NUM_RUNS x all options) */
static void v_rv_bs(const uint32_t *a)
{
    fptype *S = AKP(fptype, a[0]), *K = AKP(fptype, a[1]), *R = AKP(fptype, a[2]);   /* CHANGE: bare metal */
    fptype *V = AKP(fptype, a[3]), *T = AKP(fptype, a[4]), *price = AKP(fptype, a[6]);
    int *otype = AKP(int, a[5]);
    const int numOptions = (int)a[7], runs = (int)a[8];
    for (int j = 0; j < runs; j++) {
        unsigned long int gvl = __riscv_vsetvl_e32m1(numOptions);
        for (int i = 0; i < numOptions; i += gvl) {
            gvl = __riscv_vsetvl_e32m1(numOptions - i);
            BlkSchlsEqEuroNoDiv_vector(&price[i], gvl, &S[i], &K[i], &R[i], &V[i], &T[i], &otype[i], 0, gvl);
        }
    }
}

/* ── lavaMD: RiVEC _lavaMD/kernel/kernel_vector.c kernel_cpu (vector) ─────────────── */
/* a = rv qv fv nn nei a2 nbox   (rv: v x y z per particle; nei: 26 per box)
   CHANGE: bare metal: RiVEC's box_str array becomes nn[] and nei[] (the same neighbour
   order, rv_ref.h rv_lava_boxes); its FOUR_VECTOR arrays are the same layout. */
static void v_rv_lavamd(const uint32_t *a)
{
    const float *rv = AKP(const float, a[0]), *qv = AKP(const float, a[1]);
    float *fv = AKP(float, a[2]);
    const uint32_t *nn = AKP(const uint32_t, a[3]), *nei = AKP(const uint32_t, a[4]);
    const float a2 = ak_f(a[5]);
    const uint32_t nbox = a[6];
    for (uint32_t l = 0; l < nbox; l = l + 1) {
        const float *rA = rv + 4 * l * RV_LAVA_NP;
        float *fA = fv + 4 * l * RV_LAVA_NP;
        for (uint32_t k = 0; k < (1 + nn[l]); k++) {
            const uint32_t pointer = k == 0 ? l : nei[l * 26 + k - 1];
            const float *rB = rv + 4 * pointer * RV_LAVA_NP;
            const float *qB = qv + pointer * RV_LAVA_NP;
            vfloat32m1_t xr2, xDOT, xu2, xvij, xrB_v, xrB_x, xrB_y, xrB_z, xd_x, xd_y, xd_z;
            vfloat32m1_t xfxij, xfyij, xfzij, xfs, xqB, xfA_v, xfA_x, xfA_y, xfA_z;
            vfloat32m1_t xfA_1_v, xfA_1_x, xfA_1_y, xfA_1_z;
            for (uint32_t i = 0; i < RV_LAVA_NP; i = i + 1) {
                unsigned long int gvl = _MMR_VSETVL_E32M1(RV_LAVA_NP);
                xfA_v = _MM_SET_f32(0.0f, gvl);
                xfA_x = _MM_SET_f32(0.0f, gvl);
                xfA_y = _MM_SET_f32(0.0f, gvl);
                xfA_z = _MM_SET_f32(0.0f, gvl);
                xfA_1_v = _MM_SET_f32(fA[4 * i], 1);
                xfA_1_x = _MM_SET_f32(fA[4 * i + 1], 1);
                xfA_1_y = _MM_SET_f32(fA[4 * i + 2], 1);
                xfA_1_z = _MM_SET_f32(fA[4 * i + 3], 1);
                for (uint32_t j = 0; j < RV_LAVA_NP; j += gvl) {
                    gvl = _MMR_VSETVL_E32M1(RV_LAVA_NP - j);
                    xrB_v = _MM_LOAD_STRIDE_f32(&rB[4 * j], 16, gvl);
                    xrB_x = _MM_LOAD_STRIDE_f32(&rB[4 * j + 1], 16, gvl);
                    xrB_y = _MM_LOAD_STRIDE_f32(&rB[4 * j + 2], 16, gvl);
                    xrB_z = _MM_LOAD_STRIDE_f32(&rB[4 * j + 3], 16, gvl);
                    xr2 = _MM_ADD_VF_f32(xrB_v, rA[4 * i], gvl);
                    xDOT = _MM_MUL_VF_f32(xrB_x, rA[4 * i + 1], gvl);
                    xDOT = _MM_MACC_VF_f32(xDOT, rA[4 * i + 2], xrB_y, gvl);
                    xDOT = _MM_MACC_VF_f32(xDOT, rA[4 * i + 3], xrB_z, gvl);
                    xr2 = _MM_SUB_f32(xr2, xDOT, gvl);
                    xu2 = _MM_MUL_VF_f32(xr2, a2, gvl);
                    xvij = _MM_EXP_f32(_MM_VFSGNJN_f32(xu2, xu2, gvl), gvl);
                    xfs = _MM_MUL_f32(_MM_SET_f32(2.0f, gvl), xvij, gvl);
                    xd_x = _MM_SUB_f32(_MM_SET_f32(rA[4 * i + 1], gvl), xrB_x, gvl);
                    xd_y = _MM_SUB_f32(_MM_SET_f32(rA[4 * i + 2], gvl), xrB_y, gvl);
                    xd_z = _MM_SUB_f32(_MM_SET_f32(rA[4 * i + 3], gvl), xrB_z, gvl);
                    xfxij = _MM_MUL_f32(xfs, xd_x, gvl);
                    xfyij = _MM_MUL_f32(xfs, xd_y, gvl);
                    xfzij = _MM_MUL_f32(xfs, xd_z, gvl);
                    xqB = _MM_LOAD_f32(&qB[j], gvl);
                    xfA_v = _MM_MACC_f32(xfA_v, xqB, xvij, gvl);
                    xfA_x = _MM_MACC_f32(xfA_x, xqB, xfxij, gvl);
                    xfA_y = _MM_MACC_f32(xfA_y, xqB, xfyij, gvl);
                    xfA_z = _MM_MACC_f32(xfA_z, xqB, xfzij, gvl);
                }
                gvl = _MMR_VSETVL_E32M1(RV_LAVA_NP);
                xfA_1_v = _MM_REDSUM_f32(xfA_v, xfA_1_v, gvl);
                xfA_1_x = _MM_REDSUM_f32(xfA_x, xfA_1_x, gvl);
                xfA_1_y = _MM_REDSUM_f32(xfA_y, xfA_1_y, gvl);
                xfA_1_z = _MM_REDSUM_f32(xfA_z, xfA_1_z, gvl);
                fA[4 * i] = _MM_VGETFIRST_f32(xfA_1_v);
                fA[4 * i + 1] = _MM_VGETFIRST_f32(xfA_1_x);
                fA[4 * i + 2] = _MM_VGETFIRST_f32(xfA_1_y);
                fA[4 * i + 3] = _MM_VGETFIRST_f32(xfA_1_z);
            }
        }
    }
}
