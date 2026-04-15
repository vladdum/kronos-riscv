// FP CSR tests: FFLAGS, FRM, FCSR read/write and exception flag checks.
// a0 accumulates the failure count; a0 = 0 means pass.

.section .text
.globl main

main:
    li      a0, 0                   // fail counter

    // ------------------------------------------------------------------
    // Test 1: Write 0x1F to FCSR (all exception flags + RNE), read back
    //   FCSR layout: [7:5] FRM, [4:0] FFLAGS
    //   Writing 0x1F sets all 5 exception flags with FRM=0.
    // ------------------------------------------------------------------
    li      t0, 0x1F
    csrw    fcsr, t0
    csrr    t1, fcsr
    andi    t1, t1, 0xFF            // keep lower 8 bits (FRM+FFLAGS)
    beq     t0, t1, 1f
    addi    a0, a0, 1
1:

    // ------------------------------------------------------------------
    // Test 2: Write FRM=3 (RUP) via FRM CSR, read back
    // ------------------------------------------------------------------
    csrwi   frm, 3
    csrr    t1, frm
    li      t2, 3
    beq     t1, t2, 2f
    addi    a0, a0, 1
2:

    // ------------------------------------------------------------------
    // Test 3: Clear FFLAGS, perform inexact FADD.S, check NX bit is set.
    //   1.0f + 2^-25 is inexact; the NX (inexact) flag = bit 0 of FFLAGS.
    //   Restore RNE first so the result is well-defined.
    // ------------------------------------------------------------------
    csrwi   frm, 0                  // RNE
    csrwi   fflags, 0               // clear all exception flags
    li      t0, 0x3F800000
    fmv.w.x ft0, t0                 // ft0 = 1.0f
    li      t0, 0x33000000          // 2^-25
    fmv.w.x ft1, t0
    fadd.s  ft2, ft0, ft1           // inexact result — NX should be raised
    csrr    t1, fflags
    andi    t1, t1, 0x1             // NX = bit 0
    li      t2, 1
    beq     t1, t2, 3f
    addi    a0, a0, 1
3:

    // ------------------------------------------------------------------
    // Test 4: Write a pattern to FFLAGS, read back via FCSR lower bits
    //   Write 0x15 (NV|NX|NZ bits) to FFLAGS, confirm via FCSR
    // ------------------------------------------------------------------
    li      t0, 0x15
    csrw    fflags, t0
    csrr    t1, fcsr
    andi    t1, t1, 0x1F            // mask FFLAGS portion of FCSR
    beq     t0, t1, 4f
    addi    a0, a0, 1
4:

    // Restore clean state
    csrwi   fcsr, 0

    ret
