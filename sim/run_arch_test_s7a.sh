#!/usr/bin/env bash
set -euo pipefail
SIM_DIR="$(cd "$(dirname "$0")" && pwd)"
ELF=$1
HEX=$(mktemp /tmp/kronos_XXXXXX.hex)
trap 'rm -f "$HEX"' EXIT
riscv64-unknown-elf-objcopy -O ihex "$ELF" "$HEX"
# Stage 7a is ISA-equivalent to stage 6 (RV64IMAFDC + S-mode + PMP).  Cycle
# budget tracks stage 6: 5M is ~4× the longest observed compliance test,
# slightly larger than stage 6 to absorb the EX1/EX2 split overhead.
exec env SIM_MAX_CYCLES="${SIM_MAX_CYCLES:-5000000}" \
     timeout --foreground --signal=TERM --kill-after=5s 60s \
     "$SIM_DIR/obj_dir/s7a/Vsim_top" "$HEX"
