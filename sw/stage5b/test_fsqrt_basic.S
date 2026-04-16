// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Basic FSQRT.S, FSQRT.D with exact results (no rounding needed).
// a0 accumulates the failure count; a0 = 0 means pass.

.section .text
.globl main

main:
    li      a0, 0                   // fail counter

    // ------------------------------------------------------------------
    // Test 1: FSQRT.S  sqrt(4.0f) = 2.0f
    //   4.0f = 0x40800000
    //   2.0f = 0x40000000
    // ------------------------------------------------------------------
    li      t0, 0x40800000
    fmv.w.x ft0, t0                 // ft0 = 4.0f
    fsqrt.s ft1, ft0                // ft1 = 2.0f
    fmv.x.w t1, ft1
    li      t2, 0x40000000
    beq     t1, t2, 1f
    addi    a0, a0, 1
1:

    // ------------------------------------------------------------------
    // Test 2: FSQRT.S  sqrt(16.0f) = 4.0f
    //   16.0f = 0x41800000
    //   4.0f  = 0x40800000
    // ------------------------------------------------------------------
    li      t0, 0x41800000
    fmv.w.x ft0, t0                 // ft0 = 16.0f
    fsqrt.s ft1, ft0                // ft1 = 4.0f
    fmv.x.w t1, ft1
    li      t2, 0x40800000
    beq     t1, t2, 2f
    addi    a0, a0, 1
2:

    // ------------------------------------------------------------------
    // Test 3: FSQRT.D  sqrt(4.0d) = 2.0d
    //   4.0d = 0x4010000000000000
    //   2.0d = 0x4000000000000000
    // ------------------------------------------------------------------
    li      t0, 0x4010000000000000
    fmv.d.x ft0, t0                 // ft0 = 4.0d
    fsqrt.d ft1, ft0                // ft1 = 2.0d
    fmv.x.d t1, ft1
    li      t2, 0x4000000000000000
    beq     t1, t2, 3f
    addi    a0, a0, 1
3:

    // ------------------------------------------------------------------
    // Test 4: FSQRT.D  sqrt(9.0d) = 3.0d
    //   9.0d = 0x4022000000000000
    //   3.0d = 0x4008000000000000
    // ------------------------------------------------------------------
    li      t0, 0x4022000000000000
    fmv.d.x ft0, t0                 // ft0 = 9.0d
    fsqrt.d ft1, ft0                // ft1 = 3.0d
    fmv.x.d t1, ft1
    li      t2, 0x4008000000000000
    beq     t1, t2, 4f
    addi    a0, a0, 1
4:

    ret
