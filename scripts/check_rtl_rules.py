#!/usr/bin/env python3
"""Lightweight checker for the kronos-riscv RTL coding rules in CLAUDE.md.

Catches the two highest-leverage classes of regressions identified in
docs/superpowers/specs/2026-04-29-rtl-coding-guidelines-design.md §4:

  - R2:    `automatic` keyword on variables (anywhere except function/task
           signatures).
  - R1+R3: `logic` / `int` / `bit` / `reg` / struct / enum declarations
           appearing after the first `always_*` block in a module body
           (loop indices, inside `function`/`generate`/labelled-begin
           scopes are exempt — see CLAUDE.md R3 carve-out).

Plus two of the additions made during the Phase A/B refactor:

  - History-flavor comment prefixes (`// Stage NX:`, `// Fix #N:`).
  - Multi-line `if` / `else` body without `begin` / `end` (with the reset
    idiom and single-line bodies as carve-outs).

Use as a git pre-commit hook (.githooks/pre-commit calls this on the
staged file list) or as a standalone scan: `scripts/check_rtl_rules.py`
with no args walks `rtl/` and `tb/`.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path
from typing import Iterable

ALWAYS_RE       = re.compile(r"^\s*always_(ff|comb|latch)\b")
AUTOMATIC_RE    = re.compile(r"^\s*automatic\s+(logic|int|bit|reg)\b")
FUNCTION_RE     = re.compile(r"^\s*function\b")
ENDFUNCTION_RE  = re.compile(r"^\s*endfunction\b")
TASK_RE         = re.compile(r"^\s*task\b")
ENDTASK_RE      = re.compile(r"^\s*endtask\b")
GENERATE_RE     = re.compile(r"^\s*generate\b")
ENDGENERATE_RE  = re.compile(r"^\s*endgenerate\b")
DECL_RE         = re.compile(r"^\s*(logic|int|bit|reg|enum|struct)\b")
HISTORY_RE      = re.compile(r"^\s*//\s*(Stage\s+[0-9]+[a-z]\s*:|Fix\s+#[0-9]+\s*:)")
IF_BARE_RE      = re.compile(r"^(\s*)(?:end\s+)?(?:else\s+)?if\s*\([^)]*\)\s*$")
IF_RESET_RE     = re.compile(r"^\s*if\s*\(\s*!rst_ni\s*\)")
BEGIN_NAMED_RE  = re.compile(r"\bbegin\s*:\s*\w+")
BEGIN_PLAIN_RE  = re.compile(r"\bbegin\b(?!\s*:)")


def check_file(path: Path) -> list[str]:
    violations: list[str] = []
    try:
        lines = path.read_text(errors="replace").splitlines()
    except OSError as exc:
        return [f"{path}: cannot read: {exc}"]

    seen_first_always = False
    in_function = 0
    in_task = 0
    in_generate = 0
    # Stack of currently-open `begin` blocks. Each entry is True if the
    # block was opened with a label (`begin : <name>`), False otherwise.
    begin_stack: list[bool] = []

    for n, raw in enumerate(lines, start=1):
        line = raw.rstrip()
        no_comment = line.split("//", 1)[0]

        if FUNCTION_RE.match(line):
            in_function += 1
        if ENDFUNCTION_RE.match(line):
            in_function = max(0, in_function - 1)
        if TASK_RE.match(line):
            in_task += 1
        if ENDTASK_RE.match(line):
            in_task = max(0, in_task - 1)
        if GENERATE_RE.match(line):
            in_generate += 1
        if ENDGENERATE_RE.match(line):
            in_generate = max(0, in_generate - 1)

        for _ in BEGIN_NAMED_RE.findall(no_comment):
            begin_stack.append(True)
        for _ in BEGIN_PLAIN_RE.findall(no_comment):
            begin_stack.append(False)
        for _ in re.finditer(r"\bend\b(?!\w)", no_comment):
            if begin_stack:
                begin_stack.pop()

        in_named_begin = any(begin_stack)

        if AUTOMATIC_RE.match(line):
            violations.append(f"{path}:{n}: R2: `automatic` on variable declaration")

        if ALWAYS_RE.match(line):
            seen_first_always = True
        elif (
            seen_first_always
            and DECL_RE.match(line)
            and in_function == 0
            and in_task == 0
            and in_generate == 0
            and not in_named_begin
        ):
            violations.append(
                f"{path}:{n}: R1/R3: declaration after first `always_*` "
                f"(must move to module-scope decl block at top of module)"
            )

        if HISTORY_RE.match(line):
            violations.append(
                f"{path}:{n}: history-prefix comment "
                f"(strip `Stage NX:` / `Fix #N:` per CLAUDE.md)"
            )

        if IF_BARE_RE.match(line) and not IF_RESET_RE.match(line):
            for ahead in lines[n:n + 3]:
                ahead_strip = ahead.strip()
                if not ahead_strip:
                    continue
                if ahead_strip.startswith("begin"):
                    break
                if ahead_strip.endswith(";") or ahead_strip.endswith(",") \
                   or ahead_strip.startswith("&") or ahead_strip.startswith("|"):
                    if "begin" in ahead_strip or ahead_strip.endswith(") begin"):
                        break
                    continue
                violations.append(
                    f"{path}:{n}: multi-line `if` without `begin`/`end` "
                    f"(wrap body or use single-line form)"
                )
                break

    return violations


def gather_files(args: argparse.Namespace) -> Iterable[Path]:
    if args.staged:
        out = subprocess.run(
            ["git", "diff", "--cached", "--name-only", "--diff-filter=ACMR"],
            check=True, capture_output=True, text=True,
        )
        for line in out.stdout.splitlines():
            p = Path(line)
            if p.suffix == ".sv" and p.exists():
                yield p
        return

    if args.paths:
        for raw in args.paths:
            p = Path(raw)
            if p.is_dir():
                yield from p.rglob("*.sv")
            elif p.suffix == ".sv":
                yield p
        return

    for root in (Path("rtl"), Path("tb")):
        if root.is_dir():
            yield from root.rglob("*.sv")


def staged_added_lines(path: Path) -> set[int]:
    out = subprocess.run(
        ["git", "diff", "--cached", "--unified=0", "--no-color", "--", str(path)],
        check=True, capture_output=True, text=True,
    )
    added: set[int] = set()
    hunk_re = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")
    for raw in out.stdout.splitlines():
        m = hunk_re.match(raw)
        if m:
            start = int(m.group(1))
            count = int(m.group(2)) if m.group(2) else 1
            for ln in range(start, start + count):
                added.add(ln)
    return added


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("paths", nargs="*", help="Files or directories to scan")
    p.add_argument("--staged", action="store_true",
                   help="Check only staged files (use as git pre-commit hook)")
    args = p.parse_args()

    violations: list[str] = []
    line_re = re.compile(r"^([^:]+):(\d+):")
    for path in gather_files(args):
        file_violations = check_file(path)
        if args.staged:
            added = staged_added_lines(path)
            file_violations = [
                v for v in file_violations
                if (m := line_re.match(v)) and int(m.group(2)) in added
            ]
        violations.extend(file_violations)

    if violations:
        print("RTL rule violations:", file=sys.stderr)
        for v in violations:
            print(f"  {v}", file=sys.stderr)
        print(file=sys.stderr)
        print(f"{len(violations)} violation(s). See "
              f"CLAUDE.md `## SystemVerilog Coding Guidelines` for context.",
              file=sys.stderr)
        if args.staged:
            print("Bypass with `git commit --no-verify` if intentional.",
                  file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
