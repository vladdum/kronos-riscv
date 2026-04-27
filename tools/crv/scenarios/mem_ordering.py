"""Scenario: mem_ordering.

Exercises memory ordering with aligned loads and stores to both a DATA
region and an ATOMIC region.  Focuses on back-to-back and interleaved
address streams that stress the AXI4 data channel and the LSU ordering
logic.

Note: AMO instructions (amoadd.w etc.) are excluded from this Sail-compared
scenario because the Kronos retire trace emits mem[addr]=rs2 (source operand)
while Sail emits mem[addr]=AMO_OP(old,rs2) (computed new value), so traces
would diverge.  AMO coverage is provided by the directed assist_amo.S test
which runs through tb_crv_cov without Sail trace comparison.
LR/SC is also excluded because the Sail sail.json for this config sets
`"reservability": "RsrvNone"`, causing Sail to raise a load-access-fault
on LR.W — a configuration mismatch rather than a CPU bug.

Constraints:
  - 40% DATA-region loads/stores (lw/ld/sw/sd, aligned offsets).
  - 20% ATOMIC-region loads/stores (plain lw/ld/sw/sd — tests the
    D-cache path to that address range without using atomic instructions).
  - 40% integer ALU filler.

Pointer setup:
  - x10 = base of DATA region.
  - x11 = base of ATOMIC region.
  Both are excluded from writable destinations.
"""
from __future__ import annotations
from typing import List
import random

from ..encoding import (
    Reg, AsmInstr,
    add, sub, addi, slli, srli,
    lw, ld, sw, sd, lui,
)
from ..regfile import GPState, FPState
from ..memory import DATA_BASE, ATOMIC_BASE

_ALU_R = [add, sub]
_ALU_I = [addi, slli, srli]

# x0  = hardwired zero
# x1  = ra (saved by prologue)
# x2  = sp (stack pointer)
# x10 = DATA pointer
# x11 = ATOMIC pointer
_RESERVED = frozenset({Reg.X0, Reg.X1, Reg.X2, Reg.X10, Reg.X11})
_WRITABLE = [r for r in Reg if r not in _RESERVED]

_MAX_OFFSET = 2040  # 255 * 8, fits 12-bit signed, stays within 4 KiB region


def _random_writable(rng: random.Random) -> Reg:
    return rng.choice(_WRITABLE)


def _setup_pointers(gp: GPState) -> tuple[list[AsmInstr], Reg, Reg]:
    """Set up x10 → DATA_BASE, x11 → ATOMIC_BASE."""
    instrs: list[AsmInstr] = []

    def _load_addr(reg: Reg, base: int) -> list[AsmInstr]:
        upper = (base >> 12) & 0xFFFFF
        lower = base & 0xFFF
        if lower & 0x800:
            upper = (upper + 1) & 0xFFFFF
            lower = lower - 0x1000
        seq = [lui(reg, upper), addi(reg, reg, lower)]
        gp.write(reg)
        return seq

    instrs.extend(_load_addr(Reg.X10, DATA_BASE))
    instrs.extend(_load_addr(Reg.X11, ATOMIC_BASE))
    return instrs, Reg.X10, Reg.X11


def _emit_mem(rng: random.Random, gp: GPState, ptr: Reg) -> AsmInstr:
    offset = rng.randint(0, _MAX_OFFSET // 8) * 8
    op_choice = rng.choice(["lw", "ld", "sw", "sd"])
    if op_choice == "lw":
        rd = _random_writable(rng)
        gp.write(rd)
        return lw(rd, ptr, offset)
    if op_choice == "ld":
        rd = _random_writable(rng)
        gp.write(rd)
        return ld(rd, ptr, offset)
    if op_choice == "sw":
        rs2 = gp.random_live(rng)
        return sw(rs2, ptr, offset)
    rs2 = gp.random_live(rng)
    return sd(rs2, ptr, offset)


def _emit_alu(rng: random.Random, gp: GPState) -> AsmInstr:
    op = rng.choice(_ALU_R + _ALU_I)
    rd = _random_writable(rng)
    rs1 = gp.random_live(rng)
    if op in _ALU_I:
        if op in (slli, srli):
            imm = rng.randint(0, 63)
        else:
            imm = rng.randint(-2048, 2047)
        gp.write(rd)
        return op(rd, rs1, imm)
    rs2 = gp.random_live(rng)
    gp.write(rd)
    return op(rd, rs1, rs2)


def generate(rng: random.Random, gp: GPState, fp: FPState,
             length: int) -> List[AsmInstr]:
    out: List[AsmInstr] = []
    setup, data_ptr, atomic_ptr = _setup_pointers(gp)
    out.extend(setup)

    consec_mem = 0  # prevent long load chains that stall the AXI pipeline

    while len(out) < length + len(setup):
        if consec_mem >= 3:
            out.append(_emit_alu(rng, gp))
            consec_mem = 0
            continue

        kind = rng.choices(
            ["data_mem", "atomic_mem", "alu"],
            weights=[40, 20, 40], k=1,
        )[0]
        if kind == "data_mem":
            out.append(_emit_mem(rng, gp, data_ptr))
            consec_mem += 1
        elif kind == "atomic_mem":
            out.append(_emit_mem(rng, gp, atomic_ptr))
            consec_mem += 1
        else:
            out.append(_emit_alu(rng, gp))
            consec_mem = 0

    return out
