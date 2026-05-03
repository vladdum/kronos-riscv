"""Scenario: raw_stress.

Targets the issue #82 bug class: back-to-back same-address store→load with
varying byte/half/word/double sizes and minimal pipeline gap.  The pattern
exercises the dcache hit_beat bypass that handles same-cycle write+read
collisions for every supported access width.

Constraints:
  - Back-to-back store immediately followed by load to the same aligned
    address, covering all four widths (byte/half/word/double).
  - Hot 4 KiB data region to maximise cache-line reuse.
  - x10 = base of DATA region, excluded from writable destinations.
"""
from __future__ import annotations
from typing import List
import random

from ..encoding import (
    Reg, AsmInstr,
    addi, lui,
    lb, lh, lw, ld,
    sb, sh, sw, sd,
)
from ..regfile import GPState, FPState
from ..memory import DATA_BASE

# x0  = hardwired zero
# x1  = ra (saved by prologue)
# x2  = sp (stack pointer)
# x10 = DATA pointer
_RESERVED = frozenset({Reg.X0, Reg.X1, Reg.X2, Reg.X10})
_WRITABLE  = [r for r in Reg if r not in _RESERVED]

# (bytes, store_fn, load_fn)
_SIZES = [
    (1, sb, lb),
    (2, sh, lh),
    (4, sw, lw),
    (8, sd, ld),
]

_HOT_REGION = 4096  # bytes — stays within a few cache lines


def _random_writable(rng: random.Random) -> Reg:
    return rng.choice(_WRITABLE)


def generate(rng: random.Random, gp: GPState, fp: FPState,
             length: int) -> List[AsmInstr]:
    out: List[AsmInstr] = []

    # Set up x10 = DATA_BASE.
    upper = (DATA_BASE >> 12) & 0xFFFFF
    lower = DATA_BASE & 0xFFF
    if lower & 0x800:
        upper = (upper + 1) & 0xFFFFF
        lower = lower - 0x1000
    out.append(lui(Reg.X10, upper))
    out.append(addi(Reg.X10, Reg.X10, lower))
    gp.write(Reg.X10)

    while len(out) < length + 2:
        sz_bytes, store_op, load_op = rng.choice(_SIZES)

        # Aligned offset within the hot region.
        max_slots = (_HOT_REGION // sz_bytes) - 1
        off = rng.randint(0, max_slots) * sz_bytes

        # Cap at signed 12-bit range (−2048..2047); offsets here are 0..4088
        # which may exceed 2047 for 8-byte accesses — clamp to stay in range.
        if off > 2040:
            off = off % 2040 // sz_bytes * sz_bytes

        # Pick a register to hold the store value from live GP regs.
        rs2 = gp.random_live(rng)

        # Pick a destination register for the load (any non-reserved reg).
        rd = _random_writable(rng)

        # addi to write a fresh value into rs2 (guards against stale x0 reads).
        val = rng.randint(-2048, 2047)
        rs2 = _random_writable(rng)
        out.append(addi(rs2, Reg.X0, val))
        gp.write(rs2)

        # Back-to-back: store then load at the same address.
        out.append(store_op(rs2, Reg.X10, off))
        out.append(load_op(rd, Reg.X10, off))
        gp.write(rd)

    return out
