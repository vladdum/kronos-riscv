// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// FDIV.S NaN-boxing test.
// Verifies that single-precision results are properly NaN-boxed:
// upper 32 bits of the 64-bit register must be 0xFFFFFFFF.
// a0 accumulates the failure count; a0 = 0 means pass.

.section .text
.globl main

main:
    li      a0, 0                   // fail counter

    // ------------------------------------------------------------------
    // Test 1: FDIV.S  6.0f / 2.0f = 3.0f, check NaN-boxing
    //   6.0f = 0x40C00000
    //   2.0f = 0x40000000
    //   3.0f = 0x40400000
    //   NaN-boxed: 0xFFFFFFFF40400000
    // ------------------------------------------------------------------
    li      t0, 0x40C00000
    fmv.w.x ft0, t0                 // ft0 = 6.0f
    li      t0, 0x40000000
    fmv.w.x ft1, t0                 // ft1 = 2.0f
    fdiv.s  ft2, ft0, ft1           // ft2 = 3.0f
    fmv.x.d t1, ft2                 // read full 64 bits
    li      t2, 0xFFFFFFFF40400000  // NaN-boxed 3.0f
    beq     t1, t2, 1f
    addi    a0, a0, 1
1:

    // ------------------------------------------------------------------
    // Test 2: FSQRT.S  sqrt(16.0f) = 4.0f, check NaN-boxing
    //   16.0f = 0x41800000
    //   4.0f  = 0x40800000
    //   NaN-boxed: 0xFFFFFFFF40800000
    // ------------------------------------------------------------------
    li      t0, 0x41800000
    fmv.w.x ft0, t0                 // ft0 = 16.0f
    fsqrt.s ft1, ft0                // ft1 = 4.0f
    fmv.x.d t1, ft1                 // read full 64 bits
    li      t2, 0xFFFFFFFF40800000  // NaN-boxed 4.0f
    beq     t1, t2, 2f
    addi    a0, a0, 1
2:

    // ------------------------------------------------------------------
    // Test 3: FDIV.S  1.0f / 0.0f = +inf, check NaN-boxing
    //   +inf single = 0x7F800000
    //   NaN-boxed: 0xFFFFFFFF7F800000
    // ------------------------------------------------------------------
    li      t0, 0x3F800000
    fmv.w.x ft0, t0                 // ft0 = 1.0f
    li      t0, 0x00000000
    fmv.w.x ft1, t0                 // ft1 = 0.0f
    fdiv.s  ft2, ft0, ft1           // ft2 = +inf
    fmv.x.d t1, ft2                 // read full 64 bits
    li      t2, 0xFFFFFFFF7F800000  // NaN-boxed +inf
    beq     t1, t2, 3f
    addi    a0, a0, 1
3:

    ret
