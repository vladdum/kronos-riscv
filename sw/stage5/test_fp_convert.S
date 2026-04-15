// FP conversion tests: FCVT.W.S, FCVT.S.W, FCVT.D.S, FCVT.S.D
// a0 accumulates the failure count; a0 = 0 means pass.

.section .text
.globl main

main:
    li      a0, 0                   // fail counter

    // Set RTZ rounding for integer conversions
    csrwi   frm, 1                  // RTZ

    // ------------------------------------------------------------------
    // Test 1: FCVT.W.S  2.5f → 2 (truncate toward zero)
    //   2.5f = 0x40200000
    // ------------------------------------------------------------------
    li      t0, 0x40200000
    fmv.w.x ft0, t0                 // ft0 = 2.5f
    fcvt.w.s t1, ft0, rtz           // convert to int, truncate
    li      t2, 2
    beq     t1, t2, 1f
    addi    a0, a0, 1
1:

    // ------------------------------------------------------------------
    // Test 2: FCVT.W.S  -3.25f → -3 (truncate toward zero)
    //   -3.25f = 0xC0500000
    // ------------------------------------------------------------------
    li      t0, 0xC0500000
    fmv.w.x ft0, t0                 // ft0 = -3.25f
    fcvt.w.s t1, ft0, rtz
    li      t2, -3
    beq     t1, t2, 2f
    addi    a0, a0, 1
2:

    // ------------------------------------------------------------------
    // Test 3: FCVT.S.W  7 → 7.0f = 0x40E00000
    // ------------------------------------------------------------------
    li      t0, 7
    fcvt.s.w ft0, t0
    fmv.x.w t1, ft0
    li      t2, 0x40E00000
    beq     t1, t2, 3f
    addi    a0, a0, 1
3:

    // ------------------------------------------------------------------
    // Test 4: FCVT.D.S  1.0f → 1.0d
    //   1.0f = 0x3F800000
    //   1.0d = 0x3FF0000000000000
    // ------------------------------------------------------------------
    li      t0, 0x3F800000
    fmv.w.x ft0, t0                 // ft0 = 1.0f
    fcvt.d.s ft1, ft0               // ft1 = 1.0d
    fmv.x.d t1, ft1
    li      t2, 0x3FF0000000000000
    beq     t1, t2, 4f
    addi    a0, a0, 1
4:

    // ------------------------------------------------------------------
    // Test 5: FCVT.S.D  2.0d → 2.0f
    //   2.0d = 0x4000000000000000
    //   2.0f = 0x40000000
    // ------------------------------------------------------------------
    li      t0, 0x4000000000000000
    fmv.d.x ft0, t0                 // ft0 = 2.0d
    fcvt.s.d ft1, ft0               // ft1 = 2.0f (NaN-boxed)
    fmv.x.w t1, ft1                 // read lower 32 bits
    li      t2, 0x40000000
    beq     t1, t2, 5f
    addi    a0, a0, 1
5:

    // Restore default rounding mode
    csrwi   frm, 0

    ret
