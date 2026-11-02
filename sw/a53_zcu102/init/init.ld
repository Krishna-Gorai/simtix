/* init.ld  -  the PS initialisation program lives entirely in OCM (256 KB) */
ENTRY(_start)
MEMORY
{
    ocm (rwx) : ORIGIN = 0xFFFC0000, LENGTH = 0x20000
}
SECTIONS
{
    .text : { *(.text.boot) *(.text*) *(.rodata*) } > ocm
    .data : { *(.data*) } > ocm
    .bss (NOLOAD) : ALIGN(8) { __bss_start = .; *(.bss*) *(COMMON) . = ALIGN(8); __bss_end = .; } > ocm
    __stack_top = 0xFFFE0000;
}
