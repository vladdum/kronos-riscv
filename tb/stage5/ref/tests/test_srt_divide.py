import pytest
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from srt_divide import srt_divide

# ---------------------------------------------------------------------------
# Format: (a, b, n, expected_q, expected_sticky)
#
# a, b  : 53-bit significands with explicit leading 1 at bit 52
# n     : number of output bits (1 integer bit + n-1 fractional bits)
# expected_q : n-bit raw quotient; bit (n-1) is the integer part
# expected_sticky : True iff the final partial remainder is non-zero
# ---------------------------------------------------------------------------

KNOWN_VECTORS = [
    # 1.0 / 1.0 = 1.0  =>  Q = 1.00...0  (bit 54 set, rest 0)
    (1 << 52, 1 << 52, 55, 1 << 54, False),

    # 3.0 / 2.0 = 1.5  =>  Q = 1.10...0  (bits 54 and 53 set)
    ((1 << 52) | (1 << 51), 1 << 52, 55, (1 << 54) | (1 << 53), False),

    # 1.0 / 1.75 = 4/7 ≈ 0.5714...  =>  Q = 0.100100...  (repeating, sticky=True)
    # expected computed via floor(2^56 / 7) = 0x0024924924924924
    (1 << 52, (1 << 52) | (1 << 51) | (1 << 50), 55, 0x0024924924924924, True),

    # n=26 (single-precision mode), 1.0 / 1.0 = 1.0  =>  Q = 1.00...0 (bit 25 set)
    (1 << 52, 1 << 52, 26, 1 << 25, False),

    # n=26, 3.0 / 2.0 = 1.5  =>  Q = 1.10...0 (bits 25 and 24 set)
    ((1 << 52) | (1 << 51), 1 << 52, 26, (1 << 25) | (1 << 24), False),

    # Edge: A very close to 2*B  =>  quotient ≈ 2.0 - ulp
    # a = 2^53 - 1  (just under 2.0 * 2^52), b = 2^52
    # floor((2^53-1)/2^52 * 2^54) = 2^55 - 4 = 0x7ffffffffffffc (55 bits)
    ((2 << 52) - 1, 1 << 52, 55, 0x7ffffffffffffc, False),
]


@pytest.mark.parametrize("a,b,n,q,s", KNOWN_VECTORS)
def test_srt_divide_known(a, b, n, q, s):
    got_q, got_s = srt_divide(a, b, n)
    assert got_q == q, f"quotient mismatch: {got_q:#018x} vs {q:#018x}"
    assert got_s == s, f"sticky mismatch: {got_s} vs {s}"
