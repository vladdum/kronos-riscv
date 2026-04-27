#!/usr/bin/env python3
# Copyright 2026 Vlad-Dumitru Popescu
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
"""trace_to_text.py — pretty-print a +trace CSV as readable assembly.

Usage:
    trace_to_text.py <trace.csv>
"""
import argparse
import csv
import sys

TRAP_NAMES = {
    "0": "",
    "1": "INSTR_ACCESS_FAULT",
    "2": "ILLEGAL_INSTR",
    "3": "BREAKPOINT",
    "4": "LOAD_ADDR_MISALIGNED",
    "11": "ECALL_M",
}


def fmt_row(r):
    pc = int(r["pc"], 16)
    parts = [f"{int(r['cycle']):>8}: 0x{pc:x}  {r['mnemonic']:<10}"]
    extras = []
    if int(r["rd_wen"]) and int(r["rd"]) != 0:
        extras.append(f"x{int(r['rd'])} = 0x{int(r['rd_wdata'], 16):x}")
    if int(r["fp_wen"]):
        extras.append(f"f{int(r['fp_rd'])} = 0x{int(r['fp_wdata'], 16):x}")
    if int(r["mem_wen"]):
        extras.append(f"mem[0x{int(r['mem_addr'], 16):x}] = "
                      f"0x{int(r['mem_wdata'], 16):x}")
    if int(r["csr_wen"]):
        extras.append(f"csr[0x{int(r['csr_addr'], 16):03x}] = "
                      f"0x{int(r['csr_wdata'], 16):x}")
    if int(r["trap_taken"]):
        cause = r["trap_cause"]
        extras.append(f"trap={TRAP_NAMES.get(cause, cause)}")
    if extras:
        parts.append("  " + "  ".join(extras))
    return "".join(parts)


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("path")
    args = p.parse_args(argv)
    with open(args.path, newline="") as f:
        for r in csv.DictReader(f):
            print(fmt_row(r))
    return 0


if __name__ == "__main__":
    sys.exit(main())
