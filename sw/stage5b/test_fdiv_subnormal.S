// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// FDIV subnormal result tests.
// Uses exact power-of-2 divisions to produce subnormal outputs.
// a0 accumulates the failure count; a0 = 0 means pass.

.section .text
.globl main

main:
    li      a0, 0                   // fail counter

    // ------------------------------------------------------------------
    // Test 1: FDIV.D  smallest-normal / 2.0 = subnormal (exact)
    //   smallest normal double = 2^-1022 = 0x0010000000000000
    //   2.0d = 0x4000000000000000
    //   result = 2^-1023 = 0x0008000000000000 (subnormal, exact)
    //   fflags = 0x00
    // ------------------------------------------------------------------
    csrrw   zero, 0x001, zero       // clear fflags
    li      t0, 0x0010000000000000
    fmv.d.x ft0, t0                 // ft0 = 2^-1022
    li      t0, 0x4000000000000000
    fmv.d.x ft1, t0                 // ft1 = 2.0d
    fdiv.d  ft2, ft0, ft1
    fmv.x.d t1, ft2
    li      t2, 0x0008000000000000  // 2^-1023
    beq     t1, t2, 1f
    addi    a0, a0, 1
1:
    csrrs   t3, 0x001, zero         // read fflags
    li      t4, 0x00                // no flags (exact)
    beq     t3, t4, 2f
    addi    a0, a0, 1
2:

    // ------------------------------------------------------------------
    // Test 2: FDIV.S  smallest-normal / 2.0f = subnormal (exact)
    //   smallest normal float = 2^-126 = 0x00800000
    //   2.0f = 0x40000000
    //   result = 2^-127 = 0x00400000 (subnormal, exact)
    //   fflags = 0x00
    // ------------------------------------------------------------------
    csrrw   zero, 0x001, zero
    li      t0, 0x00800000
    fmv.w.x ft0, t0                 // ft0 = 2^-126
    li      t0, 0x40000000
    fmv.w.x ft1, t0                 // ft1 = 2.0f
    fdiv.s  ft2, ft0, ft1
    fmv.x.w t1, ft2
    li      t2, 0x00400000          // 2^-127
    beq     t1, t2, 3f
    addi    a0, a0, 1
3:
    csrrs   t3, 0x001, zero
    li      t4, 0x00                // no flags (exact)
    beq     t3, t4, 4f
    addi    a0, a0, 1
4:

    // ------------------------------------------------------------------
    // Test 3: FDIV.D  smallest-normal / 4.0 = deeper subnormal (exact)
    //   4.0d = 0x4010000000000000
    //   result = 2^-1024 = 0x0004000000000000
    //   fflags = 0x00
    // ------------------------------------------------------------------
    csrrw   zero, 0x001, zero
    li      t0, 0x0010000000000000
    fmv.d.x ft0, t0                 // ft0 = 2^-1022
    li      t0, 0x4010000000000000
    fmv.d.x ft1, t0                 // ft1 = 4.0d
    fdiv.d  ft2, ft0, ft1
    fmv.x.d t1, ft2
    li      t2, 0x0004000000000000  // 2^-1024
    beq     t1, t2, 5f
    addi    a0, a0, 1
5:
    csrrs   t3, 0x001, zero
    li      t4, 0x00                // no flags (exact)
    beq     t3, t4, 6f
    addi    a0, a0, 1
6:

    // ------------------------------------------------------------------
    // Test 4: FDIV.S  smallest-normal / 4.0f = deeper subnormal (exact)
    //   4.0f = 0x40800000
    //   result = 2^-128 = 0x00200000
    //   fflags = 0x00
    // ------------------------------------------------------------------
    csrrw   zero, 0x001, zero
    li      t0, 0x00800000
    fmv.w.x ft0, t0                 // ft0 = 2^-126
    li      t0, 0x40800000
    fmv.w.x ft1, t0                 // ft1 = 4.0f
    fdiv.s  ft2, ft0, ft1
    fmv.x.w t1, ft2
    li      t2, 0x00200000          // 2^-128
    beq     t1, t2, 7f
    addi    a0, a0, 1
7:
    csrrs   t3, 0x001, zero
    li      t4, 0x00                // no flags (exact)
    beq     t3, t4, 8f
    addi    a0, a0, 1
8:

    ret
