import subprocess
from pathlib import Path

DIFF = Path(__file__).parent.parent / "trace_diff.py"


def run_diff(a_text: str, b_text: str, tmp_path: Path):
    a = tmp_path / "a.trace"; a.write_text(a_text)
    b = tmp_path / "b.trace"; b.write_text(b_text)
    r = subprocess.run(
        ["python3", str(DIFF), str(a), str(b)],
        capture_output=True, text=True,
    )
    return r.returncode, r.stdout, r.stderr


def test_identical_traces_pass(tmp_path):
    t = "0000000080000000:00000013 x0=0000000000000000\n"
    rc, _, _ = run_diff(t, t, tmp_path)
    assert rc == 0


def test_first_mismatch_reported(tmp_path):
    a = (
        "0000000080000000:00000013\n"
        "0000000080000004:00100093 x1=0000000000000001\n"
    )
    b = (
        "0000000080000000:00000013\n"
        "0000000080000004:00100093 x1=0000000000000002\n"
    )
    rc, out, _ = run_diff(a, b, tmp_path)
    assert rc != 0
    assert "line 2" in out
    assert "x1=0000000000000001" in out
    assert "x1=0000000000000002" in out


def test_halt_region_store_stripped(tmp_path):
    # Store to 0x40000000 (halt sentinel) must be ignored.
    a = (
        "0000000080000000:00000013\n"
        "0000000080000004:00100023 mem[0000000040000000]=0000000000000000\n"
    )
    b = "0000000080000000:00000013\n"
    rc, _, _ = run_diff(a, b, tmp_path)
    assert rc == 0


def test_act4_signature_region_stripped(tmp_path):
    # Signature region defaults to 0x8000_0000_0000_2000..0x8000_0000_0000_4000.
    # Only stores in that range are stripped.
    sig_addr = 0x0000000080002000
    a = (
        "0000000080000000:00000013\n"
        f"0000000080000004:00100023 mem[{sig_addr:016x}]=0000000000000042\n"
    )
    b = "0000000080000000:00000013\n"
    rc, _, _ = run_diff(
        a, b, tmp_path,
    )
    assert rc == 0


def test_length_mismatch_reported(tmp_path):
    a = "0000000080000000:00000013\n0000000080000004:00000013\n"
    b = "0000000080000000:00000013\n"
    rc, out, _ = run_diff(a, b, tmp_path)
    assert rc != 0
    assert "length" in out.lower()
