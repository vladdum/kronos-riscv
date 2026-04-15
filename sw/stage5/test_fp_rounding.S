// FP rounding mode tests: use FADD.S with a non-exact result to verify
// that FRM controls the rounding direction.
//
// Test case: 1.0f + 0x1p-25
//   1.0f ULP = 2^-23; adding 2^-25 = 0.25 ULP
//   Exact sum lies between 1.0f and 1.0f+ULP.
//   1.0f = 0x3F800000
//   2^-25 (single) = 0x33000000
//
//   RNE (0): rounds to nearest even → 1.0f (0x3F800000)
//   RTZ (1): truncates toward zero  → 1.0f (0x3F800000)
//   RDN (2): rounds down (floor)    → 1.0f (0x3F800000)
//   RUP (3): rounds up (ceil)       → 1.0f + ULP = 0x3F800001
//
// a0 accumulates the failure count; a0 = 0 means pass.

.section .text
.globl main

main:
    li      a0, 0                   // fail counter

    // Prepare operands: ft0 = 1.0f, ft1 = 2^-25
    li      t0, 0x3F800000
    fmv.w.x ft0, t0
    li      t0, 0x33000000          // 2^-25
    fmv.w.x ft1, t0

    // ------------------------------------------------------------------
    // Test 1: RNE (FRM=0) — result should be 1.0f (round to even)
    // ------------------------------------------------------------------
    csrwi   frm, 0                  // RNE
    fadd.s  ft2, ft0, ft1
    fmv.x.w t1, ft2
    li      t2, 0x3F800000          // expected: 1.0f unchanged
    beq     t1, t2, 1f
    addi    a0, a0, 1
1:

    // ------------------------------------------------------------------
    // Test 2: RUP (FRM=3) — result should round up to 1.0f + 1 ULP
    // ------------------------------------------------------------------
    csrwi   frm, 3                  // RUP
    fadd.s  ft2, ft0, ft1
    fmv.x.w t1, ft2
    li      t2, 0x3F800001          // 1.0f + 1 ULP
    beq     t1, t2, 2f
    addi    a0, a0, 1
2:

    // ------------------------------------------------------------------
    // Test 3: RTZ (FRM=1) — truncate toward zero → 1.0f
    // ------------------------------------------------------------------
    csrwi   frm, 1                  // RTZ
    fadd.s  ft2, ft0, ft1
    fmv.x.w t1, ft2
    li      t2, 0x3F800000
    beq     t1, t2, 3f
    addi    a0, a0, 1
3:

    // ------------------------------------------------------------------
    // Test 4: RDN (FRM=2) — round down → 1.0f
    // ------------------------------------------------------------------
    csrwi   frm, 2                  // RDN
    fadd.s  ft2, ft0, ft1
    fmv.x.w t1, ft2
    li      t2, 0x3F800000
    beq     t1, t2, 4f
    addi    a0, a0, 1
4:

    // Restore default rounding mode
    csrwi   frm, 0

    ret
