# bfs.S  -  one level of a level-synchronous breadth-first search, CSR graph
#
#   Thread v: if level[v] == L, every neighbour u with level[u] == UNSEEN gets
#   level[u] = L + 1, and the launch's flag is set (amoor) when any vertex was
#   discovered. Two threads may discover the same u; both store L + 1, so the
#   result does not depend on their order. The host launches L = 0, 1, ... until
#   the flag stays clear.
#
#   a0 = tid (vertex)   a1 = &P   a4 = vertices
#   P[0] = &rowptr   P[1] = &col   P[2] = &level   P[3] = L   P[4] = &flag
#   UNSEEN = 0xffffffff
.section .text
.globl _start
_start:
    lw      s0, 0(a1)          # rowptr
    lw      s1, 4(a1)          # col
    lw      s2, 8(a1)          # level
    lw      s3, 12(a1)         # L
    slli    t0, a0, 2
    add     t1, s2, t0
    lw      t1, 0(t1)          # level[v]
    bne     t1, s3, 3f         # not in the frontier
    add     t0, s0, t0
    lw      t1, 0(t0)          # j = rowptr[v]
    lw      t2, 4(t0)          # end
    addi    s4, s3, 1          # L + 1
    li      s5, 0              # discovered anything
    bge     t1, t2, 2f
1:  slli    t3, t1, 2
    add     t3, s1, t3
    lw      t3, 0(t3)          # u = col[j]
    slli    t3, t3, 2
    add     t3, s2, t3         # &level[u]
    lw      t4, 0(t3)
    addi    t4, t4, 1          # UNSEEN + 1 == 0
    bnez    t4, 4f
    sw      s4, 0(t3)          # level[u] = L + 1
    li      s5, 1
4:  addi    t1, t1, 1
    blt     t1, t2, 1b
2:  beqz    s5, 3f
    lw      t3, 16(a1)         # flag
    amoor.w x0, s5, (t3)
3:  ecall
