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

# Accelerator RTL (this project) — linted strictly.
ACCEL_RTL := \
	../rtl/accel/simtix_pkg.sv \
	../rtl/accel/mmio_regs.sv \
	../rtl/accel/simt_accel.sv

# Host CPU RTL (reused, Verilog-2001) — linted permissively (3rd-party style).
CPU_RTL := $(wildcard ../rtl/cpu/*.v)

TB        := ../tests/tb_simt_accel.sv
TOP       := tb_simt_accel

VFLAGS    := -sv -Wall --timing
CPU_VFLAGS:= -Wno-lint -Wno-style -Wno-WIDTH

# Verilator's --binary flow shells out to GNU make, which cannot build in a
# directory containing spaces. This repo's parent ("Verilog Projects") has one,
# so the C++ build is redirected to a space-free path. (No-op on CI, where the
# checkout path has no spaces.)
MDIR      := /tmp/simtix-build

.PHONY: lint lint-accel lint-cpu test clean

lint: lint-accel lint-cpu

lint-accel:
	$(VERILATOR) --lint-only $(VFLAGS) $(ACCEL_RTL)
	@echo "[lint] accelerator RTL OK"

lint-cpu:
	$(VERILATOR) --lint-only $(CPU_VFLAGS) --top-module riscv_soc $(CPU_RTL)
	@echo "[lint] host CPU OK"

test:
	rm -rf $(MDIR)
	$(VERILATOR) --binary $(VFLAGS) --Mdir $(MDIR) --top-module $(TOP) \
		$(ACCEL_RTL) $(TB) -o $(TOP)
	@echo "[test] running regression..."
	$(MDIR)/$(TOP)

clean:
	rm -rf obj_dir $(MDIR)
