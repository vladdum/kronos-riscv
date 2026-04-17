#!/usr/bin/env bash
set -euo pipefail
SIM_DIR="$(cd "$(dirname "$0")" && pwd)"
ELF=$1
HEX=$(mktemp /tmp/kronos_XXXXXX.hex)
trap 'rm -f "$HEX"' EXIT
riscv64-unknown-elf-objcopy -O ihex "$ELF" "$HEX"
"$SIM_DIR/obj_dir/s4/Vsim_top" "$HEX"
