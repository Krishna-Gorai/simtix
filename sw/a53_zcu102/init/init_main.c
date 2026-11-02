/*
 * init_main.c  -  ZCU102 processing-system initialisation over JTAG
 *
 * The board's PS initialisation (MIO, PLLs, clocks, DDR4 controller and PHY,
 * peripherals, serdes) is U-Boot's board/xilinx/zynqmp/zynqmp-zcu102-rev1.1/
 * psu_init_gpl.c (GPL-2.0+), fetched by build_init.py and compiled with this
 * file; it is not part of this repository. This file supplies the register
 * helpers it calls (the same semantics as U-Boot's arch/arm/mach-zynqmp/
 * psu_spl_init.c) and reports through a mailbox at the top of OCM, which the
 * JTAG script reads:
 *   MB[0] = 0x5053494E ("PSIN") once started, MB[1] = stage, MB[2] = result
 *   (0 = psu_init succeeded), MB[3] = 0x444F4E45 ("DONE") at the end,
 *   MB[4] = number of messages psu_init tried to print (a serdes calibration
 *   timeout is its only one).
 */
#include <stdint.h>
#include "xil_io.h"

#define MB ((volatile uint32_t *)0xFFFFF000u)
#define PSU_MASK_POLL_TIME 1100000

int psu_init(void);

int mask_poll(uint32_t add, uint32_t mask)
{
    for (int i = 0; i <= PSU_MASK_POLL_TIME; i++)
        if (Xil_In32(add) & mask) return 1;
    return 0;
}

uint32_t mask_read(uint32_t add, uint32_t mask) { return Xil_In32(add) & mask; }

/* At least the requested microseconds at any APU clock up to 1.5 GHz: the loop
   runs from uncached OCM, so one iteration takes several cycles. */
void mask_delay(uint32_t delay)
{
    for (volatile uint64_t i = 0; i < (uint64_t)delay * 1500u; i++) ;
}

void psu_mask_write(unsigned long offset, unsigned long mask, unsigned long val)
{
    unsigned long regval = Xil_In32(offset);
    regval &= ~mask;
    regval |= val & mask;
    Xil_Out32(offset, (uint32_t)regval);
}

void prog_reg(unsigned long addr, unsigned long mask, unsigned long shift, unsigned long value)
{
    int rdata = (int)Xil_In32(addr);
    rdata &= (int)~mask;
    rdata |= (int)(value << shift);
    Xil_Out32(addr, (uint32_t)rdata);
}

/* psu_init's only message is a serdes calibration timeout: count it. */
void xil_printf(const char *fmt, ...) { (void)fmt; MB[4]++; }

void init_main(void)
{
    MB[4] = 0;
    MB[3] = 0;
    MB[2] = 0xFFFFFFFFu;
    MB[1] = 1;
    MB[0] = 0x5053494Eu;
    MB[2] = (uint32_t)psu_init();
    MB[1] = 2;
    MB[3] = 0x444F4E45u;
}
