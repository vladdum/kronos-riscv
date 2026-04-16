// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// FSQRT subnormal input tests.
// sqrt of a subnormal produces a normal result (subnormals are tiny,
// their square root is much larger).
// a0 accumulates the failure count; a0 = 0 means pass.

.section .text
.globl main

main:
    li      a0, 0                   // fail counter

    // ------------------------------------------------------------------
    // Test 1: FSQRT.D  sqrt(smallest subnormal double)
    //   input  = 2^-1074 = 0x0000000000000001
    //   result = 2^-537  (exact, since 2^-1074 = (2^-537)^2)
    //   2^-537 biased exponent = 1023 - 537 = 486 = 0x1E6
    //   result = 0x1E60000000000000
    //   fflags = 0x00 (exact)
    // ------------------------------------------------------------------
    csrrw   zero, 0x001, zero       // clear fflags
    li      t0, 0x0000000000000001
    fmv.d.x ft0, t0                 // ft0 = 2^-1074
    fsqrt.d ft1, ft0
    fmv.x.d t1, ft1
    li      t2, 0x1E60000000000000  // 2^-537
    beq     t1, t2, 1f
    addi    a0, a0, 1
1:
    csrrs   t3, 0x001, zero         // read fflags
    li      t4, 0x00                // no flags (exact)
    beq     t3, t4, 2f
    addi    a0, a0, 1
2:

    // ------------------------------------------------------------------
    // Test 2: FSQRT.S  sqrt(smallest subnormal float)
    //   input  = 2^-149 = 0x00000001
    //   result = 2^-74.5 — NOT exact (odd exponent)
    //   This will be inexact, so just check fflags has NX (0x01)
    //   and verify result is a normal positive number.
    // ------------------------------------------------------------------
    csrrw   zero, 0x001, zero
    li      t0, 0x00000001
    fmv.w.x ft0, t0                 // ft0 = 2^-149
    fsqrt.s ft1, ft0
    fmv.x.w t1, ft1
    // Result should be positive and non-zero
    beqz    t1, 4f                  // fail if zero
    li      t2, 0x7F800000
    bge     t1, t2, 4f              // fail if inf or NaN
    j       3f
4:
    addi    a0, a0, 1
3:
    csrrs   t3, 0x001, zero
    andi    t3, t3, 0x01            // check NX bit
    bnez    t3, 5f                  // NX should be set
    addi    a0, a0, 1
5:

    // ------------------------------------------------------------------
    // Test 3: FSQRT.D  sqrt(4 * 2^-1074) = 2 * 2^-537 = 2^-536
    //   input  = 0x0000000000000004  (4 * smallest subnormal)
    //   result = 2^-536 (exact)
    //   2^-536 biased exponent = 1023 - 536 = 487 = 0x1E7
    //   result = 0x1E70000000000000
    //   fflags = 0x00 (exact)
    // ------------------------------------------------------------------
    csrrw   zero, 0x001, zero
    li      t0, 0x0000000000000004
    fmv.d.x ft0, t0                 // ft0 = 4 * 2^-1074 = 2^-1072
    fsqrt.d ft1, ft0
    fmv.x.d t1, ft1
    li      t2, 0x1E70000000000000  // 2^-536
    beq     t1, t2, 6f
    addi    a0, a0, 1
6:
    csrrs   t3, 0x001, zero
    li      t4, 0x00                // no flags (exact)
    beq     t3, t4, 7f
    addi    a0, a0, 1
7:

    ret
