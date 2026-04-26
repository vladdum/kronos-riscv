"""Unit tests for tools/crv/generator.py."""
import shutil
import subprocess
from pathlib import Path
import pytest

from tools.crv.generator import generate_program


def test_int_hazards_deterministic(tmp_path):
    out1 = tmp_path / "a.S"
    out2 = tmp_path / "b.S"
    generate_program(scenario="int_hazards", seed=0, length=50, out=out1)
    generate_program(scenario="int_hazards", seed=0, length=50, out=out2)
    assert out1.read_text() == out2.read_text()


def test_int_hazards_different_seeds_differ(tmp_path):
    out1 = tmp_path / "a.S"
    out2 = tmp_path / "b.S"
    generate_program(scenario="int_hazards", seed=0, length=50, out=out1)
    generate_program(scenario="int_hazards", seed=1, length=50, out=out2)
    assert out1.read_text() != out2.read_text()


def test_int_hazards_length_in_range(tmp_path):
    out = tmp_path / "x.S"
    generate_program(scenario="int_hazards", seed=42, length=100, out=out)
    text = out.read_text()
    instrs = [
        line for line in text.splitlines()
        if line.strip()
        and not line.lstrip().startswith("#")
        and not line.lstrip().startswith(".")
        and not line.rstrip().endswith(":")
    ]
    assert 80 <= len(instrs) <= 130


def test_unknown_scenario_raises(tmp_path):
    with pytest.raises(KeyError):
        generate_program(scenario="not_a_real_scenario", seed=0, length=10, out=tmp_path / "x.S")


@pytest.mark.skipif(
    shutil.which("riscv64-unknown-elf-gcc") is None,
    reason="riscv64-unknown-elf-gcc not on PATH",
)
def test_int_hazards_compiles(tmp_path):
    """The emitted .S must compile with riscv64-unknown-elf-gcc."""
    out = tmp_path / "x.S"
    generate_program(scenario="int_hazards", seed=0, length=50, out=out)
    elf = tmp_path / "x.elf"
    common_s = Path("sw/stage0/common.S").resolve()
    link_ld  = Path("sw/stage0/link.ld").resolve()
    result = subprocess.run([
        "riscv64-unknown-elf-gcc",
        "-march=rv64imafdc_zicsr", "-mabi=lp64",
        "-nostdlib", "-static", f"-T{link_ld}",
        str(out), str(common_s),
        "-o", str(elf),
    ], capture_output=True, text=True)
    assert result.returncode == 0, f"gcc failed: {result.stderr}"
    assert elf.exists()
