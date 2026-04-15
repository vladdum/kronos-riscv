#!/usr/bin/env python3
# Copyright 2026 Vlad-Dumitru Popescu
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
"""Generate TestFloat stimulus files for Stage 5a FPU TBs.

Requires `testfloat_gen` from berkeley-testfloat-3 on PATH.
Emits one file per (op, precision, rm) tuple under tb/stage5/testfloat_vectors/.
Each line is space-separated hex: a b c expected rm flags (c omitted for 2-op).
"""
import os, subprocess, sys, pathlib

OPS_2OP_S = ["f32_add", "f32_sub", "f32_mul"]
OPS_2OP_D = ["f64_add", "f64_sub", "f64_mul"]
OPS_3OP_S = ["f32_mulAdd"]
OPS_3OP_D = ["f64_mulAdd"]
CVT_OPS = ["f32_to_i32", "f32_to_ui32", "f32_to_i64", "f32_to_ui64",
           "f64_to_i32", "f64_to_ui32", "f64_to_i64", "f64_to_ui64",
           "i32_to_f32", "ui32_to_f32", "i64_to_f32", "ui64_to_f32",
           "i32_to_f64", "ui32_to_f64", "i64_to_f64", "ui64_to_f64",
           "f32_to_f64", "f64_to_f32"]
# (rm_flag, rm_byte): rm_flag is passed to testfloat_gen; rm_byte is injected
# into each output line (before the flags field) to match parse_vec_line format.
RMS = {
    "rne": ("-rnear_even",  0),
    "rtz": ("-rminMag",     1),
    "rdn": ("-rmin",        2),
    "rup": ("-rmax",        3),
    "rmm": ("-rnear_maxMag",4),
}

OUT = pathlib.Path(__file__).parent.parent / "tb" / "stage5" / "testfloat_vectors"
OUT.mkdir(parents=True, exist_ok=True)

def run(op, rm_name, rm_flag, rm_byte):
    cmd = ["testfloat_gen", "-tininessafter", rm_flag, "-level", "1", op]
    p = subprocess.run(cmd, capture_output=True, text=True, check=True)
    lines = []
    for line in p.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            # inject rm byte before the last field (flags)
            parts.insert(len(parts) - 1, f"{rm_byte:02x}")
        lines.append(" ".join(parts))
    out = OUT / f"{op}_{rm_name}.txt"
    out.write_text("\n".join(lines) + "\n")
    print(f"  wrote {out.name}  ({len(lines)} lines)")

def main():
    for op in OPS_2OP_S + OPS_2OP_D + OPS_3OP_S + OPS_3OP_D + CVT_OPS:
        for rm_name, (rm_flag, rm_byte) in RMS.items():
            run(op, rm_name, rm_flag, rm_byte)

if __name__ == "__main__":
    main()
