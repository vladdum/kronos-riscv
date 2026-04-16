# Copyright 2026 Vlad-Dumitru Popescu
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

"""Pure-Python reference for radix-2 digit-by-digit square root.

Input: 54-bit significand with bit 52 or 53 set (explicit leading 1).
       Even exponent: a in [1<<52, 1<<53), value in [1.0, 2.0).
       Odd exponent:  a in [1<<53, 1<<54), value in [2.0, 4.0).
       Valid range: (1<<52) <= a < (1<<54).
Output: (Q, sticky) where:
  Q: n-bit raw root. Bit n-1 is always 1 (result is in [1.0, 2.0)).
     Bit n-1 is the integer part; bits n-2..0 are fractional.
     For n=56 (double precision), Q has 1 integer bit + 55 fractional bits
     (52 mantissa bits + guard + round + extra), and sticky captures any
     residual.
  sticky: True iff the final partial remainder is non-zero (inexact result).
"""


def srt_sqrt(a: int, n: int = 56) -> tuple:
    assert (1 << 52) <= a < (1 << 54), f"a={a:#x} out of range"

    # Produce n + 26 output bits total. The lowest 26 bits come from the integer
    # part of sqrt(a) (since sqrt(2^52) = 2^26), so Q = q_full >> 26 gives the
    # desired n-bit result in [2^(n-1), 2^n).
    total = n + 26

    # Pad 'a' (54 bits) on the right to fill 2*total bits so that every iteration
    # reads exactly one 2-bit group.
    a_padded = a << (2 * total - 54)

    q = 0  # running root (integer)
    r = 0  # partial remainder

    for i in range(total):
        # Shift in the next pair of bits from the padded input.
        pair = (a_padded >> (2 * (total - 1 - i))) & 3
        r = (r << 2) | pair

        # Trial subtrahend: (2*q + 1) = (q<<1)|1, but using the concatenation form
        # that avoids an explicit multiply: t = (q << 2) | 1.
        t = (q << 2) | 1
        if r >= t:
            r -= t
            q = (q << 1) | 1
        else:
            q = q << 1

    # Strip the 26-bit integer part that mirrors sqrt(2^52) = 2^26.
    Q = q >> 26
    sticky = bool(q & ((1 << 26) - 1)) or (r != 0)
    return Q, sticky
