/*
 * power.c  -  board power readout over a PS I2C bus (ZCU102 or ZCU104)
 *
 * The board is chosen at build time (-DSIMTIX_BOARD_ZCU104, else ZCU102). The
 * monitors, from the Linux device trees:
 *
 * ZCU102 (zynqmp-zcu102-revA.dts): PS I2C0 (0xFF02_0000), PCA9544 mux at 0x75
 *   channel 0 (PS PMBus): INA226 at 0x40-0x47 (U76 U77 U78 U87 U85 U86 U93 U88),
 *                         0x4A (U15), 0x4B (U92); 5 mOhm shunts
 *   channel 1 (PL PMBus): INA226 at 0x40-0x47 (U79 U81 U80 U84 U16 U65 U74 U75);
 *                         U79 2 mOhm, the others 5 mOhm
 *   A PCA9544 channel is selected by writing 0x04 | channel.
 * ZCU104 (zynqmp-zcu104-revC.dts): PS I2C1 (0xFF03_0000), PCA9548 mux at 0x74
 *   channel 2: IRPS5401 PMICs at 0x43 (U175) and 0x44 (U180), five outputs each
 *              (PMBus pages 0-4): READ_VOUT (LINEAR16) and READ_IOUT (LINEAR11)
 *   channel 3: INA226 at 0x40 (U183) on the 12 V board input, 5 mOhm shunt
 *   A PCA9548 channel is selected by writing 1 << channel.
 * The only writes are the mux's channel byte, the PMBus PAGE command and the
 * INA226 configuration register, each after the device has been identified.
 *
 * pw_sample() reads every rail once and adds its power to the current phase, at
 * most every SAMPLE_US (a sweep of the rails takes a few ms of A53 time; the
 * INA226 averages over 35 ms). apps.c repeats each phase of a DRAM-sized run for
 * two seconds, sampling between repetitions (and while it polls the
 * accelerator), and pw_report() prints one row per phase and rail:
 *   POWER,<app>,<size>,<phase>,<rail>,<mV>,<mW>,<samples>,<reps>,<ms>
 * phase: idle (A53 polling, accelerator idle), accel (A53 polling, accelerator
 * running), a53 (A53 computing, accelerator idle). The rail names are the
 * monitors' reference designators; the voltage identifies the supply.
 */
#include <string.h>
#include "xparameters.h"
#include "xiicps.h"
#include "xil_printf.h"
#include "xiltimer.h"
#include "power.h"

#define SAMPLE_US   50000u

enum { INA, PMB };                          /* monitor kind */

typedef struct {
    const char *name;
    uint8_t     mux;                        /* byte written to the mux */
    uint8_t     addr;
    uint8_t     kind;
    uint8_t     arg;                        /* INA226: shunt in mOhm; PMBus: page */
} rail_t;

#ifdef SIMTIX_BOARD_ZCU104
#define IIC_BASE    0xFF030000u             /* PS I2C1 */
#define MUX_ADDR    0x74u
#define CH(c)       ((uint8_t)(1u << (c)))  /* PCA9548 */
static const rail_t rail[] = {
    { "in12v",  CH(3), 0x40u, INA, 5 },
    { "u175_0", CH(2), 0x43u, PMB, 0 }, { "u175_1", CH(2), 0x43u, PMB, 1 },
    { "u175_2", CH(2), 0x43u, PMB, 2 }, { "u175_3", CH(2), 0x43u, PMB, 3 },
    { "u175_4", CH(2), 0x43u, PMB, 4 },
    { "u180_0", CH(2), 0x44u, PMB, 0 }, { "u180_1", CH(2), 0x44u, PMB, 1 },
    { "u180_2", CH(2), 0x44u, PMB, 2 }, { "u180_3", CH(2), 0x44u, PMB, 3 },
    { "u180_4", CH(2), 0x44u, PMB, 4 },
};
#else
#define IIC_BASE    0xFF020000u             /* PS I2C0 */
#define MUX_ADDR    0x75u
#define CH(c)       ((uint8_t)(0x04u | (c)))   /* PCA9544 */
static const rail_t rail[] = {
    { "ps_u76", CH(0), 0x40u, INA, 5 }, { "ps_u77", CH(0), 0x41u, INA, 5 },
    { "ps_u78", CH(0), 0x42u, INA, 5 }, { "ps_u87", CH(0), 0x43u, INA, 5 },
    { "ps_u85", CH(0), 0x44u, INA, 5 }, { "ps_u86", CH(0), 0x45u, INA, 5 },
    { "ps_u93", CH(0), 0x46u, INA, 5 }, { "ps_u88", CH(0), 0x47u, INA, 5 },
    { "ps_u15", CH(0), 0x4Au, INA, 5 }, { "ps_u92", CH(0), 0x4Bu, INA, 5 },
    { "pl_u79", CH(1), 0x40u, INA, 2 }, { "pl_u81", CH(1), 0x41u, INA, 5 },
    { "pl_u80", CH(1), 0x42u, INA, 5 }, { "pl_u84", CH(1), 0x43u, INA, 5 },
    { "pl_u16", CH(1), 0x44u, INA, 5 }, { "pl_u65", CH(1), 0x45u, INA, 5 },
    { "pl_u74", CH(1), 0x46u, INA, 5 }, { "pl_u75", CH(1), 0x47u, INA, 5 },
};
#endif
#define NRAIL ((int)(sizeof rail / sizeof rail[0]))

static const char *const phase_name[PW_PHASES] = { "idle", "accel", "a53" };

static XIicPs iic;
static uint8_t rail_ok[NRAIL];
static int8_t  vout_exp[NRAIL];            /* VOUT_MODE exponent (PMBus rails) */
static int     nrail, cur = PW_NONE;
static uint64_t sum_mw[PW_PHASES][NRAIL], sum_mv[PW_PHASES][NRAIL];
static uint32_t cnt[PW_PHASES][NRAIL];

/* ── I2C ───────────────────────────────────────────────────────────────────── */
static int idle(void)
{
    for (uint32_t i = 0; i < 1000000u; i++)
        if (!XIicPs_BusIsBusy(&iic)) return 0;
    return -1;
}

static int wr(uint8_t addr, const uint8_t *b, int n)
{
    if (idle()) return -1;
    return XIicPs_MasterSendPolled(&iic, (u8 *)b, n, addr) == XST_SUCCESS ? 0 : -1;
}

/* Command byte, repeated start, n bytes read back (SMBus read byte / word). */
static int rd(uint8_t addr, uint8_t cmd, uint8_t *b, int n)
{
    if (idle()) return -1;
    XIicPs_SetOptions(&iic, XIICPS_REP_START_OPTION);
    s32 s = XIicPs_MasterSendPolled(&iic, &cmd, 1, addr);
    XIicPs_ClearOptions(&iic, XIICPS_REP_START_OPTION);
    if (s != XST_SUCCESS) {                 /* release the bus the send held */
        XIicPs_WriteReg(iic.Config.BaseAddress, XIICPS_CR_OFFSET,
                        XIicPs_ReadReg(iic.Config.BaseAddress, XIICPS_CR_OFFSET) &
                        ~(u32)XIICPS_CR_HOLD_MASK);
        return -1;
    }
    return XIicPs_MasterRecvPolled(&iic, b, n, addr) == XST_SUCCESS ? 0 : -1;
}

static int mux(uint8_t ch)  { return wr(MUX_ADDR, &ch, 1); }

static int rd16be(uint8_t addr, uint8_t reg, uint16_t *v)     /* INA226 */
{
    uint8_t b[2];
    if (rd(addr, reg, b, 2)) return -1;
    *v = (uint16_t)((b[0] << 8) | b[1]);
    return 0;
}

static int rd16le(uint8_t addr, uint8_t cmd, uint16_t *v)     /* PMBus */
{
    uint8_t b[2];
    if (rd(addr, cmd, b, 2)) return -1;
    *v = (uint16_t)(b[0] | (b[1] << 8));
    return 0;
}

static int page(uint8_t addr, uint8_t p)
{
    uint8_t b[2] = { 0x00u, p };            /* PAGE */
    return wr(addr, b, 2);
}

/* ── Rails ─────────────────────────────────────────────────────────────────── */
static int64_t scale2(int64_t v, int e) { return e >= 0 ? v << e : v >> -e; }

/* INA226: bus voltage (1.25 mV LSB) and shunt voltage (2.5 uV LSB) */
static int read_ina(const rail_t *t, int32_t *mv, int32_t *mw)
{
    uint16_t sh, bus;
    if (rd16be(t->addr, 0x01u, &sh) || rd16be(t->addr, 0x02u, &bus)) return -1;
    int64_t v_mv = ((int64_t)bus * 125) / 100;
    int64_t i_ua = ((int64_t)(int16_t)sh * 2500) / t->arg;    /* nV / mOhm = uA */
    *mv = (int32_t)v_mv;
    *mw = (int32_t)(v_mv * i_ua / 1000000);
    return 0;
}

/* PMBus output: READ_VOUT (LINEAR16, VOUT_MODE exponent), READ_IOUT (LINEAR11) */
static int read_pmbus(int r, int32_t *mv, int32_t *mw)
{
    const rail_t *t = &rail[r];
    uint16_t vr, ir;
    if (page(t->addr, t->arg) || rd16le(t->addr, 0x8Bu, &vr) || rd16le(t->addr, 0x8Cu, &ir))
        return -1;
    int64_t v_mv = scale2((int64_t)vr * 1000, vout_exp[r]);
    int32_t y = ir & 0x7FF, n = (ir >> 11) & 0x1F;
    if (y & 0x400) y -= 0x800;
    if (n & 0x10)  n -= 0x20;
    int64_t i_ma = scale2((int64_t)y * 1000, n);
    *mv = (int32_t)v_mv;
    *mw = (int32_t)(v_mv * i_ma / 1000);
    return 0;
}

static int read_rail(int r, int32_t *mv, int32_t *mw)
{
    return rail[r].kind == INA ? read_ina(&rail[r], mv, mw) : read_pmbus(r, mv, mw);
}

/* INA226: manufacturer 0x5449 ("TI"), die 0x226x; then 16 averages of 1.1 ms
   shunt and bus conversions, continuous (a 35 ms window) */
static int probe_ina(const rail_t *t)
{
    uint16_t mid, did;
    if (rd16be(t->addr, 0xFEu, &mid) || rd16be(t->addr, 0xFFu, &did) ||
        mid != 0x5449u || (did & 0xFFF0u) != 0x2260u)
        return 0;
    const uint8_t cfg[3] = { 0x00u, 0x45u, 0x27u };
    return wr(t->addr, cfg, 3) == 0;
}

/* PMBus output: the device answers PMBUS_REVISION, VOUT_MODE is LINEAR, and
   VOUT and IOUT read back */
static int probe_pmbus(int r)
{
    const rail_t *t = &rail[r];
    uint8_t rev, mode;
    uint16_t v, i;
    if (rd(t->addr, 0x98u, &rev, 1) || page(t->addr, t->arg) || rd(t->addr, 0x20u, &mode, 1) ||
        (mode >> 5) != 0 || rd16le(t->addr, 0x8Bu, &v) || rd16le(t->addr, 0x8Cu, &i))
        return 0;
    vout_exp[r] = (int8_t)((mode & 0x10u) ? (int)(mode & 0x1Fu) - 32 : (int)(mode & 0x1Fu));
    return 1;
}

/* Reference clock of the I2C controller, for a platform whose hardware
   description does not list it (a ZCU102 run on the ZCU104 BSP: sw/a53_zcu102). */
uint32_t pw_iic_clock_hz;

int pw_init(void)
{
    static XIicPs_Config own;
    XIicPs_Config *c = XIicPs_LookupConfig(IIC_BASE);
    if (c == NULL && pw_iic_clock_hz != 0) {
        own.BaseAddress  = IIC_BASE;
        own.InputClockHz = pw_iic_clock_hz;
        c = &own;
    }
    if (c == NULL || XIicPs_CfgInitialize(&iic, c, c->BaseAddress) != XST_SUCCESS) {
        xil_printf("power readout: no I2C controller at 0x%08x\r\n", (unsigned)IIC_BASE);
        return 0;
    }
    XIicPs_SetSClk(&iic, 400000);
    nrail = 0;
    memset(rail_ok, 0, sizeof rail_ok);

    for (int r = 0; r < NRAIL; r++) {
        int32_t mv, mw;
        if (mux(rail[r].mux)) continue;
        rail_ok[r] = rail[r].kind == INA ? probe_ina(&rail[r]) : probe_pmbus(r);
        if (!rail_ok[r]) continue;
        if (read_rail(r, &mv, &mw)) { rail_ok[r] = 0; continue; }
        xil_printf("POWERRAIL,%s,%d,%d\r\n", rail[r].name, (int)mv, (int)mw);
        nrail++;
    }
    xil_printf("power readout: %d rails\r\n", nrail);
    memset(cnt, 0, sizeof cnt);
    return nrail;
}

void pw_phase(int phase) { cur = phase; }

void pw_sample(void)
{
    static XTime last;
    XTime now;
    if (nrail == 0 || cur < 0) return;
    XTime_GetTime(&now);
    if (now - last < (XTime)((uint64_t)COUNTS_PER_SECOND * SAMPLE_US / 1000000u)) return;
    last = now;
    int ch = -1;
    for (int r = 0; r < NRAIL; r++) {
        int32_t mv, mw;
        if (!rail_ok[r]) continue;
        if (rail[r].mux != ch) {
            if (mux(rail[r].mux)) return;
            ch = rail[r].mux;
        }
        if (read_rail(r, &mv, &mw)) continue;
        sum_mv[cur][r] += (uint64_t)(int64_t)mv;
        sum_mw[cur][r] += (uint64_t)(int64_t)mw;
        cnt[cur][r]++;
    }
}

void pw_report(const char *app, uint32_t size, const uint32_t reps[PW_PHASES],
               const double ms[PW_PHASES])
{
    for (int ph = 0; ph < PW_PHASES; ph++)
        for (int r = 0; r < NRAIL; r++) {
            if (!rail_ok[r] || cnt[ph][r] == 0) continue;
            int32_t mv = (int32_t)((int64_t)sum_mv[ph][r] / cnt[ph][r]);
            int32_t mw = (int32_t)((int64_t)sum_mw[ph][r] / cnt[ph][r]);
            xil_printf("POWER,%s,%u,%s,%s,%d,%d,%u,%u,%u\r\n", app, size, phase_name[ph],
                       rail[r].name, (int)mv, (int)mw, cnt[ph][r], reps[ph],
                       (unsigned)(ms[ph] + 0.5));
        }
    memset(sum_mv, 0, sizeof sum_mv);
    memset(sum_mw, 0, sizeof sum_mw);
    memset(cnt, 0, sizeof cnt);
}
