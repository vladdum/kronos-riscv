"""GP/FP register state model used by scenarios to make sane choices.

Tracks which registers have been written (are 'live') and avoids reading
uninitialised registers in critical positions (e.g. addresses).  This is
not a functional simulator — it doesn't compute values — it just tracks
which registers are safe to use as sources.
"""
from __future__ import annotations
from typing import Set
from .encoding import Reg, FReg


_INITIAL_LIVE_GP: Set[Reg] = {Reg.X0, Reg.X2}


class GPState:
    """Tracks live GP registers."""
    def __init__(self) -> None:
        self.live: Set[Reg] = set(_INITIAL_LIVE_GP)

    def write(self, rd: Reg) -> None:
        if rd != Reg.X0:
            self.live.add(rd)

    def is_live(self, r: Reg) -> bool:
        return r in self.live

    def random_live(self, rng) -> Reg:
        return rng.choice(sorted(self.live, key=lambda r: r.value))

    def random_writable(self, rng, exclude_x0: bool = True) -> Reg:
        choices = [r for r in Reg if r != Reg.X0] if exclude_x0 else list(Reg)
        return rng.choice(choices)


class FPState:
    """Tracks live FP registers.  All FP regs start as live."""
    def __init__(self) -> None:
        self.live: Set[FReg] = set(FReg)

    def write(self, rd: FReg) -> None:
        self.live.add(rd)

    def random_live(self, rng) -> FReg:
        return rng.choice(sorted(self.live, key=lambda r: r.value))

    def random_writable(self, rng) -> FReg:
        return rng.choice(list(FReg))
