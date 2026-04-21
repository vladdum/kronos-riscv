#!/usr/bin/env bash
# Run sail_riscv_sim on <elf> and print a Kronos-normalized retire trace.
# Usage: tools/sail_trace.sh <elf> [sail_config]
#
# <sail_config> defaults to the kronos-rv64imafd sail.json.
# Trace flags: --trace-instr --trace-reg --trace-mem  (subset of --trace-all)
# that produce per-instruction commit lines plus register/memory effects.
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <elf> [sail_config]" >&2
  exit 2
fi

ELF=$1
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

SAIL_CONFIG=${2:-"$REPO_ROOT/riscv-arch-test/config/kronos/kronos-rv64imafdc/sail.json"}

TRACE_TMP=$(mktemp /tmp/sail_trace_XXXXXX.txt)
trap 'rm -f "$TRACE_TMP"' EXIT

# ACT4 ELFs halt via HTIF/tohost; stage-5 sw tests write to 0x40000000 which
# Sail does not recognise as a halt. Use SIM_INST_LIMIT (default 5M) so the
# runner never hangs on programs that use the Verilator-only halt sentinel.
# 50 000 instructions covers all current stage-5 sw tests; ACT4 ELFs halt
# naturally via HTIF before hitting this limit.  Override via SIM_INST_LIMIT.
INST_LIMIT=${SIM_INST_LIMIT:-50000}

sail_riscv_sim \
  --trace-instr \
  --trace-reg \
  --trace-mem \
  --trace-output "$TRACE_TMP" \
  --config "$SAIL_CONFIG" \
  --inst-limit "$INST_LIMIT" \
  "$ELF" \
  >/dev/null 2>&1 || true

python3 "$SCRIPT_DIR/sail_trace_normalize.py" < "$TRACE_TMP"
