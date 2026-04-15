// FP load/store round-trips: FLW, FLD, FSW, FSD.
// Stores known bit patterns to memory, loads back, compares.
// a0 accumulates the failure count; a0 = 0 means pass.

.section .text
.globl main

main:
    li      a0, 0                   // fail counter
    la      t6, data

    // ------------------------------------------------------------------
    // Test 1: FSW/FLW round-trip — 1.0f (0x3F800000)
    // ------------------------------------------------------------------
    li      t0, 0x3F800000
    fmv.w.x ft0, t0                 // ft0 = 1.0f
    fsw     ft0, 0(t6)              // store to data[0]
    flw     ft1, 0(t6)              // load back
    fmv.x.w t1, ft1
    beq     t0, t1, 1f
    addi    a0, a0, 1
1:

    // ------------------------------------------------------------------
    // Test 2: FSW/FLW round-trip — 0x40C00000 (6.0f)
    // ------------------------------------------------------------------
    li      t0, 0x40C00000
    fmv.w.x ft0, t0
    fsw     ft0, 4(t6)              // store at byte offset 4
    flw     ft1, 4(t6)
    fmv.x.w t1, ft1
    beq     t0, t1, 2f
    addi    a0, a0, 1
2:

    // ------------------------------------------------------------------
    // Test 3: FSD/FLD round-trip — 1.0d (0x3FF0000000000000)
    // ------------------------------------------------------------------
    li      t0, 0x3FF0000000000000
    fmv.d.x ft0, t0                 // ft0 = 1.0d
    fsd     ft0, 8(t6)              // store at byte offset 8
    fld     ft1, 8(t6)              // load back
    fmv.x.d t1, ft1
    beq     t0, t1, 3f
    addi    a0, a0, 1
3:

    // ------------------------------------------------------------------
    // Test 4: FSD/FLD round-trip — 0xDEADBEEFCAFEBABE
    // ------------------------------------------------------------------
    li      t0, 0xDEADBEEFCAFEBABE
    fmv.d.x ft0, t0
    fsd     ft0, 16(t6)
    fld     ft1, 16(t6)
    fmv.x.d t1, ft1
    beq     t0, t1, 4f
    addi    a0, a0, 1
4:

    // ------------------------------------------------------------------
    // Test 5: FSW/FLW at non-zero offset within block (byte offset 12)
    // ------------------------------------------------------------------
    li      t0, 0x41200000          // 10.0f
    fmv.w.x ft0, t0
    fsw     ft0, 12(t6)
    flw     ft1, 12(t6)
    fmv.x.w t1, ft1
    beq     t0, t1, 5f
    addi    a0, a0, 1
5:

    ret

.section .data
.align 3
data:
    .zero 64
