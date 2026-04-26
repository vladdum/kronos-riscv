"""Scenario: branch_pred.

Exercises the branch predictor.  Mix of predictable (always-not-taken or
always-taken) and chaotic branches surrounded by straight-line ALU to
keep the retire stream dense.

All branches use forward targets only — labels are planted a few
instructions after the branch site, so no backward edges are created
(which would cause infinite loops in the generated test).

Constraints:
  - ~30% branches (BEQ/BNE/BLT/BGE/BLTU/BGEU).
  - ~50% of those branches use x0 vs x0 (predictable: BEQ always-taken,
    BNE/BLT/BLTU always-not-taken).
  - ~50% use live non-zero registers (chaotic outcomes).
  - ~55% straight-line ALU (R-type and I-type mix).
  - ~15% label definition sites (forward only).
  - No memory ops, no FP, no muldiv.
"""
from __future__ import annotations
from typing import List
import random

from ..encoding import (
    Reg, AsmInstr,
    add, sub, sll, srl, sra, addi, slli, srli, srai,
    beq, bne, blt, bge, bltu, bgeu,
)
from ..regfile import GPState, FPState

_ALU_R = [add, sub, sll, srl, sra]
_ALU_I = [addi, slli, srli, srai]
_BRANCH_OPS = [beq, bne, blt, bge, bltu, bgeu]

# x0  = hardwired zero
# x1  = ra (saved by prologue)
# x2  = sp (frame pointer)
_RESERVED = frozenset({Reg.X0, Reg.X1, Reg.X2})
_WRITABLE = [r for r in Reg if r not in _RESERVED]


def _random_writable(rng: random.Random) -> Reg:
    return rng.choice(_WRITABLE)


def _emit_alu_r(rng: random.Random, gp: GPState) -> AsmInstr:
    op = rng.choice(_ALU_R)
    rd = _random_writable(rng)
    rs1 = gp.random_live(rng)
    rs2 = gp.random_live(rng)
    gp.write(rd)
    return op(rd, rs1, rs2)


def _emit_alu_i(rng: random.Random, gp: GPState) -> AsmInstr:
    op = rng.choice(_ALU_I)
    rd = _random_writable(rng)
    rs1 = gp.random_live(rng)
    if op in (slli, srli, srai):
        imm = rng.randint(0, 63)
    else:
        imm = rng.randint(-2048, 2047)
    gp.write(rd)
    return op(rd, rs1, imm)


def generate(rng: random.Random, gp: GPState, fp: FPState,
             length: int) -> List[AsmInstr]:
    """Generate forward-only branch scenario.

    Algorithm:
    1. Build a raw list of instructions, marking branch positions with their
       target label name.
    2. For each branch at position i, schedule its label at position
       i + gap (1–5 instructions ahead).
    3. Walk the list in order: whenever the current position matches a
       scheduled label, emit the label definition first.
    """
    # Step 1: build raw instructions
    raw: list[AsmInstr] = []
    # List of (target_pos, label_name) pairs — list so duplicates are preserved
    branch_schedule: list[tuple[int, str]] = []
    label_idx = 0

    raw.append(addi(Reg.X5, Reg.X0, 42))
    gp.write(Reg.X5)

    while len(raw) < length:
        roll = rng.random()
        if roll < 0.30:
            op = rng.choice(_BRANCH_OPS)
            lname = f".Lbp_{label_idx}"
            label_idx += 1
            gap = rng.randint(1, 5)
            target_pos = len(raw) + gap
            branch_schedule.append((target_pos, lname))
            if rng.random() < 0.5:
                rs1, rs2 = Reg.X0, Reg.X0   # predictable
            else:
                rs1 = gp.random_live(rng)
                rs2 = gp.random_live(rng)
            raw.append(op(rs1, rs2, lname))
        elif roll < 0.70:
            raw.append(_emit_alu_r(rng, gp))
        else:
            raw.append(_emit_alu_i(rng, gp))

    # Step 2: weave labels into the output
    # Multiple branches could schedule a label at the same position — merge.
    # Also handle the case where target_pos > len(raw): plant at the end.
    pos_to_labels: dict[int, list[str]] = {}
    for pos, lname in branch_schedule:
        effective = min(pos, len(raw))
        pos_to_labels.setdefault(effective, []).append(lname)

    out: List[AsmInstr] = []
    for i, instr in enumerate(raw):
        for lname in pos_to_labels.get(i, []):
            out.append(AsmInstr("", (f"{lname}:",)))
        out.append(instr)

    # Plant any labels scheduled past the end of raw
    for lname in pos_to_labels.get(len(raw), []):
        out.append(AsmInstr("", (f"{lname}:",)))

    return out
