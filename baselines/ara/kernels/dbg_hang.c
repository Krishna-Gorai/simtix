/* dbg_hang.c - which of v_mandel's instructions deadlocks Ara (debug only) */
#include <riscv_vector.h>
#include <stdint.h>
#include "printf.h"
static uint32_t out[64];
static float fo[64];
#define STEP(name, stmt) do { stmt; __asm__ volatile("fence" ::: "memory"); printf("%s ok\n", name); } while (0)
int main(void)
{
    size_t vl = __riscv_vsetvl_e32m1(20);
    vuint32m1_t id, k;
    vfloat32m1_t f, g;
    vbool32_t a, e, b;
    STEP("vid", { id = __riscv_vid_v_u32m1(vl); __riscv_vse32_v_u32m1(out, id, vl); });
    STEP("vfcvt.f.xu", { f = __riscv_vfcvt_f_xu_v_f32m1(__riscv_vle32_v_u32m1(out, vl), vl); __riscv_vse32_v_f32m1(fo, f, vl); });
    STEP("vfmadd.vf", { g = __riscv_vfmadd_vf_f32m1(__riscv_vle32_v_f32m1(fo, vl), 0.125f, __riscv_vfmv_v_f_f32m1(-2.0f, vl), vl); __riscv_vse32_v_f32m1(fo, g, vl); });
    STEP("vmset", { a = __riscv_vmset_m_b32(vl); __riscv_vse32_v_u32m1(out, __riscv_vmerge_vxm_u32m1(__riscv_vmv_v_x_u32m1(0, vl), 1, a, vl), vl); });
    STEP("vmfgt.vf", { e = __riscv_vmfgt_vf_f32m1_b32(__riscv_vle32_v_f32m1(fo, vl), -1.0f, vl); __riscv_vse32_v_u32m1(out, __riscv_vmerge_vxm_u32m1(__riscv_vmv_v_x_u32m1(0, vl), 1, e, vl), vl); });
    STEP("vmandn", { a = __riscv_vmset_m_b32(vl); e = __riscv_vmfgt_vf_f32m1_b32(__riscv_vle32_v_f32m1(fo, vl), -1.0f, vl); b = __riscv_vmandn_mm_b32(a, e, vl); __riscv_vse32_v_u32m1(out, __riscv_vmerge_vxm_u32m1(__riscv_vmv_v_x_u32m1(0, vl), 1, b, vl), vl); });
    STEP("vmsltu+vmand", { k = __riscv_vle32_v_u32m1(out, vl); b = __riscv_vmand_mm_b32(__riscv_vmset_m_b32(vl), __riscv_vmsltu_vx_u32m1_b32(k, 40, vl), vl); __riscv_vse32_v_u32m1(out, __riscv_vmerge_vxm_u32m1(__riscv_vmv_v_x_u32m1(0, vl), 1, b, vl), vl); });
    STEP("vadd_mu", { k = __riscv_vle32_v_u32m1(out, vl); a = __riscv_vmsltu_vx_u32m1_b32(k, 1, vl); k = __riscv_vadd_vx_u32m1_mu(a, k, k, 1, vl); __riscv_vse32_v_u32m1(out, k, vl); });
    STEP("vredsum_m", { k = __riscv_vle32_v_u32m1(out, vl); a = __riscv_vmsltu_vx_u32m1_b32(k, 2, vl); out[40] = __riscv_vmv_x_s_u32m1_u32(__riscv_vredsum_vs_u32m1_u32m1_m(a, __riscv_vmv_v_x_u32m1(1, vl), __riscv_vmv_v_x_u32m1(0, 1), vl)); });
    printf("dbg_hang done\n");
    return 0;
}
