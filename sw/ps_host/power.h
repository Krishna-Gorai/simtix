/* power.h  -  ZCU104 board power readout (power.c) */
#ifndef POWER_H
#define POWER_H
#include <stdint.h>

enum { PW_NONE = -1, PW_IDLE = 0, PW_ACCEL = 1, PW_A53 = 2, PW_PHASES = 3 };

int  pw_init(void);                 /* number of rails found; 0 = no readout */
void pw_phase(int phase);           /* samples go to this phase (PW_NONE: dropped) */
void pw_sample(void);               /* read every rail once */
void pw_report(const char *app, uint32_t size, const uint32_t reps[PW_PHASES],
               const double ms[PW_PHASES]);   /* print and clear the averages */

#endif
