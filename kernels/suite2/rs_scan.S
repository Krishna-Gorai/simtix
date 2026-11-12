# rs_scan.S  -  SHOC sort, step 2: per-digit exclusive prefix over the workers
#
#   Thread d (16 threads): off[d][w] = hist[d][0] + ... + hist[d][w-1];
#   tot[d] = hist[d][0] + ... + hist[d][W-1]
#
#   a0 = tid (d)   a1 = &P   a4 = 16
#   P[0] = &hist  P[1] = &off  P[2] = &tot  P[3] = W
.section .text
.globl _start
_start:
    lw      s0, 0(a1)          # hist
    lw      s1, 4(a1)          # off
    lw      s2, 8(a1)          # tot
    lw      s3, 12(a1)         # W
    mul     t0, a0, s3
    sh2add  s0, t0, s0         # &hist[d][0]
    sh2add  s1, t0, s1         # &off[d][0]
    sh2add  t6, s3, s0         # &hist[d][W]
    li      t1, 0              # running sum
1:  lw      t2, 0(s0)
    sw      t1, 0(s1)
    add     t1, t1, t2
    addi    s0, s0, 4
    addi    s1, s1, 4
    bne     s0, t6, 1b
    sh2add  t0, a0, s2
    sw      t1, 0(t0)          # tot[d]
    ecall
