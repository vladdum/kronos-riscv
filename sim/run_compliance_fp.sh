#!/usr/bin/env bash
# run_compliance_fp.sh — run riscv-arch-test F or D suite against kronos stage5.
#
# Usage: run_compliance_fp.sh <suite>
#   suite: rv64i_m/F  or  rv64i_m/D
#
# Prerequisites:
#   - riscv-arch-test cloned at $ARCH_TEST (default: /home/popes/riscv-arch-test)
#   - A "kronos" target set up inside the repo under
#       riscv-arch-test/riscv-target/kronos/
#     pointing at sim/obj_dir/s5/Vsim_top as the simulator.
#
# The "kronos" target Makefile should look roughly like:
#   RISCV_TARGET_FLAGS :=
#   TARGET_SIM := /path/to/kronos-riscv/sim/obj_dir/s5/Vsim_top
#   $(WORK)/%.elf: $(WORK)/%.S
#       riscv64-unknown-elf-gcc -march=rv64gc -mabi=lp64 -static -mcmodel=medany \
#           -fvisibility=hidden -nostdlib \
#           -T$(RISCV_TARGET)/link.ld $< -o $@
#   ...
#
set -euo pipefail

SUITE=${1:-rv64i_m/F}
ARCH_TEST=${ARCH_TEST:-/home/popes/riscv-arch-test}

if [ ! -d "$ARCH_TEST" ]; then
    echo "[compliance] SKIP: riscv-arch-test not found at $ARCH_TEST"
    echo "  Clone it with:"
    echo "    git clone https://github.com/riscv-non-isa/riscv-arch-test $ARCH_TEST"
    exit 0
fi

cd "$ARCH_TEST"
make RISCV_TARGET=kronos RISCV_DEVICE="$SUITE" XLEN=64 sim
