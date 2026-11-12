/* test_hconsts.c - print s2_hotspot_consts for n = 32, 512, 1024 (compare with gen_suite2) */
#include <stdio.h>
#include "s2_ref.h"
int main(void)
{
    const unsigned n[3] = { 32, 512, 1024 };
    for (int i = 0; i < 3; i++) {
        float k[5];
        s2_hotspot_consts(n[i], k);
        for (int j = 0; j < 5; j++) printf("%08x ", s2_u(k[j]));
        printf("\n");
    }
    return 0;
}
