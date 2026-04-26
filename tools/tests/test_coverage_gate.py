"""Tests for tools/coverage_gate.py — line and functional coverage modes."""

import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path

GATE = Path(__file__).parent.parent / "coverage_gate.py"


def run_gate(*args):
    """Run coverage_gate.py with the given arguments; return (returncode, stdout+stderr)."""
    result = subprocess.run(
        [sys.executable, str(GATE)] + list(args),
        capture_output=True, text=True
    )
    return result.returncode, result.stdout + result.stderr


# ---------------------------------------------------------------------------
# Helpers to create temp files
# ---------------------------------------------------------------------------

def make_merged(bins: dict, tmp_path) -> Path:
    """Write a merged.txt with format '<name>  <0|1>'."""
    p = tmp_path / "merged.txt"
    lines = [f"{name:<36}{val}" for name, val in bins.items()]
    p.write_text("\n".join(lines) + "\n")
    return p


def make_excludes(names: list, tmp_path) -> Path:
    """Write an excludes file listing the given bin names."""
    p = tmp_path / "excludes.txt"
    p.write_text("\n".join(names) + "\n")
    return p


def make_info(total: int, hit: int, tmp_path) -> Path:
    """Write a minimal LCOV .info file with `total` DA lines, `hit` of which are > 0."""
    p = tmp_path / "coverage.info"
    lines = ["SF:rtl/stage5/kronos_top.sv"]
    for i in range(1, total + 1):
        count = 1 if i <= hit else 0
        lines.append(f"DA:{i},{count}")
    lines.append("end_of_record")
    p.write_text("\n".join(lines) + "\n")
    return p


# ---------------------------------------------------------------------------
# Functional coverage tests
# ---------------------------------------------------------------------------

class TestFunctionalPass:
    def test_all_bins_hit(self, tmp_path):
        merged = make_merged({"grp.a": 1, "grp.b": 1, "grp.c": 1}, tmp_path)
        rc, out = run_gate("--functional", str(merged))
        assert rc == 0
        assert "PASS" in out
        assert "3/3" in out

    def test_threshold_met(self, tmp_path):
        merged = make_merged({"grp.a": 1, "grp.b": 1, "grp.c": 0}, tmp_path)
        rc, out = run_gate("--functional", str(merged), "--threshold", "66")
        assert rc == 0
        assert "PASS" in out

    def test_100_percent_default_threshold(self, tmp_path):
        merged = make_merged({"grp.a": 1}, tmp_path)
        rc, out = run_gate("--functional", str(merged))
        assert rc == 0


class TestFunctionalFail:
    def test_some_bins_missed(self, tmp_path):
        merged = make_merged({"grp.a": 1, "grp.b": 0, "grp.c": 0}, tmp_path)
        rc, out = run_gate("--functional", str(merged))
        assert rc == 1
        assert "FAIL" in out
        assert "MISS: grp.b" in out
        assert "MISS: grp.c" in out

    def test_threshold_not_met(self, tmp_path):
        merged = make_merged({"grp.a": 1, "grp.b": 0, "grp.c": 0}, tmp_path)
        rc, out = run_gate("--functional", str(merged), "--threshold", "90")
        assert rc == 1
        assert "FAIL" in out


class TestFunctionalExclusions:
    def test_excluded_bins_not_counted(self, tmp_path):
        merged = make_merged({"grp.a": 1, "grp.b": 0, "grp.c": 0}, tmp_path)
        excludes = make_excludes(["grp.b", "grp.c"], tmp_path)
        rc, out = run_gate("--functional", str(merged), "--exclude-bins", str(excludes))
        assert rc == 0
        assert "1/1" in out
        assert "excluded 2" in out

    def test_excluded_miss_does_not_appear_in_misses(self, tmp_path):
        merged = make_merged({"grp.a": 1, "grp.b": 0}, tmp_path)
        excludes = make_excludes(["grp.b"], tmp_path)
        rc, out = run_gate("--functional", str(merged), "--exclude-bins", str(excludes))
        assert rc == 0
        assert "MISS: grp.b" not in out

    def test_excludes_comments_and_blanks_ignored(self, tmp_path):
        merged = make_merged({"grp.a": 0}, tmp_path)
        p = tmp_path / "excludes.txt"
        p.write_text("# comment\n\ngrp.a\n")
        rc, out = run_gate("--functional", str(merged), "--exclude-bins", str(p))
        # grp.a excluded, so 0 applicable bins
        assert rc == 2  # "no bins found" error


class TestFunctionalEdgeCases:
    def test_empty_merged_file_exits_2(self, tmp_path):
        p = tmp_path / "empty.txt"
        p.write_text("# only comments\n\n")
        rc, _ = run_gate("--functional", str(p))
        assert rc == 2

    def test_comment_lines_skipped(self, tmp_path):
        p = tmp_path / "merged.txt"
        p.write_text("# header\ngrp.a                               1\n")
        rc, out = run_gate("--functional", str(p))
        assert rc == 0
        assert "1/1" in out


# ---------------------------------------------------------------------------
# Line coverage tests (backward compat)
# ---------------------------------------------------------------------------

class TestLineCoverage:
    def test_pass_at_threshold(self, tmp_path):
        info = make_info(100, 95, tmp_path)
        rc, out = run_gate(str(info), "--threshold", "95")
        assert rc == 0
        assert "PASS" in out

    def test_fail_below_threshold(self, tmp_path):
        info = make_info(100, 80, tmp_path)
        rc, out = run_gate(str(info), "--threshold", "95")
        assert rc == 1
        assert "FAIL" in out

    def test_default_threshold_95(self, tmp_path):
        info = make_info(100, 94, tmp_path)
        rc, out = run_gate(str(info))
        assert rc == 1

    def test_tb_lines_excluded(self, tmp_path):
        # A .info file where a tb/ source has a missed line but rtl/ has 100% hit.
        p = tmp_path / "cov.info"
        p.write_text(textwrap.dedent("""\
            SF:rtl/stage5/kronos_top.sv
            DA:1,1
            DA:2,1
            end_of_record
            SF:../tb/stage5/tb_crv_cov.sv
            DA:1,0
            end_of_record
        """))
        rc, out = run_gate(str(p))
        assert rc == 0
        assert "2/2" in out
