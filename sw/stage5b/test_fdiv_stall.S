// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// FDIV pipeline stall test.
// Back-to-back dependent FDIV.D chain: each iteration depends on the
// previous result, forcing the pipeline to stall on every iteration.
// 1024.0 / 2.0^16 = 0.015625 = 2^-6.
// a0 accumulates the failure count; a0 = 0 means pass.

.section .text
.globl main

main:
    li      a0, 0                   // fail counter

    // ------------------------------------------------------------------
    // Test 1: Dependent chain — 1024.0 / 2.0 repeated 16 times
    //   1024.0d = 0x4090000000000000
    //   2.0d    = 0x4000000000000000
    //   result  = 1024 / 65536 = 0.015625 = 2^-6 = 0x3F90000000000000
    // ------------------------------------------------------------------
    li      t0, 0x4090000000000000
    fmv.d.x ft0, t0                 // ft0 = 1024.0d
    li      t0, 0x4000000000000000
    fmv.d.x ft1, t0                 // ft1 = 2.0d
    li      t2, 16                  // loop counter

1:
    fdiv.d  ft0, ft0, ft1           // dependent chain: ft0 = ft0 / 2.0
    addi    t2, t2, -1
    bnez    t2, 1b

    fmv.x.d t1, ft0
    li      t3, 0x3F90000000000000  // 2^-6 = 0.015625
    beq     t1, t3, 2f
    addi    a0, a0, 1
2:

    // ------------------------------------------------------------------
    // Test 2: Mixed FDIV.D + FDIV.S dependent chain
    //   Start: 64.0d, divide by 2.0 four times = 4.0d
    //   Then:  64.0f, divide by 2.0f four times = 4.0f
    // ------------------------------------------------------------------
    li      t0, 0x4050000000000000
    fmv.d.x ft0, t0                 // ft0 = 64.0d
    li      t0, 0x4000000000000000
    fmv.d.x ft1, t0                 // ft1 = 2.0d

    fdiv.d  ft0, ft0, ft1           // 32.0
    fdiv.d  ft0, ft0, ft1           // 16.0
    fdiv.d  ft0, ft0, ft1           // 8.0
    fdiv.d  ft0, ft0, ft1           // 4.0

    fmv.x.d t1, ft0
    li      t3, 0x4010000000000000  // 4.0d
    beq     t1, t3, 3f
    addi    a0, a0, 1
3:

    li      t0, 0x42800000
    fmv.w.x ft0, t0                 // ft0 = 64.0f
    li      t0, 0x40000000
    fmv.w.x ft1, t0                 // ft1 = 2.0f

    fdiv.s  ft0, ft0, ft1           // 32.0f
    fdiv.s  ft0, ft0, ft1           // 16.0f
    fdiv.s  ft0, ft0, ft1           // 8.0f
    fdiv.s  ft0, ft0, ft1           // 4.0f

    fmv.x.w t1, ft0
    li      t3, 0x40800000          // 4.0f
    beq     t1, t3, 4f
    addi    a0, a0, 1
4:

    ret
