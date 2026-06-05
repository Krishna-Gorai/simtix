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
	../rtl/accel/warp_pool.sv

# Host CPU RTL (reused, Verilog-2001) — linted permissively (3rd-party style).
CPU_RTL := $(wildcard ../rtl/cpu/*.v)

# Full SoC: accelerator + host CPU core (the FPGA wrapper top.v is excluded —
# it pulls in Xilinx clocking primitives that the simulator does not model).
SOC_CPU_RTL := $(filter-out ../rtl/cpu/top.v, $(CPU_RTL))
SOC_RTL := \
	../rtl/accel/simtix_pkg.sv \
	../rtl/accel/mmio_regs.sv \
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

.PHONY: lint lint-accel lint-lane lint-warp lint-pool lint-cpu lint-soc lint-chip test test-accel test-lane test-warp test-pool test-soc test-chip clean

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

test: test-accel test-lane test-warp test-pool test-soc test-chip

test-accel:
	$(call run_tb,tb_simt_accel,$(PKG) ../rtl/accel/mmio_regs.sv ../rtl/accel/warp_pool.sv ../rtl/accel/simt_accel.sv ../tests/tb_simt_accel.sv)

test-lane:
	$(call run_tb,tb_lane,$(PKG) ../rtl/accel/lane.sv ../tests/tb_lane.sv)

test-warp:
	$(call run_tb,tb_warp,$(PKG) ../rtl/accel/warp.sv ../tests/tb_warp.sv)

test-pool:
	$(call run_tb,tb_warp_pool,$(PKG) ../rtl/accel/warp_pool.sv ../tests/tb_warp_pool.sv)

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

clean:
	rm -rf obj_dir $(MDIR)
