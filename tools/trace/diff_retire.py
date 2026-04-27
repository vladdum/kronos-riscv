#!/usr/bin/env python3
# Copyright 2026 Vlad-Dumitru Popescu
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
"""diff_retire.py — locate the first row where two +trace CSVs diverge.

Usage:
    diff_retire.py <a.csv> <b.csv> [--context N]

Diff key: (pc, rd_wdata, fp_wdata, mem_wdata).  On divergence, prints
N (default 10) surrounding rows from each side, side-by-side.
Returns 0 on identity, 1 on divergence, 2 on file/format error.
"""
import argparse
import csv
import sys


def load_rows(path):
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        return list(reader)


def diff_key(row):
    return (row["pc"], row["rd_wdata"], row["fp_wdata"], row["mem_wdata"])


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("a")
    p.add_argument("b")
    p.add_argument("--context", type=int, default=10)
    args = p.parse_args(argv)
    try:
        a = load_rows(args.a)
        b = load_rows(args.b)
    except (OSError, csv.Error) as e:
        print(f"error: {e}", file=sys.stderr)
        return 2

    n = min(len(a), len(b))
    for i in range(n):
        if diff_key(a[i]) != diff_key(b[i]):
            print(f"DIVERGE at row {i}:")
            lo = max(0, i - args.context // 2)
            hi = min(n, i + args.context // 2 + 1)
            for j in range(lo, hi):
                marker = ">>" if j == i else "  "
                ar = a[j]
                br = b[j]
                print(f"{marker}{j:6d} | A pc={ar['pc']} mn={ar['mnemonic']:<8} "
                      f"rd={ar['rd_wdata']} mem={ar['mem_wdata']}")
                print(f"{marker}{j:6d} | B pc={br['pc']} mn={br['mnemonic']:<8} "
                      f"rd={br['rd_wdata']} mem={br['mem_wdata']}")
            return 1
    if len(a) != len(b):
        print(f"DIVERGE at end: a={len(a)} rows, b={len(b)} rows")
        return 1
    print(f"OK — {n} rows identical on diff key")
    return 0


if __name__ == "__main__":
    sys.exit(main())
