"""Unit tests for tools/crv/regfile.py + memory.py."""
import random
import pytest
from tools.crv.encoding import Reg, FReg
from tools.crv.regfile import GPState, FPState
from tools.crv.memory import DATA, ATOMIC, DATA_BASE, DATA_SIZE


def test_gpstate_initial_live():
    gp = GPState()
    assert gp.is_live(Reg.X0)
    assert gp.is_live(Reg.X2)
    assert not gp.is_live(Reg.X5)


def test_gpstate_write_marks_live():
    gp = GPState()
    gp.write(Reg.X5)
    assert gp.is_live(Reg.X5)


def test_gpstate_x0_write_does_not_change_state():
    gp = GPState()
    gp.write(Reg.X0)
    assert gp.is_live(Reg.X0)


def test_gpstate_random_live_deterministic():
    rng = random.Random(0)
    gp = GPState()
    gp.write(Reg.X5)
    gp.write(Reg.X10)
    picks = [gp.random_live(rng) for _ in range(20)]
    assert all(gp.is_live(r) for r in picks)


def test_fpstate_all_live_initially():
    fp = FPState()
    for r in FReg:
        assert r in fp.live


def test_data_range_aligned_addresses():
    rng = random.Random(0)
    for _ in range(50):
        addr = DATA.random_aligned(rng, 4)
        assert DATA_BASE <= addr < DATA_BASE + DATA_SIZE
        assert addr % 4 == 0


def test_atomic_range_in_atomic_region():
    rng = random.Random(0)
    for _ in range(50):
        addr = ATOMIC.random_aligned(rng, 4)
        assert 0x00016000 <= addr < 0x00017000
