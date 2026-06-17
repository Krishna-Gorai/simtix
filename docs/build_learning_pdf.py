# build_learning_pdf.py  -  generate SIMTiX_Learning_Guide.pdf
#
# Renders the full "SIMTiX from first principles" course + cycle-by-cycle trace
# into a styled PDF. Uses DejaVu fonts (from matplotlib) for full Unicode so the
# box-drawing chip diagram, arrows and Greek symbols render correctly.
#
#   python build_learning_pdf.py
#
import os, re, matplotlib
from reportlab.lib.pagesizes import A4, landscape
from reportlab.lib.units import cm
from reportlab.lib import colors
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.enums import TA_JUSTIFY, TA_CENTER, TA_LEFT
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfbase.pdfmetrics import registerFontFamily
from reportlab.platypus import (BaseDocTemplate, PageTemplate, Frame, Paragraph,
                                Spacer, Table, TableStyle, Preformatted, PageBreak,
                                NextPageTemplate, KeepTogether)

# ── Fonts ────────────────────────────────────────────────────────────────────
FT = os.path.join(matplotlib.get_data_path(), "fonts", "ttf")
pdfmetrics.registerFont(TTFont("Body",      os.path.join(FT, "DejaVuSans.ttf")))
pdfmetrics.registerFont(TTFont("Body-Bold", os.path.join(FT, "DejaVuSans-Bold.ttf")))
pdfmetrics.registerFont(TTFont("Body-Obl",  os.path.join(FT, "DejaVuSans-Oblique.ttf")))
pdfmetrics.registerFont(TTFont("Mono",      os.path.join(FT, "DejaVuSansMono.ttf")))
pdfmetrics.registerFont(TTFont("Mono-Bold", os.path.join(FT, "DejaVuSansMono-Bold.ttf")))
registerFontFamily("Body", normal="Body", bold="Body-Bold",
                   italic="Body-Obl", boldItalic="Body-Bold")
registerFontFamily("Mono", normal="Mono", bold="Mono-Bold",
                   italic="Mono", boldItalic="Mono-Bold")

# ── Palette ──────────────────────────────────────────────────────────────────
NAVY   = colors.HexColor("#16324f")
BLUE   = colors.HexColor("#1f6feb")
TEAL   = colors.HexColor("#0b7285")
INK    = colors.HexColor("#1b1b1b")
GREY   = colors.HexColor("#6b7280")
CODEBG = colors.HexColor("#f3f4f6")
CODEBD = colors.HexColor("#d0d7de")
HDRBG  = colors.HexColor("#16324f")
ROWBG  = colors.HexColor("#eef3f8")

# ── Styles ───────────────────────────────────────────────────────────────────
ss = getSampleStyleSheet()
body = ParagraphStyle("body", parent=ss["Normal"], fontName="Body", fontSize=10.3,
                      leading=15, alignment=TA_JUSTIFY, textColor=INK, spaceAfter=6)
bodyL = ParagraphStyle("bodyL", parent=body, alignment=TA_LEFT)
h1 = ParagraphStyle("h1", parent=body, fontName="Body-Bold", fontSize=17, leading=21,
                    textColor=NAVY, spaceBefore=20, spaceAfter=8, alignment=TA_LEFT)
h2 = ParagraphStyle("h2", parent=body, fontName="Body-Bold", fontSize=12.5, leading=16,
                    textColor=BLUE, spaceBefore=13, spaceAfter=5, alignment=TA_LEFT)
h3 = ParagraphStyle("h3", parent=body, fontName="Body-Bold", fontSize=10.8, leading=14,
                    textColor=TEAL, spaceBefore=9, spaceAfter=3, alignment=TA_LEFT)
bullet = ParagraphStyle("bullet", parent=body, leftIndent=16, bulletIndent=4, spaceAfter=3)
codest = ParagraphStyle("code", parent=body, fontName="Mono", fontSize=8.4, leading=11.2,
                        textColor=INK, alignment=TA_LEFT)
cell = ParagraphStyle("cell", parent=body, fontSize=8.6, leading=11, alignment=TA_LEFT,
                      spaceAfter=0)
cellb = ParagraphStyle("cellb", parent=cell, fontName="Body-Bold")
cellw = ParagraphStyle("cellw", parent=cell, textColor=colors.white, fontName="Body-Bold")
cellmono = ParagraphStyle("cellmono", parent=cell, fontName="Mono", fontSize=8.0)
tcell = ParagraphStyle("tcell", parent=cell, fontSize=7.3, leading=9.2)   # tight (trace)
tcellb = ParagraphStyle("tcellb", parent=tcell, fontName="Body-Bold")
tcellm = ParagraphStyle("tcellm", parent=tcell, fontName="Mono", fontSize=7.0)
tcellw = ParagraphStyle("tcellw", parent=tcell, textColor=colors.white, fontName="Body-Bold")
cover_t = ParagraphStyle("cover_t", parent=body, fontName="Body-Bold", fontSize=30,
                         leading=36, textColor=NAVY, alignment=TA_CENTER)
cover_s = ParagraphStyle("cover_s", parent=body, fontSize=14, leading=20, textColor=TEAL,
                         alignment=TA_CENTER)
cover_m = ParagraphStyle("cover_m", parent=body, fontSize=10.5, leading=16, textColor=GREY,
                         alignment=TA_CENTER)

# ── Inline markdown: **bold**, `mono` ────────────────────────────────────────
def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

def inl(s):
    s = esc(s)
    s = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", s)
    s = re.sub(r"`(.+?)`", r'<font face="Mono" size=9.2>\1</font>', s)
    return s

def P(s, style=body):  return Paragraph(inl(s), style)
def B(s):              return Paragraph("•&nbsp;&nbsp;" + inl(s), bullet)
def CP(s, style=cell): return Paragraph(inl(s), style)

def code(text):
    pre = Preformatted(esc(text.strip("\n")), codest)
    t = Table([[pre]], colWidths=[17.0*cm])
    t.setStyle(TableStyle([
        ("BACKGROUND", (0,0), (-1,-1), CODEBG),
        ("BOX",        (0,0), (-1,-1), 0.6, CODEBD),
        ("LEFTPADDING",(0,0), (-1,-1), 8), ("RIGHTPADDING",(0,0),(-1,-1),8),
        ("TOPPADDING", (0,0), (-1,-1), 6), ("BOTTOMPADDING",(0,0),(-1,-1),6),
    ]))
    return t

def mktable(rows, widths, header=True, font_hdr=cellw, font_cell=cell, zebra=True):
    data = []
    for r in rows:
        data.append([c if hasattr(c, "wrapOn") else CP(str(c), font_cell) for c in r])
    if header:
        data[0] = [c if hasattr(c, "wrapOn") else CP(str(c), font_hdr) for c in rows[0]]
    t = Table(data, colWidths=widths, repeatRows=1 if header else 0)
    sty = [
        ("GRID", (0,0), (-1,-1), 0.5, CODEBD),
        ("VALIGN", (0,0), (-1,-1), "TOP"),
        ("LEFTPADDING",(0,0),(-1,-1),5), ("RIGHTPADDING",(0,0),(-1,-1),5),
        ("TOPPADDING",(0,0),(-1,-1),3), ("BOTTOMPADDING",(0,0),(-1,-1),3),
    ]
    if header:
        sty += [("BACKGROUND",(0,0),(-1,0),HDRBG)]
        if zebra:
            for i in range(2, len(data), 2):
                sty.append(("BACKGROUND",(0,i),(-1,i),ROWBG))
    t.setStyle(TableStyle(sty))
    return t

story = []
def add(*xs): story.extend(xs)
def sp(h=6): story.append(Spacer(1, h))

# ═══════════════════════════════════════════════════════════════════════════════
#  COVER
# ═══════════════════════════════════════════════════════════════════════════════
add(Spacer(1, 4.8*cm))
add(Paragraph("SIMTiX", cover_t))
add(Spacer(1, 0.3*cm))
add(Paragraph("A GPU-inspired SIMT accelerator on RISC-V", cover_s))
add(Spacer(1, 0.2*cm))
add(Paragraph("From First Principles to Silicon &mdash; A Learning Guide", cover_s))
add(Spacer(1, 1.6*cm))
add(Paragraph("Covers: the core idea &bull; SIMT theory &bull; build methodology &bull; "
              "module-by-module function &bull; full execution mechanism &bull; "
              "how the result 964 is computed &bull; a complete cycle-by-cycle trace",
              cover_m))
add(Spacer(1, 2.4*cm))
add(Paragraph("Krishna Gorai", cover_m))
add(Paragraph("github.com/Krishna-Gorai/simtix", cover_m))
add(NextPageTemplate("portrait"))
add(PageBreak())

# ═══════════════════════════════════════════════════════════════════════════════
#  PART 0
# ═══════════════════════════════════════════════════════════════════════════════
add(P("Part 0 — The One-Sentence Idea", h1))
add(P("SIMTiX is a tiny GPU-style “do-the-same-thing-to-many-data-elements” "
      "accelerator, bolted onto an ordinary RISC-V CPU, where the CPU acts as the boss "
      "and the accelerator is the muscle for parallel work."))
add(P("Everything else is detail about <i>how</i> the boss tells the muscle what to do, "
      "<i>how</i> the muscle does 8 things at once, and <i>how</i> you proved it works on "
      "a real FPGA."))

# PART 1
add(P("Part 1 — The Problem It Solves (why GPUs exist)", h1))
add(P("A normal CPU executes **one instruction on one piece of data at a time**. To add "
      "two 8-element arrays:"))
add(code("for i in 0..7:   C[i] = A[i] + B[i]"))
add(P("a CPU loops 8 times — fetch/decode/execute the <i>same</i> add eight separate "
      "times. That is wasteful: the instruction is identical each iteration; only the "
      "<i>data</i> differs."))
add(P("The GPU insight, called **SIMT** (Single Instruction, Multiple Threads): keep "
      "**one** instruction stream, but run it on **many parallel datapaths (“lanes”) "
      "at once**. One `add` instruction → 8 adds happen simultaneously, one per lane, "
      "each on its own data element. An 8-iteration loop becomes effectively one step. "
      "SIMTiX is a from-scratch hardware implementation of that idea, sized small "
      "(8 lanes, 4 warps) so it actually fits, builds, and runs end-to-end."))

# PART 2 — vocab
add(P("Part 2 — The Vocabulary (six words and the rest is easy)", h1))
vocab = [
    ["Term", "Meaning in SIMTiX", "Where in code"],
    ["Lane", "One physical ALU+register slice. There are 8 (NUM_LANES=8). All lanes run "
             "the same instruction on different data.", "warp_pool.sv per-lane loops"],
    ["Thread", "One logical worker doing the kernel for one data element "
               "(e.g. computing C[3]).", "seeded via tid"],
    ["Warp", "A bundle of threads marching in lockstep on the 8 lanes. WARP_SIZE=8, "
             "so one warp = 8 threads = fills all 8 lanes.", "wstate[warp]"],
    ["Warp pool", "The hardware holds 4 warps resident at once (NUM_WARPS=4) and "
                  "interleaves them to hide memory latency.", "warp_pool.sv"],
    ["Kernel", "The little program each thread runs: C[tid]=A[tid]+B[tid].",
               "shared_mem.sv words 0x080..0x088"],
    ["MMIO", "Memory-Mapped I/O — the CPU controls the accelerator by writing special "
             "addresses, as if poking a device's registers.", "mmio_regs.sv"],
]
add(mktable(vocab, [2.6*cm, 9.4*cm, 5.0*cm]))
sp()
add(P("**Key relationship:** 8 threads ÷ 8 lanes/warp = **1 warp** for the demo "
      "workload. So in the actual run, exactly one warp fills all 8 lanes; the multi-warp "
      "pool exists to scale but is not stressed by this tiny job."))

# PART 3 — methodology
add(P("Part 3 — The Methodology: how it was built", h1))
add(P("The project used a **green-milestone methodology**: every milestone is a "
      "self-contained step that lints clean, simulates green, and is committed, before the "
      "next one starts. The system is <i>always working</i> — each step makes it do more. "
      "This mirrors how real chip teams de-risk a design."))
mil = [
    ["Milestone", "What it added"],
    ["M2", "One warp, 8 lanes, basic RV32I execution across the lanes."],
    ["M3", "The warp pool: 4 warps + round-robin scheduler (latency hiding)."],
    ["M4", "Memory coalescing: merge 8 lanes' accesses into one wide transaction."],
    ["M5", "Control divergence (true SIMT): if/loops via a reconvergence stack."],
    ["M6", "RV32M mul + per-warp scratchpad memory."],
    ["M7", "Energy study: divergence-aware lane clock-gating accounting."],
    ["M8 / M9", "Move the vector register file (VRF) and scratchpad into LUTRAM."],
    ["M10", "The whole chip (chip_top): CPU + accelerator + shared mem + driver ROM."],
    ["M11", "Full place & route → timing-closed bitstream on ZCU104 (xczu7ev)."],
    ["M12", "CPU-side input loading: the host CPU writes A/B at runtime."],
    ["M13", "Post-implementation gate-level sim: the routed netlist still gives 964."],
]
add(mktable(mil, [2.4*cm, 14.6*cm]))
sp()
add(P("**The lesson:** correctness-first, incremental, always-green, always-committed."))

# PART 4 — anatomy
add(P("Part 4 — System Anatomy (the map of chip_top)", h1))
add(P("The full chip is four blocks and two output pins (`clk`/`rst` in, `done`/`result` out):"))
diagram = r"""
        +----------------------- chip_top.sv ----------------------+
        |                                                          |
 clk -->|   +--------------+   instr   +------------------+        |
 rst -->|   | riscv_pipeline|<----------| cpu_driver_rom   |       |
        |   |  (HOST CPU)   |  addr --->|  (boss's program)|       |
        |   |  5-stage      |           +------------------+        |
        |   +------+--------+                                       |
        |          | data bus (ALUResultM, WriteDataM, ReadDataM)  |
        |   +------v------ address decode (top 4 bits) -------+     |
        |   | 0x9.. -> result reg   0x8.. -> MMIO  else->mem  |     |
        |   +--+-----------+----------------------+-----------+     |
        |      |           |                      |                |
        |  +---v---+   +----v---------+    +-------v--------+       |
        |  | result|   |  simt_accel  |<-->|   shared_mem   |      |
        |  |  reg  |   | (ACCELERATOR)|imem| (kernel+A+B+C) |      |
        |  +---+---+   |  mmio_regs   |dmem|  8 LUTRAM banks |      |
        |      |       |  warp_pool   |    +----------------+       |
        |      |       +--------------+                            |
        +------+----------------------------------------------------+
  done <-+
result <-+
"""
add(code(diagram))
sp(2)
add(P("One-line job of each module:", h3))
modtab = [
    ["Module", "File", "Job"],
    ["riscv_pipeline", "rtl/cpu/riscv_pipeline.v",
     "The host CPU — an ordinary 5-stage RISC-V core. The “boss.”"],
    ["cpu_driver_rom", "rtl/soc/cpu_driver_rom.sv",
     "The boss's program, baked into a ROM."],
    ["simt_accel", "rtl/accel/simt_accel.sv",
     "Accelerator shell: command registers + dispatcher FSM."],
    ["mmio_regs", "rtl/accel/mmio_regs.sv",
     "The control panel — registers the CPU writes to give commands."],
    ["warp_pool", "rtl/accel/warp_pool.sv",
     "The actual SIMT engine: lanes, warps, scheduler, memory engine, divergence stack."],
    ["shared_mem", "rtl/soc/shared_mem.sv",
     "Shared memory holding the kernel + A/B/C arrays. CPU and accelerator both reach it."],
    ["simtix_pkg", "rtl/accel/simtix_pkg.sv",
     "Constants — sizes, the MMIO register map, opcode encodings."],
]
add(mktable(modtab, [3.0*cm, 4.8*cm, 9.2*cm], font_cell=cellmono))

# PART 5 — execution mechanism
add(P("Part 5 — The Execution Mechanism, End to End", h1))
add(P("The theory of how it actually runs, as a story in six acts — what happens from "
      "the moment you press reset."))

add(P("Act 1 — Boot &amp; the CPU loads the inputs (M12)", h2))
add(P("On reset the CPU's PC is `0x0000_0000` and it fetches from `cpu_driver_rom`. The "
      "first 14 instructions are a **store loop** that writes the inputs into shared memory:"))
add(code("A[i] = 10 + i     @ 0x300   ->  A = {10,11,12,13,14,15,16,17}\n"
         "B[i] = 100 + 2i   @ 0x340   ->  B = {100,102,104,106,108,110,112,114}"))
add(P("Address `0x300` has top nibble `0x3` — neither `0x8` nor `0x9` — so the "
      "decoder routes it to shared memory. The memory no longer preloads A/B, so a correct "
      "result **proves the CPU genuinely moved the data**."))

add(P("Act 2 — The CPU programs the accelerator over MMIO", h2))
add(P("The CPU loads `x1 = 0x8000_0000` and stores the command block. Top nibble `0x8` "
      "asserts `is_mmio`, so these stores land in `mmio_regs`:"))
add(code("kernel_pc = 0x200   base_a = 0x300   base_b = 0x340\n"
         "base_c    = 0x380   N      = 8"))
add(P("Each store hits the `case(offset)` in mmio_regs and latches one register. This is "
      "the **driver/device contract**: software fills known registers, then rings a doorbell."))

add(P("Act 3 — The doorbell: GO", h2))
add(P("Writing `1` to `REG_CTRL` (offset 0x14) produces a **1-cycle go_pulse**, which "
      "drives the dispatcher FSM in simt_accel: `D_IDLE → D_LAUNCH` (pulses pool_start, "
      "handing the whole grid to the warp pool) `→ D_RUN` (counts cycles until "
      "pool_done) `→ D_DONE` (latches REG_CYCLES)."))

add(P("Act 4 — The warp pool executes the kernel (the SIMT core)", h2))
add(P("On start the pool computes `total_warps = ceil(8/8) = 1`, so **one warp** spawns "
      "and fills all 8 lanes. Each lane's `a0` is seeded with its thread id "
      "(lane 0 → tid 0 … lane 7 → tid 7); the kernel's argument registers "
      "(a1=&A, a2=&B, a3=&C, a4=N) are seeded identically. The warp then runs the 9-"
      "instruction kernel one instruction at a time, but **8 lanes wide**:"))
add(code(
"slli t0, a0, 2      # t0 = tid*4   (byte offset)     <- each lane: its own tid\n"
"add  t1, a1, t0     # t1 = &A[tid]\n"
"lw   t2, 0(t1)      # t2 = A[tid]                     <- 8 loads at once\n"
"add  t3, a2, t0     # t3 = &B[tid]\n"
"lw   t4, 0(t3)      # t4 = B[tid]                     <- 8 loads at once\n"
"add  t2, t2, t4     # t2 = A[tid] + B[tid]            <- 8 adds at once\n"
"add  t5, a3, t0     # t5 = &C[tid]\n"
"sw   t2, 0(t5)      # C[tid] = result                 <- 8 stores at once\n"
"ecall               # thread done"))
add(P("The execution loop does up to three things each cycle: **spawn** a warp into a free "
      "slot, **issue** one runnable warp on the shared datapath (round-robin), and "
      "**advance the memory engine**. For a compute op the hardware computes the result "
      "independently for all 8 lanes in parallel — one instruction, eight results. "
      "That is SIMT in silicon."))

add(P("Act 5 — Memory coalescing (the M4 cleverness)", h2))
add(P("For `lw t2, 0(t1)` the 8 lanes generate addresses 0x300, 0x304, … 0x31C — "
      "all inside one 32-byte cache line. The coalescing engine services **all 8 lanes in a "
      "single 256-bit transaction** instead of 8. `dbg_mem_txns` counts them; the whole "
      "kernel uses just **3** (one per lw/lw/sw). The wide line comes from shared_mem's "
      "8 LUTRAM banks read in parallel."))

add(P("Act 6 — Retire, read-back, publish", h2))
add(P("Each lane hits `ecall` and the warp retires; when nothing is left the pool pulses "
      "`done`. The CPU has been **polling** STATUS.DONE; once set it reads C[0..7] back, "
      "sums them, and stores the sum to `0x9000_0000` (top nibble 0x9 → result register "
      "latches the value and raises the chip's `done` pin). Then it halts in a self-loop."))

# PART 6 — 964
add(P("Part 6 — How the Result 964 Is Computed", h1))
add(code(
"A[i] = 10 + i        ->   10, 11, 12, 13, 14, 15, 16, 17\n"
"B[i] = 100 + 2i      ->  100,102,104,106,108,110,112,114\n"
"-------------------------------------------------------------\n"
"C[i] = A[i] + B[i]   ->  110,113,116,119,122,125,128,131  = 110 + 3i\n"
"\n"
"result = sum C[i]  for i=0..7\n"
"       = sum (110 + 3i)\n"
"       = (8 x 110) + 3 x (0+1+2+3+4+5+6+7)\n"
"       = 880 + 3 x 28\n"
"       = 880 + 84\n"
"       = 964"))
sp(2)
add(P("**Why a sum and not the array?** A single 32-bit `result` pin cannot show 8 values, "
      "so the CPU collapses them into one **checksum**. 964 is reachable only if every "
      "stage worked: the CPU wrote A/B (M12), MMIO reached the accelerator, the warp ran "
      "the kernel on all lanes, coalesced memory hit the right addresses, and the CPU read "
      "C back and summed it. Any broken link gives a different number (A=B=0 → 0; a "
      "missed C write leaves 0xdeadbeef poison). **964 is a single-number proof that the "
      "entire CPU → memory → accelerator → memory → CPU loop is correct.**"))

# PART 7 — advanced
add(P("Part 7 — The Advanced Bits (for interviews)", h1))
add(P("**1. The reconvergence stack (control divergence, M5).** Real GPU code has "
      "`if (cond)` where some lanes branch and some do not. A per-warp SIMT stack pushes a "
      "frame on a divergent branch so one lane group runs while the other waits, then they "
      "reconverge at a join PC. `dbg_divergences` counts events. (The demo kernel is "
      "uniform, but the hardware handles divergence.)"))
add(P("**2. Round-robin scheduling &amp; latency hiding (M3).** With 4 warp slots and one "
      "datapath, the scheduler issues a different warp each cycle. When one warp stalls on "
      "memory, others keep computing — the single most important GPU performance idea."))
add(P("**3. The VRF write arbiter (M8/M9).** The register file is LUTRAM with one write "
      "port per lane. When a compute result and a returning load collide, the memory write "
      "wins and the compute instruction re-issues next cycle (it is idempotent). The "
      "`reg_written` trick avoids clearing 32 registers on spawn (which broke RAM "
      "inference): an unwritten register simply returns its seed value on read."))
add(P("**4. The scratchpad (M6).** A small per-warp on-chip memory at 0x4000_0000, served "
      "in-engine and never touching global memory — the GPU “shared memory” concept."))

# PART 8 — verification
add(P("Part 8 — Four Independent Proofs (all give 964)", h1))
ver = [
    ["Level", "What it proves", "How"],
    ["1. RTL simulation", "The logic is correct",
     "Verilator/xsim on the .sv source; tb_chip_top checks result==964"],
    ["2. GUI behavioral sim", "Same, in Vivado's simulator",
     "vivado_project → Run Simulation → 964"],
    ["3. Synth + impl + bitstream (M11)", "Maps to real gates, closes timing at 100 MHz, "
     "emits chip_top.bit", "impl_chip.tcl → place &amp; route → write_bitstream"],
    ["4. Post-impl gate sim (M13)", "The actual routed netlist (real gates) still gives 964",
     "write_verilog -mode funcsim → xsim with glbl"],
]
add(mktable(ver, [4.2*cm, 5.2*cm, 7.6*cm]))
sp()
add(P("Level 4 is the strongest: it simulates the <i>physical</i> design Vivado produced. "
      "964 at the gate level means the silicon would do this."))

# PART 9 — caveat
add(P("Part 9 — The Honest Scale Caveat", h1))
add(P("The demo workload is deliberately small: 8 threads = exactly 1 warp, no divergence, "
      "perfectly contiguous memory. So this run does not <i>stress</i> the multi-warp "
      "scheduler, divergence stack, or scattered coalescing — those are exercised by the "
      "per-milestone testbenches. `chip_top` exists to prove the **full integration** "
      "end-to-end on real silicon, with a result simple enough to hand-verify. Both stories "
      "are true and worth telling: “the chip integrates and runs on FPGA” and "
      "“the engine implements full SIMT with divergence and coalescing.”"))

# ═══════════════════════════════════════════════════════════════════════════════
#  PART 10 — CYCLE TRACE  (landscape for the wide timeline)
# ═══════════════════════════════════════════════════════════════════════════════
add(P("Part 10 — Cycle-by-Cycle Trace", h1))
add(P("We follow one warp through the 9-instruction kernel, cycle by cycle, watching all "
      "8 lanes move in lockstep and the memory engine fire. Traced directly from the "
      "always_ff at warp_pool.sv."))

add(P("Setup — what is true before instruction 0", h2))
add(P("When the dispatcher pulses start, the pool spawns one warp (total_warps = "
      "ceil(8/8) = 1). All 8 lanes get seeded registers; the only difference between lanes "
      "is **a0 = tid = lane index**. This is the whole trick of SIMT in one table:"))
seed = [
    ["Register", "Seed", "Lane 0", "Lane 7", "Meaning"],
    ["a0 (x10)", "tid", "0", "7", "the thread id — differs per lane"],
    ["a1 (x11)", "base_a", "0x300", "0x300", "&A (same for all)"],
    ["a2 (x12)", "base_b", "0x340", "0x340", "&B"],
    ["a3 (x13)", "base_c", "0x380", "0x380", "&C"],
    ["a4 (x14)", "N", "8", "8", "thread count"],
]
add(mktable(seed, [3.0*cm, 2.4*cm, 2.4*cm, 2.4*cm, 6.8*cm], font_cell=cellmono))

add(P("The kernel, with PCs and register targets", h2))
add(P("(t0=x5, t1=x6, t2=x7, t3=x28, t4=x29, t5=x30)"))
add(code(
"PC      word  instruction        per-lane effect (lane l)\n"
"0x200   0x80  slli t0, a0, 2      t0 = tid*4 = 4l        (byte offset)\n"
"0x204   0x81  add  t1, a1, t0     t1 = 0x300 + 4l = &A[l]\n"
"0x208   0x82  lw   t2, 0(t1)      t2 = A[l]              <- MEMORY\n"
"0x20C   0x83  add  t3, a2, t0     t3 = 0x340 + 4l = &B[l]\n"
"0x210   0x84  lw   t4, 0(t3)      t4 = B[l]              <- MEMORY\n"
"0x214   0x85  add  t2, t2, t4     t2 = A[l] + B[l]\n"
"0x218   0x86  add  t5, a3, t0     t5 = 0x380 + 4l = &C[l]\n"
"0x21C   0x87  sw   t2, 0(t5)      C[l] = t2              <- MEMORY\n"
"0x220   0x88  ecall               retire thread"))

# the wide timeline -> landscape
add(NextPageTemplate("landscape"))
add(PageBreak())
add(P("The master timeline", h2))
add(P("Three things can happen each cycle (spawn / issue / memory-service). C0 = the cycle "
      "start is high. Watch lane 0 vs lane 7 to see SIMT, and the W_MEM rows to see a warp "
      "park itself on memory.", bodyL))

H = tcellw
def r(*c): return list(c)
trace = [
    [CP("Cyc",H),CP("State (during)",H),CP("PC",H),CP("Instr issued",H),
     CP("Lane 0",H),CP("Lane 7",H),CP("Mem engine",H),CP("End-of-cycle effect",H)],
    ["C0","—","—","—","—","—","idle",
     "latch grid; total_warps=1; all slots EMPTY; running=1"],
    ["C1","EMPTY→spawn","—","(none — warp not RUN yet)","—","—","idle",
     "warp0 → W_RUN, seeded, PC=0x200, mask=0xFF"],
    ["C2","W_RUN","0x200","slli t0,a0,2","t0=0","t0=28","idle",
     "t0=4l written all lanes; PC→0x204"],
    ["C3","W_RUN","0x204","add t1,a1,t0","t1=0x300","t1=0x31C","idle",
     "&A[l] in t1; PC→0x208"],
    ["C4","W_RUN","0x208","lw t2,0(t1)","req 0x300","req 0x31C","LATCH",
     "warp→W_MEM; mem_pending=0xFF; PC parked 0x20C"],
    ["C5","W_MEM","(idle)","(none)","t2←10","t2←17","1 txn ✓",
     "8 lanes share line 0x300..0x31F → 1 coalesced read; A[l]→t2; "
     "warp→W_RUN; PC→0x20C"],
    ["C6","W_RUN","0x20C","add t3,a2,t0","t3=0x340","t3=0x35C","idle",
     "&B[l] in t3; PC→0x210"],
    ["C7","W_RUN","0x210","lw t4,0(t3)","req 0x340","req 0x35C","LATCH",
     "warp→W_MEM; PC parked 0x214"],
    ["C8","W_MEM","(idle)","(none)","t4←100","t4←114","1 txn ✓",
     "line 0x340..0x35F → 1 coalesced read; B[l]→t4; warp→W_RUN; PC→0x214"],
    ["C9","W_RUN","0x214","add t2,t2,t4","t2=110","t2=131","idle",
     "t2 = A[l]+B[l] = C[l] = 110+3l; PC→0x218"],
    ["C10","W_RUN","0x218","add t5,a3,t0","t5=0x380","t5=0x39C","idle",
     "&C[l] in t5; PC→0x21C"],
    ["C11","W_RUN","0x21C","sw t2,0(t5)","st 110→0x380","st 131→0x39C","LATCH",
     "warp→W_MEM; per-lane store data latched; PC parked 0x220"],
    ["C12","W_MEM","(idle)","(none)","—","—","1 txn ✓",
     "8 lanes merged → 1 coalesced line WRITE; C[0..7] land in shared_mem; "
     "warp→W_RUN; PC→0x220"],
    ["C13","W_RUN","0x220","ecall","retire","retire","idle","warp0 → W_DONE"],
    ["C14","W_DONE","—","(none)","—","—","idle",
     "nothing busy → running=0, done<=1"],
    ["C15","—","—","—","—","—","—",
     "done pulses → dispatcher latches REG_CYCLES≈16"],
]
# convert plain strings to tight cells
trace_rows = [trace[0]] + [[CP(str(c), tcellm if i in (0,2) else tcell) for i,c in enumerate(row)]
                           for row in trace[1:]]
widths = [0.95*cm, 2.35*cm, 1.25*cm, 3.0*cm, 2.05*cm, 2.05*cm, 1.7*cm, 9.0*cm]
tt = Table(trace_rows, colWidths=widths, repeatRows=1)
tsty = [("GRID",(0,0),(-1,-1),0.4,CODEBD),("VALIGN",(0,0),(-1,-1),"TOP"),
        ("BACKGROUND",(0,0),(-1,0),HDRBG),
        ("LEFTPADDING",(0,0),(-1,-1),3),("RIGHTPADDING",(0,0),(-1,-1),3),
        ("TOPPADDING",(0,0),(-1,-1),2.5),("BOTTOMPADDING",(0,0),(-1,-1),2.5)]
# highlight W_MEM rows (C5,C8,C12 -> data indices 6,9,13) light teal
for idx in (6, 9, 13):
    tsty.append(("BACKGROUND",(0,idx),(-1,idx),colors.HexColor("#e6f4f1")))
tt.setStyle(TableStyle(tsty))
add(tt)
sp(4)
add(P("By C12 the 8 results {110,113,116,119,122,125,128,131} sit in shared memory. The CPU "
      "then reads them back and sums to 964.", bodyL))

add(NextPageTemplate("portrait"))
add(PageBreak())

add(P("Zoom in: how ONE memory instruction works (C4 → C5)", h2))
add(P("A `lw` is not a single-cycle event; it splits into **issue** and **service**."))
add(P("**C4 — Issue (the warp hands off and steps aside).** The issue logic sees "
      "`is_mem && !mem_busy` and latches the request:"))
add(code(
"mem_busy        <= 1\n"
"mem_pending     <= cur_mask        // 0xFF - all 8 lanes want data\n"
"mem_addr_lane[l]<= addr[l]         // 0x300, 0x304, ... 0x31C\n"
"mem_rd          <= t2\n"
"mem_next_pc     <= 0x20C           // where to resume after the load\n"
"wstate[0]       <= W_MEM           // <- warp parks itself"))
add(P("The warp takes itself out of W_RUN and will not be fetched again until the memory "
      "engine wakes it. No load value is produced this cycle — only the request."))
add(P("**C5 — Service + coalesce + writeback.** With mem_busy=1, the memory engine: "
      "(1) picks the leader = lowest pending lane (lane 0, addr 0x300); (2) coalesces every "
      "pending lane sharing that line tag — all 8 are inside 0x300..0x31F, so grp=0xFF; "
      "(3) drives one 256-bit line read; (4) slices each lane's word out and writes it to "
      "t2 (lane 0 gets 10, lane 7 gets 17); (5) sees all lanes serviced, so mem_busy<=0, "
      "PC<=0x20C, warp→W_RUN. **8 loads → 1 transaction.**"))

add(P("The “bubble” — and why the warp pool exists", h2))
add(P("In cycles C5, C8, C12 the issue datapath fetches nothing (the only warp is parked in "
      "W_MEM). These are **stall bubbles**. With 4 warps (e.g. N=32) the round-robin "
      "scheduler would issue a different warp's compute during those cycles:"))
add(code(
"C4: warp 0 issues lw       -> warp 0 parks in W_MEM\n"
"C5: warp 0's load services  AND  warp 1 issues its slli   <- bubble filled!\n"
"C6: warp 1 issues add       AND  (warp 0 back in W_RUN)\n"
"..."))
add(P("Memory latency disappears behind other warps' useful work — the single most "
      "important idea in GPU performance, already present in warp_pool. The demo simply "
      "lacks enough threads to show it off."))

add(P("The cycle budget", h2))
add(code(
"5 compute instrs  x 1 cycle each            =  5   (slli, add, add, add, add)\n"
"3 memory instrs   x 2 cycles each           =  6   (issue + service: lw, lw, sw)\n"
"1 ecall           x 1 cycle                 =  1\n"
"---------------------------------------------------\n"
"kernel execution                            = 12 cycles   (C2 -> C13)\n"
"+ launch / spawn overhead (C0, C1)          =  2\n"
"+ completion + done pulse (C14, C15)        =  2\n"
"---------------------------------------------------\n"
"total ~ 16 cycles  ->  this is REG_CYCLES, readable by the CPU"))
sp(2)
add(P("Each memory op costs one extra bubble cycle <i>here</i> — but that is exactly the "
      "cost a full warp pool would hide. Both readings are true: “memory ops cost 2 "
      "cycles on a single warp” and “with a full pool those service cycles are free.”"))

add(P("What you can now see in the silicon", h2))
add(B("**Lockstep with a twist:** all 8 lanes run the same instruction each cycle; only "
      "tid (seeded in a0) makes results differ."))
add(B("**Memory is a two-phase background operation:** issue (park the warp) then service "
      "(coalesce + write back + resume)."))
add(B("**Coalescing is real and measurable:** 8 contiguous accesses → 1 transaction; "
      "dbg_mem_txns ends at 3."))
add(B("**Bubbles reveal the warp pool's purpose:** the empty issue slots in C5/C8/C12 are "
      "exactly what multi-warp scheduling fills."))
add(B("**The result exists in memory by C12,** before the CPU reads it back — the 964 sum "
      "is the CPU's verification of the accelerator's work."))

# ═══════════════════════════════════════════════════════════════════════════════
#  PART 11 — DIVERGENT-KERNEL TRACE
# ═══════════════════════════════════════════════════════════════════════════════
add(P("Part 11 — Bonus: A Divergent-Kernel Trace (the reconvergence stack)", h1))
add(P("The vector-add kernel is <i>uniform</i> — every lane takes the same path, so the "
      "SIMT stack never grows. To see Part 7's reconvergence stack actually work, here is "
      "an illustrative kernel with a data-dependent branch. (This is a teaching example, "
      "not the kernel in the ROM; the divergence hardware it exercises is the real M5 "
      "logic in warp_pool.sv.)"))

add(P("The divergent kernel", h2))
add(P("Single-sided if (the M5-supported form): lanes with tid &lt; 4 run the body; the "
      "rest skip it. The guard branch is the negation — it is <i>taken</i> (skips the "
      "body) when tid &gt;= 4, so the lanes that run the body are the fall-through lanes."))
add(code(
"PC      instruction          per-lane effect\n"
"0x200   addi t0, x0, 4       t0 = 4                         (uniform)\n"
"0x204   bge  a0, t0, 0x210   if tid>=4 -> JOIN (skip body)  DIVERGENT (forward if)\n"
"0x208   addi t1, a0, 100     t1 = tid + 100                 (body: lanes tid<4)\n"
"0x20C   ori  t1, t1, 0       t1 = t1                        (body 2nd instr)\n"
"0x210   add  t2, a0, t1      JOIN: t2 = tid + t1            (reconverged, all lanes)\n"
"0x214   ecall                retire"))
add(P("Lanes that skip the body never write t1, so it keeps its spawn seed 0. The result "
      "therefore differs sharply between the two halves of the warp:"))
dres = [
    ["Lane (tid)", "Path", "t1", "t2 = tid + t1"],
    ["0–3  (tid<4)", "runs body", "tid+100 -> 100,101,102,103", "2*tid+100 -> 100,102,104,106"],
    ["4–7  (tid>=4)", "skips body", "0  (spawn seed)", "tid -> 4,5,6,7"],
]
add(mktable(dres, [3.4*cm, 2.6*cm, 5.5*cm, 5.5*cm], font_cell=cellmono))

add(P("The SIMT stack, in one breath", h2))
add(P("Each warp owns a small stack of frames. The top-of-stack (TOS) frame defines the "
      "warp's live **PC**, its **active mask** (which lanes execute), and an **RPC** (the "
      "join PC at which this frame pops). A divergent branch pushes a frame; when a pushed "
      "frame's PC reaches its RPC it pops, and the warp reconverges into the frame below "
      "(which already holds the full union mask)."))
add(code(
"After spawn (C1):         sp=0   TOS ->[ pc=0x200  mask=0xFF  rpc=BOTTOM ]\n"
"\n"
"After divergent br (C3):  sp=1   TOS ->[ pc=0x208  mask=0x0F  rpc=0x210  ]   body lanes (tid<4)\n"
"                                       [ pc=0x210  mask=0xFF  rpc=BOTTOM ]   waiting at join\n"
"\n"
"After pop (C6):           sp=0   TOS ->[ pc=0x210  mask=0xFF  rpc=BOTTOM ]   RECONVERGED"))

# wide divergent timeline -> landscape
add(NextPageTemplate("landscape"))
add(PageBreak())
add(P("The divergent timeline", h2))
add(P("Watch the Active mask column narrow to the body lanes after the branch (C3), then "
      "widen back to all 8 after the pop (C6). bge funct3 = 101. (C0 launch is omitted; "
      "C1 = spawn, as before.)", bodyL))
H = tcellw
dtrace = [
    [CP("Cyc",H),CP("sp",H),CP("PC",H),CP("Instr",H),CP("Active mask",H),
     CP("Per-lane effect",H),CP("Stack action / end-of-cycle",H)],
    ["C1","0","—","(spawn)","0xFF (all 8)","warp0 seeded; a0 = tid per lane",
     "stack init: frame0{pc=0x200, mask=0xFF, rpc=BOTTOM}"],
    ["C2","0","0x200","addi t0,x0,4","0xFF (all 8)","t0 = 4 (all lanes)",
     "uniform compute; TOS.pc→0x204"],
    ["C3","0","0x204","bge a0,t0,0x210","0xFF (all 8)",
     "cond tid>=4: lanes 4–7 taken, lanes 0–3 fall-through",
     "DIVERGENT (fwd if): dbg_divergences=1. TOS.pc←0x210 (JOIN), mask←0xFF; "
     "PUSH frame{pc=0x208, mask=0x0F, rpc=0x210}; sp→1"],
    ["C4","1","0x208","addi t1,a0,100","0x0F (lanes 0–3)",
     "lanes 0–3: t1 = tid+100 (100..103); lanes 4–7: masked, no write",
     "body; TOS.pc→0x20C"],
    ["C5","1","0x20C","ori t1,t1,0","0x0F (lanes 0–3)",
     "lanes 0–3: t1 unchanged (100..103); lanes 4–7: idle (masked)",
     "body; TOS.pc→0x210 (= RPC)"],
    ["C6","1","0x210","(none — POP)","—","— (no datapath work)",
     "cur_pc == RPC → POP; sp→0; reconverge into frame0 (mask 0xFF)"],
    ["C7","0","0x210","add t2,a0,t1","0xFF (all 8)",
     "lanes 0–3: t2 = 2*tid+100 (100,102,104,106); lanes 4–7: t2 = tid (4,5,6,7)",
     "reconverged compute; TOS.pc→0x214"],
    ["C8","0","0x214","ecall","0xFF (all 8)","all lanes retire","warp0 → W_DONE"],
    ["C9","—","—","(none)","—","—","nothing busy → done<=1"],
]
dtrace_rows = [dtrace[0]] + [[CP(str(c), tcellm if i in (2,3,4) else tcell)
                              for i,c in enumerate(row)] for row in dtrace[1:]]
dwidths = [0.9*cm, 0.9*cm, 1.25*cm, 2.9*cm, 2.5*cm, 8.0*cm, 10.05*cm]
dtt = Table(dtrace_rows, colWidths=dwidths, repeatRows=1)
dtsty = [("GRID",(0,0),(-1,-1),0.4,CODEBD),("VALIGN",(0,0),(-1,-1),"TOP"),
         ("BACKGROUND",(0,0),(-1,0),HDRBG),
         ("LEFTPADDING",(0,0),(-1,-1),3),("RIGHTPADDING",(0,0),(-1,-1),3),
         ("TOPPADDING",(0,0),(-1,-1),2.5),("BOTTOMPADDING",(0,0),(-1,-1),2.5)]
dtsty.append(("BACKGROUND",(0,3),(-1,3),colors.HexColor("#fdf0d5")))  # C3 divergent (amber)
dtsty.append(("BACKGROUND",(0,4),(-1,5),colors.HexColor("#f3f4f6")))  # C4-C5 reduced mask
dtsty.append(("BACKGROUND",(0,6),(-1,6),colors.HexColor("#e6f4f1")))  # C6 pop/reconverge (teal)
dtt.setStyle(TableStyle(dtsty))
add(dtt)
sp(4)
add(P("Active mask narrows 0xFF → 0x0F at the divergent branch (C3) and widens back to "
      "0xFF at the pop (C6). dbg_divergences ends at 1.", bodyL))

add(NextPageTemplate("portrait"))
add(PageBreak())
add(P("The divergence penalty", h2))
add(P("During C4 and C5 only 4 of the 8 lanes do useful work — the other 4 are masked off "
      "and idle. That is **8 wasted lane-cycles**: the fundamental SIMT divergence penalty "
      "(lane underutilization). The M7 counters measure exactly this — `dbg_issued_insns` "
      "counts datapath instructions (each could clock all 8 lanes) while `dbg_active_lanes` "
      "sums the lanes actually active; their ratio is lane utilization. A general two-sided "
      "if/else would be worse: it serializes **both** arms (the else lanes run in extra "
      "cycles too), which is why the M5 convention favours single-sided ifs written as two "
      "of them."))
add(P("Key takeaways", h2))
add(B("**A divergent branch pushes a stack frame** and narrows the active mask to one lane "
      "group; the other group is parked in the frame below, waiting at the join."))
add(B("**Masked-off lanes do nothing** — their writeback is gated by the active mask, so "
      "they neither corrupt state nor make progress."))
add(B("**A pushed frame pops when its PC reaches its RPC** (the join), restoring the full "
      "union mask — that is reconvergence."))
add(B("**Nesting works** up to the stack depth (SDEPTH = 8): each further divergence "
      "pushes another frame."))
add(B("**dbg_divergences = 1** for this kernel — exactly one divergent-branch event."))

# Appendix
add(P("Appendix — File Map", h1))
fm = [
    ["File", "Role"],
    ["rtl/soc/chip_top.sv", "Top-level SoC: CPU + accel + memory + result register."],
    ["rtl/soc/cpu_driver_rom.sv", "Host driver program (store loop, MMIO, poll, readback)."],
    ["rtl/soc/shared_mem.sv", "8-bank LUTRAM shared memory (kernel + A/B/C)."],
    ["rtl/accel/simt_accel.sv", "Accelerator shell: mmio_regs + warp_pool + dispatcher FSM."],
    ["rtl/accel/mmio_regs.sv", "Memory-mapped command/status registers."],
    ["rtl/accel/warp_pool.sv", "The SIMT engine (lanes, warps, scheduler, mem engine, stack)."],
    ["rtl/accel/simtix_pkg.sv", "Global parameters, MMIO map, ISA constants."],
    ["rtl/cpu/riscv_pipeline.v", "Reused 5-stage RISC-V host core."],
    ["tests/tb_chip_top.sv", "Self-checking testbench (expects result==964)."],
    ["fpga/impl_chip.tcl", "Synthesis → place &amp; route → bitstream flow."],
    ["fpga/create_project.tcl", "Builds a clickable Vivado GUI project."],
]
add(mktable(fm, [5.6*cm, 11.4*cm], font_cell=cellmono))
sp(8)
add(P("<i>Generated for personal study of the SIMTiX project. All facts are traced to the "
      "RTL in the repository.</i>", ParagraphStyle("foot", parent=body, fontSize=9,
      textColor=GREY)))

# ── Page furniture ───────────────────────────────────────────────────────────
def footer(canvas, doc):
    canvas.saveState()
    canvas.setFont("Body", 8)
    canvas.setFillColor(GREY)
    w = doc.pagesize[0]
    canvas.drawString(1.6*cm, 1.0*cm, "SIMTiX — Learning Guide")
    canvas.drawRightString(w - 1.6*cm, 1.0*cm, "Page %d" % doc.page)
    canvas.setStrokeColor(CODEBD)
    canvas.line(1.6*cm, 1.35*cm, w - 1.6*cm, 1.35*cm)
    canvas.restoreState()

def cover(canvas, doc):
    canvas.saveState()
    canvas.setFillColor(NAVY)
    canvas.rect(0, A4[1]-1.1*cm, A4[0], 1.1*cm, fill=1, stroke=0)
    canvas.rect(0, 0, A4[0], 0.7*cm, fill=1, stroke=0)
    canvas.restoreState()

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "SIMTiX_Learning_Guide.pdf")
doc = BaseDocTemplate(OUT, pagesize=A4,
                      leftMargin=1.6*cm, rightMargin=1.6*cm,
                      topMargin=1.7*cm, bottomMargin=1.7*cm,
                      title="SIMTiX Learning Guide", author="Krishna Gorai")
pw, ph = A4
fp = Frame(1.6*cm, 1.6*cm, pw-3.2*cm, ph-3.4*cm, id="p")
lw, lh = landscape(A4)
fl = Frame(1.6*cm, 1.6*cm, lw-3.2*cm, lh-3.4*cm, id="l")
doc.addPageTemplates([
    PageTemplate(id="cover", frames=[Frame(1.6*cm,1.6*cm,pw-3.2*cm,ph-3.4*cm)],
                 pagesize=A4, onPage=cover),
    PageTemplate(id="portrait", frames=[fp], pagesize=A4, onPage=footer),
    PageTemplate(id="landscape", frames=[fl], pagesize=landscape(A4), onPage=footer),
])
doc.build(story)
print("WROTE", OUT)
