// NaN-boxing: FLW must set upper 32 bits of FP register to 0xFFFFFFFF.
// Read back via fmv.x.d and check bits [63:32].
// a0 accumulates the failure count; a0 = 0 means pass.

.section .text
.globl main

main:
    li      a0, 0                   // fail counter
    la      t6, data

    // ------------------------------------------------------------------
    // Test 1: NaN-box of 0.0f — lower word = 0x00000000
    //   Upper 32 bits of FP reg must be 0xFFFFFFFF after FLW.
    //   fmv.x.d gives the full 64-bit view.
    //   Expected: 0xFFFFFFFF00000000
    // ------------------------------------------------------------------
    li      t0, 0x00000000
    fmv.w.x ft0, t0                 // set ft0 = 0.0f
    fsw     ft0, 0(t6)              // write to memory
    flw     ft1, 0(t6)              // reload — NaN-boxing must apply
    fmv.x.d t1, ft1                 // read full 64-bit register
    li      t2, 0xFFFFFFFF00000000
    beq     t1, t2, 1f
    addi    a0, a0, 1
1:

    // ------------------------------------------------------------------
    // Test 2: NaN-box of 1.0f = 0x3F800000
    //   Expected: 0xFFFFFFFF3F800000
    // ------------------------------------------------------------------
    li      t0, 0x3F800000
    fmv.w.x ft0, t0
    fsw     ft0, 0(t6)
    flw     ft1, 0(t6)
    fmv.x.d t1, ft1
    li      t2, 0xFFFFFFFF3F800000
    beq     t1, t2, 2f
    addi    a0, a0, 1
2:

    // ------------------------------------------------------------------
    // Test 3: NaN-box of 0xDEADBEEF (arbitrary pattern)
    //   Expected: 0xFFFFFFFFDEADBEEF
    // ------------------------------------------------------------------
    li      t0, 0xDEADBEEF
    fmv.w.x ft0, t0
    fsw     ft0, 0(t6)
    flw     ft1, 0(t6)
    fmv.x.d t1, ft1
    li      t2, 0xFFFFFFFFDEADBEEF
    beq     t1, t2, 3f
    addi    a0, a0, 1
3:

    ret

.section .data
.align 3
data:
    .zero 8
