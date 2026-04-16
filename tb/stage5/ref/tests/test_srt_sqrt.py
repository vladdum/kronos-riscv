import pytest
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from srt_sqrt import srt_sqrt

# ---------------------------------------------------------------------------
# Format: (a, n, expected_q, expected_sticky)
#
# a     : 54-bit significand with explicit leading 1.
#           Even exponent (a in [1<<52, 1<<53)): value in [1.0, 2.0).
#           Odd exponent  (a in [1<<53, 1<<54)): value in [2.0, 4.0).
# n     : number of output bits (bit n-1 = integer 1, bits n-2..0 = fractional).
# expected_q : n-bit raw root; bit n-1 is always 1 (result in [1.0, 2.0)).
# expected_sticky : True iff the final partial remainder is non-zero.
# ---------------------------------------------------------------------------

KNOWN_VECTORS = [
    # sqrt(1.0) = 1.0 exactly.
    # a=1<<52 (even exponent, value 1.0), Q = 1.00..0 (only bit 54 set).
    (0x0010000000000000, 55, 0x0040000000000000, False),

    # sqrt(2.0): a=1<<53 (odd exponent, value 2.0). sqrt(2) is irrational.
    (0x0020000000000000, 55, 0x005a827999fcef32, True),

    # sqrt(2.25) = sqrt(9/4) = 3/2 = 1.5 exactly.
    # a = 9*(1<<50) = 0x24000000000000 (value 2.25), Q = 1.10..0 (bits 54 and 53 set).
    (0x0024000000000000, 55, 0x0060000000000000, False),

    # sqrt(4 - ulp): a just below 2^54 (value just below 4.0). Result just below 2.0.
    (0x003fffffffffffff, 55, 0x007ffffffffffffe, True),

    # n=26 (single-precision mode): sqrt(1.0) = 1.0.
    # Q = 1.00..0 (bit 25 set).
    (0x0010000000000000, 26, 0x0000000002000000, False),

    # n=26, sqrt(2.0): irrational.
    (0x0020000000000000, 26, 0x0000000002d413cc, True),
]


@pytest.mark.parametrize("a,n,q,s", KNOWN_VECTORS)
def test_srt_sqrt_known(a, n, q, s):
    got_q, got_s = srt_sqrt(a, n)
    assert got_q == q, f"root mismatch: {got_q:#018x} vs {q:#018x}"
    assert got_s == s, f"sticky mismatch: {got_s} vs {s}"
