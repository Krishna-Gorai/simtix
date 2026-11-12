/* dbg_mask.c - what Ara's vcpop.m / vfirst.m return for compare results (debug only) */
#include <riscv_vector.h>
#include <stdint.h>
#include "printf.h"

static uint32_t buf[64];

int main(void)
{
    for (unsigned i = 0; i < 64; i++) buf[i] = i;
    static const unsigned vls[] = { 64, 44, 24, 10, 1 };
    for (unsigned t = 0; t < 5; t++) {
        size_t vl = __riscv_vsetvl_e32m1(vls[t]);
        vuint32m1_t v = __riscv_vle32_v_u32m1(buf, vl);
        vbool32_t none = __riscv_vmsgtu_vx_u32m1_b32(v, 1000, vl);      /* no element set */
        vbool32_t some = __riscv_vmsgtu_vx_u32m1_b32(v, vl / 2, vl);    /* upper half set */
        vbool32_t andm = __riscv_vmand_mm_b32(some, none, vl);          /* none */
        printf("vl %u none cpop %ld first %ld | some cpop %ld first %ld | and cpop %ld first %ld\n",
               (unsigned)vl,
               (long)__riscv_vcpop_m_b32(none, vl), (long)__riscv_vfirst_m_b32(none, vl),
               (long)__riscv_vcpop_m_b32(some, vl), (long)__riscv_vfirst_m_b32(some, vl),
               (long)__riscv_vcpop_m_b32(andm, vl), (long)__riscv_vfirst_m_b32(andm, vl));
    }
    return 0;
}
