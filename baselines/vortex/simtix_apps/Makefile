ROOT_DIR := $(realpath ../../..)
include $(ROOT_DIR)/config.mk

PROJECT := simtix_apps

SRC_DIR := $(VORTEX_HOME)/tests/regression/$(PROJECT)

SRCS := $(SRC_DIR)/main.cpp

VX_SRCS := $(SRC_DIR)/kernel.cpp

# The kernels fix the order of every FP operation; keep the compiler from fusing others.
VX_CFLAGS += -ffp-contract=off

KERNEL_LIB := vortex2

include ../common.mk
