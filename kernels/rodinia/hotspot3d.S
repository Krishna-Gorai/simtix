# hotspot3d.S  -  Rodinia hotspot3D: one time step of the 3-D thermal simulation, FP32
#
#   Grid nx x nx x nz (nx a power of two), cell (i, j, k) at word c = i + j*nx + k*nx*nx
#   (Rodinia's layout). Thread t owns the column i = t & (nx-1), j = t >> log2nx and
#   walks its nz layers, as Rodinia's hotspotOpt1 does. A neighbour outside the grid is
#   replaced by the cell itself (W/E/N/S and the layers below/above). Per cell:
#       s = cc*t
#       s = fma(ce, tW, s)  s = fma(ce, tE, s)  s = fma(cn, tS, s)  s = fma(cn, tN, s)
#       s = fma(ct, tB, s)  s = fma(ct, tT, s)  s = fma(sdc, p, s)  s = fma(ct, amb, s)
#   (Rodinia's sum cc*t + cw*tW + ce*tE + cs*tS + cn*tN + cb*tB + ct*tT + sdc*p + ct*amb
#   from the left, with cw = ce, cs = cn, cb = ct.) nz >= 2.
#
#   a0 = tid   a1 = &P
#   P[0] = &Tin  P[1] = &Tout  P[2] = &Pw  P[3] = log2nx  P[4] = nz
#   P[5] = cc  P[6] = ce  P[7] = cn  P[8] = ct  P[9] = sdc  P[10] = amb   (f32)
.section .text
.globl _start
_start:
    lw      s0, 0(a1)          # Tin
    lw      s1, 4(a1)          # Tout
    lw      s2, 8(a1)          # Pw
    lw      t5, 12(a1)         # log2nx
    lw      s3, 16(a1)         # nz
    flw     f10, 20(a1)        # cc
    flw     f11, 24(a1)        # ce (= cw)
    flw     f12, 28(a1)        # cn (= cs)
    flw     f13, 32(a1)        # ct (= cb)
    flw     f14, 36(a1)        # sdc
    flw     f15, 40(a1)        # amb
    li      t6, 1
    sll     t6, t6, t5
    addi    t6, t6, -1         # nx - 1
    and     t0, a0, t6         # i
    srl     t1, a0, t5         # j
    snez    t2, t0
    slli    t2, t2, 2
    neg     a2, t2             # oW: -4, or 0 at i = 0
    sub     t2, t0, t6
    snez    t2, t2
    slli    a3, t2, 2          # oE: +4, or 0 at i = nx-1
    addi    t3, t5, 2          # log2(4 * nx)
    snez    t2, t1
    sll     t2, t2, t3
    neg     a4, t2             # oN: -4nx, or 0 at j = 0
    sub     t2, t1, t6
    snez    t2, t2
    sll     a5, t2, t3         # oS: +4nx, or 0 at j = nx-1
    add     t3, t3, t5         # log2(4 * nx * nx)
    li      t4, 1
    sll     t4, t4, t3         # xy stride in bytes
    sh2add  s0, a0, s0         # &Tin[c], layer 0
    sh2add  s1, a0, s1         # &Tout[c]
    sh2add  s2, a0, s2         # &Pw[c]
    flw     f1, 0(s0)          # temp2 = t (layer 0)
    fmv.s   f0, f1             # temp1 = the layer below: itself at k = 0
    add     t0, s0, t4
    flw     f2, 0(t0)          # temp3 = layer 1
    li      t1, 0              # k
    addi    s3, s3, -1         # nz - 1
1:  add     t2, s0, a2
    flw     f3, 0(t2)          # tW
    add     t2, s0, a3
    flw     f4, 0(t2)          # tE
    add     t2, s0, a5
    flw     f5, 0(t2)          # tS
    add     t2, s0, a4
    flw     f6, 0(t2)          # tN
    flw     f7, 0(s2)          # p
    fmul.s  f8, f10, f1        # cc * t
    fmadd.s f8, f11, f3, f8    # + cw*tW
    fmadd.s f8, f11, f4, f8    # + ce*tE
    fmadd.s f8, f12, f5, f8    # + cs*tS
    fmadd.s f8, f12, f6, f8    # + cn*tN
    fmadd.s f8, f13, f0, f8    # + cb*tB
    fmadd.s f8, f13, f2, f8    # + ct*tT
    fmadd.s f8, f14, f7, f8    # + sdc*p
    fmadd.s f8, f13, f15, f8   # + ct*amb
    fsw     f8, 0(s1)
    beq     t1, s3, 2f         # last layer done
    addi    t1, t1, 1
    add     s0, s0, t4
    add     s1, s1, t4
    add     s2, s2, t4
    fmv.s   f0, f1             # temp1 = temp2
    fmv.s   f1, f2             # temp2 = temp3
    beq     t1, s3, 1b         # last layer: the layer above is itself (temp3 = temp2)
    add     t0, s0, t4
    flw     f2, 0(t0)          # temp3 = the layer above
    j       1b
2:  ecall
