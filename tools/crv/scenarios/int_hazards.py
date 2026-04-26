"""Scenario: int_hazards.

Heavy register-dependency chains.  Hits EX/MEM/WB forwarding paths,
load-use stall, WB→ID bypass.

Constraints:
  - 70% of body instructions read a register written by one of the
    previous 4 instructions.
  - Mix of ALU (60%) and memory (40%; loads from DATA region with
    pre-computed addresses).
  - No FP, no atomics, no muldiv, no branches in this scenario.
"""
from __future__ import annotations
from typing import List
import random

from ..encoding import (
    Reg, AsmInstr,
    add, sub, sll, srl, sra, addi, slli, srli, srai,
    lw, ld, sw, sd, lui,
)
from ..regfile import GPState, FPState
from ..memory import DATA, DATA_BASE


_ALU_R = [add, sub, sll, srl, sra]
_ALU_I = [addi, slli, srli, srai]

# Registers that must not be overwritten by the scenario body:
#   x0  = hardwired zero
#   x1  = ra (return address saved on stack by prologue)
#   x2  = sp (stack pointer — prologue saves/restores frame)
#   x10 = a0 (data pointer set up by _setup_data_pointer; also return value)
_RESERVED = frozenset({Reg.X0, Reg.X1, Reg.X2, Reg.X10})

_WRITABLE = [r for r in Reg if r not in _RESERVED]


def _random_writable(rng: random.Random) -> Reg:
    return rng.choice(_WRITABLE)


def _pick_dependent_source(rng: random.Random, recent_writes: list[Reg],
                           gp: GPState) -> Reg:
    """Pick a register that's both live AND was written in the last 4
    instructions.  Falls back to a generic live reg if no recent writes."""
    candidates = [r for r in recent_writes[-4:] if gp.is_live(r) and r != Reg.X0]
    if candidates:
        return rng.choice(candidates)
    return gp.random_live(rng)


def _emit_alu_r(rng, gp, dependent: bool, recent_writes) -> AsmInstr:
    op = rng.choice(_ALU_R)
    rd = _random_writable(rng)
    if dependent:
        rs1 = _pick_dependent_source(rng, recent_writes, gp)
    else:
        rs1 = gp.random_live(rng)
    rs2 = gp.random_live(rng)
    gp.write(rd)
    return op(rd, rs1, rs2)


def _emit_alu_i(rng, gp, dependent: bool, recent_writes) -> AsmInstr:
    op = rng.choice(_ALU_I)
    rd = _random_writable(rng)
    if dependent:
        rs1 = _pick_dependent_source(rng, recent_writes, gp)
    else:
        rs1 = gp.random_live(rng)
    if op in (slli, srli, srai):
        imm = rng.randint(0, 63)
    else:
        imm = rng.randint(-2048, 2047)
    gp.write(rd)
    return op(rd, rs1, imm)


def _setup_data_pointer(gp: GPState) -> tuple[list[AsmInstr], Reg]:
    """Emit a 2-instruction sequence to set up x10 as a pointer to DATA_BASE.

    Note: DATA_BASE has bit 11 = 0 (0x80004000), so no upper-bias is needed,
    but we use the general bias logic in case DATA_BASE changes later.
    """
    base = Reg.X10
    upper = (DATA_BASE >> 12) & 0xFFFFF
    lower = DATA_BASE & 0xFFF
    if lower & 0x800:
        upper = (upper + 1) & 0xFFFFF
        lower = lower - 0x1000
    seq = [lui(base, upper), addi(base, base, lower)]
    gp.write(base)
    return seq, base


_MAX_MEM_OFFSET = (min(DATA.size, 2048) // 8 - 1) * 8  # must fit in signed 12-bit


def _emit_mem(rng, gp, ptr_reg: Reg, dependent: bool,
              recent_writes) -> AsmInstr:
    op_choice = rng.choice(["lw", "ld", "sw", "sd"])
    offset = rng.randint(0, _MAX_MEM_OFFSET // 8) * 8
    if op_choice == "lw":
        rd = _random_writable(rng)
        gp.write(rd)
        return lw(rd, ptr_reg, offset)
    if op_choice == "ld":
        rd = _random_writable(rng)
        gp.write(rd)
        return ld(rd, ptr_reg, offset)
    if op_choice == "sw":
        if dependent:
            rs2 = _pick_dependent_source(rng, recent_writes, gp)
        else:
            rs2 = gp.random_live(rng)
        return sw(rs2, ptr_reg, offset)
    # sd
    if dependent:
        rs2 = _pick_dependent_source(rng, recent_writes, gp)
    else:
        rs2 = gp.random_live(rng)
    return sd(rs2, ptr_reg, offset)


def generate(rng: random.Random, gp: GPState, fp: FPState,
             length: int) -> List[AsmInstr]:
    out: List[AsmInstr] = []
    setup, ptr = _setup_data_pointer(gp)
    out.extend(setup)

    recent_writes: list[Reg] = []
    while len(out) < length + len(setup):
        dependent = rng.random() < 0.70
        kind = rng.choices(
            ["alu_r", "alu_i", "mem"],
            weights=[35, 25, 40], k=1,
        )[0]
        if kind == "alu_r":
            instr = _emit_alu_r(rng, gp, dependent, recent_writes)
        elif kind == "alu_i":
            instr = _emit_alu_i(rng, gp, dependent, recent_writes)
        else:
            instr = _emit_mem(rng, gp, ptr, dependent, recent_writes)
        out.append(instr)
        if instr.mnemonic in ("add", "sub", "sll", "srl", "sra",
                              "addi", "slli", "srli", "srai",
                              "lw", "ld"):
            rd_str = instr.operands[0]
            rd_idx = int(rd_str[1:])
            recent_writes.append(Reg(rd_idx))
            recent_writes = recent_writes[-8:]

    return out
