// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Basic FDIV.S, FDIV.D with exact results (no rounding needed).
// a0 accumulates the failure count; a0 = 0 means pass.

.section .text
.globl main

main:
    li      a0, 0                   // fail counter

    // ------------------------------------------------------------------
    // Test 1: FDIV.S  6.0f / 2.0f = 3.0f
    //   6.0f = 0x40C00000
    //   2.0f = 0x40000000
    //   3.0f = 0x40400000
    // ------------------------------------------------------------------
    li      t0, 0x40C00000
    fmv.w.x ft0, t0                 // ft0 = 6.0f
    li      t0, 0x40000000
    fmv.w.x ft1, t0                 // ft1 = 2.0f
    fdiv.s  ft2, ft0, ft1           // ft2 = 3.0f
    fmv.x.w t1, ft2
    li      t2, 0x40400000
    beq     t1, t2, 1f
    addi    a0, a0, 1
1:

    // ------------------------------------------------------------------
    // Test 2: FDIV.S  1.0f / 4.0f = 0.25f
    //   1.0f = 0x3F800000
    //   4.0f = 0x40800000
    //   0.25f = 0x3E800000
    // ------------------------------------------------------------------
    li      t0, 0x3F800000
    fmv.w.x ft0, t0                 // ft0 = 1.0f
    li      t0, 0x40800000
    fmv.w.x ft1, t0                 // ft1 = 4.0f
    fdiv.s  ft2, ft0, ft1           // ft2 = 0.25f
    fmv.x.w t1, ft2
    li      t2, 0x3E800000
    beq     t1, t2, 2f
    addi    a0, a0, 1
2:

    // ------------------------------------------------------------------
    // Test 3: FDIV.D  6.0d / 2.0d = 3.0d
    //   6.0d = 0x4018000000000000
    //   2.0d = 0x4000000000000000
    //   3.0d = 0x4008000000000000
    // ------------------------------------------------------------------
    li      t0, 0x4018000000000000
    fmv.d.x ft0, t0                 // ft0 = 6.0d
    li      t0, 0x4000000000000000
    fmv.d.x ft1, t0                 // ft1 = 2.0d
    fdiv.d  ft2, ft0, ft1           // ft2 = 3.0d
    fmv.x.d t1, ft2
    li      t2, 0x4008000000000000
    beq     t1, t2, 3f
    addi    a0, a0, 1
3:

    // ------------------------------------------------------------------
    // Test 4: FDIV.D  1.0d / 8.0d = 0.125d
    //   1.0d = 0x3FF0000000000000
    //   8.0d = 0x4020000000000000
    //   0.125d = 0x3FC0000000000000
    // ------------------------------------------------------------------
    li      t0, 0x3FF0000000000000
    fmv.d.x ft0, t0                 // ft0 = 1.0d
    li      t0, 0x4020000000000000
    fmv.d.x ft1, t0                 // ft1 = 8.0d
    fdiv.d  ft2, ft0, ft1           // ft2 = 0.125d
    fmv.x.d t1, ft2
    li      t2, 0x3FC0000000000000
    beq     t1, t2, 4f
    addi    a0, a0, 1
4:

    ret
