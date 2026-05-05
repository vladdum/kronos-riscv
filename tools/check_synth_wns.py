#!/usr/bin/env python3
"""Parse a Vivado post_synth_timing.txt and assert WNS >= a per-stage floor.

Usage:
    check_synth_wns.py <path-to-post_synth_timing.txt> --floor <ns>

Exits 0 if WNS >= floor (regression-free), 1 otherwise.
"""
import argparse
import re
import sys


def parse_wns(path: str) -> float:
    """Return the worst-case setup WNS (ns) from a Vivado timing summary."""
    pattern = re.compile(
        r"Setup\s*:\s*\d+\s*Failing Endpoints,\s*Worst Slack\s*([+\-]?\d+\.\d+)ns"
    )
    with open(path) as fh:
        for line in fh:
            m = pattern.search(line)
            if m:
                return float(m.group(1))
    raise RuntimeError(f"No 'Setup ... Worst Slack' line found in {path}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("report")
    ap.add_argument("--floor", type=float, required=True,
                    help="Minimum allowed WNS in ns (negative ok).")
    args = ap.parse_args()
    wns = parse_wns(args.report)
    print(f"Post-synth WNS: {wns:+.3f} ns (floor {args.floor:+.3f} ns)")
    if wns < args.floor:
        print(f"FAIL: WNS regressed below floor by {args.floor - wns:.3f} ns")
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
