# Copyright 2026 Vlad-Dumitru Popescu
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

"""Pure-Python reference for radix-2 SRT non-restoring divide.

Input: integer significands A and B, each with bit 52 set (explicit leading 1).
       A must be < 2*B (result < 2, standard FP precondition).
Output: (Q, sticky) where Q is an n-bit raw quotient laid out as:
          bit (n-1): integer part  (1 if quotient >= 1.0, 0 otherwise)
          bits (n-2)..0: fractional part
        For n=56 (double precision), Q has 1 integer bit + 55 fractional bits
        (52 mantissa bits + guard + round + extra), and sticky is True if the
        final partial remainder is non-zero.
"""


def srt_divide(a: int, b: int, n: int = 56) -> tuple:
    assert 0 < a < (2 << 52) and 0 < b < (2 << 52), "operands out of range"
    assert a < 2 * b, "precondition: A < 2B"

    p = a
    q = 0

    # Integer bit: quotient is in [0, 2) so the leading bit tells if >= 1.
    if p >= b:
        q = 1
        p = p - b
    else:
        q = 0

    # n-1 fractional bits via restoring binary long division.
    for _ in range(n - 1):
        p <<= 1
        if p >= b:
            q = (q << 1) | 1
            p -= b
        else:
            q = (q << 1)

    return q, p != 0
