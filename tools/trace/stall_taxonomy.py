#!/usr/bin/env python3
# Copyright 2026 Vlad-Dumitru Popescu
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
"""stall_taxonomy.py — per-cause stall breakdown table with ASCII bars.

Usage:
    stall_taxonomy.py <stalls.csv>
"""
import argparse
import csv
import sys

BAR_WIDTH = 30


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument("path")
    args = p.parse_args(argv)

    with open(args.path, newline="") as f:
        rows = list(csv.DictReader(f))

    rows.sort(key=lambda r: int(r["cycle_count"]), reverse=True)
    max_c = max((int(r["cycle_count"]) for r in rows), default=1) or 1

    print(f"{'event':<22} {'cycles':>10} {'fraction':>10}  bar")
    for r in rows:
        c = int(r["cycle_count"])
        frac = float(r["fraction"])
        bar = "█" * int(BAR_WIDTH * c / max_c)
        print(f"{r['event_name']:<22} {c:>10} {frac*100:9.2f}%  {bar}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
