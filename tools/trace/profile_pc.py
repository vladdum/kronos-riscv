#!/usr/bin/env python3
# Copyright 2026 Vlad-Dumitru Popescu
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
"""profile_pc.py — top-N hot-PC bar chart with ASCII bars.

Usage:
    profile_pc.py <profile.csv> [--top N] [--cacheline]

If --cacheline is given, group entries by 64-byte cache line first.
"""
import argparse
import csv
import sys

BAR_WIDTH = 40


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("path")
    p.add_argument("--top", type=int, default=20)
    p.add_argument("--cacheline", action="store_true")
    args = p.parse_args(argv)

    with open(args.path, newline="") as f:
        rows = list(csv.DictReader(f))
    if not rows:
        print("(empty profile)")
        return 0

    if args.cacheline:
        agg = {}
        for r in rows:
            line = int(r["pc"], 16) & ~0x3F
            agg.setdefault(line, [0, r["mnemonic"]])
            agg[line][0] += int(r["count"])
        flat = [(f"{k:016x}", v[1], v[0]) for k, v in agg.items()]
    else:
        flat = [(r["pc"], r["mnemonic"], int(r["count"])) for r in rows]
    flat.sort(key=lambda x: x[2], reverse=True)
    flat = flat[: args.top]
    total = sum(c for _, _, c in flat) or 1
    max_count = max(c for _, _, c in flat) or 1

    print(f"{'pc':>16} {'mnemonic':<10} {'count':>10}  fraction  bar")
    for pc, mn, c in flat:
        frac = c / total
        bar = "█" * int(BAR_WIDTH * c / max_count)
        print(f"{pc:>16} {mn:<10} {c:>10}  {frac*100:6.2f}%  {bar}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
