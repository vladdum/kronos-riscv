#!/usr/bin/env python3
# coverage_gate.py — parse a merged LCOV .info file and gate on line coverage.
#
# Usage: coverage_gate.py <merged.info> [threshold_pct]
#   threshold_pct: required line coverage percentage (default 95).
#   Exit 0 if coverage >= threshold, exit 1 otherwise.
#
import sys
import re

def main():
    if len(sys.argv) < 2:
        print("Usage: coverage_gate.py <merged.info> [threshold_pct]", file=sys.stderr)
        sys.exit(2)

    info_file  = sys.argv[1]
    threshold  = float(sys.argv[2]) if len(sys.argv) > 2 else 95.0

    total = 0
    hit   = 0

    with open(info_file) as f:
        for line in f:
            m = re.match(r'^DA:(\d+),(\d+)', line)
            if m:
                total += 1
                if int(m.group(2)) > 0:
                    hit += 1

    if total == 0:
        print("ERROR: no DA lines in coverage file — was it built with --coverage-line?",
              file=sys.stderr)
        sys.exit(2)

    pct = 100.0 * hit / total
    status = "PASS" if pct >= threshold else "FAIL"
    print(f"{status}: line coverage {hit}/{total} = {pct:.1f}%  (threshold {threshold:.0f}%)")

    sys.exit(0 if pct >= threshold else 1)

if __name__ == "__main__":
    main()
