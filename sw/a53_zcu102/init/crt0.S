/*
 * crt0.S  -  start-up for the ZCU102 PS initialisation program (A53 #0, EL3)
 *
 * Runs from on-chip memory with the MMU and caches off, so nothing touches DDR
 * before psu_init() has brought it up. Only core 0 runs; the others wait.
 */
    .section .text.boot, "ax"
    .global _start
_start:
    mrs     x0, mpidr_el1
    and     x0, x0, #0xFF
    cbnz    x0, park
    ldr     x1, =__stack_top
    mov     sp, x1
    ldr     x1, =__bss_start
    ldr     x2, =__bss_end
zero:
    cmp     x1, x2
    b.hs    run
    str     xzr, [x1], #8
    b       zero
run:
    bl      init_main
park:
    wfe
    b       park
