# Copyright 2026 Vlad-Dumitru Popescu
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

"""Generate test vectors for kronos_fpu_fsqrt_core.

Output: fsqrt_vectors.hex  —  one line per test:
    <fmt_d 1b> <a 14hex> <exp_q 14hex> <exp_sticky 1b>

a is a 53/54-bit significand with bit 52 or 53 set.
  Even exponent: a in [1<<52, 1<<53) — bit 52 set, bit 53 clear.
  Odd exponent:  a in [1<<53, 1<<54) — bit 53 set.
exp_q is a 56-bit root for D, 27-bit for S (zero-extended to 56 bits).
"""

import os
import random
import sys

# Resolve the srt_sqrt function from the same directory.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from srt_sqrt import srt_sqrt


def emit(f, fmt_d: int, a: int):
    n = 56 if fmt_d else 27
    q, sticky = srt_sqrt(a, n)
    s = 1 if sticky else 0
    f.write(f"{fmt_d:01b} {a:014x} {q:014x} {s:01b}\n")


def directed_vectors(f):
    """20 directed edge-case vectors."""
    cases = []

    # 1. sqrt(1.0) even exponent: a = 1<<52, both formats
    cases.append((0, 1 << 52))
    cases.append((1, 1 << 52))

    # 2. sqrt(2.0) odd exponent: a = 1<<53, both formats
    cases.append((0, 1 << 53))
    cases.append((1, 1 << 53))

    # 3. Maximum even-exponent significand: a = (1<<53) - 1
    cases.append((0, (1 << 53) - 1))
    cases.append((1, (1 << 53) - 1))

    # 4. Maximum odd-exponent significand: a = (1<<54) - 1
    cases.append((0, (1 << 54) - 1))
    cases.append((1, (1 << 54) - 1))

    # 5. Minimum odd-exponent significand: a = 1<<53
    #    (already covered as sqrt(2.0), add explicit)
    cases.append((1, 1 << 53))

    # 6. Perfect square: a = (1<<52) | (1<<50)  -> 1.25 in binary
    cases.append((0, (1 << 52) | (1 << 50)))
    cases.append((1, (1 << 52) | (1 << 50)))

    # 7. a = (1<<52) + 1  (just above 1.0)
    cases.append((0, (1 << 52) + 1))
    cases.append((1, (1 << 52) + 1))

    # 8. a = (1<<53) - 2  (just below max even-exp)
    cases.append((1, (1 << 53) - 2))

    # 9. a = (1<<53) + 1  (just above min odd-exp)
    cases.append((0, (1 << 53) + 1))
    cases.append((1, (1 << 53) + 1))

    # 10. a with alternating bit pattern (even exp)
    cases.append((1, (1 << 52) | 0xAAAAAAAAAAAAA))

    # 11. a with alternating bit pattern (odd exp)
    cases.append((1, (1 << 53) | 0x5555555555555))

    # 12. Single-precision specific: lower mantissa bits
    cases.append((0, (1 << 52) | (0x7FFFFF << 29)))

    for fmt_d, a in cases:
        emit(f, fmt_d, a)


def random_vectors(f, fmt_d: int, count: int, seed: int):
    """Generate `count` random vectors for the given format."""
    rng = random.Random(seed)
    for _ in range(count):
        # Randomly choose even-exponent (bit 52 set) or odd-exponent (bit 53 set)
        if rng.randint(0, 1) == 0:
            # Even exponent: a in [1<<52, 1<<53)
            a = (1 << 52) | rng.getrandbits(52)
        else:
            # Odd exponent: a in [1<<53, 1<<54)
            a = (1 << 53) | rng.getrandbits(53)
        # Clamp to valid range
        assert (1 << 52) <= a < (1 << 54), f"a={a:#x} out of range"
        emit(f, fmt_d, a)


def main():
    out_path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "fsqrt_vectors.hex")
    with open(out_path, "w") as f:
        directed_vectors(f)
        random_vectors(f, fmt_d=1, count=500, seed=42)
        random_vectors(f, fmt_d=0, count=500, seed=137)
    print(f"Generated {out_path}")


if __name__ == "__main__":
    main()
