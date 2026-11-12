/* dbg_vm.c - the real v_mandel (ak_vector.c) through ak_vector[], with or without the
 * scalar run first (-DSCALAR_FIRST), self-test arguments (debug only). */
#include <stdint.h>
#include "ak.h"
#include "printf.h"
#define H(p) ((uint32_t)((uintptr_t)(p) - AK_OFS))
static uint32_t os[400], ov[400];
static uint32_t f2u(float f) { union { float f; uint32_t u; } v = { .f = f }; return v.u; }
int main(void)
{
    const uint32_t n = 20, m = 40;
    uint32_t as[] = { H(os), n, f2u(-2.0f), f2u(-1.25f), f2u(2.5f / 20.0f), m };
    uint32_t av[] = { H(ov), n, f2u(-2.0f), f2u(-1.25f), f2u(2.5f / 20.0f), m };
#ifdef SCALAR_FIRST
    ak_scalar[AK_MANDEL](as);
    __asm__ volatile("fence" ::: "memory");
    printf("scalar done\n");
#endif
    ak_vector[AK_MANDEL](av);
    __asm__ volatile("fence" ::: "memory");
    printf("vector done\n");
#ifndef SCALAR_FIRST
    ak_scalar[AK_MANDEL](as);
#endif
    unsigned e = 0;
    for (unsigned i = 0; i < n * n; i++) e += os[i] != ov[i];
    printf("dbg_vm err %u\n", e);
    return (int)e;
}
