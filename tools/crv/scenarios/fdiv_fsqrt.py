"""Scenario: fdiv_fsqrt.

Exercises the iterative FDIV/FSQRT units and their interaction with the
pipelined FP units competing for writeback slots.

Constraints:
  - 50% iterative FP (FDIV.S, FDIV.D, FSQRT.S, FSQRT.D).
  - 30% pipelined FP (FADD.S, FMUL.S) — contend for writeback slots.
  - 20% integer ALU background filler.
"""
from __future__ import annotations
from typing import List
import random

from ..encoding import (
    Reg, FReg, RoundingMode, AsmInstr,
    add, addi,
    fadd_s, fmul_s,
    fdiv_s, fdiv_d, fsqrt_s, fsqrt_d,
)
from ..regfile import GPState, FPState

_ITERATIVE_OPS_BINARY = [fdiv_s, fdiv_d]
_PIPELINE_OPS = [fadd_s, fmul_s]

# x0  = hardwired zero
# x1  = ra (saved by prologue)
# x2  = sp (stack pointer)
_RESERVED = frozenset({Reg.X0, Reg.X1, Reg.X2})
_WRITABLE = [r for r in Reg if r not in _RESERVED]


def _random_writable(rng: random.Random) -> Reg:
    return rng.choice(_WRITABLE)


def _emit_iterative(rng: random.Random, fp: FPState) -> AsmInstr:
    choice = rng.randint(0, 3)
    rm = RoundingMode.RNE
    rd = fp.random_writable(rng)
    rs1 = fp.random_live(rng)
    fp.write(rd)
    if choice == 0:
        return fdiv_s(rd, rs1, fp.random_live(rng), rm)
    if choice == 1:
        return fdiv_d(rd, rs1, fp.random_live(rng), rm)
    if choice == 2:
        return fsqrt_s(rd, rs1, rm)
    return fsqrt_d(rd, rs1, rm)


def _emit_pipelined(rng: random.Random, fp: FPState) -> AsmInstr:
    op = rng.choice(_PIPELINE_OPS)
    rd = fp.random_writable(rng)
    rs1 = fp.random_live(rng)
    rs2 = fp.random_live(rng)
    fp.write(rd)
    return op(rd, rs1, rs2)


def _emit_alu(rng: random.Random, gp: GPState) -> AsmInstr:
    rd = _random_writable(rng)
    rs1 = gp.random_live(rng)
    if rng.random() < 0.5:
        imm = rng.randint(-2048, 2047)
        gp.write(rd)
        return addi(rd, rs1, imm)
    rs2 = gp.random_live(rng)
    gp.write(rd)
    return add(rd, rs1, rs2)


def generate(rng: random.Random, gp: GPState, fp: FPState,
             length: int) -> List[AsmInstr]:
    out: List[AsmInstr] = []

    while len(out) < length:
        kind = rng.choices(["iterative", "pipelined", "alu"],
                           weights=[50, 30, 20], k=1)[0]
        if kind == "iterative":
            out.append(_emit_iterative(rng, fp))
        elif kind == "pipelined":
            out.append(_emit_pipelined(rng, fp))
        else:
            out.append(_emit_alu(rng, gp))

    return out
