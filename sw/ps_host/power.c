/*
 * power.c  -  ZCU104 board power readout over the PS I2C1 bus
 *
 * The monitors sit behind the PCA9548 mux at 0x74 (Linux device tree
 * zynqmp-zcu104-revC.dts):
 *   channel 2: IRPS5401 PMICs at 0x43 (U175) and 0x44 (U180), five outputs each
 *              (PMBus pages 0-4): READ_VOUT (LINEAR16) and READ_IOUT (LINEAR11)
 *   channel 3: INA226 at 0x40 (U183) on the 12 V board input, 5 mOhm shunt
 * The only writes are the mux's channel byte, the PMBus PAGE command and the
 * INA226 configuration register, each after the device has been identified.
 *
 * pw_sample() reads every rail once and adds its power to the current phase, at
 * most every SAMPLE_US (a sweep of the rails takes a few ms of A53 time; the
 * INA226 averages over 35 ms). apps.c repeats each phase of a DRAM-sized run for
 * two seconds, sampling between repetitions (and while it polls the
 * accelerator), and pw_report()
 * prints one row per phase and rail:
 *   POWER,<app>,<size>,<phase>,<rail>,<mV>,<mW>,<samples>,<reps>,<ms>
 * phase: idle (A53 polling, accelerator idle), accel (A53 polling, accelerator
 * running), a53 (A53 computing, accelerator idle).
 */
#include <string.h>
#include "xparameters.h"
#include "xiicps.h"
#include "xil_printf.h"
#include "xiltimer.h"
#include "power.h"

#define MUX_ADDR    0x74u
#define MUX_PMIC    (1u << 2)
#define MUX_INA     (1u << 3)
#define INA_ADDR    0x40u
#define INA_SHUNT_MOHM 5
#define NPMIC       2
#define NPAGE       5
#define NRAIL       (1 + NPMIC * NPAGE)
#define SAMPLE_US   50000u

static const uint8_t pmic_addr[NPMIC] = { 0x43u, 0x44u };
static const char *const rail_name[NRAIL] = {
    "in12v", "u175_0", "u175_1", "u175_2", "u175_3", "u175_4",
    "u180_0", "u180_1", "u180_2", "u180_3", "u180_4" };
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
static int read_ina(int32_t *mv, int32_t *mw)
{
    uint16_t sh, bus;
    if (rd16be(INA_ADDR, 0x01u, &sh) || rd16be(INA_ADDR, 0x02u, &bus)) return -1;
    int64_t v_mv = ((int64_t)bus * 125) / 100;
    int64_t i_ua = ((int64_t)(int16_t)sh * 2500) / INA_SHUNT_MOHM;    /* nV / mOhm = uA */
    *mv = (int32_t)v_mv;
    *mw = (int32_t)(v_mv * i_ua / 1000000);
    return 0;
}

/* PMBus rail r (1..): READ_VOUT (LINEAR16, VOUT_MODE exponent), READ_IOUT (LINEAR11) */
static int read_pmbus(int r, int32_t *mv, int32_t *mw)
{
    uint8_t a = pmic_addr[(r - 1) / NPAGE];
    uint16_t vr, ir;
    if (page(a, (uint8_t)((r - 1) % NPAGE)) || rd16le(a, 0x8Bu, &vr) || rd16le(a, 0x8Cu, &ir))
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
    return r == 0 ? read_ina(mv, mw) : read_pmbus(r, mv, mw);
}

int pw_init(void)
{
    XIicPs_Config *c = XIicPs_LookupConfig(XPAR_XIICPS_0_BASEADDR);
    if (c == NULL || XIicPs_CfgInitialize(&iic, c, c->BaseAddress) != XST_SUCCESS) {
        xil_printf("power readout: no I2C controller\r\n");
        return 0;
    }
    XIicPs_SetSClk(&iic, 400000);
    nrail = 0;
    memset(rail_ok, 0, sizeof rail_ok);

    /* INA226: manufacturer 0x5449 ("TI"), die 0x226x; then 16 averages of
       1.1 ms shunt and bus conversions, continuous (a 35 ms window) */
    uint16_t mid, did;
    if (mux(MUX_INA) == 0 && rd16be(INA_ADDR, 0xFEu, &mid) == 0 &&
        rd16be(INA_ADDR, 0xFFu, &did) == 0 && mid == 0x5449u && (did & 0xFFF0u) == 0x2260u) {
        const uint8_t cfg[3] = { 0x00u, 0x45u, 0x27u };
        rail_ok[0] = (wr(INA_ADDR, cfg, 3) == 0);
    }

    /* IRPS5401: answers PMBUS_REVISION; a page is used if VOUT_MODE is LINEAR
       and VOUT and IOUT read back */
    if (mux(MUX_PMIC) == 0) {
        for (int p = 0; p < NPMIC; p++) {
            uint8_t rev;
            if (rd(pmic_addr[p], 0x98u, &rev, 1)) continue;
            for (int g = 0; g < NPAGE; g++) {
                int r = 1 + p * NPAGE + g;
                uint8_t mode;
                uint16_t v, i;
                if (page(pmic_addr[p], (uint8_t)g) || rd(pmic_addr[p], 0x20u, &mode, 1) ||
                    (mode >> 5) != 0 || rd16le(pmic_addr[p], 0x8Bu, &v) ||
                    rd16le(pmic_addr[p], 0x8Cu, &i))
                    continue;
                vout_exp[r] = (int8_t)((mode & 0x10u) ? (int)(mode & 0x1Fu) - 32 : (int)(mode & 0x1Fu));
                rail_ok[r] = 1;
            }
        }
    }

    for (int r = 0; r < NRAIL; r++) {
        int32_t mv, mw;
        if (!rail_ok[r]) continue;
        if (mux(r == 0 ? MUX_INA : MUX_PMIC) || read_rail(r, &mv, &mw)) { rail_ok[r] = 0; continue; }
        xil_printf("POWERRAIL,%s,%d,%d\r\n", rail_name[r], (int)mv, (int)mw);
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
        int want = (r == 0) ? MUX_INA : MUX_PMIC;
        if (!rail_ok[r]) continue;
        if (want != ch) {
            if (mux((uint8_t)want)) return;
            ch = want;
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
                       rail_name[r], (int)mv, (int)mw, cnt[ph][r], reps[ph],
                       (unsigned)(ms[ph] + 0.5));
        }
    memset(sum_mv, 0, sizeof sum_mv);
    memset(sum_mw, 0, sizeof sum_mw);
    memset(cnt, 0, sizeof cnt);
}
