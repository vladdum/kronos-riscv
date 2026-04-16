// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// FDIV rounding-mode tests using static rounding-mode instruction fields.
// Tests 1.0d/3.0d and 1.0f/3.0f under all five IEEE 754 rounding modes.
// a0 accumulates the failure count; a0 = 0 means pass.

.section .text
.globl main

main:
    li      a0, 0                   // fail counter

    // Load double operands: 1.0d / 3.0d
    li      t0, 0x3FF0000000000000
    fmv.d.x ft0, t0                 // ft0 = 1.0d
    li      t0, 0x4008000000000000
    fmv.d.x ft1, t0                 // ft1 = 3.0d

    // ------------------------------------------------------------------
    // Test 1: FDIV.D  1.0d / 3.0d, RNE
    //   Expected: 0x3FD5555555555555
    // ------------------------------------------------------------------
    fdiv.d  ft2, ft0, ft1, rne
    fmv.x.d t1, ft2
    li      t2, 0x3FD5555555555555
    beq     t1, t2, 1f
    addi    a0, a0, 1
1:

    // ------------------------------------------------------------------
    // Test 2: FDIV.D  1.0d / 3.0d, RTZ
    //   Expected: 0x3FD5555555555555
    // ------------------------------------------------------------------
    fdiv.d  ft2, ft0, ft1, rtz
    fmv.x.d t1, ft2
    li      t2, 0x3FD5555555555555
    beq     t1, t2, 2f
    addi    a0, a0, 1
2:

    // ------------------------------------------------------------------
    // Test 3: FDIV.D  1.0d / 3.0d, RDN
    //   Expected: 0x3FD5555555555555
    // ------------------------------------------------------------------
    fdiv.d  ft2, ft0, ft1, rdn
    fmv.x.d t1, ft2
    li      t2, 0x3FD5555555555555
    beq     t1, t2, 3f
    addi    a0, a0, 1
3:

    // ------------------------------------------------------------------
    // Test 4: FDIV.D  1.0d / 3.0d, RUP
    //   Expected: 0x3FD5555555555556
    // ------------------------------------------------------------------
    fdiv.d  ft2, ft0, ft1, rup
    fmv.x.d t1, ft2
    li      t2, 0x3FD5555555555556
    beq     t1, t2, 4f
    addi    a0, a0, 1
4:

    // ------------------------------------------------------------------
    // Test 5: FDIV.D  1.0d / 3.0d, RMM
    //   Expected: 0x3FD5555555555555
    // ------------------------------------------------------------------
    fdiv.d  ft2, ft0, ft1, rmm
    fmv.x.d t1, ft2
    li      t2, 0x3FD5555555555555
    beq     t1, t2, 5f
    addi    a0, a0, 1
5:

    // ------------------------------------------------------------------
    // Test 6: FDIV.D  -1.0d / 3.0d, RDN
    //   -1.0d = 0xBFF0000000000000
    //   Expected: 0xBFD5555555555556 (toward -inf rounds away for negative)
    // ------------------------------------------------------------------
    li      t0, 0xBFF0000000000000
    fmv.d.x ft3, t0                 // ft3 = -1.0d
    fdiv.d  ft2, ft3, ft1, rdn
    fmv.x.d t1, ft2
    li      t2, 0xBFD5555555555556
    beq     t1, t2, 6f
    addi    a0, a0, 1
6:

    // ------------------------------------------------------------------
    // Test 7: FDIV.D  -1.0d / 3.0d, RUP
    //   Expected: 0xBFD5555555555555 (toward +inf truncates for negative)
    // ------------------------------------------------------------------
    fdiv.d  ft2, ft3, ft1, rup
    fmv.x.d t1, ft2
    li      t2, 0xBFD5555555555555
    beq     t1, t2, 7f
    addi    a0, a0, 1
7:

    // Load single operands: 1.0f / 3.0f
    li      t0, 0x3F800000
    fmv.w.x ft0, t0                 // ft0 = 1.0f
    li      t0, 0x40400000
    fmv.w.x ft1, t0                 // ft1 = 3.0f

    // ------------------------------------------------------------------
    // Test 8: FDIV.S  1.0f / 3.0f, RNE
    //   Expected: 0x3EAAAAAB (rounds up — guard=1, sticky=1)
    // ------------------------------------------------------------------
    fdiv.s  ft2, ft0, ft1, rne
    fmv.x.w t1, ft2
    li      t2, 0x3EAAAAAB
    beq     t1, t2, 8f
    addi    a0, a0, 1
8:

    // ------------------------------------------------------------------
    // Test 9: FDIV.S  1.0f / 3.0f, RTZ
    //   Expected: 0x3EAAAAAA (truncate)
    // ------------------------------------------------------------------
    fdiv.s  ft2, ft0, ft1, rtz
    fmv.x.w t1, ft2
    li      t2, 0x3EAAAAAA
    beq     t1, t2, 9f
    addi    a0, a0, 1
9:

    ret
