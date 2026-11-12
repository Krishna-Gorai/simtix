"""rv_qtest_input.py -- RiVEC's in_64K.input as a C header of FP32 bits (fscanf %f rounding),
for kernels/rivec/qtest/rv_qtest.c:  python sim/rv_qtest_input.py <out.h>"""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rv_data  # noqa: E402

n, cols, ot, _ = rv_data.blackscholes('in_64K.input')
out = ['/* in_64K.input as FP32 bits (fscanf %f): S K r v T, type (generated) */', '#define BS_N %d' % n]
for name, c in zip(['bs_S', 'bs_K', 'bs_r', 'bs_v', 'bs_T'], cols):
    out.append('static const unsigned %s[%d] = {' % (name, n) + ','.join('0x%08x' % w for w in c) + '};')
out.append('static const int bs_type[%d] = {' % n + ','.join(map(str, ot)) + '};')
open(sys.argv[1], 'w').write('\n'.join(out) + '\n')
