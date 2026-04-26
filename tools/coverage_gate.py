#!/usr/bin/env python3
# coverage_gate.py — gate on line coverage and/or functional coverage.
#
# Line-coverage mode (original):
#   coverage_gate.py <merged.info> [threshold_pct]
#     merged.info:    LCOV .info file produced by verilator_coverage + lcov
#     threshold_pct:  required line coverage % (default 95)
#     Exit 0 if coverage >= threshold, exit 1 otherwise.
#
# Functional-coverage mode (new):
#   coverage_gate.py --functional <merged.txt> [--exclude-bins <bins.txt>]
#                    [--threshold <pct>]
#     merged.txt:     text file with lines "<group.bin>  <0|1>" (from
#                     tools/crv_cov_merge.py)
#     bins.txt:       optional file listing bin names to exclude (one per line;
#                     lines starting with # are comments)
#     threshold:      required hit percentage after exclusions (default 100)
#     Exit 0 if all non-excluded bins are hit, exit 1 otherwise.
#
import sys
import re
import argparse


def load_excludes(path):
    """Return a set of bin names to exclude."""
    excluded = set()
    if path is None:
        return excluded
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            excluded.add(line)
    return excluded


def run_functional(args):
    """Gate on functional coverage from a merged.txt file."""
    excluded = load_excludes(args.exclude_bins)
    threshold = args.threshold if args.threshold is not None else 100.0

    total = 0
    hit   = 0
    misses = []

    with open(args.functional) as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith('#'):
                continue
            # Format: "<name>  <0|1>"  (variable whitespace)
            parts = line.rsplit(None, 1)
            if len(parts) != 2:
                continue
            name, val = parts[0].strip(), parts[1].strip()
            if name in excluded:
                continue
            total += 1
            if val != '0':
                hit += 1
            else:
                misses.append(name)

    if total == 0:
        print("ERROR: no bins found in functional coverage file.", file=sys.stderr)
        sys.exit(2)

    pct = 100.0 * hit / total
    status = "PASS" if pct >= threshold else "FAIL"
    print(f"{status}: functional coverage {hit}/{total} = {pct:.1f}%"
          f"  (threshold {threshold:.0f}%)"
          f"  excluded {len(excluded)}")
    if misses:
        for m in misses:
            print(f"  MISS: {m}")

    sys.exit(0 if pct >= threshold else 1)


def run_line(args):
    """Gate on line coverage from an LCOV .info file (original behaviour)."""
    info_file = args.info_file
    threshold = args.threshold if args.threshold is not None else 95.0

    total = 0
    hit   = 0
    skip  = False

    with open(info_file) as f:
        for line in f:
            if line.startswith('SF:'):
                path = line[3:].strip()
                skip = path.startswith('../tb/')
                continue
            if skip:
                continue
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


def main():
    parser = argparse.ArgumentParser(
        description="Gate on line or functional coverage.")
    # Functional-coverage mode
    parser.add_argument('--functional', metavar='MERGED_TXT',
                        help='functional coverage merged.txt from crv_cov_merge.py')
    parser.add_argument('--exclude-bins', metavar='BINS_TXT',
                        help='file listing bin names to exclude from the gate')
    parser.add_argument('--threshold', type=float, metavar='PCT',
                        help='required hit percentage (default: 100 for functional, '
                             '95 for line)')
    # Line-coverage mode (positional, for backward compat)
    parser.add_argument('info_file', nargs='?',
                        help='LCOV merged.info file (line-coverage mode)')

    args = parser.parse_args()

    if args.functional:
        run_functional(args)
    elif args.info_file:
        run_line(args)
    else:
        parser.print_help(sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
