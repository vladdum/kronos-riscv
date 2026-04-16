// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// FSQRT rounding-mode tests using static rounding-mode instruction fields.
// Tests sqrt(2.0d) and sqrt(2.0f) under all five IEEE 754 rounding modes.
// a0 accumulates the failure count; a0 = 0 means pass.

.section .text
.globl main

main:
    li      a0, 0                   // fail counter

    // Load double operand: 2.0d
    li      t0, 0x4000000000000000
    fmv.d.x ft0, t0                 // ft0 = 2.0d

    // ------------------------------------------------------------------
    // Test 1: FSQRT.D  sqrt(2.0d), RNE
    //   Expected: 0x3FF6A09E667F3BCD
    // ------------------------------------------------------------------
    fsqrt.d ft1, ft0, rne
    fmv.x.d t1, ft1
    li      t2, 0x3FF6A09E667F3BCD
    beq     t1, t2, 1f
    addi    a0, a0, 1
1:

    // ------------------------------------------------------------------
    // Test 2: FSQRT.D  sqrt(2.0d), RTZ
    //   Expected: 0x3FF6A09E667F3BCC
    // ------------------------------------------------------------------
    fsqrt.d ft1, ft0, rtz
    fmv.x.d t1, ft1
    li      t2, 0x3FF6A09E667F3BCC
    beq     t1, t2, 2f
    addi    a0, a0, 1
2:

    // ------------------------------------------------------------------
    // Test 3: FSQRT.D  sqrt(2.0d), RDN
    //   Expected: 0x3FF6A09E667F3BCC
    // ------------------------------------------------------------------
    fsqrt.d ft1, ft0, rdn
    fmv.x.d t1, ft1
    li      t2, 0x3FF6A09E667F3BCC
    beq     t1, t2, 3f
    addi    a0, a0, 1
3:

    // ------------------------------------------------------------------
    // Test 4: FSQRT.D  sqrt(2.0d), RUP
    //   Expected: 0x3FF6A09E667F3BCD
    // ------------------------------------------------------------------
    fsqrt.d ft1, ft0, rup
    fmv.x.d t1, ft1
    li      t2, 0x3FF6A09E667F3BCD
    beq     t1, t2, 4f
    addi    a0, a0, 1
4:

    // ------------------------------------------------------------------
    // Test 5: FSQRT.D  sqrt(2.0d), RMM
    //   Expected: 0x3FF6A09E667F3BCD
    // ------------------------------------------------------------------
    fsqrt.d ft1, ft0, rmm
    fmv.x.d t1, ft1
    li      t2, 0x3FF6A09E667F3BCD
    beq     t1, t2, 5f
    addi    a0, a0, 1
5:

    // Load single operand: 2.0f
    li      t0, 0x40000000
    fmv.w.x ft0, t0                 // ft0 = 2.0f

    // ------------------------------------------------------------------
    // Test 6: FSQRT.S  sqrt(2.0f), RNE
    //   Expected: 0x3FB504F3
    // ------------------------------------------------------------------
    fsqrt.s ft1, ft0, rne
    fmv.x.w t1, ft1
    li      t2, 0x3FB504F3
    beq     t1, t2, 6f
    addi    a0, a0, 1
6:

    // ------------------------------------------------------------------
    // Test 7: FSQRT.S  sqrt(2.0f), RTZ
    //   Expected: 0x3FB504F3
    // ------------------------------------------------------------------
    fsqrt.s ft1, ft0, rtz
    fmv.x.w t1, ft1
    li      t2, 0x3FB504F3
    beq     t1, t2, 7f
    addi    a0, a0, 1
7:

    // ------------------------------------------------------------------
    // Test 8: FSQRT.S  sqrt(2.0f), RDN
    //   Expected: 0x3FB504F3
    // ------------------------------------------------------------------
    fsqrt.s ft1, ft0, rdn
    fmv.x.w t1, ft1
    li      t2, 0x3FB504F3
    beq     t1, t2, 8f
    addi    a0, a0, 1
8:

    // ------------------------------------------------------------------
    // Test 9: FSQRT.S  sqrt(2.0f), RUP
    //   Expected: 0x3FB504F4
    // ------------------------------------------------------------------
    fsqrt.s ft1, ft0, rup
    fmv.x.w t1, ft1
    li      t2, 0x3FB504F4
    beq     t1, t2, 9f
    addi    a0, a0, 1
9:

    // ------------------------------------------------------------------
    // Test 10: FSQRT.S  sqrt(2.0f), RMM
    //   Expected: 0x3FB504F3
    // ------------------------------------------------------------------
    fsqrt.s ft1, ft0, rmm
    fmv.x.w t1, ft1
    li      t2, 0x3FB504F3
    beq     t1, t2, 10f
    addi    a0, a0, 1
10:

    ret
