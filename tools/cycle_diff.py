#!/usr/bin/env python3
"""Compare halt cycle counts between two Vsim runs (stage6 baseline vs stage7a).

Both binaries run the same .hex; the simulator prints a single
`[sim] halt at cycle <N>, x10 = <M>` line per run.  This script extracts the
cycle count and the program-reported success flag (x10=0 means PASS) from
both runs, computes IPC delta = (candidate_cycles - baseline_cycles) /
baseline_cycles (the candidate retires the same number of instructions since
both binaries execute the same hex), and asserts that the slowdown is within
the per-stage budget.

Usage:
    cycle_diff.py --baseline-bin <s6_Vsim_top> \\
                  --candidate-bin <s7a_Vsim_top> \\
                  --prog <prog.hex> \\
                  --max-delta 0.05
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path


HALT_RE = re.compile(r"\[sim\]\s+halt\s+at\s+cycle\s+(\d+),\s+x10\s*=\s*(-?\d+)")


def run_sim(sim_bin: Path, prog_hex: Path) -> tuple[int, int, str]:
    """Run a simulator binary on a .hex and return (cycles, x10, stdout_tail)."""
    proc = subprocess.run(
        [str(sim_bin), str(prog_hex)],
        capture_output=True, text=True, timeout=300,
    )
    out = proc.stdout
    m = HALT_RE.search(out)
    if not m:
        tail = "\n".join(out.splitlines()[-20:])
        raise RuntimeError(
            f"Could not parse '[sim] halt at cycle ..., x10 = ...' from "
            f"{sim_bin}:\n{tail}"
        )
    cycles = int(m.group(1))
    x10 = int(m.group(2))
    return cycles, x10, m.group(0)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--baseline-bin",  type=Path, required=True,
                    help="Path to the baseline simulator (e.g. sim/obj_dir/s6/Vsim_top).")
    ap.add_argument("--candidate-bin", type=Path, required=True,
                    help="Path to the candidate simulator (e.g. sim/obj_dir/s7a/Vsim_top).")
    ap.add_argument("--prog",          type=Path, required=True,
                    help="Path to the .hex program both simulators run.")
    ap.add_argument("--max-delta",     type=float, default=0.05,
                    help="Maximum allowed cycle delta (default 0.05 = 5%%).")
    args = ap.parse_args()

    base_cyc, base_x10, base_line = run_sim(args.baseline_bin,  args.prog)
    cand_cyc, cand_x10, cand_line = run_sim(args.candidate_bin, args.prog)

    print(f"baseline:  {base_line}")
    print(f"candidate: {cand_line}")

    # Both runs must succeed (the .hex's self-check, x10=0).  A non-zero x10
    # means the program detected an internal mismatch (correctness bug, or a
    # perf-gate program like dhrystone reporting cycle delta out of tolerance);
    # either way we cannot compute a meaningful IPC delta from it.
    if base_x10 != 0:
        print(f"FAIL: baseline reported x10={base_x10} (expected 0).")
        return 1
    if cand_x10 != 0:
        print(f"FAIL: candidate reported x10={cand_x10} (expected 0).")
        # Still print the cycle delta so the regression is visible.
        delta = (cand_cyc - base_cyc) / base_cyc
        print(f"  cycle delta: {delta * 100:+.2f}% "
              f"({base_cyc} -> {cand_cyc}; budget +{args.max_delta * 100:.0f}%)")
        return 1

    # Both binaries execute the same program from the same .hex, so the retired
    # instruction count is identical.  Cycle delta therefore equals IPC delta.
    delta = (cand_cyc - base_cyc) / base_cyc
    print(f"baseline cycles:  {base_cyc}")
    print(f"candidate cycles: {cand_cyc}")
    print(f"cycle delta: {delta * 100:+.2f}% "
          f"(budget +{args.max_delta * 100:.0f}%)")

    if delta > args.max_delta:
        print("FAIL: cycle/IPC regression exceeds budget")
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
