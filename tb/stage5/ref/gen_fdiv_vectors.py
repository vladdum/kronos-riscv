# Copyright 2026 Vlad-Dumitru Popescu
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

"""Generate test vectors for kronos_fpu_fdiv_core.

Output: fdiv_vectors.hex  —  one line per test:
    <fmt_d 1b> <a 14hex> <b 14hex> <exp_q 14hex> <exp_sticky 1b>

a and b are 53-bit significands (bit 52 = hidden 1).
exp_q is a 56-bit quotient for D, 27-bit for S (zero-extended to 56 bits).
"""

import os
import random
import sys

# Resolve the srt_divide function from the same directory.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from srt_divide import srt_divide


def make_sig(mant_bits: int, val: int) -> int:
    """Build a 53-bit significand: hidden-1 at bit 52, mantissa in lower bits."""
    return (1 << 52) | (val & ((1 << mant_bits) - 1))


def emit(f, fmt_d: int, a: int, b: int):
    n = 56 if fmt_d else 27
    q, sticky = srt_divide(a, b, n)
    s = 1 if sticky else 0
    f.write(f"{fmt_d:01b} {a:014x} {b:014x} {q:014x} {s:01b}\n")


def directed_vectors(f):
    """20 directed edge-case vectors."""
    one = 1 << 52  # 1.0 significand

    cases = []

    # 1. 1.0 / 1.0  (both formats)
    cases.append((0, one, one))
    cases.append((1, one, one))

    # 2. 3.0 / 2.0 = 1.5  — a > b
    #    3.0 sig = 1.1 binary = (1 << 52) | (1 << 51)
    #    2.0 sig = 1.0 binary = (1 << 52)
    a_3 = (1 << 52) | (1 << 51)
    b_2 = 1 << 52
    cases.append((0, a_3, b_2))
    cases.append((1, a_3, b_2))

    # 3. Near 2*B: a = 2*b - 1  (just under the precondition limit)
    b_val = (1 << 52) | (1 << 30)
    a_val = 2 * b_val - 1
    # a must fit in 53 bits — 2*b - 1 for b with bit 52 set is at most
    # 2*(2^53-1)-1 which exceeds 53 bits. Constrain b to keep a < 2^53.
    b_val = (1 << 52) | 1
    a_val = 2 * b_val - 1  # = (1 << 53) | 1 — 54 bits, too big.
    # Instead: a just under 2*b with both in range.
    # Use a = (1 << 53) - 1 (all-ones 53-bit), b = (1 << 52) + 1
    # Check: a < 2*b => (2^53 - 1) < 2*(2^52 + 1) = 2^53 + 2 => yes.
    a_val = (1 << 53) - 1
    b_val = (1 << 52) + 1
    cases.append((0, a_val, b_val))
    cases.append((1, a_val, b_val))

    # 4. Minimum significand: a = b = 1<<52 (already covered as 1.0/1.0)
    #    Minimum a, maximum b that satisfies a < 2*b:
    a_min = 1 << 52
    b_max = (1 << 53) - 1
    cases.append((0, a_min, b_max))
    cases.append((1, a_min, b_max))

    # 5. Maximum a, minimum b that satisfies a < 2*b:
    #    a < 2*b => a_max = 2*b_min - 1 with b_min = 1<<52
    #    a_max = (1<<53) - 1 = all-ones 53-bit
    a_max = (1 << 53) - 1
    b_min = 1 << 52
    cases.append((0, a_max, b_min))
    cases.append((1, a_max, b_min))

    # 6. a = b + 1 (quotient just above 1.0)
    b6 = (1 << 52) | 0x123456
    a6 = b6 + 1
    cases.append((0, a6, b6))
    cases.append((1, a6, b6))

    # 7. a = b - 1 (quotient just below 1.0)
    b7 = (1 << 52) | 0xABCDEF
    a7 = b7 - 1
    cases.append((0, a7, b7))
    cases.append((1, a7, b7))

    # 8. Single-precision: only lower 23 mantissa bits matter
    a8 = (1 << 52) | (0x7FFFFF << 29)  # max single significand, left-aligned
    b8 = (1 << 52) | (0x400000 << 29)
    cases.append((0, a8, b8))

    # 9. Power-of-two-ish: a = 1.5 * b (exact)
    b9 = (1 << 52)
    a9 = b9 + (b9 >> 1)  # 1.5 * b9 — need a < 2*b => 1.5*b < 2*b, yes
    cases.append((1, a9, b9))

    # 10. Remainder exactly zero (exact division): a = b
    b10 = (1 << 52) | 0xDEADBEEF
    a10 = b10
    cases.append((0, a10, b10))
    cases.append((1, a10, b10))

    # 11. a much smaller than b (quotient close to 0.5)
    a11 = 1 << 52
    b11 = (1 << 53) - 3
    cases.append((1, a11, b11))

    # 12. Both operands all-ones 53-bit
    a12 = (1 << 53) - 1
    b12 = (1 << 53) - 1
    cases.append((0, a12, b12))

    for fmt_d, a, b in cases:
        emit(f, fmt_d, a, b)


def random_vectors(f, fmt_d: int, count: int, seed: int):
    """Generate `count` random vectors for the given format."""
    rng = random.Random(seed)
    for _ in range(count):
        # Both operands have bit 52 set (normalized).
        a = (1 << 52) | rng.getrandbits(52)
        b = (1 << 52) | rng.getrandbits(52)
        # Ensure a < 2*b (standard FP precondition).
        if a >= 2 * b:
            # Swap or clamp: easiest is to set a = a % b + b (keeps a in [b, 2b))
            # or just regenerate. Simple: a = a % b + b won't always have bit 52.
            # Just mask a to be < 2*b.
            a = a % b + b  # a in [b, 2b), but bit 52 may be lost if b is small.
            # Re-set bit 52 — b has bit 52 set so b >= 2^52, a >= b >= 2^52,
            # so bit 52 is already set. Verify:
            assert a & (1 << 52), f"a={a:#x} lost bit 52"
        assert a < 2 * b
        emit(f, fmt_d, a, b)


def main():
    out_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fdiv_vectors.hex")
    with open(out_path, "w") as f:
        directed_vectors(f)
        random_vectors(f, fmt_d=1, count=500, seed=42)
        random_vectors(f, fmt_d=0, count=500, seed=137)
    print(f"Generated {out_path}")


if __name__ == "__main__":
    main()
