# gemm.S  -  FP32 matrix multiply, one thread per output element
#
#   C[M x N] = A[M x K] * B[K x N], all row-major; N is a power of two.
#   Thread t computes C[t] with row = t >> log2N, col = t & (N-1):
#       acc = +0.0;  for k in 0..K-1:  acc = fmadd(A[row][k], B[k][col], acc)
#   A warp's lanes share the row, so A[row][k] is one broadcast request and
#   B[k][col..col+7] one line.
#
#   a0 = tid   a1 = &P   a4 = M*N (threads)
#   P[0] = &A   P[1] = &B   P[2] = &C   P[3] = K   P[4] = log2N
.section .text
.globl _start
_start:
    lw      s0, 0(a1)          # A
    lw      s1, 4(a1)          # B
    lw      s2, 8(a1)          # C
    lw      s3, 12(a1)         # K
    lw      s4, 16(a1)         # log2N
    srl     t0, a0, s4         # row
    li      t1, 1
    sll     t1, t1, s4         # N
    addi    t1, t1, -1
    and     t1, a0, t1         # col
    mul     t2, t0, s3         # row*K
    slli    t2, t2, 2
    add     t2, s0, t2         # &A[row][0]
    slli    t3, t1, 2
    add     t3, s1, t3         # &B[0][col]
    li      t4, 4
    sll     t4, t4, s4         # B row stride (bytes)
    fmv.w.x f0, x0             # acc = +0.0
    mv      t5, s3             # k counter
1:  flw     f1, 0(t2)          # A[row][k]
    flw     f2, 0(t3)          # B[k][col]
    fmadd.s f0, f1, f2, f0
    addi    t2, t2, 4
    add     t3, t3, t4
    addi    t5, t5, -1
    bnez    t5, 1b
    slli    t6, a0, 2
    add     t6, s2, t6
    fsw     f0, 0(t6)          # C[row][col]
    ecall
