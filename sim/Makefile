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
	../rtl/accel/lane.sv \
	../rtl/accel/simt_accel.sv

LANE_RTL := \
	../rtl/accel/simtix_pkg.sv \
	../rtl/accel/lane.sv

# Host CPU RTL (reused, Verilog-2001) — linted permissively (3rd-party style).
CPU_RTL := $(wildcard ../rtl/cpu/*.v)

# Package + per-block sources used by the unit testbenches.
PKG       := ../rtl/accel/simtix_pkg.sv

VFLAGS    := -sv -Wall --timing
CPU_VFLAGS:= -Wno-lint -Wno-style -Wno-WIDTH

# Verilator's --binary flow shells out to GNU make, which cannot build in a
# directory containing spaces. This repo's parent ("Verilog Projects") has one,
# so the C++ build is redirected to a space-free path. (No-op on CI, where the
# checkout path has no spaces.)
MDIR      := /tmp/simtix-build

.PHONY: lint lint-accel lint-lane lint-cpu test test-accel test-lane clean

lint: lint-accel lint-lane lint-cpu

lint-accel:
	$(VERILATOR) --lint-only $(VFLAGS) --top-module simt_accel $(ACCEL_RTL)
	@echo "[lint] accelerator top OK"

lint-lane:
	$(VERILATOR) --lint-only $(VFLAGS) --top-module lane $(LANE_RTL)
	@echo "[lint] lane OK"

lint-cpu:
	$(VERILATOR) --lint-only $(CPU_VFLAGS) --top-module riscv_soc $(CPU_RTL)
	@echo "[lint] host CPU OK"

# Build & run a self-checking testbench.  $(1)=top module, $(2..)=extra sources.
define run_tb
	rm -rf $(MDIR)
	$(VERILATOR) --binary $(VFLAGS) --Mdir $(MDIR) --top-module $(1) $(2) -o $(1)
	@echo "[test] running $(1)..."
	$(MDIR)/$(1)
endef

test: test-accel test-lane

test-accel:
	$(call run_tb,tb_simt_accel,$(PKG) ../rtl/accel/mmio_regs.sv ../rtl/accel/lane.sv ../rtl/accel/simt_accel.sv ../tests/tb_simt_accel.sv)

test-lane:
	$(call run_tb,tb_lane,$(PKG) ../rtl/accel/lane.sv ../tests/tb_lane.sv)

clean:
	rm -rf obj_dir $(MDIR)
