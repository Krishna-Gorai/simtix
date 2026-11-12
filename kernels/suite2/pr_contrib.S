# pr_contrib.S  -  GAP PageRank, first step of an iteration: c[u] = pr[u] * invdeg[u]
#
#   One thread per vertex u; invdeg[u] = 1.0f / deg(u) is computed once by the host.
#
#   a0 = tid   a1 = &P   a4 = N
#   P[0] = &pr  P[1] = &invdeg  P[2] = &c
.section .text
.globl _start
_start:
    lw      s0, 0(a1)          # pr
    lw      s1, 4(a1)          # invdeg
    lw      s2, 8(a1)          # c
    sh2add  s0, a0, s0
    sh2add  s1, a0, s1
    flw     f0, 0(s0)          # pr[u]
    flw     f1, 0(s1)          # invdeg[u]
    fmul.s  f0, f0, f1
    sh2add  s2, a0, s2
    fsw     f0, 0(s2)          # c[u]
    ecall
