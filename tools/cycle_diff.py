#!/usr/bin/env python3
"""Compare halt cycle counts between two Vsim runs (baseline vs candidate).

Both binaries run the same .hex; the simulator prints a single
`[sim] halt at cycle <N>, x10 = <M>` line per run.  This script extracts the
cycle count and the program-reported success flag (x10=0 means PASS) from
both runs, computes IPC delta = (candidate_cycles - baseline_cycles) /
baseline_cycles (the candidate retires the same number of instructions since
both binaries execute the same hex), and asserts that the slowdown is within
the per-stage budget.

Two modes:

1) Direct binaries (kept for local use):
       cycle_diff.py --baseline-bin <s6_Vsim_top> \\
                     --candidate-bin <s7a_Vsim_top> \\
                     --prog <prog.hex> \\
                     --max-delta 0.05

2) Baseline-commit orchestration (CI use):
       cycle_diff.py --baseline-commit <sha> \\
                     --prog <prog.hex> \\
                     --max-delta 0.05

   This mode:
     - Verifies <sha> exists in the local git history.
     - Creates a temporary worktree at /tmp/kronos-baseline-<sha>.
     - Builds the baseline binary there with `make build-s7a PULP_AXI_ROOT=...`.
     - Builds the candidate binary in the current repo the same way (unless
       --candidate-bin is supplied).
     - Runs both binaries on --prog and compares cycle counts.
     - Removes the worktree at the end (pass or fail).

   PULP_AXI_ROOT is taken from the environment if set, otherwise it defaults
   to /home/popes/opensoc/hw/ip/pulp_axi (the local development default).
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


HALT_RE = re.compile(r"\[sim\]\s+halt\s+at\s+cycle\s+(\d+),\s+x10\s*=\s*(-?\d+)")

DEFAULT_PULP_AXI_ROOT = "/home/popes/opensoc/hw/ip/pulp_axi"


def run_sim(sim_bin: Path, prog_hex: Path) -> tuple[int, int, str]:
    """Run a simulator binary on a .hex and return (cycles, x10, halt_line)."""
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


def repo_root() -> Path:
    """Return the absolute path to the current git repo root."""
    out = subprocess.check_output(
        ["git", "rev-parse", "--show-toplevel"], text=True
    ).strip()
    return Path(out)


def verify_commit(sha: str) -> str:
    """Resolve <sha> to a full commit id, raise if it doesn't exist."""
    try:
        full = subprocess.check_output(
            ["git", "rev-parse", f"{sha}^{{commit}}"],
            text=True, stderr=subprocess.PIPE,
        ).strip()
    except subprocess.CalledProcessError as e:
        raise RuntimeError(
            f"baseline commit {sha!r} not found in local git history "
            f"(git rev-parse failed: {e.stderr.strip() if e.stderr else e})"
        )
    return full


def build_s7a(work_root: Path, pulp_axi_root: str) -> Path:
    """Run `make -C sim build-s7a` in <work_root>; return path to the binary."""
    sim_bin = work_root / "sim" / "obj_dir" / "s7a" / "Vsim_top"
    print(f"[cycle_diff] building s7a in {work_root} "
          f"(PULP_AXI_ROOT={pulp_axi_root}) ...", flush=True)
    env = os.environ.copy()
    env["PULP_AXI_ROOT"] = pulp_axi_root
    subprocess.check_call(
        ["make", "-C", str(work_root / "sim"), "build-s7a",
         f"PULP_AXI_ROOT={pulp_axi_root}"],
        env=env,
    )
    if not sim_bin.exists():
        raise RuntimeError(f"build succeeded but {sim_bin} is missing")
    return sim_bin


def build_baseline(sha: str, pulp_axi_root: str) -> tuple[Path, Path]:
    """Create a worktree at <sha>, build s7a there.  Returns (worktree, bin).

    The caller is responsible for tearing the worktree down via
    cleanup_worktree(worktree).
    """
    full_sha = verify_commit(sha)
    worktree = Path(f"/tmp/kronos-baseline-{full_sha[:12]}")

    # Remove any stale worktree from a previous interrupted run.
    if worktree.exists():
        cleanup_worktree(worktree)

    print(f"[cycle_diff] creating worktree {worktree} at {full_sha[:12]} ...",
          flush=True)
    subprocess.check_call(
        ["git", "worktree", "add", str(worktree), full_sha],
    )

    sim_bin = build_s7a(worktree, pulp_axi_root)
    return worktree, sim_bin


def cleanup_worktree(worktree: Path) -> None:
    """Best-effort removal of a git worktree directory."""
    if not worktree.exists():
        return
    print(f"[cycle_diff] removing worktree {worktree}", flush=True)
    rc = subprocess.call(
        ["git", "worktree", "remove", "--force", str(worktree)],
    )
    if rc != 0 or worktree.exists():
        # Fallback: nuke the directory directly so /tmp doesn't accumulate
        # half-removed worktrees across CI re-runs.
        shutil.rmtree(worktree, ignore_errors=True)
        subprocess.call(["git", "worktree", "prune"])


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--baseline-bin",  type=Path, default=None,
                    help="Path to the baseline simulator (e.g. "
                         "sim/obj_dir/s7a/Vsim_top).  Mutually exclusive with "
                         "--baseline-commit.")
    ap.add_argument("--baseline-commit", type=str, default=None,
                    help="Git SHA to build the baseline binary from.  Mutually "
                         "exclusive with --baseline-bin.")
    ap.add_argument("--candidate-bin", type=Path, default=None,
                    help="Path to the candidate simulator.  In "
                         "--baseline-commit mode this is built automatically "
                         "from the current HEAD if omitted.")
    ap.add_argument("--prog",          type=Path, required=True,
                    help="Path to the .hex program both simulators run.")
    ap.add_argument("--max-delta",     type=float, default=0.05,
                    help="Maximum allowed cycle delta (default 0.05 = 5%%).")
    ap.add_argument("--ignore-x10",    action="store_true",
                    help="Skip the x10=0 success check on both runs.  Use for "
                         "workloads whose x10 is a program-internal "
                         "perf-tolerance flag (e.g. dhrystone) rather than a "
                         "correctness signal — cycle_diff makes its own "
                         "cross-binary cycle comparison and the in-program "
                         "check is redundant.")
    args = ap.parse_args()

    if args.baseline_bin and args.baseline_commit:
        ap.error("--baseline-bin and --baseline-commit are mutually exclusive")
    if not args.baseline_bin and not args.baseline_commit:
        ap.error("one of --baseline-bin or --baseline-commit is required")

    pulp_axi_root = os.environ.get("PULP_AXI_ROOT", DEFAULT_PULP_AXI_ROOT)

    worktree: Path | None = None
    try:
        if args.baseline_commit:
            worktree, baseline_bin = build_baseline(
                args.baseline_commit, pulp_axi_root,
            )
            if args.candidate_bin is None:
                candidate_bin = build_s7a(repo_root(), pulp_axi_root)
            else:
                candidate_bin = args.candidate_bin
        else:
            baseline_bin = args.baseline_bin
            if args.candidate_bin is None:
                ap.error("--candidate-bin is required when not using "
                         "--baseline-commit")
            candidate_bin = args.candidate_bin

        base_cyc, base_x10, base_line = run_sim(baseline_bin,  args.prog)
        cand_cyc, cand_x10, cand_line = run_sim(candidate_bin, args.prog)
    finally:
        if worktree is not None:
            cleanup_worktree(worktree)

    print(f"baseline:  {base_line}")
    print(f"candidate: {cand_line}")

    # Both runs must succeed (the .hex's self-check, x10=0).  A non-zero x10
    # normally means the program detected an internal mismatch (correctness
    # bug, or a perf-gate program like dhrystone reporting cycle delta out of
    # tolerance against its own baked-in BASELINE_CYCLES).  --ignore-x10 lets
    # cross-binary perf comparisons skip that check (the in-program check is
    # redundant when cycle_diff is doing its own cycle-delta comparison
    # against a separately-built baseline binary).
    if not args.ignore_x10:
        if base_x10 != 0:
            print(f"FAIL: baseline reported x10={base_x10} (expected 0).")
            return 1
        if cand_x10 != 0:
            print(f"FAIL: candidate reported x10={cand_x10} (expected 0).")
            # Still print the cycle delta so the regression is visible.
            delta = (cand_cyc - base_cyc) / base_cyc
            print(f"  cycle delta: {delta * 100:+.2f}% "
                  f"({base_cyc} -> {cand_cyc}; "
                  f"budget +{args.max_delta * 100:.0f}%)")
            return 1
    else:
        if base_x10 != 0:
            print(f"note: baseline x10={base_x10} (ignored, --ignore-x10).")
        if cand_x10 != 0:
            print(f"note: candidate x10={cand_x10} (ignored, --ignore-x10).")

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
