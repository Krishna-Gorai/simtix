# =============================================================================
# mnist_driver.S — host-CPU driver for the on-chip MNIST demo (AI-4 step 4d)
#
# The rv32i program the full chip's host RISC-V core runs to perform quantized
# MNIST inference (784->128->10 INT8) end-to-end through the REAL chip datapath:
# host CPU  <->  BRAM weight store (region 0xA)  <->  16 KB LUTRAM working memory
# (region 0x0)  <->  MMIO (0x8..)  <->  SIMT accelerator.
#
# The accelerator only ever sees the small 16 KB working memory, so the weights
# (98 KB) do NOT fit — the driver STREAMS them: for each output-column tile it
# copies that tile's weights out of the BRAM store into the working memory,
# repacked to the tile stride, then launches qgemv on the tile. This is the
# whole point of the BRAM-store architecture (weights in block RAM, tiled into
# fabric SRAM on demand), exactly as real inference accelerators do.
#
# Per image:  x -> qgemv(K=784,N=128, tiled Nt=16) -> requant_relu(M1)
#               -> qgemv(K=128,N=10) -> argmax.
# The driver self-checks each predicted digit against the integer-exact golden
# (also in the BRAM store) and publishes the count of golden-matching images to
# the chip result register; a correct chip reports 64.
#
# BRAM store (region 0xA, byte = word*4), built by ml/mnist_quant.py:
#   0xA0000000 qgemv kernel (20 w)      0xA0000060 requant_relu kernel (16 w)
#   0xA00000A0 params (M1,zp)           0xA00000A8 golden preds (64 w)
#   0xA0001000 W1packed[196][128]       0xA001A000 W2packed[32][10]
#   0xA001B000 images[64][196]  (img i @ +i*0x310)
#
# Working memory (region 0x0, byte addr):
#   0x000 qgemv  0x060 requant_relu     0x100 CFG(Kp)   0x140 params
#   0x180 OACC[10]  0x1C0 PRED[64]      0x300 X[196]    0x640 HACC[128]
#   0x840 H[128] (packed 32 w)          0x900 WTILE (Kp*Nt staging buffer)
#
# Assemble: riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32 -nostdlib
#           -nostartfiles -Wl,-Ttext=0 -o mnist_driver.elf mnist_driver.S
# =============================================================================
    .text
    .globl _start
_start:
    # ── boot: copy the two accelerator kernels (40 words) into working memory ──
    li   a0, 0xA0000000        # src: BRAM kernels
    li   a1, 0x0               # dst: working mem @ 0
    li   a2, 40
1:  lw   t0, 0(a0)
    sw   t0, 0(a1)
    addi a0, a0, 4
    addi a1, a1, 4
    addi a2, a2, -1
    bne  a2, x0, 1b

    # ── copy requant params (2 words) into working mem @ 0x140 ─────────────────
    li   a0, 0xA00000A0
    li   a1, 0x140
    li   a2, 2
2:  lw   t0, 0(a0)
    sw   t0, 0(a1)
    addi a0, a0, 4
    addi a1, a1, 4
    addi a2, a2, -1
    bne  a2, x0, 2b

    # ── persistent state across the 64-image loop ──────────────────────────────
    li   s0, 0                 # i        = image index
    li   s1, 0xA001B000        # img_src  = &BRAM images[i]  (+0x310 per image)
    li   s2, 0x1C0             # pred_ptr = &PRED[i]         (+4 per image)
    li   s3, 0                 # correct  = golden-match count
    li   s4, 0x80000000        # MMIO command/status base

image_loop:
    # ── copy image i (196 words) into working mem X @ 0x300 ────────────────────
    mv   a0, s1
    li   a1, 0x300
    li   a2, 196
3:  lw   t0, 0(a0)
    sw   t0, 0(a1)
    addi a0, a0, 4
    addi a1, a1, 4
    addi a2, a2, -1
    bne  a2, x0, 3b

    # ── layer 1: CFG.Kp = 196, tiled qgemv (Nt=16, 8 tiles) ────────────────────
    li   t0, 196
    li   t1, 0x100
    sw   t0, 0(t1)             # CFG = Kp1

    li   s5, 0                 # n0     = tile's first output column
    li   s6, 0xA0001000        # w1col  = &W1[0][n0]  (+64B per tile)
tile_loop:
    # copy weight tile: 196 rows x 16 words, src row-stride 512B, dst 0x900 (64B)
    mv   t3, s6                # src row pointer
    li   t4, 0x900            # dst = WTILE
    li   t5, 196             # rows (=Kp1)
trow:
    lw t0,0(t3)   ; sw t0,0(t4)
    lw t0,4(t3)   ; sw t0,4(t4)
    lw t0,8(t3)   ; sw t0,8(t4)
    lw t0,12(t3)  ; sw t0,12(t4)
    lw t0,16(t3)  ; sw t0,16(t4)
    lw t0,20(t3)  ; sw t0,20(t4)
    lw t0,24(t3)  ; sw t0,24(t4)
    lw t0,28(t3)  ; sw t0,28(t4)
    lw t0,32(t3)  ; sw t0,32(t4)
    lw t0,36(t3)  ; sw t0,36(t4)
    lw t0,40(t3)  ; sw t0,40(t4)
    lw t0,44(t3)  ; sw t0,44(t4)
    lw t0,48(t3)  ; sw t0,48(t4)
    lw t0,52(t3)  ; sw t0,52(t4)
    lw t0,56(t3)  ; sw t0,56(t4)
    lw t0,60(t3)  ; sw t0,60(t4)
    addi t3, t3, 512
    addi t4, t4, 64
    addi t5, t5, -1
    bne  t5, x0, trow

    # launch qgemv on the tile: a=X, b=WTILE, c=HACC+n0*4, N=16, kpc=0
    sw   x0, 0x00(s4)          # kernel_pc = 0 (qgemv)
    li   t0, 0x300 ; sw t0, 0x04(s4)     # base_a = X
    li   t0, 0x900 ; sw t0, 0x08(s4)     # base_b = WTILE
    slli t1, s5, 2
    li   t0, 0x640 ; add t0, t0, t1
    sw   t0, 0x0C(s4)                     # base_c = HACC + n0*4
    li   t0, 16    ; sw t0, 0x10(s4)     # N = 16
    li   t0, 1     ; sw t0, 0x14(s4)     # GO
    # two-phase poll (robust across many launches): wait BUSY, then wait DONE
wb1: lw t0, 0x18(s4) ; andi t0, t0, 2 ; beq t0, x0, wb1
wd1: lw t0, 0x18(s4) ; andi t0, t0, 1 ; beq t0, x0, wd1

    addi s5, s5, 16           # next tile column
    addi s6, s6, 64           # advance W1 column base (+16 words)
    li   t0, 128
    blt  s5, t0, tile_loop

    # ── requant_relu: a=HACC, b=params, c=H, N=128, kpc=0x60 ───────────────────
    li   t0, 0x60  ; sw t0, 0x00(s4)
    li   t0, 0x640 ; sw t0, 0x04(s4)
    li   t0, 0x140 ; sw t0, 0x08(s4)
    li   t0, 0x840 ; sw t0, 0x0C(s4)
    li   t0, 128   ; sw t0, 0x10(s4)
    li   t0, 1     ; sw t0, 0x14(s4)
wb2: lw t0, 0x18(s4) ; andi t0, t0, 2 ; beq t0, x0, wb2
wd2: lw t0, 0x18(s4) ; andi t0, t0, 1 ; beq t0, x0, wd2

    # ── layer 2: CFG.Kp = 32, copy W2 (320 w) into WTILE, qgemv N=10 ───────────
    li   t0, 32
    li   t1, 0x100
    sw   t0, 0(t1)            # CFG = Kp2

    li   a0, 0xA001A000       # src: BRAM W2
    li   a1, 0x900           # dst: WTILE
    li   a2, 320
4:  lw   t0, 0(a0)
    sw   t0, 0(a1)
    addi a0, a0, 4
    addi a1, a1, 4
    addi a2, a2, -1
    bne  a2, x0, 4b

    sw   x0, 0x00(s4)         # kernel_pc = 0 (qgemv)
    li   t0, 0x840 ; sw t0, 0x04(s4)     # base_a = H (layer-2 activations)
    li   t0, 0x900 ; sw t0, 0x08(s4)     # base_b = WTILE (=W2)
    li   t0, 0x180 ; sw t0, 0x0C(s4)     # base_c = OACC
    li   t0, 10    ; sw t0, 0x10(s4)     # N = 10
    li   t0, 1     ; sw t0, 0x14(s4)     # GO
wb3: lw t0, 0x18(s4) ; andi t0, t0, 2 ; beq t0, x0, wb3
wd3: lw t0, 0x18(s4) ; andi t0, t0, 1 ; beq t0, x0, wd3

    # ── argmax over OACC[0..9] (signed int32 logits) ───────────────────────────
    li   a0, 0x180           # &OACC
    lw   t0, 0(a0)           # best = OACC[0]
    li   t1, 0               # pred = 0
    li   t2, 1               # n = 1
am:  slli t3, t2, 2
    add  t3, a0, t3
    lw   t4, 0(t3)           # OACC[n]
    bge  t0, t4, amskip      # keep best if best >= OACC[n]  (strict argmax)
    mv   t0, t4
    mv   t1, t2              # pred = n
amskip:
    addi t2, t2, 1
    li   t5, 10
    blt  t2, t5, am
    sw   t1, 0(s2)           # PRED[i] = pred

    # ── self-check vs golden pred[i] (BRAM 0xA00000A8 + i*4) ───────────────────
    li   t2, 0xA00000A8
    slli t3, s0, 2
    add  t2, t2, t3
    lw   t4, 0(t2)           # gold[i]
    bne  t1, t4, nocorr
    addi s3, s3, 1           # correct++
nocorr:

    # ── advance image loop ─────────────────────────────────────────────────────
    addi s0, s0, 1
    addi s1, s1, 0x310       # img_src += 196 words
    addi s2, s2, 4           # pred_ptr += 1 word
    li   t0, 64
    blt  s0, t0, image_loop

    # ── publish golden-match count (== 64 when bit-exact) and halt ─────────────
    li   t0, 0x90000000
    sw   s3, 0(t0)           # result = correct, done = 1
halt:
    beq  x0, x0, halt
