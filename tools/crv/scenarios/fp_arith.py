"""Scenario: fp_arith.

Exercises the pipelined FP execution units (FADD, FSUB, FMUL, FMADD)
with both single and double precision, rotating through all rounding
modes.  No FDIV/FSQRT — those have their own scenario.

Constraints:
  - 40% FP binary (FADD/FSUB/FMUL — S and D variants).
  - 20% FP ternary (FMADD — S and D variants).
  - 40% integer ALU background filler.
  - Rounding mode rotates through {RNE, RTZ, RDN, RUP, RMM, DYN}.
"""
from __future__ import annotations
from typing import List
import random

from ..encoding import (
    Reg, FReg, RoundingMode, AsmInstr,
    add, sub, addi,
    fadd_s, fadd_d, fsub_s, fsub_d, fmul_s, fmul_d,
    fmadd_s, fmadd_d,
)
from ..regfile import GPState, FPState

_ALU_R = [add, sub]
_FP_BINARY_OPS = [fadd_s, fadd_d, fsub_s, fsub_d, fmul_s, fmul_d]
_FP_TERNARY_OPS = [fmadd_s, fmadd_d]
_RM_CYCLE = [
    RoundingMode.RNE, RoundingMode.RTZ, RoundingMode.RDN,
    RoundingMode.RUP, RoundingMode.RMM, RoundingMode.DYN,
]

# x0  = hardwired zero
# x1  = ra (saved by prologue)
# x2  = sp (stack pointer)
_RESERVED = frozenset({Reg.X0, Reg.X1, Reg.X2})
_WRITABLE = [r for r in Reg if r not in _RESERVED]


def _random_writable(rng: random.Random) -> Reg:
    return rng.choice(_WRITABLE)


def _emit_fp_binary(rng: random.Random, fp: FPState, rm: RoundingMode) -> AsmInstr:
    op = rng.choice(_FP_BINARY_OPS)
    rd = fp.random_writable(rng)
    rs1 = fp.random_live(rng)
    rs2 = fp.random_live(rng)
    fp.write(rd)
    return op(rd, rs1, rs2, rm)


def _emit_fp_ternary(rng: random.Random, fp: FPState, rm: RoundingMode) -> AsmInstr:
    op = rng.choice(_FP_TERNARY_OPS)
    rd = fp.random_writable(rng)
    rs1 = fp.random_live(rng)
    rs2 = fp.random_live(rng)
    rs3 = fp.random_live(rng)
    fp.write(rd)
    return op(rd, rs1, rs2, rs3, rm)


def _emit_alu(rng: random.Random, gp: GPState) -> AsmInstr:
    op = rng.choice(_ALU_R + [addi])
    rd = _random_writable(rng)
    rs1 = gp.random_live(rng)
    if op is addi:
        imm = rng.randint(-2048, 2047)
        gp.write(rd)
        return addi(rd, rs1, imm)
    rs2 = gp.random_live(rng)
    gp.write(rd)
    return op(rd, rs1, rs2)


def generate(rng: random.Random, gp: GPState, fp: FPState,
             length: int) -> List[AsmInstr]:
    out: List[AsmInstr] = []
    rm_idx = 0

    while len(out) < length:
        rm = _RM_CYCLE[rm_idx % len(_RM_CYCLE)]
        kind = rng.choices(["fp_binary", "fp_ternary", "alu"],
                           weights=[40, 20, 40], k=1)[0]
        if kind == "fp_binary":
            out.append(_emit_fp_binary(rng, fp, rm))
            rm_idx += 1
        elif kind == "fp_ternary":
            out.append(_emit_fp_ternary(rng, fp, rm))
            rm_idx += 1
        else:
            out.append(_emit_alu(rng, gp))

    return out
