# collatz.S  -  SIMTiX benchmark kernel: Collatz step count (heavy data-dependent
#               divergence) — the flagship kernel for the lane-gating energy study.
#
#   C[i] = number of Collatz steps to bring n=A[i] down to 1 (capped at MAXITER)
#   Collatz step:  n even -> n/2 ;  n odd -> 3n+1
#
# Why this kernel: the per-lane work (how many steps until n==1) depends entirely
# on the *value* of A[i], so as the warp runs, lanes finish at different times and
# mask off — control divergence that grows over the kernel's life and is purely
# data-driven. We keep the OUTER loop uniform (every lane runs MAXITER iterations,
# the well-tested regime) and predicate the body with a single-sided forward `if`:
# a lane that has reached n==1 skips the body and idles (clock-gated) until the
# others finish. Inside the body, the odd/even split is two more single-sided ifs.
# So divergence nests to depth ~2 and reconverges every iteration — no SIMT-stack
# pressure, no divergent backward loop.  No multiply (3n via (n<<1)+n; /2 via >>1).
#   a0 = tid   a1 = &A   a3 = &C   a4 = N        MAXITER = 32
#
# Seeds A[i] are chosen small (2..9) so every lane converges in < 32 steps and the
# cap never bites: C[i] is then the exact Collatz step count.
#
# Assemble (rv32im, no compressed):
#   riscv-none-elf-gcc -march=rv32im -mabi=ilp32 -nostdlib -nostartfiles \
#       -Wl,-Ttext=0 -o collatz.elf collatz.S
#   riscv-none-elf-objcopy -O binary collatz.elf collatz.bin

.section .text
.globl _start
_start:
    slli  t0, a0, 2        # i*4
    add   t1, a1, t0       # &A[i]
    lw    t2, 0(t1)        # n = A[i]
    addi  t3, x0, 0        # steps = 0
    addi  s0, x0, 0        # it = 0
    addi  s1, x0, 32       # MAXITER (uniform bound)
.Lloop:
    # ── if (n != 1) { one Collatz step; steps++ }  (single-sided forward if) ──
    addi  t4, x0, 1
    beq   t2, t4, .Lskip   # n==1 lanes skip the body (wait at .Lskip)
    andi  t5, t2, 1        # parity (preserved across both sub-ifs)
    # odd:  if (n & 1)      n = 3n + 1
    beq   t5, x0, .Lnotodd
    slli  t6, t2, 1        # 2n
    add   t2, t2, t6       # 3n
    addi  t2, t2, 1        # 3n+1
.Lnotodd:
    # even: if (!(n & 1))   n = n >> 1
    bne   t5, x0, .Lnoteven
    srli  t2, t2, 1
.Lnoteven:
    addi  t3, t3, 1        # steps++
.Lskip:
    addi  s0, s0, 1        # it++
    blt   s0, s1, .Lloop   # uniform loop: all lanes run MAXITER iterations
    # ── store the step count ─────────────────────────────────────────────────
    add   t6, a3, t0       # &C[i]
    sw    t3, 0(t6)        # C[i] = steps
    ecall
