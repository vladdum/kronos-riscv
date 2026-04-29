#!/usr/bin/env bash
set -euo pipefail
SIM_DIR="$(cd "$(dirname "$0")" && pwd)"
ELF=$1
HEX=$(mktemp /tmp/kronos_XXXXXX.hex)
trap 'rm -f "$HEX"' EXIT
riscv64-unknown-elf-objcopy -O ihex "$ELF" "$HEX"
# SIM_MAX_CYCLES: 5M is ~4× the longest observed compliance test.
# S7 reuses the S5 RV64IMAFDC envelope; priv-suite tests stay well under 5M.
# timeout: wall-clock safety net under the run_tests.py 5-minute bound.
exec env SIM_MAX_CYCLES="${SIM_MAX_CYCLES:-5000000}" \
     timeout --foreground --signal=TERM --kill-after=5s 60s \
     "$SIM_DIR/obj_dir/s7/Vsim_top" "$HEX"
