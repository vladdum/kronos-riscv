"""Memory layout used by generated tests.

Generators emit loads/stores with pre-computed offsets; we never randomise
addresses at runtime (the generator already constrains them to land in
the data or atomic region).
"""
from __future__ import annotations
from dataclasses import dataclass


CODE_BASE   = 0x00000000
CODE_SIZE   = 64 * 1024    # matches ROM region in link.ld (0x0–0xFFFF)

DATA_BASE   = 0x00014000   # within RAM (0x10000–0x1FFFF); clear of code + stack
DATA_SIZE   = 4 * 1024

ATOMIC_BASE = 0x00016000   # immediately after DATA region
ATOMIC_SIZE = 4 * 1024

HALT_ADDR   = 0x40000000


@dataclass(frozen=True)
class MemRange:
    base: int
    size: int

    def random_aligned(self, rng, alignment: int) -> int:
        max_off = (self.size // alignment) - 1
        return self.base + rng.randint(0, max_off) * alignment


DATA   = MemRange(DATA_BASE,   DATA_SIZE)
ATOMIC = MemRange(ATOMIC_BASE, ATOMIC_SIZE)
