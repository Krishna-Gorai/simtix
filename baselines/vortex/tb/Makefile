# Verilator build of the board wrapper vortex_ps_top + vx_ps_tb.cpp. Run in
# $VORTEX_HOME/build/sim/vxps (build_tb.sh copies this file there), like Vortex's
# sim/xrtsim, whose flags and RTL include list this follows.
include ../common.mk

DESTDIR ?= $(CURDIR)
SIMTIX  ?= /mnt/c/work/SIMTiX-v2
TB_DIR  := $(SIMTIX)/baselines/vortex/tb
WRAP_DIR:= $(SIMTIX)/baselines/vortex/rtl
APP_DIR := $(SIMTIX)/baselines/vortex/simtix_apps

CXXFLAGS += -std=c++17 -Wall -Wextra -Wfatal-errors -O2 -fno-tree-loop-distribute-patterns
CXXFLAGS += -I$(ROOT_DIR)/sw -I$(ROOT_DIR)/hw -I$(APP_DIR) -I$(SIM_COMMON_DIR) -I$(SW_COMMON_DIR)
CXXFLAGS += -I$(THIRD_PARTY_DIR)/softfloat/source/include
CXXFLAGS += -DVX_CFG_XLEN=$(XLEN) -DVX_CFG_XLEN_$(XLEN) $(CONFIGS)
LDFLAGS  += $(THIRD_PARTY_DIR)/softfloat/build/Linux-x86_64-GCC/softfloat.a

override CONFIGS += -DSIMULATION -DSV_DPI
XCONFIGS := $(shell python3 $(ROOT_DIR)/ci/gen_config.py --config=$(VORTEX_HOME)/VX_config.toml --cflags='$(CONFIGS) -DVX_CFG_XLEN=$(XLEN)')

SRCS  = $(SW_COMMON_DIR)/softfloat_ext.cpp $(SW_COMMON_DIR)/rvfloats.cpp
SRCS += $(DPI_DIR)/dpi_util.cpp $(DPI_DIR)/dpi_float.cpp
SRCS += $(TB_DIR)/vx_ps_tb.cpp

RTL_PKGS += $(RTL_DIR)/VX_gpu_pkg.sv $(RTL_DIR)/fpu/VX_fpu_pkg.sv $(RTL_DIR)/VX_trace_pkg.sv
RTL_INCLUDE = -I$(ROOT_DIR)/sw -I$(ROOT_DIR)/hw -I$(RTL_DIR) -I$(DPI_DIR) -I$(RTL_DIR)/libs \
              -I$(RTL_DIR)/interfaces -I$(RTL_DIR)/core -I$(RTL_DIR)/mem -I$(RTL_DIR)/vm \
              -I$(RTL_DIR)/cache -I$(RTL_DIR)/fpu -I$(WRAP_DIR)
ifneq (,$(filter -DVX_CFG_EXT_TCU_ENABLE, $(XCONFIGS)))
	RTL_INCLUDE += -I$(RTL_DIR)/tcu -I$(RTL_DIR)/tcu/tfr
endif

TOP = vortex_ps_top

VL_FLAGS += --language 1800-2012 --assert -Wall -Wpedantic -Wno-fatal
VL_FLAGS += -Wno-DECLFILENAME -Wno-REDEFMACRO -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM
VL_FLAGS += --x-initial unique --x-assign unique
VL_FLAGS += $(SIM_DIR_VLT)
VL_FLAGS += -DVX_CFG_XLEN=$(XLEN) -DVX_CFG_XLEN_$(XLEN) -DNDEBUG
VL_FLAGS += $(CONFIGS) $(filter -DVX_CFG_TCU_TYPE_% -DVX_CFG_FPU_TYPE_%,$(XCONFIGS))
VL_FLAGS += $(RTL_INCLUDE) $(RTL_PKGS)
VL_FLAGS += -j 4

all: $(DESTDIR)/vx_ps_tb

$(DESTDIR)/vx_ps_tb: $(SRCS) $(WRAP_DIR)/vortex_ps_top.sv
	MAKEFLAGS= $(VERILATOR_PATH)/bin/verilator --build --exe $(VL_FLAGS) --cc $(WRAP_DIR)/vortex_ps_top.sv \
	  --top-module $(TOP) $(SRCS) -CFLAGS '$(CXXFLAGS)' -LDFLAGS '$(LDFLAGS)' --Mdir $@.obj_dir -o $@

clean:
	rm -rf $(DESTDIR)/vx_ps_tb $(DESTDIR)/vx_ps_tb.obj_dir
