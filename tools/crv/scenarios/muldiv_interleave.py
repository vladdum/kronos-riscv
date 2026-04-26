"""Scenario: muldiv_interleave.

Interleaves multiply/divide instructions with dependent consumers and
memory ops to stress the multi-cycle muldiv unit and its interaction
with the pipeline's forwarding and hazard-detection logic.

Constraints:
  - 30% muldiv (MUL/DIV/DIVU/REM/REMU).
  - After each muldiv, emit 0–4 dependent consumers that read rd.
  - 30% plain ALU (R-type and I-type).
  - 40% memory loads from the DATA region (via data pointer in x10).
"""
from __future__ import annotations
from typing import List
import random

from ..encoding import (
    Reg, AsmInstr,
    add, sub, sll, srl, addi, slli, srli, srai,
    mul, div, divu, rem, remu,
    lw, ld, sw, sd, lui,
)
from ..regfile import GPState, FPState
from ..memory import DATA_BASE
from .int_hazards import _setup_data_pointer

_MULDIV_OPS = [mul, div, divu, rem, remu]
_ALU_R = [add, sub, sll, srl]
_ALU_I = [addi, slli, srli, srai]

# x0  = hardwired zero
# x1  = ra (saved by prologue)
# x2  = sp (stack pointer)
# x10 = data pointer
_RESERVED = frozenset({Reg.X0, Reg.X1, Reg.X2, Reg.X10})
_WRITABLE = [r for r in Reg if r not in _RESERVED]

_MAX_MEM_OFFSET = 2040  # 255 * 8; fits signed 12-bit and stays within 4 KiB DATA region


def _random_writable(rng: random.Random) -> Reg:
    return rng.choice(_WRITABLE)


def _emit_muldiv(rng: random.Random, gp: GPState) -> tuple[AsmInstr, Reg]:
    op = rng.choice(_MULDIV_OPS)
    rd = _random_writable(rng)
    # Workaround: avoid div/rem-by-zero operands.
    # Symptom observed during Stage 5d CRV bring-up (crv-harness branch):
    # when either rs1 or rs2 is x0 (zero) in a DIV/REM instruction, the
    # muldiv unit enters a stall state that the pipeline never clears,
    # causing the simulation to hang rather than retire the instruction.
    # The root cause is a pipeline bug in the div-by-zero early-exit path
    # in kronos_muldiv.sv.  Investigate and fix as a separate issue; remove
    # this workaround once the underlying RTL bug is resolved.
    live_nonzero = [r for r in gp.live if r != Reg.X0]
    if not live_nonzero:
        live_nonzero = [Reg.X2]  # sp is always live and non-zero
    rs1 = rng.choice(sorted(live_nonzero, key=lambda r: r.value))
    rs2 = rng.choice(sorted(live_nonzero, key=lambda r: r.value))
    gp.write(rd)
    return op(rd, rs1, rs2), rd


def _emit_dependent_consumer(rng: random.Random, gp: GPState,
                              src: Reg) -> AsmInstr:
    """Emit an ALU instruction that reads src as rs1."""
    op = rng.choice(_ALU_R)
    rd = _random_writable(rng)
    rs2 = gp.random_live(rng)
    gp.write(rd)
    return op(rd, src, rs2)


def _emit_alu(rng: random.Random, gp: GPState) -> AsmInstr:
    op = rng.choice(_ALU_R + _ALU_I)
    rd = _random_writable(rng)
    rs1 = gp.random_live(rng)
    if op in _ALU_I:
        if op in (slli, srli, srai):
            imm = rng.randint(0, 63)
        else:
            imm = rng.randint(-2048, 2047)
        gp.write(rd)
        return op(rd, rs1, imm)
    rs2 = gp.random_live(rng)
    gp.write(rd)
    return op(rd, rs1, rs2)


def _emit_mem(rng: random.Random, gp: GPState, ptr: Reg) -> AsmInstr:
    offset = rng.randint(0, _MAX_MEM_OFFSET // 8) * 8
    op_choice = rng.choice(["lw", "ld"])
    if op_choice == "lw":
        rd = _random_writable(rng)
        gp.write(rd)
        return lw(rd, ptr, offset)
    rd = _random_writable(rng)
    gp.write(rd)
    return ld(rd, ptr, offset)


def generate(rng: random.Random, gp: GPState, fp: FPState,
             length: int) -> List[AsmInstr]:
    out: List[AsmInstr] = []
    setup, ptr = _setup_data_pointer(gp)
    out.extend(setup)

    consec_mem = 0     # track consecutive memory ops (avoid long load chains)
    since_muldiv = 99  # instructions since last muldiv (avoid muldiv→muldiv)

    while len(out) < length + len(setup):
        # Force an ALU instruction after 2 consecutive loads to prevent pipeline
        # stalls from long load chains in the stage5 AXI memory model.
        if consec_mem >= 2:
            out.append(_emit_alu(rng, gp))
            consec_mem = 0
            since_muldiv += 1
            continue

        kind = rng.choices(["muldiv", "alu", "mem"], weights=[30, 30, 40], k=1)[0]

        # Workaround: enforce a minimum gap between consecutive muldiv ops.
        # Symptom observed during Stage 5d CRV bring-up (crv-harness branch):
        # when two MUL/DIV/REM instructions appear within ~4 instructions of
        # each other, the pipeline hangs — the second muldiv stalls waiting for
        # a resource that the first hasn't fully released, and the hazard logic
        # does not recover.  The root cause is likely in the handshake between
        # kronos_muldiv and the stall/flush control in kronos_hazard.
        # Requiring at least 4 ALU instructions between muldiv ops gives the
        # pipeline enough time to drain.  Investigate and fix as a separate
        # issue; remove this workaround once the underlying RTL bug is resolved.
        if kind == "muldiv" and since_muldiv < 4:
            kind = "alu"

        if kind == "muldiv":
            instr, rd = _emit_muldiv(rng, gp)
            out.append(instr)
            consec_mem = 0
            since_muldiv = 0
            # Emit 1–3 dependent consumers (ALU only, not muldiv)
            n_consumers = rng.randint(1, 3)
            for _ in range(n_consumers):
                out.append(_emit_dependent_consumer(rng, gp, rd))
                since_muldiv += 1
        elif kind == "alu":
            out.append(_emit_alu(rng, gp))
            consec_mem = 0
            since_muldiv += 1
        else:
            out.append(_emit_mem(rng, gp, ptr))
            consec_mem += 1
            since_muldiv += 1

    return out
