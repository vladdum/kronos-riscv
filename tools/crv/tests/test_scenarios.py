"""Sanity tests for every scenario module."""
import pytest

from tools.crv.generator import generate_program


SCENARIOS = [
    "int_hazards", "muldiv_interleave", "mem_ordering",
    "fp_arith", "fdiv_fsqrt", "branch_pred", "traps",
]


@pytest.mark.parametrize("scenario", SCENARIOS)
def test_scenario_emits_well_formed_asm(tmp_path, scenario):
    out = tmp_path / f"{scenario}.S"
    generate_program(scenario=scenario, seed=0, length=100, out=out)
    text = out.read_text()
    assert ".global main" in text
    assert "main:" in text
    assert "ret" in text


@pytest.mark.parametrize("scenario", SCENARIOS)
def test_scenario_deterministic(tmp_path, scenario):
    out1 = tmp_path / "a.S"
    out2 = tmp_path / "b.S"
    generate_program(scenario=scenario, seed=42, length=100, out=out1)
    generate_program(scenario=scenario, seed=42, length=100, out=out2)
    assert out1.read_text() == out2.read_text()
