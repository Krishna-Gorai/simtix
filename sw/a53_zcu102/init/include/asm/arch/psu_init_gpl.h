/* psu_init_gpl.h  -  declarations psu_init_gpl.c expects (see init_main.c) */
#ifndef PSU_INIT_GPL_H
#define PSU_INIT_GPL_H
#include <stdint.h>
int mask_poll(uint32_t add, uint32_t mask);
uint32_t mask_read(uint32_t add, uint32_t mask);
void mask_delay(uint32_t delay);
void psu_mask_write(unsigned long offset, unsigned long mask, unsigned long val);
void prog_reg(unsigned long addr, unsigned long mask, unsigned long shift, unsigned long value);
int psu_init(void);
void xil_printf(const char *fmt, ...);
#endif
