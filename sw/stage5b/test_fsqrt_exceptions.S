// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// FSQRT exception / FFLAGS tests.
// Checks result and accrued exception flags after each operation.
// FFLAGS (CSR 0x001): NV=0x10, DZ=0x08, OF=0x04, UF=0x02, NX=0x01.
// a0 accumulates the failure count; a0 = 0 means pass.

.section .text
.globl main

main:
    li      a0, 0                   // fail counter

    // ------------------------------------------------------------------
    // Test 1: FSQRT.D  sqrt(-1.0d) = canonical NaN, fflags = NV (0x10)
    // ------------------------------------------------------------------
    csrrw   zero, 0x001, zero       // clear fflags
    li      t0, 0xBFF0000000000000
    fmv.d.x ft0, t0                 // ft0 = -1.0d
    fsqrt.d ft1, ft0
    fmv.x.d t1, ft1
    li      t2, 0x7FF8000000000000  // canonical NaN
    beq     t1, t2, 1f
    addi    a0, a0, 1
1:
    csrrs   t3, 0x001, zero         // read fflags
    li      t4, 0x10                // NV
    beq     t3, t4, 2f
    addi    a0, a0, 1
2:

    // ------------------------------------------------------------------
    // Test 2: FSQRT.D  sqrt(-inf) = canonical NaN, fflags = NV (0x10)
    //   -inf = 0xFFF0000000000000
    // ------------------------------------------------------------------
    csrrw   zero, 0x001, zero
    li      t0, 0xFFF0000000000000
    fmv.d.x ft0, t0                 // ft0 = -inf
    fsqrt.d ft1, ft0
    fmv.x.d t1, ft1
    li      t2, 0x7FF8000000000000  // canonical NaN
    beq     t1, t2, 3f
    addi    a0, a0, 1
3:
    csrrs   t3, 0x001, zero
    li      t4, 0x10                // NV
    beq     t3, t4, 4f
    addi    a0, a0, 1
4:

    // ------------------------------------------------------------------
    // Test 3: FSQRT.D  sqrt(sNaN) = canonical NaN, fflags = NV (0x10)
    //   sNaN = 0x7FF0000000000001
    // ------------------------------------------------------------------
    csrrw   zero, 0x001, zero
    li      t0, 0x7FF0000000000001
    fmv.d.x ft0, t0                 // ft0 = sNaN
    fsqrt.d ft1, ft0
    fmv.x.d t1, ft1
    li      t2, 0x7FF8000000000000  // canonical NaN
    beq     t1, t2, 5f
    addi    a0, a0, 1
5:
    csrrs   t3, 0x001, zero
    li      t4, 0x10                // NV
    beq     t3, t4, 6f
    addi    a0, a0, 1
6:

    // ------------------------------------------------------------------
    // Test 4: FSQRT.D  sqrt(-0.0d) = -0.0d, fflags = 0x00
    // ------------------------------------------------------------------
    csrrw   zero, 0x001, zero
    li      t0, 0x8000000000000000
    fmv.d.x ft0, t0                 // ft0 = -0.0d
    fsqrt.d ft1, ft0
    fmv.x.d t1, ft1
    li      t2, 0x8000000000000000  // -0.0d
    beq     t1, t2, 7f
    addi    a0, a0, 1
7:
    csrrs   t3, 0x001, zero
    li      t4, 0x00                // no flags
    beq     t3, t4, 8f
    addi    a0, a0, 1
8:

    // ------------------------------------------------------------------
    // Test 5: FSQRT.D  sqrt(+0.0d) = +0.0d, fflags = 0x00
    // ------------------------------------------------------------------
    csrrw   zero, 0x001, zero
    li      t0, 0x0000000000000000
    fmv.d.x ft0, t0                 // ft0 = +0.0d
    fsqrt.d ft1, ft0
    fmv.x.d t1, ft1
    li      t2, 0x0000000000000000  // +0.0d
    beq     t1, t2, 9f
    addi    a0, a0, 1
9:
    csrrs   t3, 0x001, zero
    li      t4, 0x00                // no flags
    beq     t3, t4, 10f
    addi    a0, a0, 1
10:

    // ------------------------------------------------------------------
    // Test 6: FSQRT.D  sqrt(+inf) = +inf, fflags = 0x00
    // ------------------------------------------------------------------
    csrrw   zero, 0x001, zero
    li      t0, 0x7FF0000000000000
    fmv.d.x ft0, t0                 // ft0 = +inf
    fsqrt.d ft1, ft0
    fmv.x.d t1, ft1
    li      t2, 0x7FF0000000000000  // +inf
    beq     t1, t2, 11f
    addi    a0, a0, 1
11:
    csrrs   t3, 0x001, zero
    li      t4, 0x00                // no flags
    beq     t3, t4, 12f
    addi    a0, a0, 1
12:

    // ------------------------------------------------------------------
    // Test 7: FSQRT.S  sqrt(-1.0f) = canonical NaN, fflags = NV (0x10)
    // ------------------------------------------------------------------
    csrrw   zero, 0x001, zero
    li      t0, 0xBF800000
    fmv.w.x ft0, t0                 // ft0 = -1.0f
    fsqrt.s ft1, ft0
    fmv.x.w t1, ft1
    li      t2, 0x7FC00000          // canonical NaN (single)
    beq     t1, t2, 13f
    addi    a0, a0, 1
13:
    csrrs   t3, 0x001, zero
    li      t4, 0x10                // NV
    beq     t3, t4, 14f
    addi    a0, a0, 1
14:

    ret
