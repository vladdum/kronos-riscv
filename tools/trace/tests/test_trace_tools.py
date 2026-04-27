"""Tests for the tools/trace/* utilities."""
import os
import subprocess
import sys

HERE = os.path.dirname(__file__)
TOOLS_DIR = os.path.dirname(HERE)
FIX = os.path.join(HERE, "fixtures")


def run(*args):
    return subprocess.run(
        [sys.executable, *args],
        capture_output=True, text=True
    )


def test_diff_retire_identical(tmp_path):
    a = os.path.join(FIX, "diff_a.csv")
    res = run(os.path.join(TOOLS_DIR, "diff_retire.py"), a, a)
    assert res.returncode == 0
    assert "identical" in res.stdout


def test_diff_retire_diverges():
    a = os.path.join(FIX, "diff_a.csv")
    b = os.path.join(FIX, "diff_b.csv")
    res = run(os.path.join(TOOLS_DIR, "diff_retire.py"), a, b)
    assert res.returncode == 1
    assert "DIVERGE" in res.stdout


def test_profile_pc():
    res = run(os.path.join(TOOLS_DIR, "profile_pc.py"),
              os.path.join(FIX, "profile.csv"))
    assert res.returncode == 0
    assert "addi" in res.stdout
    assert "5000" in res.stdout


def test_profile_pc_cacheline():
    res = run(os.path.join(TOOLS_DIR, "profile_pc.py"),
              os.path.join(FIX, "profile.csv"), "--cacheline")
    assert res.returncode == 0
    # All three PCs share the same 64-byte cache line (0x80) → one row.
    assert res.stdout.count("\n") <= 4   # header + 1 data + a couple of blanks


def test_stall_taxonomy():
    res = run(os.path.join(TOOLS_DIR, "stall_taxonomy.py"),
              os.path.join(FIX, "stalls.csv"))
    assert res.returncode == 0
    assert "mem_busy_stall" in res.stdout
    assert "frm_hazard_stall" in res.stdout
    # Largest bucket (mem_busy_stall) appears before load_use_stall in the output.
    out = res.stdout
    assert out.find("mem_busy_stall") < out.find("load_use_stall")


def test_trace_to_text():
    res = run(os.path.join(TOOLS_DIR, "trace_to_text.py"),
              os.path.join(FIX, "diff_a.csv"))
    assert res.returncode == 0
    # Three rows in the fixture should produce three output lines.
    lines = [l for l in res.stdout.splitlines() if l.strip()]
    assert len(lines) == 3
    assert "addi" in res.stdout
    assert "0x80" in res.stdout


# --- 10 new tests ---


def test_trace_to_text_trap_known():
    """trap_taken=1 with a known cause (3 = BREAKPOINT) prints trap=BREAKPOINT."""
    res = run(os.path.join(TOOLS_DIR, "trace_to_text.py"),
              os.path.join(FIX, "diff_a_rich.csv"))
    assert res.returncode == 0
    assert "trap=BREAKPOINT" in res.stdout


def test_trace_to_text_trap_fallback():
    """trap_cause=42 (not in TRAP_NAMES) prints the raw number as the name."""
    res = run(os.path.join(TOOLS_DIR, "trace_to_text.py"),
              os.path.join(FIX, "diff_a_rich.csv"))
    assert res.returncode == 0
    assert "trap=42" in res.stdout


def test_trace_to_text_fp_write():
    """fp_wen=1 row prints the FP destination register and wdata."""
    res = run(os.path.join(TOOLS_DIR, "trace_to_text.py"),
              os.path.join(FIX, "diff_a_rich.csv"))
    assert res.returncode == 0
    # fp_rd=2, fp_wdata=deadbeef00000000
    assert "f2 = 0x" in res.stdout
    assert "deadbeef" in res.stdout


def test_trace_to_text_csr_write():
    """csr_wen=1 row prints csr[<addr>] = <wdata>."""
    res = run(os.path.join(TOOLS_DIR, "trace_to_text.py"),
              os.path.join(FIX, "diff_a_rich.csv"))
    assert res.returncode == 0
    assert "csr[0x305]" in res.stdout


def test_trace_to_text_mem_write():
    """mem_wen=1 row prints mem[<addr>] = <wdata>."""
    res = run(os.path.join(TOOLS_DIR, "trace_to_text.py"),
              os.path.join(FIX, "diff_a_rich.csv"))
    assert res.returncode == 0
    assert "mem[0x40000000] = 0x0" in res.stdout


def test_trace_to_text_no_extras():
    """A row with rd=0 (x0) and no FP/CSR/mem/trap writes has no extras section."""
    res = run(os.path.join(TOOLS_DIR, "trace_to_text.py"),
              os.path.join(FIX, "diff_a_rich.csv"))
    assert res.returncode == 0
    # The sw row (cycle 40) has rd=0 and mem_wen=1 so it DOES have extras.
    # The fadd.d row (cycle 20) has rd_wen=0, rd=0, fp_wen=1 → has extras.
    # The addi row (cycle 10) has rd_wen=1, rd=10 → has extras (x10 = ...).
    # Check diff_a.csv: the add row (rd=12) always has an extra.
    # Use the plain diff_a.csv where the first two rows write x10/x11/x12;
    # there is no row without extras there either. Instead, create a one-row
    # check: rd=0, all other flags 0. That is the header row in diff_a_rich.csv
    # — i.e. the addi at cycle 10 writes x10, so it DOES have an extra.
    # The cleanest check: look for a line that has NO "  " suffix (extras block).
    # Actually, verify via diff_a.csv using add row rd_wen=1,rd=12 — always has extra.
    # The requested scenario is "rd=0, no extras" — craft a dedicated one-line CSV.
    import tempfile, textwrap
    content = textwrap.dedent("""\
        cycle,pc,instr,mnemonic,rd_wen,rd,rd_wdata,fp_wen,fp_rd,fp_wdata,csr_wen,csr_addr,csr_wdata,mem_wen,mem_addr,mem_wdata,mem_funct3,trap_taken,trap_cause
        5,0000000000000010,00000013,nop,1,0,0000000000000000,0,0,0000000000000000,0,000,0000000000000000,0,0000000000000000,0000000000000000,0,0,0
    """)
    with tempfile.NamedTemporaryFile(mode="w", suffix=".csv", delete=False) as t:
        t.write(content)
        t.flush()
        res2 = run(os.path.join(TOOLS_DIR, "trace_to_text.py"), t.name)
    assert res2.returncode == 0
    line = res2.stdout.strip()
    # Only one non-empty line, no extras appended after the mnemonic
    assert "nop" in line
    assert "x0" not in line   # x0 write should be suppressed
    assert "csr" not in line
    assert "mem" not in line
    assert "trap" not in line


def test_diff_retire_format_error(tmp_path):
    """Passing a non-existent file path triggers exit code 2 with 'error:' on stderr."""
    missing = str(tmp_path / "nonexistent.csv")
    a = os.path.join(FIX, "diff_a.csv")
    res = run(os.path.join(TOOLS_DIR, "diff_retire.py"), a, missing)
    assert res.returncode == 2
    assert "error:" in res.stderr


def test_stall_taxonomy_empty():
    """Header-only stalls CSV exits 0 and prints just the column header line."""
    res = run(os.path.join(TOOLS_DIR, "stall_taxonomy.py"),
              os.path.join(FIX, "empty_stalls.csv"))
    assert res.returncode == 0
    lines = [l for l in res.stdout.splitlines() if l.strip()]
    # Only the header line should be present
    assert len(lines) == 1
    assert "event" in lines[0]


def test_profile_pc_empty():
    """Header-only profile CSV exits 0 and prints '(empty profile)'."""
    res = run(os.path.join(TOOLS_DIR, "profile_pc.py"),
              os.path.join(FIX, "empty_profile.csv"))
    assert res.returncode == 0
    assert "(empty profile)" in res.stdout


def test_diff_retire_one_file_shorter():
    """When A has fewer rows than B, script reports DIVERGE at end and exits 1."""
    a = os.path.join(FIX, "diff_a.csv")       # 3 rows
    b = os.path.join(FIX, "diff_a_rich.csv")  # 6 rows, same first row
    res = run(os.path.join(TOOLS_DIR, "diff_retire.py"), a, b)
    assert res.returncode == 1
    assert "DIVERGE" in res.stdout
