"""Scenario: traps.

Exercises M-mode trap handling.  A small trap handler is installed via
mtvec before the body begins; it bumps mepc by 4 and returns via mret.
The body then sprinkles ECALL and EBREAK instructions among ordinary ALU
ops so that the core must enter and exit the trap handler repeatedly.

Constraints:
  - 90% ALU (addi filler, keeps retire rate up between traps).
  - 10% trap-inducers: ECALL or EBREAK (alternating for variety).
  - The trap handler is installed via a standard prologue before the body.
  - No illegal-instruction (.word 0xFFFFFFFF) — mtval handling differs
    between Kronos and Sail for instruction-address-misaligned vs
    illegal-instruction traps; ECALL/EBREAK are safer.
    TODO: revisit .word 0xFFFFFFFF once mtval semantics are pinned.
"""
from __future__ import annotations
from typing import List
import random

from ..encoding import (
    Reg, AsmInstr,
    add, sub, addi, slli, srli,
    ecall, ebreak,
)
from ..regfile import GPState, FPState

_ALU_R = [add, sub]
_ALU_I = [addi, slli, srli]

# x0  = hardwired zero
# x1  = ra (saved by prologue)
# x2  = sp (stack pointer)
# x5  = t0 (used in handler prologue — protect it in scenario body)
# x6  = t1 (used in handler prologue — protect it in scenario body)
_RESERVED = frozenset({Reg.X0, Reg.X1, Reg.X2, Reg.X5, Reg.X6})
_WRITABLE = [r for r in Reg if r not in _RESERVED]


def _random_writable(rng: random.Random) -> Reg:
    return rng.choice(_WRITABLE)


# CSR numbers (from RISC-V privileged spec)
_MTVEC = 0x305
_MEPC  = 0x341


def _trap_handler_prologue() -> List[AsmInstr]:
    """Install a minimal M-mode trap handler.

    On every trap: bump mepc by 4 (so ECALL/EBREAK are not re-executed) and
    return with mret.  Uses t0 (x5) and t1 (x6) as scratch registers.

    Key constraints:
    - `.option norvc` disables compressed instructions for the entire
      scenario.  This guarantees every instruction (including ECALL/EBREAK
      and the handler itself) is exactly 4 bytes, so `mepc+4` is always the
      correct resume PC.
    - The handler label is 4-byte aligned because mtvec.BASE ignores bits[1:0]
      (MODE field).  Without alignment Sail rounds the address down by 2.
    """
    lines = [
        "    .option norvc",          # disable C-ext for this file
        "    la      t0, .Ltrap_handler",
        "    csrw    mtvec, t0",
        "    j       .Lpost_handler",
        "    .align  2",
        ".Ltrap_handler:",
        "    csrr    t1, mepc",
        "    addi    t1, t1, 4",
        "    csrw    mepc, t1",
        "    mret",
        "    .align  2",
        ".Lpost_handler:",
    ]
    return [AsmInstr("", (line,)) for line in lines]


def generate(rng: random.Random, gp: GPState, fp: FPState,
             length: int) -> List[AsmInstr]:
    out: List[AsmInstr] = []

    # Install the trap handler before the body
    prologue = _trap_handler_prologue()
    out.extend(prologue)
    # Mark t0/t1 as written (they are set in the handler)
    gp.write(Reg.X5)
    gp.write(Reg.X6)

    trap_toggle = 0  # alternates between ecall and ebreak
    while len(out) < length + len(prologue):
        if rng.random() < 0.10:
            if trap_toggle % 2 == 0:
                out.append(ecall())
            else:
                out.append(ebreak())
            trap_toggle += 1
        else:
            op = rng.choice(_ALU_R + _ALU_I)
            rd = _random_writable(rng)
            if op in _ALU_R:
                rs1 = gp.random_live(rng)
                rs2 = gp.random_live(rng)
                gp.write(rd)
                out.append(op(rd, rs1, rs2))
            else:
                rs1 = gp.random_live(rng)
                if op in (slli, srli):
                    imm = rng.randint(0, 63)
                else:
                    imm = rng.randint(-2048, 2047)
                gp.write(rd)
                out.append(op(rd, rs1, imm))

    return out
