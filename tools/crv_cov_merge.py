#!/usr/bin/env python3
# Copyright 2026 Vlad-Dumitru Popescu
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
"""Merge per-scenario coverage.txt files into a single merged.txt report.

Usage:
    python3 tools/crv_cov_merge.py coverage_sc1.txt coverage_sc2.txt ... \
            --out merged.txt

Each input file contains lines: "<group.bin>  <0|1>"
The merge ORs all per-bin hit flags across input files and writes the result
to --out, then prints a summary table to stdout.

Exit code:
    0  always (gate logic is Task 7)
"""
from __future__ import annotations
import argparse
import sys
from collections import OrderedDict
from pathlib import Path


def load(path: Path) -> dict[str, int]:
    result: dict[str, int] = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) != 2:
            continue
        result[parts[0]] = int(parts[1])
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="Merge CRV coverage files")
    parser.add_argument("inputs", nargs="+", type=Path,
                        help="Per-scenario coverage.txt files")
    parser.add_argument("--out", type=Path, default=Path("merged.txt"),
                        help="Output merged coverage file")
    args = parser.parse_args()

    merged: dict[str, int] = OrderedDict()
    for f in args.inputs:
        if not f.exists():
            sys.stderr.write(f"[crv_cov_merge] WARNING: {f} not found, skipping\n")
            continue
        data = load(f)
        for k, v in data.items():
            merged[k] = merged.get(k, 0) | v

    if not merged:
        sys.stderr.write("[crv_cov_merge] ERROR: no coverage data loaded\n")
        return 1

    # Write merged file
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w") as fout:
        for k, v in merged.items():
            fout.write(f"{k:<36} {v}\n")

    # Print summary grouped by covergroup
    total = len(merged)
    hit   = sum(1 for v in merged.values() if v)
    print(f"\n{'Coverage summary':}")
    print(f"{'':─<60}")
    current_group = None
    g_total = g_hit = 0
    group_stats: list[tuple[str, int, int]] = []
    for k, v in merged.items():
        grp = k.split(".")[0]
        if grp != current_group:
            if current_group is not None:
                group_stats.append((current_group, g_hit, g_total))
            current_group = grp
            g_total = g_hit = 0
        g_total += 1
        g_hit   += v
    if current_group is not None:
        group_stats.append((current_group, g_hit, g_total))

    for grp, gh, gt in group_stats:
        pct = 100.0 * gh / gt if gt else 0.0
        bar = "█" * int(pct / 5)
        print(f"  {grp:<22} {gh:>3}/{gt:<3}  {pct:5.1f}%  {bar}")
    print(f"{'':─<60}")
    pct_total = 100.0 * hit / total if total else 0.0
    print(f"  {'TOTAL':<22} {hit:>3}/{total:<3}  {pct_total:5.1f}%")
    print(f"\nMerged coverage written to {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
