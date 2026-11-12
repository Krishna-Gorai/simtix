# nn.S  -  Rodinia nn (nearest neighbour): the distance of every record to the target
#
#   loc[] holds (lat, lng) pairs (FP32, Rodinia's LatLong). Thread t computes
#       dx = lat - loc[t].lat     dy = lng - loc[t].lng
#       dist[t] = sqrt(dx*dx + dy*dy)        (each operation rounded once, no fma)
#   The host then picks the k nearest records, as Rodinia's findLowest does.
#
#   a0 = tid   a1 = &P
#   P[0] = &loc  P[1] = &dist  P[2] = lat  P[3] = lng   (f32)
.section .text
.globl _start
_start:
    lw      t0, 0(a1)          # loc
    lw      t1, 4(a1)          # dist
    flw     f10, 8(a1)         # lat
    flw     f11, 12(a1)        # lng
    sh3add  t2, a0, t0         # &loc[t]
    flw     f0, 0(t2)          # loc[t].lat
    flw     f1, 4(t2)          # loc[t].lng
    fsub.s  f0, f10, f0        # dx
    fsub.s  f1, f11, f1        # dy
    fmul.s  f0, f0, f0         # dx*dx
    fmul.s  f1, f1, f1         # dy*dy
    fadd.s  f0, f0, f1
    fsqrt.s f0, f0
    sh2add  t1, a0, t1
    fsw     f0, 0(t1)          # dist[t]
    ecall
