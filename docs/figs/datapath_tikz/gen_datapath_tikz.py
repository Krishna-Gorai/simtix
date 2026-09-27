"""
gen_datapath_tikz.py -- SIMTiX warp_pool datapath as a verified TikZ figure.

    python gen_datapath_tikz.py      # writes simtix_datapath.tex, checks, builds PDF

Coordinates are millimetres, origin bottom-left. Every wire, block and label
is checked by dp_engine.verify(); the PDF is only built when it reports zero
errors. Source of truth for the structure: rtl/accel/warp_pool.sv.
"""
import subprocess, sys, os
from dp_engine import Fig

f = Fig()
W_ = f.wire
BR = '\\\\'


def t(*lines):
    return BR.join(lines)


def small(s, pt=5.5):
    return rf'{{\fontsize{{{pt}}}{{{pt * 1.15:.1f}}}\selectfont {s}}}'


# ============================================================================ FETCH  (F)
WST = f.box('wst', 3, 176, 19, 16, t('Warp state', 'wstate,', 'inflight'), 'mem', pt=6.5)
RRP = f.reg('rrp', 3, 155, 17, 8, r'rr\_ptr')
INC = f.circ('inc', 11.5, 139, 2.9, r'+1')
PE = f.box('pe', 27, 144, 9, 52, t('Round-robin', 'warp select'), 'ctl', rot=True)
STK = f.box('stk', 41, 142, 24, 58,
            t('SIMT stack', '4 warps', r'$\times$ 8 frames', r'\{npc, rpc,', r'mask\}, sp'), 'mem', pt=6.5)
IMEM = f.box('imem', 68, 139, 13, 14, t('Shared', 'memory', 'instr.', 'port'), 'ext', pt=5.5)
BFX = f.bar('bfx', 86, 100, 3.5, 99, 'F/X', lbl_below=True)

Y_SP, Y_RPC, Y_MASK, Y_PC, Y_INS, Y_W = 196, 192, 185, 168, 146, 122

W_('runnable', [WST.R(184), PE.L(184)])
W_('rr', [RRP.R(159), PE.L(159)])
W_('fetch_w', [PE.R(169), (38.5, 169), STK.L(169)])
W_('fetch_w', [(38.5, 169), (38.5, Y_W), BFX.L(Y_W)])
W_('fetch_w', [(38.5, 139), INC.Rp])
f.label(r'fetch\_w', 62, Y_W + 0.35, 'south', pt=5.5)
W_('rr_inc', [INC.Tp, RRP.B(11.5)])
for nm, yy, lb in (('stk_sp', Y_SP, 'sp'), ('stk_rpc', Y_RPC, 'rpc'), ('stk_mask', Y_MASK, 'mask')):
    W_(nm, [STK.R(yy), BFX.L(yy)], style='bus' if nm == 'stk_mask' else 'sig')
    f.label(lb, 75.5, yy + 0.35, 'south', pt=5.5)
W_('fetch_pc', [STK.R(Y_PC), BFX.L(Y_PC)])
W_('fetch_pc', [(74.5, Y_PC), IMEM.T(74.5)])
f.label(r'fetch\_pc', 69.5, Y_PC + 0.35, 'south', pt=5.5)
W_('instr_f', [IMEM.R(Y_INS), BFX.L(Y_INS)])

# ============================================================================ ISSUE / EXECUTE  (X)
DEC = f.box('dec', 114, 110, 15, 42, t('Decode', r'\&', 'imm gen'), 'ctl', pt=6.5)
W_('instr', [BFX.R(Y_INS), DEC.L(Y_INS)])
W_('issue_w', [BFX.R(Y_W), DEC.L(Y_W)])
f.label('instr', 108, Y_INS + 0.35, 'south', pt=5.5)
f.label(r'issue\_w', 108, Y_W + 0.35, 'south', pt=5.5)

VRF = f.box('vrf', 138, 114, 22, 32, t('VRF', 'LUTRAM', '2R / 1W', 'per lane'), 'mem', rep=True, pt=6.5)
FRF = f.box('frf', 138, 60, 22, 32, t('FRF', 'LUTRAM', '3R / 1W', 'per lane'), 'mem', rep=True, pt=6.5)
W_('raddr_v', [DEC.R(140), VRF.L(140)])
f.label(r'\{w,rs\}', 132.5, 140.4, 'south', pt=5.5)
W_('raddr_f', [DEC.B(121), (121, 84), FRF.L(84)])
f.label(r'\{w,fs\}', 125.5, 84.4, 'south', pt=5.5)

SEED = f.box('seed', 164, 124, 12, 14, t('Seed', 'a0=tid', 'a1--a4'), 'ctl', pt=5.5)
M1 = f.mux('m1', 180, [142, 134], ins=['1', '0'], sel='top')
M2 = f.mux('m2', 180, [127, 119], ins=['0', '1'], sel='bot')
W_('vrd1', [VRF.R(142), M1.inp[0]], style='bus')
W_('vrd2', [VRF.R(119), M2.inp[1]], style='bus')
W_('seed1', [SEED.R(134), M1.inp[1]], style='bus')
W_('seed2', [SEED.R(127), M2.inp[0]], style='bus')
f.stub('wr1', M1.selpt, 'up', 3.0, r'wr', pt=5.5)
f.stub('wr2', M2.selpt, 'down', 3.0, r'wr', pt=5.5)

MA = f.mux('ma', 202, [146, 142, 138], ins=['', '', ''], sel='bot')
MB = f.mux('mb', 202, [123, 118], ins=['', ''], sel='bot')
ALU = f.alu('alu', 213, 142, 120.5, 13, t(r'ALU', r'$\times$8'), rep=True)
W_('rv1', [M1.out, MA.inp[2]], style='bus')
W_('rv2', [M2.out, MB.inp[0]], style='bus')
W_('opa', [MA.out, ALU.a], style='bus')
W_('opb', [MB.out, ALU.b], style='bus')
f.label('rv1', 195.5, 138.35, 'south', pt=5.5)
f.label('rv2', 195.5, 123.35, 'south', pt=5.5)
f.stub('ma_pc', MA.inp[0], 'left', 2.4, 'pc', pt=5.5)
f.stub('ma_0', MA.inp[1], 'left', 2.4, '0', pt=5.5)
f.stub('opa_s', MA.selpt, 'down', 2.6, r'asel', pt=5.5)
f.stub('opb_s', MB.selpt, 'down', 2.6, r'bsel', pt=5.5)
W_('imm', [DEC.B(125), (125, 104), (196, 104), (196, 118), MB.inp[1]])
f.label('imm', 176, 104.35, 'south', pt=5.5)

# write-back value: ALU result / link (pc+4) / tid (csrr)
WBM = f.mux('wbm', 234, [139, 135, 131.25], ins=['', '', ''], sel='bot')
W_('alu_y', [ALU.out, WBM.inp[2]], style='bus')
W_('link', [(232, 145.8), (232, 139), WBM.inp[0]], style='bus')
W_('tidv', [(230, 145.8), (230, 135), WBM.inp[1]], style='bus')
f.label('pc+4', 232.4, 145.9, 'south west', pt=5.5)
f.label('tid', 229.6, 145.9, 'south east', pt=5.5)
f.stub('wbm_s', WBM.selpt, 'down', 2.6, r'wsel', pt=5.5)

# ---- control row: pop check  (cur_sp != 0) & (cur_pc == cur_rpc)
EQP = f.circ('eqp', 123, Y_RPC, 2.4, r'=', kind='ctl')
NZ = f.gate('nz', 'or', 112, [Y_SP], w=5.5, pad=1.8)
f.label(r'$\neq$0', 114.6, Y_SP + 2.0, 'south', pt=5.5)
W_('cur_sp', [BFX.R(Y_SP), NZ.inp[0]])
W_('cur_rpc', [BFX.R(Y_RPC), EQP.Lp])
ANDP = f.gate('andp', 'and', 130, [Y_SP, Y_RPC], w=6)
W_('nz', [NZ.out, ANDP.inp[0]])
W_('eqp', [EQP.Rp, ANDP.inp[1]])

# ---- control row: next-PC candidates
AI = f.circ('ai', 137, 161, 2.8, r'+')
A4 = f.circ('a4', 150, 174, 2.8, r'+4')
W_('cur_pc', [BFX.R(Y_PC), (150, Y_PC), A4.Bp])
W_('cur_pc', [(123, Y_PC), EQP.Bp])
W_('cur_pc', [(137, Y_PC), AI.Tp])
f.label(r'cur\_pc', 96, Y_PC + 0.35, 'south', pt=5.5)
W_('imm', [DEC.T(126), (126, 161), AI.Lp])

Y_FT, Y_JR, Y_TG = 174, 167.5, 161
NPC = f.mux('npc', 204, [Y_FT, Y_JR, Y_TG], ins=['', '', ''], sel='top', pad=2.4)
W_('fallthru', [A4.Rp, NPC.inp[0]])
W_('target', [AI.Rp, NPC.inp[2]])
f.label('fall-through', 175, Y_FT + 0.35, 'south', pt=5.5)
f.label('branch / jal target', 168, Y_TG + 0.35, 'south', pt=5.5)
f.stub('jalr', NPC.inp[1], 'left', 2.6, r'jalr', pt=5.5)
f.stub('npc_s', NPC.selpt, 'up', 2.4, r'psel', pt=5.5)

# ---- control row: per-lane branch resolve, divergence masks, stack update
BCMP = f.box('bcmp', 183, 153, 13, 6.5, r'cmp $\times$8', 'alu', pt=6, bold_first=False)
W_('rv2', [(188, 123), (188, BCMP.y0)], style='bus')
W_('rv1', [(192, 138), (192, BCMP.y0)], style='bus')
f.stub('f3', BCMP.L(156.25), 'left', 3.0, r'funct3', pt=5.5)

ANDT = f.gate('andt', 'and', 222, [188.5, Y_MASK], w=6)
ANDN = f.gate('andn', 'and', 222, [180, 176.5], w=6, neg_in=(1,))
W_('t', [BCMP.R(156.25), (218, 156.25), (218, 188.5), ANDT.inp[0]], style='bus')
W_('t', [(218, 176.5), ANDN.inp[1]], style='bus')
f.label(r't', 213, 156.6, 'south', pt=5.5)
W_('cur_mask', [BFX.R(Y_MASK), ANDT.inp[1]], style='bus')
W_('cur_mask', [(220, Y_MASK), (220, 180), ANDN.inp[0]], style='bus')
f.label(r'cur\_mask', 160, Y_MASK + 0.35, 'south', pt=5.5)

PUSH = f.box('push', 236, 158, 19, 40,
             t('Stack', 'update', '', small('uniform:'), small('retarget'), small('divergent:'),
               small('push frame'), small('pc = rpc:'), small('pop')), 'ctl', pt=6.5)
W_('taken', [ANDT.out, PUSH.L(ANDT.out[1])], style='bus')
W_('ntaken', [ANDN.out, PUSH.L(ANDN.out[1])], style='bus')
W_('npc', [NPC.out, PUSH.L(NPC.out[1])])
W_('do_pop', [ANDP.out, PUSH.L(ANDP.out[1])])
f.label('taken', 232, ANDT.out[1] + 0.35, 'south', pt=5.5)
f.label(r'ntaken', 232, ANDN.out[1] + 0.35, 'south', pt=5.5)
f.label('npc', 232, NPC.out[1] + 0.35, 'south', pt=5.5)
f.label(r'do\_pop', 175, ANDP.out[1] + 0.35, 'south', pt=5.5)

# ---- FP datapath beside the FRF: 5-stage FPU and the shared div/sqrt SFU
Y_FS3, Y_FS2, Y_FS1 = 88, 80, 72
C_FPU = f.reg('c_fpu', 172, 67, 6, 25, '')
U_FPU = f.box('u_fpu', 184, 69.5, 24, 21, t(r'FPU (5-stage)', 'FP32 / FP16', 'add mul FMA', 'cvt cmp sgnj'),
              'alu', rep=True, pt=5.5)
H_FPU = f.reg('h_fpu', 215, 73, 5, 14, '')
for yy, nm in ((Y_FS3, 'frv3'), (Y_FS2, 'frv2'), (Y_FS1, 'frv1')):
    W_(nm, [FRF.R(yy), C_FPU.L(yy)], style='bus')
W_('fpu_c', [C_FPU.R(80), U_FPU.L(80)], style='bus')
W_('fpu_r', [U_FPU.R(80), H_FPU.L(80)], style='bus')
f.stub('fpu_x', C_FPU.B(173.1), 'down', 3.0, r'rv1', pt=5.5)
f.label(r'fs3,2,1', 175, 92.35, 'south', pt=5.5)
f.label('fpc', 217.5, 87.35, 'south', pt=5.5)

C_SFU = f.reg('c_sfu', 172, 40, 6, 14, '')
W_('frv1', [(169, Y_FS1), (169, 50), C_SFU.L(50)], style='bus')
W_('frv2', [(166, Y_FS2), (166, 44), C_SFU.L(44)], style='bus')
f.label(r'fs1,2', 175, 54.35, 'south', pt=5.5)
# lane mux: 8:1 over the captured per-lane operands (lanes 0, 1, ..., 7)
LM = f.mux('lm', 183, [52, 49, 46, 43], pad=1.8, sel='top', ins=['0', '1', r'$\vdots$', '7'], w=6)
for yy, nm in ((52, 'sfu_l0'), (49, 'sfu_l1'), (43, 'sfu_l7')):
    W_(nm, [C_SFU.R(yy), (LM.inp[0][0], yy)])
LSEQ = f.box('lseq', 180.5, 57, 11, 6, t('lane seq.'), 'ctl', pt=5.5, bold_first=False)
W_('lane', [LSEQ.B(LM.selpt[0]), LM.selpt])
DSQ = f.box('dsq', 194, 41, 16, 12, t('div / sqrt', 'iterative', '1 shared'), 'alu', pt=5.5)
W_('sfu_a', [LM.out, DSQ.L(LM.out[1])])
H_SFU = f.reg('h_sfu', 215, 41, 5, 12, '')
W_('sfu_r', [DSQ.R(47), H_SFU.L(47)])
f.label('hold', 217.5, 53.35, 'south', pt=5.5)

# ============================================================================ ENGINES
RV1, RV2 = 270, 274
X_CAP, X_UNIT, X_HOLD = 292, 302, 332
UW = 24


def engine(name, ycen, h, ins, unit_text, cap_text, hold_text, pt=6):
    C = f.reg('c_' + name, X_CAP, ycen - h / 2, 5, h, '')
    U = f.box('u_' + name, X_UNIT, ycen - h / 2 - 0.5, UW, h + 1, unit_text, 'alu', rep=True, pt=pt)
    H = f.reg('h_' + name, X_HOLD, ycen - h / 2, 5, h, '')
    for rx, yy, net in ins:
        W_(net, [(rx, yy), C.L(yy)], style='bus')
    W_(name + '_c', [C.R(ycen), U.L(ycen)], style='bus')
    W_(name + '_r', [U.R(ycen), H.L(ycen)], style='bus')
    f.label(cap_text, X_CAP + 2.5, ycen + h / 2 + 0.35, 'south', pt=5.5)
    f.label(hold_text, X_HOLD + 2.5, ycen + h / 2 + 0.35, 'south', pt=5.5)
    return C, U, H


# integer operand rails (rv1 / rv2 enter from the top)
Y_RV1E, Y_RV2E = 149.6, 151.6
W_('rv1', [(192, Y_RV1E), (RV1, Y_RV1E), (RV1, 128)], style='bus', arrow=False)
W_('rv2', [(188, Y_RV2E), (RV2, Y_RV2E), (RV2, 74)], style='bus', arrow=False)

C_MUL, U_MUL, H_MUL = engine('mul', 144, 9, [(RV1, 147, 'rv1'), (RV2, 141.5, 'rv2')],
                             t('Integer MUL', r'3$\times$(16$\times$16) DSP'), 'q', 'mul', pt=5.5)
C_DOT, U_DOT, H_DOT = engine('dot', 125, 9, [(RV1, 128, 'rv1'), (RV2, 122.5, 'rv2')],
                             t('pdot8 INT8 dot', r'4 DSP + adder tree'), 'q', 'dot', pt=5.5)

# ---- coalescing memory engine ----------------------------------------------
Y_AD = 110
W_('alu_y', [(228, ALU.out[1]), (228, Y_AD), (X_CAP, Y_AD)], style='bus')
C_A = f.reg('c_a', X_CAP, 104, 5, 12, '')
f.label('addr', 250, Y_AD + 0.35, 'south', pt=5.5)
f.label('addr', X_CAP + 2.5, 116.35, 'south', pt=5.5)

# lead-lane mux: 8:1 over the captured per-lane addresses (lanes 0, 1, ..., 7)
LAM = f.mux('lam', 307, [113, 110, 107, 104], pad=1.8, sel='bot', ins=['0', '1', r'$\vdots$', '7'], w=6)
W_('a_vec', [C_A.R(Y_AD), (303.5, Y_AD)], style='bus', arrow=False)
W_('a_vec', [(303.5, Y_AD), LAM.inp[1]])
W_('a_vec', [(303.5, Y_AD), (303.5, 113), LAM.inp[0]])
W_('a_vec', [(303.5, Y_AD), (303.5, 104), LAM.inp[3]])
TAG = f.box('tag', 321, 102, 8, 17.5, t(r'=', r'$\times$8'), 'ctl', pt=6.5, bold_first=False)
Y_TAG = LAM.out[1]
W_('lead_a', [LAM.out, TAG.L(Y_TAG)])
W_('a_vec', [(300, Y_AD), (300, 117), TAG.L(117)], style='bus')
f.label('tag', 315, Y_TAG + 0.35, 'south', pt=5.5)
ANDG = f.gate('andg', 'and', 336, [113, 108], w=6)
W_('eq', [TAG.R(113), ANDG.inp[0]], style='bus')

# pending mask: loaded with cur_mask at issue, then pending & ~grp each cycle
PMUX = f.mux('pmux', 285, [97, 91], sel='bot', ins=['', ''])
f.stub('pm_m', PMUX.inp[0], 'left', 2.6, r'mask', pt=5.5)
f.stub('pm_s', PMUX.selpt, 'down', 2.6, r'issue', pt=5.5)
C_P = f.reg('c_p', X_CAP, 89, 5, 10, '')
W_('pmux_o', [PMUX.out, C_P.L(PMUX.out[1])], style='bus')
f.label('pend', X_CAP + 2.5, 99.35, 'south', pt=5.5)
PEL = f.box('pel', 304, 88, 11, 11, t('lowest', 'pending'), 'ctl', pt=5.5, bold_first=False)
W_('pend', [C_P.R(94), PEL.L(94)], style='bus')
W_('lead', [PEL.T(LAM.selpt[0]), LAM.selpt])
f.label('lead', LAM.selpt[0] + 0.5, 101.6, 'west', pt=5.5)
W_('pend', [(300.5, 94), (300.5, 84.5), (333, 84.5), (333, 108), ANDG.inp[1]], style='bus')
ANDPN = f.gate('andpn', 'and', 349, [110.5, 104], w=6, neg_in=(0,))
W_('grp', [ANDG.out, ANDPN.inp[0]], style='bus')
W_('pend', [(333, 104), ANDPN.inp[1]], style='bus')
W_('pnext', [ANDPN.out, (358, ANDPN.out[1]), (358, 81), (282, 81), (282, 91), PMUX.inp[1]], style='bus')
f.label('grp', 344.8, 110.85, 'south', pt=5.5)

# data side: store select, line port, shared memory, scratchpad, result select
SDM = f.mux('sdm', 285, [74, 68], sel='bot', ins=['', ''])
W_('rv2', [(RV2, 74), SDM.inp[0]], style='bus')
f.stub('sdm_f', SDM.inp[1], 'left', 2.6, r'frv2', pt=5.5, style='bus')
f.stub('sdm_s', SDM.selpt, 'down', 2.6, r'fsw', pt=5.5)
C_D = f.reg('c_d', X_CAP, 65, 5, 12, '')
W_('sd', [SDM.out, C_D.L(SDM.out[1])], style='bus')
f.label('data', X_CAP + 2.5, 77.35, 'south', pt=5.5)
LINE = f.box('line', 304, 58, 16, 16, t('Line port', 'store merge', 'load extract'), 'ctl', pt=5.5)
W_('sd_q', [C_D.R(71), LINE.L(71)], style='bus')
W_('lead_a', [(316.8, Y_TAG), LINE.T(316.8)])
W_('grp', [(346, 110.5), (346, 78), (319, 78), LINE.T(319)], style='bus')
DMEM = f.box('dmem', 330, 56, 18, 18, t('Shared', 'memory', 'data port', '256-b line'), 'ext', pt=5.5)
W_('wline', [LINE.R(69), DMEM.L(69)], style='wide')
W_('rline', [DMEM.L(62), LINE.R(62)], style='wide')
SCR = f.box('scr', 322, 38, 16, 10, t('Scratchpad', 'LUTRAM'), 'mem', pt=5.5)
f.stub('scr_i', SCR.L(43), 'left', 3, r'lead lane', pt=5.5)
RMUX = f.mux('rmux', 356, [51, 43], sel='top', ins=['', ''])
W_('ld', [LINE.B(312), (312, 51), RMUX.inp[0]], style='bus')
W_('scrd', [SCR.R(43), RMUX.inp[1]])
f.stub('rm_s', RMUX.selpt, 'up', 2.4, r'scratch', pt=5.5)

# ============================================================================ WRITEBACK  (W)
X_WB = 384
Y_FPB, Y_SFB = 33, 27
VWB = f.mux('vwb', X_WB, [118, 113, 108, 103, 98], sel='top', ins=['mul', 'alu', 'dot', 'mem', 'fpc'], w=7)
FWB = f.mux('fwb', X_WB, [40, Y_FPB, Y_SFB], sel='top', ins=['mem', 'fpc', 'sfu'], w=7, pad=2.8)
W_('mul_o', [H_MUL.R(144), (380, 144), (380, 118), VWB.inp[0]], style='bus')
W_('wbv', [WBM.out, (377, WBM.out[1]), (377, 113), VWB.inp[1]], style='bus')
f.label(r'wb\_val', 250, WBM.out[1] + 0.35, 'south', pt=5.5)
W_('dot_o', [H_DOT.R(125), (374, 125), (374, 108), VWB.inp[2]], style='bus')
W_('mem_o', [RMUX.out, (366, RMUX.out[1]), (366, 103), VWB.inp[3]], style='bus')
W_('mem_o', [(366, RMUX.out[1]), (366, 40), FWB.inp[0]], style='bus')
W_('fpc_o', [H_FPU.R(80), (224, 80), (224, Y_FPB), FWB.inp[1]], style='bus')
W_('fpc_o', [(370, Y_FPB), (370, 98), VWB.inp[4]], style='bus')
W_('sfu_o', [H_SFU.R(47), (221, 47), (221, Y_SFB), FWB.inp[2]], style='bus')
f.label('fpc', 300, Y_FPB + 0.35, 'south', pt=5.5)
f.label('sfu', 300, Y_SFB + 0.35, 'south', pt=5.5)
f.label(t('VRF', 'write'), X_WB + 7.6, VWB.out[1] + 2.5, 'south west', pt=5.5, bold=True)
f.label(t('FRF', 'write'), X_WB - 0.6, FWB.y1 + 0.2, 'south east', pt=5.5, bold=True)
f.stub('fwb_s', FWB.selpt, 'up', 2.4, r'prio', pt=5.5)

# register-file write ports (bottom channel, back to the VRF / FRF)
Y_VB, Y_FB = 18, 21.5
X_VW, X_FW = 133, 135.5
W_('vrf_w', [VWB.out, (395, VWB.out[1]), (395, Y_VB), (X_VW, Y_VB), (X_VW, 118), VRF.L(118)], style='bus')
W_('frf_w', [FWB.out, (392.5, FWB.out[1]), (392.5, Y_FB), (X_FW, Y_FB), (X_FW, 64), FRF.L(64)], style='bus')
f.label(r'VRF write port: \{w, rd\}, data, lane enables', 250, Y_VB + 0.35, 'south', pt=5.5)
f.label(r'FRF write port: \{w, fd\}, data, lane enables', 250, Y_FB + 0.35, 'south', pt=5.5)

# engine resume + stack update (top channel, back to fetch)
RES = f.box('res', 372, 158, 22, 14, t('Resume', r'W\_RUN,', r'pc$\gets$resume'), 'ctl', pt=5.5)
# write-back arbiter control: drives the VRF arbiter's select and, when an
# engine's result is granted the port, fires that engine's resume
ARB = f.box('arb', 382, 127, 12, 8, t('WB', 'arbiter'), 'ctl', pt=5.5, bold_first=False)
W_('vsel', [ARB.B(VWB.selpt[0]), VWB.selpt], style='ctl')
W_('wbfire', [ARB.T(388), (388, RES.y0)], style='ctl')
f.label(t('grant', r'(wb fire)'), 388.5, 146, 'west', pt=5.5)
Y_T1, Y_T2 = 204, 207.5
W_('stk_upd', [PUSH.T(245.5), (245.5, Y_T1), (60, Y_T1), STK.T(60)])
f.label(r'stack write: npc, push / pop, sp$\pm$1', 160, Y_T1 + 0.35, 'south', pt=5.5)
W_('resume', [RES.T(383), (383, Y_T2), (48, Y_T2), STK.T(48)], style='ctl')
W_('resume', [(48, Y_T2), (12, Y_T2), WST.T(12)], style='ctl')
f.label(r'resume: \{w, pc\} $\to$ W\_RUN', 300, Y_T2 + 0.35, 'south', pt=5.5)

# ============================================================================ tighten
f.shift(262, -8)      # empty corridor between the stack-update block and the rails
f.shift(100, -12)     # empty corridor between the F/X register and decode


# ============================================================================ stage bands + legend
def add_frame():
    x0, y0, x1, y1 = f.extent()
    top = y1 + 7.5
    bot = y0 - 1.5
    b1 = (BFX.x0 + BFX.x1) / 2
    rails_x = max(p[0] for ln in f.nets['rv1']['lines'] for p in ln['pts'] if abs(p[1] - Y_RV1E) < 0.01)
    b2 = (PUSH.x1 + rails_x) / 2
    memo_x = min(p[0] for ln in f.nets['mem_o']['lines'] for p in ln['pts'][1:])
    b3 = (RMUX.x1 + memo_x) / 2
    f.bands = [(x0 - 1.5, bot, b1, top, 'FETCH'),
               (b1, bot, b2, top, 'ISSUE / EXECUTE'),
               (b2, bot, b3, top, 'PARK-AND-RESUME ENGINES'),
               (b3, bot, x1 + 1.5, top, 'WB')]
    return x0, bot


def add_legend(lx, ly, lw, lh):
    f.frames.append((lx, ly, lx + lw, ly + lh))
    f.label('Notation', lx + 2, ly + lh - 1.2, 'north west', pt=6.5, bold=True)
    row = ly + lh - 9.5
    dy = 6.6
    sx = lx + 3
    tx = lx + 19

    def txt(s):
        f.label(s, tx, row, 'west', pt=5.5)

    W_('lg_s', [(sx, row), (sx + 12, row)])
    txt('scalar signal'); row -= dy
    W_('lg_b', [(sx, row), (sx + 12, row)], style='bus')
    txt(r'8-lane bus (8 $\times$ 32 b)'); row -= dy
    W_('lg_w', [(sx, row), (sx + 12, row)], style='wide')
    txt('256-bit memory line'); row -= dy
    W_('lg_c', [(sx, row), (sx + 12, row)], style='ctl')
    txt('control')

if __name__ == '__main__':
    here = os.path.dirname(os.path.abspath(__file__))
    x0, bot = add_frame()
    add_legend(x0 + 0.5, bot + 2.5, 46, 36)
    for w in f.warn:
        print('WARN', w)
    errs = f.verify()
    for e in errs:
        print(e)
    X0, Y0, X1, Y1 = f.extent()
    print(f"extent {X1 - X0:.0f} x {Y1 - Y0:.0f} mm")
    cross = f.emit(os.path.join(here, 'simtix_datapath_fig.tex'))
    print(f"{len(errs)} errors, {len(cross)} crossings")
    if errs:
        sys.exit(1)

    def latex(name):
        r = subprocess.run(['pdflatex', '-interaction=nonstopmode', '-halt-on-error', name],
                           cwd=here, capture_output=True, text=True)
        if r.returncode:
            print([l for l in r.stdout.splitlines() if l.startswith('!') or l.startswith('l.')][:6])
            sys.exit(1)
        return r.stdout

    # page 1: the figure
    latex('simtix_datapath_fig.tex')
    info = subprocess.run(['pdfinfo', 'simtix_datapath_fig.pdf'], cwd=here, capture_output=True, text=True).stdout
    pw, ph = [float(v) for v in info.split('Page size:')[1].split('pts')[0].split('x')]
    # page 2: the glossary (glossary.tex), same page size; one two-page PDF
    wrap = rf"""\documentclass{{article}}
\usepackage[paperwidth={pw:.2f}bp,paperheight={ph:.2f}bp,margin=7mm]{{geometry}}
\usepackage[T1]{{fontenc}}\usepackage{{helvet}}\renewcommand{{\familydefault}}{{\sfdefault}}
\usepackage{{pdfpages,tabularx,array,xcolor,amssymb,multicol,enumitem,longtable}}
\renewcommand{{\ttdefault}}{{lmtt}}
\pagestyle{{empty}}\setlength{{\parindent}}{{0pt}}
\begin{{document}}
\includepdf[pages=1,noautoscale]{{simtix_datapath_fig.pdf}}
\input{{operation.tex}}
\input{{connections.tex}}
\input{{glossary.tex}}
\end{{document}}
"""
    with open(os.path.join(here, 'simtix_datapath.tex'), 'w', encoding='utf-8') as fh:
        fh.write(wrap)
    out = latex('simtix_datapath.tex')
    if 'Overfull' in out or 'overfull' in open(os.path.join(here, 'simtix_datapath.log'), encoding='latin-1').read():
        print('WARN overfull boxes on the glossary page')
    npages = subprocess.run(['pdfinfo', 'simtix_datapath.pdf'], cwd=here, capture_output=True, text=True).stdout
    print('pages:', npages.split('Pages:')[1].split()[0])
    print('built')
