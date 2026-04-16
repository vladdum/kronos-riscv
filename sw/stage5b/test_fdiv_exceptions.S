// Copyright 2026 Vlad-Dumitru Popescu
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// FDIV exception / FFLAGS tests.
// Checks result and accrued exception flags after each operation.
// FFLAGS (CSR 0x001): NV=0x10, DZ=0x08, OF=0x04, UF=0x02, NX=0x01.
// a0 accumulates the failure count; a0 = 0 means pass.

.section .text
.globl main

main:
    li      a0, 0                   // fail counter

    // ------------------------------------------------------------------
    // Test 1: FDIV.D  1.0d / 0.0d = +inf, fflags = DZ (0x08)
    // ------------------------------------------------------------------
    csrrw   zero, 0x001, zero       // clear fflags
    li      t0, 0x3FF0000000000000
    fmv.d.x ft0, t0                 // ft0 = 1.0d
    li      t0, 0x0000000000000000
    fmv.d.x ft1, t0                 // ft1 = 0.0d
    fdiv.d  ft2, ft0, ft1
    fmv.x.d t1, ft2
    li      t2, 0x7FF0000000000000  // +inf
    beq     t1, t2, 1f
    addi    a0, a0, 1
1:
    csrrs   t3, 0x001, zero         // read fflags
    li      t4, 0x08                // DZ
    beq     t3, t4, 2f
    addi    a0, a0, 1
2:

    // ------------------------------------------------------------------
    // Test 2: FDIV.D  0.0d / 0.0d = canonical NaN, fflags = NV (0x10)
    // ------------------------------------------------------------------
    csrrw   zero, 0x001, zero
    li      t0, 0x0000000000000000
    fmv.d.x ft0, t0                 // ft0 = 0.0d
    fmv.d.x ft1, t0                 // ft1 = 0.0d
    fdiv.d  ft2, ft0, ft1
    fmv.x.d t1, ft2
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
    // Test 3: FDIV.D  inf / inf = canonical NaN, fflags = NV (0x10)
    // ------------------------------------------------------------------
    csrrw   zero, 0x001, zero
    li      t0, 0x7FF0000000000000
    fmv.d.x ft0, t0                 // ft0 = +inf
    fmv.d.x ft1, t0                 // ft1 = +inf
    fdiv.d  ft2, ft0, ft1
    fmv.x.d t1, ft2
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
    // Test 4: FDIV.D  1.0d / sNaN = canonical NaN, fflags = NV (0x10)
    //   sNaN double: 0x7FF0000000000001
    // ------------------------------------------------------------------
    csrrw   zero, 0x001, zero
    li      t0, 0x3FF0000000000000
    fmv.d.x ft0, t0                 // ft0 = 1.0d
    li      t0, 0x7FF0000000000001
    fmv.d.x ft1, t0                 // ft1 = sNaN
    fdiv.d  ft2, ft0, ft1
    fmv.x.d t1, ft2
    li      t2, 0x7FF8000000000000  // canonical NaN
    beq     t1, t2, 7f
    addi    a0, a0, 1
7:
    csrrs   t3, 0x001, zero
    li      t4, 0x10                // NV
    beq     t3, t4, 8f
    addi    a0, a0, 1
8:

    // ------------------------------------------------------------------
    // Test 5: FDIV.S  1.0f / 0.0f = +inf, fflags = DZ (0x08)
    // ------------------------------------------------------------------
    csrrw   zero, 0x001, zero
    li      t0, 0x3F800000
    fmv.w.x ft0, t0                 // ft0 = 1.0f
    li      t0, 0x00000000
    fmv.w.x ft1, t0                 // ft1 = 0.0f
    fdiv.s  ft2, ft0, ft1
    fmv.x.w t1, ft2
    li      t2, 0x7F800000          // +inf (single)
    beq     t1, t2, 9f
    addi    a0, a0, 1
9:
    csrrs   t3, 0x001, zero
    li      t4, 0x08                // DZ
    beq     t3, t4, 10f
    addi    a0, a0, 1
10:

    // ------------------------------------------------------------------
    // Test 6: FDIV.S  0.0f / 0.0f = canonical NaN, fflags = NV (0x10)
    // ------------------------------------------------------------------
    csrrw   zero, 0x001, zero
    li      t0, 0x00000000
    fmv.w.x ft0, t0                 // ft0 = 0.0f
    fmv.w.x ft1, t0                 // ft1 = 0.0f
    fdiv.s  ft2, ft0, ft1
    fmv.x.w t1, ft2
    li      t2, 0x7FC00000          // canonical NaN (single)
    beq     t1, t2, 11f
    addi    a0, a0, 1
11:
    csrrs   t3, 0x001, zero
    li      t4, 0x10                // NV
    beq     t3, t4, 12f
    addi    a0, a0, 1
12:

    ret
