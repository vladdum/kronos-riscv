# Copyright 2026 Vlad-Dumitru Popescu
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

STAGE ?= 5
JOBS  ?= $(shell nproc)

-include fpga/kv260/synth.cfg
SYNTH_FREQ_MHZ ?= 200

# Map STAGE to the right sim/Makefile build target:
#   stage 0 → "build", stages 1-5 → "build-s<N>"
_BUILD_TARGET  = $(if $(filter 0,$(STAGE)),build,build-s$(STAGE))

# Map STAGE to the right FuseSoC lint target:
#   stage 5 → "lint" (default), others → "lint-s<N>"
_LINT_TARGET   = $(if $(filter 5,$(STAGE)),lint,lint-s$(STAGE))

.PHONY: help lint build regression compliance coverage synth gls-funcsim gls-sdf clean

help:
	@echo "Usage: make <target> [STAGE=<0-5>] [JOBS=<N>]"
	@echo ""
	@echo "Targets"
	@echo "  lint        Verilator lint (uses STAGE)"
	@echo "  build       Build Verilator simulator (uses STAGE)"
	@echo "  regression  Unit testbench suite across all stages"
	@echo "  compliance  ACT4 compliance suite (uses STAGE, stages 1-5 only)"
	@echo "  coverage    Line coverage gate (stage 5 FPU + ALU/LSU/decode)"
	@echo "  synth       Vivado synthesis + P&R on KV260"
	@echo "  gls-funcsim Gate-level funcsim of OOC kronos_top netlist"
	@echo "  gls-sdf     Gate-level SDF timing sim (single smoke test)"
	@echo "  clean       Remove build artefacts"
	@echo ""
	@echo "Options"
	@echo "  STAGE=5   Active stage (0-5, default 5)"
	@echo "  JOBS=$(JOBS)    Parallel jobs (default: nproc)"

# ── Lint ──────────────────────────────────────────────────────────────────────

lint:
	fusesoc --cores-root=. run --target=$(_LINT_TARGET) opensoc:ip:kronos_riscv

# ── Build ─────────────────────────────────────────────────────────────────────

build:
	$(MAKE) -C sim $(_BUILD_TARGET)

# ── Regression ────────────────────────────────────────────────────────────────

regression:
	$(MAKE) -C sim -j$(JOBS) sim-all

# ── Compliance ────────────────────────────────────────────────────────────────

compliance:
ifeq ($(STAGE),0)
	$(error compliance suite is not available for stage 0)
endif
	$(MAKE) -C sim sim-arch-test-s$(STAGE)

# ── Coverage ──────────────────────────────────────────────────────────────────

coverage:
	$(MAKE) -C sim coverage

# ── Synthesis ─────────────────────────────────────────────────────────────────

synth:
	vivado -mode batch -source fpga/kv260/synth.tcl \
	  -tclargs SYNTH_FREQ_MHZ=$(SYNTH_FREQ_MHZ)

# ── Gate-level simulation ─────────────────────────────────────────────────────

gls-funcsim:
	$(MAKE) -C sim gls-funcsim

gls-sdf:
	$(MAKE) -C sim gls-sdf

# ── Clean ─────────────────────────────────────────────────────────────────────

clean:
	$(MAKE) -C sim clean
	$(MAKE) -C sim clean-vivado
	rm -rf build/opensoc_ip_kronos_riscv_0
