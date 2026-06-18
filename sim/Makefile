# =============================================================================
# SIMTiX simulation / lint harness (Verilator)
#
#   make lint   - lint-only check of the accelerator RTL (strict) + host CPU
#   make test   - build & run the SystemVerilog regression, exit non-zero on fail
#   make clean  - remove build artifacts
#
# Run from the repo root:  make lint   (the root Makefile delegates here).
# Paths are kept RELATIVE to this directory on purpose: the repo lives under a
# parent dir with a space ("Verilog Projects"), and relative paths avoid it.
# =============================================================================

VERILATOR ?= verilator

# Accelerator top + its children — linted strictly as one design.
ACCEL_RTL := \
	../rtl/accel/simtix_pkg.sv \
	../rtl/accel/mmio_regs.sv \
	../rtl/accel/simt_fpu.sv \
	../rtl/accel/warp_pool.sv \
	../rtl/accel/simt_accel.sv

# lane.sv is the M1 single-thread reference core, still linted/tested standalone.
LANE_RTL := \
	../rtl/accel/simtix_pkg.sv \
	../rtl/accel/lane.sv

# warp.sv is the M2 single-warp reference, still linted/tested standalone.
WARP_RTL := \
	../rtl/accel/simtix_pkg.sv \
	../rtl/accel/warp.sv

# warp_pool.sv is the M3 multi-warp engine (used by simt_accel).
POOL_RTL := \
	../rtl/accel/simtix_pkg.sv \
	../rtl/accel/simt_fpu.sv \
	../rtl/accel/warp_pool.sv

# Host CPU RTL (reused, Verilog-2001) — linted permissively (3rd-party style).
CPU_RTL := $(wildcard ../rtl/cpu/*.v)

# Full SoC: accelerator + host CPU core (the FPGA wrapper top.v is excluded —
# it pulls in Xilinx clocking primitives that the simulator does not model).
SOC_CPU_RTL := $(filter-out ../rtl/cpu/top.v, $(CPU_RTL))
SOC_RTL := \
	../rtl/accel/simtix_pkg.sv \
	../rtl/accel/mmio_regs.sv \
	../rtl/accel/simt_fpu.sv \
	../rtl/accel/warp_pool.sv \
	../rtl/accel/simt_accel.sv \
	../rtl/soc/soc_top.sv \
	$(SOC_CPU_RTL)

# Full chip (M10): host CPU pipeline + accelerator + on-chip shared memory +
# driver ROM, wired into one self-contained top (chip_top). Uses only the
# pipeline + its leaf modules from the CPU RTL (the standalone CPU SoC wrapper,
# its ROM/SRAM, and the FPGA top are excluded — chip_top supplies its own).
CHIP_CPU_RTL := $(filter-out ../rtl/cpu/top.v ../rtl/cpu/riscv_soc.v \
	../rtl/cpu/instr_mem.v ../rtl/cpu/data_mem.v, $(CPU_RTL))
CHIP_RTL := \
	../rtl/accel/simtix_pkg.sv \
	../rtl/accel/mmio_regs.sv \
	../rtl/accel/simt_fpu.sv \
	../rtl/accel/warp_pool.sv \
	../rtl/accel/simt_accel.sv \
	../rtl/soc/shared_mem.sv \
	../rtl/soc/cpu_driver_rom.sv \
	../rtl/soc/chip_top.sv \
	$(CHIP_CPU_RTL)

# Package + per-block sources used by the unit testbenches.
PKG       := ../rtl/accel/simtix_pkg.sv

VFLAGS    := -sv -Wall --timing
CPU_VFLAGS:= -Wno-lint -Wno-style -Wno-WIDTH
# The SoC mixes strict SV with the permissive Verilog CPU, so lint/build the
# integrated design with the CPU's relaxed ruleset.
SOC_VFLAGS:= -sv -Wno-lint -Wno-style -Wno-WIDTH --timing

# Verilator's --binary flow shells out to GNU make, which cannot build in a
# directory containing spaces. This repo's parent ("Verilog Projects") has one,
# so the C++ build is redirected to a space-free path. (No-op on CI, where the
# checkout path has no spaces.)
MDIR      := /tmp/simtix-build

.PHONY: lint lint-accel lint-lane lint-warp lint-pool lint-cpu lint-soc lint-chip test test-accel test-lane test-warp test-pool test-fp test-fpu test-fparith test-fparith16 test-soc test-chip bench fp-bench cpu-bench clean

lint: lint-accel lint-lane lint-warp lint-pool lint-cpu lint-soc lint-chip

lint-accel:
	$(VERILATOR) --lint-only $(VFLAGS) --top-module simt_accel $(ACCEL_RTL)
	@echo "[lint] accelerator top OK"

lint-lane:
	$(VERILATOR) --lint-only $(VFLAGS) --top-module lane $(LANE_RTL)
	@echo "[lint] lane OK"

lint-warp:
	$(VERILATOR) --lint-only $(VFLAGS) --top-module warp $(WARP_RTL)
	@echo "[lint] warp OK"

lint-pool:
	$(VERILATOR) --lint-only $(VFLAGS) --top-module warp_pool $(POOL_RTL)
	@echo "[lint] warp_pool OK"

lint-cpu:
	$(VERILATOR) --lint-only $(CPU_VFLAGS) --top-module riscv_soc $(CPU_RTL)
	@echo "[lint] host CPU OK"

lint-soc:
	$(VERILATOR) --lint-only $(SOC_VFLAGS) --top-module soc_top $(SOC_RTL)
	@echo "[lint] SoC integration OK"

lint-chip:
	$(VERILATOR) --lint-only $(SOC_VFLAGS) --top-module chip_top $(CHIP_RTL)
	@echo "[lint] full chip OK"

# Build & run a self-checking testbench.  $(1)=top module, $(2..)=extra sources.
define run_tb
	rm -rf $(MDIR)
	$(VERILATOR) --binary $(VFLAGS) --Mdir $(MDIR) --top-module $(1) $(2) -o $(1)
	@echo "[test] running $(1)..."
	$(MDIR)/$(1)
endef

test: test-accel test-lane test-warp test-pool test-fp test-fpu test-fparith test-fparith16 test-soc test-chip

test-accel:
	$(call run_tb,tb_simt_accel,$(PKG) ../rtl/accel/mmio_regs.sv ../rtl/accel/simt_fpu.sv ../rtl/accel/warp_pool.sv ../rtl/accel/simt_accel.sv ../tests/tb_simt_accel.sv)

test-lane:
	$(call run_tb,tb_lane,$(PKG) ../rtl/accel/lane.sv ../tests/tb_lane.sv)

test-warp:
	$(call run_tb,tb_warp,$(PKG) ../rtl/accel/warp.sv ../tests/tb_warp.sv)

test-pool:
	$(call run_tb,tb_warp_pool,$(PKG) ../rtl/accel/simt_fpu.sv ../rtl/accel/warp_pool.sv ../tests/tb_warp_pool.sv)

# M14.0: floating-point load/store data path (flw/fsw through the f-regfile).
test-fp:
	$(call run_tb,tb_fp,$(PKG) ../rtl/accel/simt_fpu.sv ../rtl/accel/warp_pool.sv ../tests/tb_fp.sv)

# M14.1: standalone bit-exact verification of the per-lane FP32 unit against a
# DPI-C IEEE-754 single-precision reference. Verilator compiles the DPI .c with
# its C++ toolchain, so the source path must be space-free — stage it to /tmp
# (the repo's parent dir has a space) and hand Verilator the absolute path.
FPU_REF_SRC := /tmp/simtix-fpu_ref.c
test-fpu:
	cp ../tests/fpu_ref.c $(FPU_REF_SRC)
	rm -rf $(MDIR)
	$(VERILATOR) --binary $(VFLAGS) --Mdir $(MDIR) --top-module tb_fpu \
		$(PKG) ../rtl/accel/simt_fpu.sv ../tests/tb_fpu.sv $(FPU_REF_SRC) -o tb_fpu
	@echo "[test] running tb_fpu..."
	$(MDIR)/tb_fpu

# M14.1: end-to-end FP arithmetic (fmul.s + fadd.s) through warp_pool, checked
# bit-exact against the same DPI IEEE-754 reference (staged space-free, as above).
test-fparith:
	cp ../tests/fpu_ref.c $(FPU_REF_SRC)
	rm -rf $(MDIR)
	$(VERILATOR) --binary $(VFLAGS) --Mdir $(MDIR) --top-module tb_fparith \
		$(PKG) ../rtl/accel/simt_fpu.sv ../rtl/accel/warp_pool.sv ../tests/tb_fparith.sv $(FPU_REF_SRC) -o tb_fparith
	@echo "[test] running tb_fparith..."
	$(MDIR)/tb_fparith

# M14.2: end-to-end FP16 (half) arithmetic (fmul.h + fadd.h) through warp_pool,
# checked bit-exact against the DPI half reference (NaN-boxed operands via flw/fsw).
test-fparith16:
	cp ../tests/fpu_ref.c $(FPU_REF_SRC)
	rm -rf $(MDIR)
	$(VERILATOR) --binary $(VFLAGS) --Mdir $(MDIR) --top-module tb_fparith16 \
		$(PKG) ../rtl/accel/simt_fpu.sv ../rtl/accel/warp_pool.sv ../tests/tb_fparith16.sv $(FPU_REF_SRC) -o tb_fparith16
	@echo "[test] running tb_fparith16..."
	$(MDIR)/tb_fparith16

# The SoC test pulls in the Verilog CPU core, so it builds with SOC_VFLAGS.
test-soc:
	rm -rf $(MDIR)
	$(VERILATOR) --binary $(SOC_VFLAGS) --Mdir $(MDIR) --top-module tb_soc_top $(SOC_RTL) ../tests/tb_soc_top.sv -o tb_soc_top
	@echo "[test] running tb_soc_top..."
	$(MDIR)/tb_soc_top

# The full-chip test pulls in the Verilog CPU core, so it builds with SOC_VFLAGS.
test-chip:
	rm -rf $(MDIR)
	$(VERILATOR) --binary $(SOC_VFLAGS) --Mdir $(MDIR) --top-module tb_chip_top $(CHIP_RTL) ../tests/tb_chip_top.sv -o tb_chip_top
	@echo "[test] running tb_chip_top..."
	$(MDIR)/tb_chip_top

# Benchmark suite (publication evaluation): runs every kernel at several sizes,
# verifies golden results, and prints a metrics table + CSV rows. Capture with:
#   make bench | grep '^CSV,' > ../docs/bench.csv
bench:
	$(call run_tb,tb_bench,$(PKG) ../rtl/accel/simt_fpu.sv ../rtl/accel/warp_pool.sv ../tests/tb_bench.sv)

# FP benchmark (M14 evaluation): FP32 + FP16 streaming kernels, golden-checked
# against the DPI reference. Capture with:
#   make fp-bench | grep '^FPCSV,' > ../docs/fp_bench.csv
fp-bench:
	cp ../tests/fpu_ref.c $(FPU_REF_SRC)
	rm -rf $(MDIR)
	$(VERILATOR) --binary $(VFLAGS) --Mdir $(MDIR) --top-module tb_fpbench \
		$(PKG) ../rtl/accel/simt_fpu.sv ../rtl/accel/warp_pool.sv ../tests/tb_fpbench.sv $(FPU_REF_SRC) -o tb_fpbench
	@echo "[bench] running tb_fpbench..."
	$(MDIR)/tb_fpbench

# Scalar host-CPU baseline: runs the same kernels on the 5-stage RV32I pipeline
# and reports cycles. Capture with:  make cpu-bench | grep '^CSVCPU,' > ../docs/bench_cpu.csv
# (uses the pipeline + its leaf modules — the same subset chip_top instantiates.)
cpu-bench:
	rm -rf $(MDIR)
	$(VERILATOR) --binary $(SOC_VFLAGS) --Mdir $(MDIR) --top-module tb_cpu_bench $(CHIP_CPU_RTL) ../tests/tb_cpu_bench.sv -o tb_cpu_bench
	@echo "[bench] running tb_cpu_bench..."
	$(MDIR)/tb_cpu_bench

# Design-space-exploration sweep (Part 2): elaborate the engine at LANES/WARPS
# and run the lane-agnostic kernels. Defaults reproduce the 8/4 config. Sweep:
#   for L in 4 8 16 32; do for W in 2 4 8; do make dse LANES=$L WARPS=$W; done; done
LANES ?= 8
WARPS ?= 4
dse:
	rm -rf $(MDIR)
	$(VERILATOR) --binary $(SOC_VFLAGS) +define+SIMTIX_NUM_LANES=$(LANES) +define+SIMTIX_NUM_WARPS=$(WARPS) \
		--Mdir $(MDIR) --top-module tb_dse $(PKG) ../rtl/accel/simt_fpu.sv ../rtl/accel/warp_pool.sv ../tests/tb_dse.sv -o tb_dse
	@echo "[dse] running tb_dse LANES=$(LANES) WARPS=$(WARPS)..."
	$(MDIR)/tb_dse

clean:
	rm -rf obj_dir $(MDIR)
