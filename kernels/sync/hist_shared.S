# hist_shared.S  -  16-bin histogram privatised in block-shared memory
#
#   C[k] += #{tid : A[tid] & 15 == k}       (host clears C[0..15])
#
# Launch with REG_BLOCK = 2 (32-thread blocks). Each block clears 16 shared bins,
# counts into them with scratchpad atomics, then merges them into the global
# histogram with one global atomic per bin, so global atomics fall from one per
# element to sixteen per block.
#   a0 = tid   a1 = &A   a3 = &C
.include "simtix_v2.inc"
.section .text
.globl _start
_start:
    andi  s0, a0, 31       # local thread id
    slli  s1, s0, 2
    lui   s2, 0x60000      # SHARED_BASE
    add   s3, s2, s1       # &shared[lid]
    li    t0, 16
    bgeu  s0, t0, 1f       # warps 0-1 of the block clear the 16 bins
    sw    x0, 0(s3)
1:
    bar
    slli  t1, a0, 2
    add   t1, a1, t1
    lw    t2, 0(t1)
    andi  t2, t2, 15
    slli  t2, t2, 2
    add   t2, s2, t2       # &shared[bin]
    li    t3, 1
    amoadd.w x0, t3, (t2)
    bar
    li    t0, 16
    bgeu  s0, t0, 2f       # warps 0-1 merge one bin per thread
    lw    t4, 0(s3)
    add   t5, a3, s1
    amoadd.w x0, t4, (t5)  # C[lid] += shared[lid]
2:
    ecall
