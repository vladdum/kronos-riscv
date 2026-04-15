# File list for Verilator inclusion when building an FPU testbench.
HARDFLOAT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
HARDFLOAT_V := \
  $(HARDFLOAT_DIR)/HardFloat_primitives.v \
  $(HARDFLOAT_DIR)/HardFloat_rawFN.v \
  $(HARDFLOAT_DIR)/isSigNaNRecFN.v \
  $(HARDFLOAT_DIR)/fNToRecFN.v \
  $(HARDFLOAT_DIR)/recFNToFN.v \
  $(HARDFLOAT_DIR)/iNToRecFN.v \
  $(HARDFLOAT_DIR)/recFNToIN.v \
  $(HARDFLOAT_DIR)/recFNToRecFN.v \
  $(HARDFLOAT_DIR)/addRecFN.v \
  $(HARDFLOAT_DIR)/mulRecFN.v \
  $(HARDFLOAT_DIR)/mulAddRecFN.v \
  $(HARDFLOAT_DIR)/compareRecFN.v
