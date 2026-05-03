"""Scenario registry.

Each scenario module exports `generate(rng, gp_state, fp_state, length)
-> List[AsmInstr]`.  Adding a new scenario: drop a module in this
package and register it below.
"""
from importlib import import_module
from typing import Callable, List

from ..encoding import AsmInstr
from ..regfile import GPState, FPState


_SCENARIOS = {
    "int_hazards":        "tools.crv.scenarios.int_hazards",
    "muldiv_interleave":  "tools.crv.scenarios.muldiv_interleave",
    "mem_ordering":       "tools.crv.scenarios.mem_ordering",
    "fp_arith":           "tools.crv.scenarios.fp_arith",
    "fdiv_fsqrt":         "tools.crv.scenarios.fdiv_fsqrt",
    "branch_pred":        "tools.crv.scenarios.branch_pred",
    "traps":              "tools.crv.scenarios.traps",
    "raw_stress":         "tools.crv.scenarios.raw_stress",
}


def all_scenarios() -> list[str]:
    return list(_SCENARIOS.keys())


def get_scenario(name: str) -> Callable[..., List[AsmInstr]]:
    if name not in _SCENARIOS:
        raise KeyError(f"unknown scenario {name!r}; available: {sorted(_SCENARIOS)}")
    mod = import_module(_SCENARIOS[name])
    return mod.generate
